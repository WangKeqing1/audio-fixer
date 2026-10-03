import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json_api_client.dart';

class ApiResponse {
  const ApiResponse(this.statusCode, this.body, {this.headers = const {}});
  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

typedef ApiTransport = Future<ApiResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// Low-volume, public metadata transport. A cache directory must be private to
/// the app; it contains query metadata and public JSON, never audio or headers.
/// Share one client across the app so all sources use the same request budget.
class HttpJsonApiClient implements JsonApiClient {
  HttpJsonApiClient({
    ApiTransport? transport,
    DateTime Function()? now,
    Future<void> Function(Duration)? pause,
    Duration requestTimeout = const Duration(seconds: 12),
    this._cacheDirectory,
    this.cacheTtl = const Duration(hours: 24),
    this.negativeCacheTtl = const Duration(minutes: 10),
    this.maxCacheEntries = 256,
    this.maxCacheBytes = 4 * 1024 * 1024,
    this.maxInFlightRequests = 128,
  }) : assert(requestTimeout > Duration.zero),
       assert(cacheTtl >= Duration.zero),
       assert(negativeCacheTtl >= Duration.zero),
       assert(maxCacheEntries >= 0),
       assert(maxCacheBytes >= 0),
       assert(maxInFlightRequests > 0),
       _transport = transport ?? _send,
       _now = now ?? DateTime.now,
       _pause = pause ?? Future<void>.delayed,
       _requestTimeout = requestTimeout;

  final ApiTransport _transport;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _pause;
  final Duration _requestTimeout;
  final Directory? _cacheDirectory;
  final Duration cacheTtl;
  final Duration negativeCacheTtl;
  final int maxCacheEntries;
  final int maxCacheBytes;
  final int maxInFlightRequests;
  final _nextRequest = <String, DateTime>{};
  final _cooldowns = <String, _Cooldown>{};
  final _tails = <String, Future<void>>{};
  final _inFlight = <String, Future<String>>{};
  final _cache = <String, _CachedJson>{};
  Future<void>? _ready;
  int _cacheBytes = 0;

  static const userAgent =
      'AudioFixer/0.2.0 (Android; https://github.com/WangKeqing1/audio-fixer)';
  static const _headers = {
    'User-Agent': userAgent,
    'Accept': 'application/json',
  };
  static const _providers = {
    'musicbrainz.org',
    'lrclib.net',
    'coverartarchive.org',
    'archive.org',
    'music.163.com',
  };
  static const _cacheFileName = 'source-http-cache-v1.json';
  static final _directoryWrites = <String, Future<void>>{};

  @override
  Future<Object?> getJson(Uri uri) async {
    if (!_allowed(uri)) throw const ApiException('数据源地址不可用。');
    // Fragments are not transmitted. Preserve every query byte, including
    // duration/album and repeated parameters: cache hits never relax identity.
    uri = uri.removeFragment().normalizePath();
    final key = uri.toString();
    await (_ready ??= _load());
    final cacheable = _cacheable(uri);
    if (cacheable) {
      final cached = _cache.remove(key);
      if (cached != null) {
        if (_now().isBefore(cached.expiresAt)) {
          _cache[key] = cached; // In-memory LRU, without a disk write per hit.
          return jsonDecode(cached.json);
        }
        _cacheBytes -= cached.bytes;
      }
    }
    var operation = _inFlight[key];
    if (operation == null) {
      if (_inFlight.length >= maxInFlightRequests) {
        throw const ApiException('待查询项目过多，请等待当前查询完成。');
      }
      operation = _getAndCache(uri, key, cacheable);
      _inFlight[key] = operation;
      final current = operation;
      // Handle both outcomes on the cleanup future, so failed deduplicated
      // requests cannot create an unhandled asynchronous error.
      unawaited(
        operation.then<void>(
          (_) {
            if (identical(_inFlight[key], current)) _inFlight.remove(key);
          },
          onError: (Object _, StackTrace _) {
            if (identical(_inFlight[key], current)) _inFlight.remove(key);
          },
        ),
      );
    }
    // Each caller owns its decoded result. Mutating one result cannot poison
    // another caller or the cache.
    return jsonDecode(await operation);
  }

  Future<String> _getAndCache(Uri uri, String key, bool cacheable) async {
    final value = await _get(uri);
    final encoded = jsonEncode(value);
    if (cacheable) {
      final ttl = _isEmpty(value, uri) ? negativeCacheTtl : cacheTtl;
      if (ttl > Duration.zero) {
        final entry = _CachedJson(key, encoded, _now().add(ttl));
        _prune();
        if (maxCacheEntries > 0 && entry.bytes <= maxCacheBytes) {
          final previous = _cache.remove(key);
          if (previous != null) _cacheBytes -= previous.bytes;
          _cache[key] = entry;
          _cacheBytes += entry.bytes;
          _prune();
          await _persist();
        }
      }
    }
    return encoded;
  }

  // Each provider is independent. Archive redirect hosts share one budget.
  Future<ApiResponse> _queueRequest(Uri uri) {
    final provider = _provider(uri);
    final operation = (_tails[provider] ?? Future<void>.value()).then(
      (_) => _request(uri, provider),
    );
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[provider] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[provider], tail)) _tails.remove(provider);
      }),
    );
    return operation;
  }

  Future<ApiResponse> _request(Uri uri, String provider) async {
    _checkCooldown(provider);
    final next = _nextRequest[provider];
    if (next != null && _now().isBefore(next)) {
      await _pause(next.difference(_now()));
    }
    _checkCooldown(provider);
    try {
      final ApiResponse response;
      try {
        response = await _transport(uri, _headers).timeout(_requestTimeout);
      } on TimeoutException {
        throw const ApiException('连接超时，请检查网络后重试。');
      } on SocketException {
        throw const ApiException('无法连接数据源，请检查网络。');
      } on HandshakeException {
        throw const ApiException('无法建立安全连接。');
      } on HttpException {
        throw const ApiException('网络响应中断，请稍后重试。');
      }
      var failureStatus = response.statusCode;
      var providerFailure = false;
      // NetEase can report rate limiting in an HTTP 200 JSON envelope.
      if (provider == 'music.163.com' && response.statusCode == 200) {
        try {
          final body = jsonDecode(response.body);
          if (body is! Map || body['code'] != 200) {
            final code = body is Map
                ? int.tryParse(body['code'].toString())
                : null;
            if (code == null || code == 200) {
              throw const ApiException('网易云响应格式异常，已停止请求。');
            }
            failureStatus = code;
            providerFailure = true;
          }
        } on FormatException {
          throw const ApiException('网易云响应格式异常，已停止请求。');
        }
      }
      if (failureStatus == 429 || failureStatus == 503 || providerFailure) {
        final until = await _recordFailure(
          provider,
          statusCode: failureStatus,
          retryAfter: _header(response, 'retry-after'),
        );
        throw ApiException(
          const {301, 401, 403}.contains(failureStatus)
              ? '数据源当前不允许匿名访问，已停止请求。'
              : '数据源暂时繁忙，请稍后重试。',
          statusCode: failureStatus,
          retryAfter: until,
        );
      }
      if (response.statusCode == 200 || response.statusCode == 404) {
        if (_cooldowns.remove(provider) != null) await _persist();
      }
      return response;
    } on ApiException catch (error) {
      // Rate-limit errors were already recorded above. Network failures also
      // cool down the provider; callers decide when to try again, never us.
      if (error.retryAfter != null) rethrow;
      final until = await _recordFailure(provider);
      throw ApiException(
        error.message,
        statusCode: error.statusCode,
        retryAfter: until,
      );
    } finally {
      // LRCLIB requests must finish sequentially with a 200–500ms gap:
      // https://lrclib.net/docs#request-throttling
      _nextRequest[provider] = _now().add(
        Duration(
          milliseconds:
              provider == 'musicbrainz.org' || provider == 'music.163.com'
              ? 1100
              : 400,
        ),
      );
    }
  }

  void _checkCooldown(String provider) {
    final cooldown = _cooldowns[provider];
    if (cooldown == null || !_now().isBefore(cooldown.until)) return;
    final seconds = (cooldown.until.difference(_now()).inMilliseconds / 1000)
        .ceil();
    throw ApiException(
      '数据源暂时繁忙，请 $seconds 秒后重试。',
      statusCode: cooldown.statusCode,
      retryAfter: cooldown.until,
    );
  }

  Future<DateTime> _recordFailure(
    String provider, {
    int? statusCode,
    String? retryAfter,
  }) async {
    final now = _now();
    final previous = _cooldowns[provider];
    final failures =
        previous != null &&
            now.difference(previous.updatedAt) < const Duration(hours: 24)
        ? (previous.failures + 1).clamp(1, 16)
        : 1;
    final seconds = (30 * (1 << (failures - 1))).clamp(30, 1800);
    var until = now.add(Duration(seconds: seconds));
    final serverUntil = _parseRetryAfter(retryAfter, now);
    if (serverUntil != null && serverUntil.isAfter(until)) until = serverUntil;
    _cooldowns[provider] = _Cooldown(until, now, failures, statusCode);
    await _persist();
    return until;
  }

  static DateTime? _parseRetryAfter(String? value, DateTime now) {
    if (value == null) return null;
    value = value.trim();
    if (RegExp(r'^\d+$').hasMatch(value)) {
      final seconds = BigInt.tryParse(value);
      if (seconds == null) return null;
      // Avoid integer overflow without turning an enormous server cooldown
      // into a short delay. Year 9999 is effectively disabled for this client.
      final maximum = DateTime.utc(9999, 12, 31);
      final remaining = maximum.difference(now).inSeconds;
      if (seconds >= BigInt.from(remaining)) return maximum;
      return now.add(Duration(seconds: seconds.toInt()));
    }
    try {
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  String? _header(ApiResponse response, String name) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  Future<Object?> _get(Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!_allowed(uri)) throw const ApiException('数据源地址不可用。');
      final response = await _queueRequest(uri);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = _header(response, 'location');
        if (location == null) throw const ApiException('数据源返回了无效的跳转。');
        try {
          uri = uri.resolve(location).removeFragment().normalizePath();
        } on FormatException {
          throw const ApiException('数据源返回了无效的跳转。');
        }
        continue;
      }
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw ApiException(
          '数据源请求失败（HTTP ${response.statusCode}）。',
          statusCode: response.statusCode,
        );
      }
      try {
        return jsonDecode(response.body);
      } on FormatException {
        throw const ApiException('数据源响应格式异常。');
      }
    }
    throw const ApiException('数据源跳转次数过多。');
  }

  static bool _allowed(Uri uri) =>
      uri.scheme == 'https' &&
      !uri.hasPort &&
      uri.userInfo.isEmpty &&
      (_providers.contains(uri.host) || uri.host.endsWith('.archive.org')) &&
      (uri.host != 'music.163.com' ||
          const {
            '/api/search/get',
            '/api/song/lyric',
            '/api/song/detail',
          }.contains(uri.path));

  static String _provider(Uri uri) =>
      uri.host.endsWith('.archive.org') ? 'archive.org' : uri.host;

  static bool _cacheable(Uri uri) => !uri.queryParameters.keys.any((key) {
    final lower = key.toLowerCase();
    return lower.contains('token') ||
        lower.contains('secret') ||
        lower.contains('password') ||
        lower.contains('credential') ||
        lower.contains('authorization') ||
        lower == 'api_key' ||
        lower == 'apikey' ||
        lower == 'signature';
  });

  static bool _isEmpty(Object? value, Uri uri) {
    if (value == null || value == '') return true;
    if (value is List) return value.isEmpty;
    if (value is Map) {
      if (uri.host == 'music.163.com' && value['code'] == 200) {
        if (uri.path == '/api/search/get') {
          final result = value['result'];
          final songs = result is Map ? result['songs'] : null;
          return songs == null || (songs is List && songs.isEmpty);
        }
        if (uri.path == '/api/song/detail') {
          final songs = value['songs'];
          return songs == null || (songs is List && songs.isEmpty);
        }
        if (uri.path == '/api/song/lyric') {
          final lrc = value['lrc'];
          final lyric = lrc is Map ? lrc['lyric'] : null;
          return value['nolyric'] == true ||
              value['uncollected'] == true ||
              lyric == null ||
              (lyric is String && lyric.trim().isEmpty);
        }
      }
      if (value.isEmpty) return true;
      for (final key in ['recordings', 'images']) {
        if (value[key] is List && (value[key] as List).isEmpty) return true;
      }
      if (value.containsKey('plainLyrics') ||
          value.containsKey('syncedLyrics')) {
        bool blank(Object? lyric) =>
            lyric == null || (lyric is String && lyric.trim().isEmpty);
        return value['instrumental'] != true &&
            blank(value['plainLyrics']) &&
            blank(value['syncedLyrics']);
      }
    }
    return false;
  }

  void _prune() {
    final expired = _cache.values
        .where((entry) => !_now().isBefore(entry.expiresAt))
        .map((entry) => entry.key)
        .toList();
    for (final key in expired) {
      _cacheBytes -= _cache.remove(key)!.bytes;
    }
    while (_cache.length > maxCacheEntries || _cacheBytes > maxCacheBytes) {
      _cacheBytes -= _cache.remove(_cache.keys.first)!.bytes;
    }
    _cooldowns.removeWhere(
      (_, value) =>
          !value.until.isAfter(_now()) &&
          _now().difference(value.updatedAt) >= const Duration(hours: 24),
    );
  }

  Future<void> _load() async {
    final directory = _cacheDirectory;
    if (directory == null) return;
    try {
      final file = File('${directory.path}/$_cacheFileName');
      if (!await file.exists() ||
          await file.length() > maxCacheBytes + 64 * 1024) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1) return;
      final responses = data['responses'];
      if (responses is List) {
        for (final raw in responses.take(maxCacheEntries)) {
          if (raw is! Map ||
              raw['key'] is! String ||
              raw['json'] is! String ||
              raw['expiresAt'] is! String) {
            continue;
          }
          final uri = Uri.tryParse(raw['key'] as String);
          final expires = DateTime.tryParse(raw['expiresAt'] as String);
          if (uri == null ||
              !_allowed(uri) ||
              !_cacheable(uri) ||
              expires == null ||
              !expires.isAfter(_now())) {
            continue;
          }
          try {
            jsonDecode(raw['json'] as String);
          } on FormatException {
            continue;
          }
          final entry = _CachedJson(
            uri.toString(),
            raw['json'] as String,
            expires,
          );
          if (entry.bytes > maxCacheBytes) continue;
          final previous = _cache.remove(entry.key);
          if (previous != null) _cacheBytes -= previous.bytes;
          _cache[entry.key] = entry;
          _cacheBytes += entry.bytes;
        }
      }
      final cooldowns = data['cooldowns'];
      if (cooldowns is Map) {
        for (final provider in _providers) {
          final raw = cooldowns[provider];
          if (raw is! Map ||
              raw['until'] is! String ||
              raw['updatedAt'] is! String ||
              raw['failures'] is! int) {
            continue;
          }
          final until = DateTime.tryParse(raw['until'] as String);
          final updated = DateTime.tryParse(raw['updatedAt'] as String);
          if (until == null || updated == null) continue;
          _cooldowns[provider] = _Cooldown(
            until,
            updated,
            (raw['failures'] as int).clamp(1, 16),
            raw['statusCode'] is int ? raw['statusCode'] as int : null,
          );
        }
      }
      _prune();
    } on FileSystemException {
      // Read-only/full storage must never break online lookups.
    } on FormatException {
      // An interrupted or old/corrupt cache is disposable.
    }
  }

  Future<void> _persist() {
    final directory = _cacheDirectory;
    if (directory == null) return Future<void>.value();
    final path = directory.absolute.path;
    final operation = (_directoryWrites[path] ?? Future<void>.value()).then((
      _,
    ) async {
      File? temporary;
      try {
        _prune();
        final data = jsonEncode({
          'version': 1,
          'responses': _cache.values.map((entry) => entry.toJson()).toList(),
          'cooldowns': _cooldowns.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
        });
        await directory.create(recursive: true);
        // One fixed staging file bounds disk usage even after a crash. Writes
        // to a directory are serialized across replacing client instances.
        temporary = File('${directory.path}/$_cacheFileName.tmp');
        await temporary.writeAsString(data, flush: true);
        await temporary.rename('${directory.path}/$_cacheFileName');
      } on FileSystemException {
        // Persistence is best effort; the in-memory budget remains active.
      } finally {
        if (temporary != null) {
          try {
            if (await temporary.exists()) await temporary.delete();
          } on FileSystemException {
            // A failed cleanup must not replace the lookup's actual result.
          }
        }
      }
    });
    _directoryWrites[path] = operation;
    unawaited(
      operation.then<void>((_) {
        if (identical(_directoryWrites[path], operation)) {
          _directoryWrites.remove(path);
        }
      }),
    );
    return operation;
  }

  static Future<ApiResponse> _send(Uri uri, Map<String, String> headers) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await _readResponse(
        client,
        uri,
        headers,
      ).timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }

  static Future<ApiResponse> _readResponse(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    headers.forEach((key, value) => request.headers.set(key, value));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const ApiException('数据源响应过大，已停止读取。');
      }
      bytes.addAll(chunk);
    }
    return ApiResponse(
      response.statusCode,
      utf8.decode(bytes, allowMalformed: true),
      headers: {
        'location': ?response.headers.value('location'),
        'retry-after': ?response.headers.value('retry-after'),
      },
    );
  }
}

class _CachedJson {
  _CachedJson(this.key, this.json, this.expiresAt) {
    bytes = utf8.encode(jsonEncode(toJson())).length + 1;
  }
  final String key;
  final String json;
  final DateTime expiresAt;
  late final int bytes;
  Map<String, Object?> toJson() => {
    'key': key,
    'json': json,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

class _Cooldown {
  const _Cooldown(this.until, this.updatedAt, this.failures, this.statusCode);
  final DateTime until;
  final DateTime updatedAt;
  final int failures;
  final int? statusCode;
  Map<String, Object?> toJson() => {
    'until': until.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'failures': failures,
    'statusCode': statusCode,
  };
}

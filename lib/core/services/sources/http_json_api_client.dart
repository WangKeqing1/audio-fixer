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

class HttpJsonApiClient implements JsonApiClient {
  HttpJsonApiClient({
    ApiTransport? transport,
    DateTime Function()? now,
    Future<void> Function(Duration)? pause,
    this._requestTimeout = const Duration(seconds: 12),
  }) : _transport = transport ?? _send,
       _now = now ?? DateTime.now,
       _pause = pause ?? Future<void>.delayed;

  final ApiTransport _transport;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _pause;
  final _nextRequest = <String, DateTime>{};
  final _retryAfter = <String, DateTime>{};
  final Duration _requestTimeout;
  final _tails = <String, Future<void>>{};

  static const userAgent =
      'AudioFixer/0.2.0 (Android; https://github.com/WangKeqing1/audio-fixer)';
  static const _headers = {
    'User-Agent': userAgent,
    'Accept': 'application/json',
  };

  @override
  Future<Object?> getJson(Uri uri) => _get(uri);

  // Serialize each host independently. A slow lyrics response must not block a
  // MusicBrainz lookup, but redirects still join their destination host's queue.
  Future<ApiResponse> _queueRequest(Uri uri) {
    final operation = (_tails[uri.host] ?? Future<void>.value()).then(
      (_) => _request(uri),
    );
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[uri.host] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[uri.host], tail)) _tails.remove(uri.host);
      }),
    );
    return operation;
  }

  Future<ApiResponse> _request(Uri uri) async {
    final retry = _retryAfter[uri.host];
    if (retry != null && _now().isBefore(retry)) {
      throw ApiException(
        '请求过于频繁，请 ${retry.difference(_now()).inSeconds + 1} 秒后重试。',
        statusCode: 429,
      );
    }
    final next = _nextRequest[uri.host];
    if (next != null && _now().isBefore(next)) {
      await _pause(next.difference(_now()));
    }
    _nextRequest[uri.host] = _now().add(
      Duration(milliseconds: uri.host == 'musicbrainz.org' ? 1100 : 400),
    );
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
    if (response.statusCode == 429 || response.statusCode == 503) {
      final value = _header(response, 'retry-after');
      final seconds = int.tryParse(value?.trim() ?? '');
      DateTime? until;
      if (seconds != null && seconds > 0) {
        // Bound hostile values before Duration's integer multiplication.
        until = _now().add(
          Duration(seconds: seconds > 31536000 ? 31536000 : seconds),
        );
      } else if (value != null) {
        try {
          until = HttpDate.parse(value);
        } on FormatException {
          // Use the fallback below for invalid or expired server dates.
        }
      }
      _retryAfter[uri.host] = until != null && until.isAfter(_now())
          ? until
          : _now().add(const Duration(seconds: 30));
      throw ApiException('数据源暂时繁忙，请稍后重试。', statusCode: response.statusCode);
    }
    return response;
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
          uri = uri.resolve(location);
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
      (const {
            'musicbrainz.org',
            'lrclib.net',
            'coverartarchive.org',
            'archive.org',
          }.contains(uri.host) ||
          uri.host.endsWith('.archive.org'));

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

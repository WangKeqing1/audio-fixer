import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _png({bool corruptPixels = false}) {
  List<int> number(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
  List<int> chunk(String type, List<int> payload) {
    final bytes = [...ascii.encode(type), ...payload];
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
      }
    }
    return [...number(payload.length), ...bytes, ...number(crc ^ 0xffffffff)];
  }

  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', [...number(1), ...number(1), 8, 2, 0, 0, 0]),
    ...chunk(
      'IDAT',
      corruptPixels ? [1, 2, 3, 4] : ZLibEncoder().convert([0, 30, 80, 140]),
    ),
    ...chunk('IEND', []),
  ]);
}

class _Headers extends Fake implements HttpHeaders {
  _Headers(this.location);
  final String? location;
  @override
  String? value(String name) => name == 'location' ? location : null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.chunks, {String? location})
    : headers = _Headers(location);
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  final List<List<int>> chunks;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  set followRedirects(bool value) {
    expect(value, isFalse);
  }

  @override
  Future<HttpClientResponse> close() async => response;
}

class _Client extends Fake implements HttpClient {
  _Client(this.respond);
  final _Response Function(Uri) respond;
  final requested = <Uri>[];
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    return _Request(respond(url));
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const archive = 'https://coverartarchive.org/release/example/front';
  const netease =
      'https://p1.music.126.net/W6MDlem6_FsymbnxKc_BKQ==/109951171530948990.jpg';
  final image = _png();
  Future<Uint8List> load(_Client client, String value) =>
      HttpOverrides.runZoned(
        () => loadRemoteArtwork(value),
        createHttpClient: (_) => client,
      );

  test(
    'remote preview accepts the same verified NetEase image path as export',
    () async {
      final client = _Client((_) => _Response(200, [image]));
      expect(await load(client, netease), image);
      expect(client.requested.single.toString(), netease);
      expect(client.closed, isTrue);
    },
  );

  test('remote loader rejects local files and untrusted hosts or asset paths before GET', () async {
    for (final value in [
      'file:///private/cover.png',
      'http://p1.music.126.net/asset/1.jpg',
      'https://p5.music.126.net/asset/1.jpg',
      'https://p1.music.126.net/private.png',
      'https://p1.music.126.net/asset/1.jpg?token=anything',
      'https://example.org/a.png',
    ]) {
      final client = _Client((_) => _Response(200, [image]));
      await expectLater(load(client, value), throwsA(isA<ExportException>()));
      expect(client.requested, isEmpty, reason: value);
      expect(client.closed, isTrue);
    }
  });

  test('every redirect is validated before a new request', () async {
    final client = _Client(
      (_) => _Response(302, [], location: 'https://example.org/private.png'),
    );
    await expectLater(load(client, archive), throwsA(isA<ExportException>()));
    expect(client.requested.map((uri) => uri.toString()), [archive]);
  });

  test(
    'trusted redirect works and automatic redirect following remains disabled',
    () async {
      final client = _Client(
        (uri) => uri.host == 'coverartarchive.org'
            ? _Response(307, [], location: netease)
            : _Response(200, [image]),
      );
      expect(await load(client, archive), image);
      expect(client.requested.map((uri) => uri.toString()), [archive, netease]);
    },
  );

  test('remote loader stops redirect loops at six requests', () async {
    final client = _Client((_) => _Response(302, [], location: archive));
    await expectLater(load(client, archive), throwsA(isA<ExportException>()));
    expect(client.requested.length, 6);
  });

  test(
    'oversized responses and corrupt pixel payloads cannot become covers',
    () async {
      for (final bytes in [
        Uint8List(10 * 1024 * 1024 + 1),
        _png(corruptPixels: true),
      ]) {
        final client = _Client((_) => _Response(200, [bytes]));
        await expectLater(
          load(client, archive),
          throwsA(isA<ExportException>()),
        );
        expect(client.closed, isTrue);
      }
    },
  );
}

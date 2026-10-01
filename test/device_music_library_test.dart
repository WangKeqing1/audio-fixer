import 'dart:io';

import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('audio_fixer/device_library');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('device-library-test-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test(
    'native query maps stable content identity and leaves details unknown',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'permissionStatus') return 'granted';
        if (call.method == 'querySongs') {
          return [
            {
              'id': 'media:external_primary:1',
              'contentUri': 'content://media/external_primary/audio/media/1',
              'fileName': 'song.flac',
              'sizeBytes': 1234,
              'title': '系统歌曲',
              'dateModifiedMs': 1000,
            },
          ];
        }
        return null;
      });
      final library = AndroidMusicLibrary(() async => temporary);
      expect(await library.permissionStatus(), AudioLibraryPermission.granted);
      final track = (await library.querySongs()).single;
      expect(track.title, '系统歌曲');
      expect(track.detailsLoaded, isFalse);
      expect(track.localPath, isEmpty);
    },
  );

  test(
    'temporary read copy is released even when metadata parsing fails',
    () async {
      final audio = File(p.join(temporary.path, 'native-read.tmp'));
      await audio.writeAsBytes([1, 2, 3]);
      var released = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'copyForRead') return audio.path;
        if (call.method == 'releaseReadCopy') {
          expect((call.arguments as Map)['path'], audio.path);
          await audio.delete();
          released = true;
        }
        return null;
      });
      final result = await AndroidMusicLibrary(() async => temporary)
          .readDetails(fixtureDeviceTrack());
      expect(result.readError, isNotNull);
      expect(result.contentUri, fixtureDeviceTrack().contentUri);
      expect(released, isTrue);
      expect(await audio.exists(), isFalse);
    },
  );

  test('permission loss is distinct from a damaged audio file', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'permission_denied');
    });
    await expectLater(
      AndroidMusicLibrary(() async => temporary)
          .readDetails(fixtureDeviceTrack()),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'permission_denied',
        ),
      ),
    );
  });
}

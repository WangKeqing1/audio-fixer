import 'dart:convert';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/online_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'HTML unavailable responses retain valid lyrics and never invent metadata',
    () async {
      final calls = <Uri>[];
      final client = HttpJsonApiClient(
        pause: (_) async {},
        transport: (uri, _) async {
          calls.add(uri);
          if (uri.host == 'musicbrainz.org') {
            return const ApiResponse(
              200,
              '<html><h1>Site Unavailable</h1></html>',
            );
          }
          if (uri.host == 'coverartarchive.org') {
            return const ApiResponse(200, '{"images":[]}');
          }
          final song = {
            'id': 123,
            'trackName': 'Offline Song',
            'artistName': 'Offline Artist',
            'albumName': 'Offline Album',
            'duration': 120,
            'instrumental': false,
            'syncedLyrics':
                '[00:00.00] A synthetic fixture for source failure testing',
          };
          return ApiResponse(
            200,
            jsonEncode(uri.path.endsWith('/search') ? [song] : song),
          );
        },
      );
      final sources = createOnlineSources(client: client);
      final cover = sources.singleWhere(
        (source) => source.name == 'Cover Art Archive',
      );
      await (cover as SourceConnectionTester).checkConnection();
      final track = AudioTrack(
        id: 'offline',
        fileName: 'offline.mp3',
        sizeBytes: 100,
        importedAt: DateTime(2026),
        title: 'Offline Song',
        artist: 'Offline Artist',
        durationMs: 120000,
      );
      final result = await CompletionService(sources: sources)
          .preview(track, const AppSettings());
      expect(result.status, TaskStatus.needsReview);
      expect(result.suggestions.single.field, AudioField.lyrics);
      expect(result.suggestions.single.value, contains('synthetic fixture'));
      expect(result.message, contains('MusicBrainz'));
      expect(result.message, contains('Cover Art Archive'));
      expect(track.album, isNull);
      expect(track.artworkPath, isNull);
      expect(track.lyrics, isNull);
      expect(calls.any((uri) => uri.host == 'lrclib.net'), isTrue);
    },
  );
}

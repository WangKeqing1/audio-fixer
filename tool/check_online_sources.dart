// Makes real, read-only API requests. Prints only metadata and lengths, never
// lyrics or audio. Usage: dart run tool/check_online_sources.dart [title] [artist] [seconds] [album]
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/online_sources.dart';

Future<void> main(List<String> arguments) async {
  final track = AudioTrack(
    id: 'online-source-smoke',
    fileName: 'smoke.mp3',
    sizeBytes: 0,
    importedAt: DateTime.now(),
    title: arguments.isNotEmpty ? arguments[0] : 'Never Gonna Give You Up',
    artist: arguments.length > 1 ? arguments[1] : 'Rick Astley',
    durationMs:
        ((arguments.length > 2 ? double.parse(arguments[2]) : 213) * 1000)
            .round(),
    album: arguments.length > 3 ? arguments[3] : 'Whenever You Need Somebody',
  );
  for (final source in createOnlineSources()) {
    try {
      if (source is SourceConnectionTester) {
        await (source as SourceConnectionTester).checkConnection();
      }
      final results = await source.lookup(track, source.supportedFields);
      stdout.writeln('${source.name}: reachable; candidates=${results.length}');
      for (final result in results) {
        stdout.writeln(
          '  ${result.field.name}: length=${result.value.length}; source=${result.sourceUrl}',
        );
      }
    } catch (error) {
      stderr.writeln('${source.name}: $error');
      exitCode = 1;
    }
  }
}

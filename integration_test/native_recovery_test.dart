import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Host seeds a production-format interrupted journal and app-private synthetic
// fixture while the disposable QA app is stopped. This exercises real recovery
// after a fresh Activity launch; it does not simulate the timing of a crash.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native interrupted-write journal restores exact original bytes',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      const channel = MethodChannel('audio_fixer/device_library');
      final support = await getApplicationSupportDirectory();
      final fixture = jsonDecode(
        await File('${support.path}/native_recovery_expected.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(fixture['synthetic_only'], isTrue);
      final target = File(fixture['target_path'] as String);
      final backup = File(fixture['backup_path'] as String);
      final expected = fixture['original_sha256'] as String;
      expect(await backup.exists(), isTrue);
      expect(sha256.convert(await backup.readAsBytes()).toString(), expected);
      expect(
        sha256.convert(await target.readAsBytes()).toString(),
        isNot(expected),
      );

      final notice = await channel.invokeMethod<String>('recoverExport');
      expect(notice, contains('已恢复'));
      expect(sha256.convert(await target.readAsBytes()).toString(), expected);
      expect(await backup.exists(), isFalse);
      expect(await channel.invokeMethod<String>('recoverExport'), notice);
      await channel.invokeMethod<void>('acknowledgeExportRecovery');
      expect(await channel.invokeMethod<String>('recoverExport'), isNull);
      // Exercise the native last-source-snapshot guard directly. The stale
      // digest must reject before any truncating writer is opened.
      final cache = await getTemporaryDirectory();
      final work = Directory(
        '${cache.path}/tagged_exports/export_native_guard',
      );
      await work.create(recursive: true);
      final tagged = await File('${work.path}/tagged.mp3')
          .writeAsBytes(await target.readAsBytes());
      try {
        await expectLater(
          channel.invokeMethod<String>('saveAudioOriginal', {
            'path': tagged.path,
            'sourcePath': target.path,
            'sourceUri': null,
            'sourceSha256': List.filled(64, '0').join(),
          }),
          throwsA(
            isA<PlatformException>()
                .having((error) => error.code, 'code', 'original_save_failed')
                .having(
                  (error) => error.message,
                  'message',
                  contains('原音频已变化'),
                ),
          ),
        );
        expect(sha256.convert(await target.readAsBytes()).toString(), expected);
        expect(await backup.parent.list().toList(), isEmpty);
        expect(await channel.invokeMethod<String>('recoverExport'), isNull);
      } finally {
        await work.delete(recursive: true);
      }

      await File('${support.path}/native_recovery_result.json').writeAsString(
        jsonEncode({
          'passed': true,
          'synthetic_only': true,
          'mocked_native_channels': false,
          'injected_interrupted_journal': true,
          'timed_process_crash_tested': false,
          'original_sha256': expected,
          'checks': [
            'fresh_activity_reads_persisted_interrupted_journal',
            'real_native_recovery_restores_truncated_private_fixture',
            'restored_whole_file_sha256_exact',
            'verified_backup_cleaned_after_restore',
            'recovery_notice_persists_until_acknowledged',
            'acknowledgement_clears_resolved_notice',
            'native_stale_source_hash_rejected_before_write',
            'rejected_source_hash_leaves_no_pending_backup',
          ],
        }),
      );
    },
  );
}

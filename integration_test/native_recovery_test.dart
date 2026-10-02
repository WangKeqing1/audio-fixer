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
    'native recovery preserves unknown current version until a decision',
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
      final originalHash = fixture['original_sha256'] as String;
      final currentHash = fixture['current_sha256'] as String;
      Future<String> hash(File file) async =>
          sha256.convert(await file.readAsBytes()).toString();
      Future<Map<String, dynamic>> state() async => Map<String, dynamic>.from(
        (await channel.invokeMapMethod<String, dynamic>(
          'getOriginalRecoveryState',
        ))!,
      );
      Future<void> expectNoRecoveryState() async {
        expect(
          await channel.invokeMapMethod<String, dynamic>(
            'getOriginalRecoveryState',
          ),
          isNull,
        );
      }

      expect(await hash(backup), originalHash);
      expect(await hash(target), currentHash);
      expect(currentHash, isNot(originalHash));

      // Neither startup nor reauthorizing/checking is permission to overwrite a
      // third-hash target. Even dismissing a notice cannot discard its backup.
      expect(await channel.invokeMethod<String>('recoverExport'), isNotNull);
      expect((await state())['status'], 'conflict');
      expect(await hash(target), currentHash);
      expect(await hash(backup), originalHash);
      expect((await state())['status'], 'conflict');
      expect((await state())['canRestore'], isTrue);
      expect((await state())['canFinish'], isFalse);
      await channel.invokeMethod<String>('retryOriginalRecovery');
      expect((await state())['status'], 'conflict');
      expect(await hash(target), currentHash);
      expect(await hash(backup), originalHash);
      await expectLater(
        channel.invokeMethod<void>('acknowledgeExportRecovery'),
        throwsA(isA<PlatformException>()),
      );
      expect((await state())['status'], 'conflict');
      expect(await hash(target), currentHash);
      expect(await backup.exists(), isTrue);

      // A distinct, explicit restore must first retain the current bytes.
      expect(
        await channel.invokeMethod<String>('restoreOriginalBackup'),
        contains('已恢复'),
      );
      final restoredState = await state();
      expect(await hash(target), originalHash);
      expect(await hash(backup), originalHash);
      expect(restoredState['status'], 'restored');
      expect(restoredState['canFinish'], isFalse);
      final versions = (restoredState['versions'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      final preservedVersion = versions.singleWhere(
        (item) => item['sha256'] == currentHash,
      );
      expect(preservedVersion['id'], isNot('original'));
      final retainedFiles = await backup.parent
          .list()
          .where((entry) => entry.path.endsWith('.current'))
          .toList();
      expect(retainedFiles, hasLength(1));
      final preserved = File(retainedFiles.single.path);
      expect(await hash(preserved), currentHash);
      await expectLater(
        channel.invokeMethod<void>('finishOriginalRecovery'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'original_recovery_required',
          ),
        ),
      );
      expect((await state())['canFinish'], isFalse);
      expect(await hash(target), originalHash);
      expect(await hash(preserved), currentHash);
      expect(await backup.exists(), isTrue);

      await File('${support.path}/native_recovery_phase')
          .writeAsString('recovery_export_cancel');
      final cancelledExport = await channel.invokeMethod<String>(
        'exportOriginalRecoveryVersion',
        {'versionId': preservedVersion['id']},
      );
      expect(cancelledExport, isNull);
      expect((await state())['canFinish'], isFalse);
      expect(await hash(target), originalHash);
      expect(await hash(backup), originalHash);
      expect(await hash(preserved), currentHash);

      await File('${support.path}/native_recovery_phase')
          .writeAsString('recovery_export');
      final exportUri = await channel.invokeMethod<String>(
        'exportOriginalRecoveryVersion',
        {'versionId': preservedVersion['id']},
      );
      expect(exportUri, startsWith('content://'));
      expect((await state())['canFinish'], isTrue);
      Future<void> hostCheckpoint(String phase) async {
        await File('${support.path}/native_recovery_phase')
            .writeAsString(phase);
        final ack = File('${support.path}/native_recovery_ack');
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!await ack.exists() || await ack.readAsString() != phase) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Host did not complete $phase');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      // A remembered export URI is not enough: finish must reread and validate
      // its bytes. Host changes only the just-created synthetic export.
      await hostCheckpoint('recovery_export_corrupted');
      expect((await state())['canFinish'], isFalse);
      await expectLater(
        channel.invokeMethod<void>('finishOriginalRecovery'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'original_recovery_required',
          ),
        ),
      );
      expect((await state())['canFinish'], isFalse);
      expect(await hash(target), originalHash);
      expect(await hash(backup), originalHash);
      expect(await hash(preserved), currentHash);
      await hostCheckpoint('recovery_export_restored');
      expect((await state())['canFinish'], isTrue);
      await channel.invokeMethod<void>('finishOriginalRecovery');
      await expectNoRecoveryState();
      expect(await hash(target), originalHash);
      expect(await backup.exists(), isFalse);
      expect(await preserved.exists(), isFalse);
      expect(await backup.parent.list().toList(), isEmpty);
      expect(await channel.invokeMethod<String>('recoverExport'), isNotNull);
      await channel.invokeMethod<void>('acknowledgeExportRecovery');
      await expectNoRecoveryState();
      expect(await channel.invokeMethod<String>('recoverExport'), isNull);
      await channel.invokeMethod<String>('retryOriginalRecovery');
      await expectNoRecoveryState();

      // Legacy private imports use content-addressed identities. New writes are
      // rejected while historical private recovery targets remain supported.
      final cache = await getTemporaryDirectory();
      final work = Directory(
        '${cache.path}/tagged_exports/export_private_guard',
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
            'sourceSha256': originalHash,
          }),
          throwsA(
            isA<PlatformException>()
                .having((error) => error.code, 'code', 'original_save_failed')
                .having((error) => error.message, 'message', contains('导出')),
          ),
        );
        await expectNoRecoveryState();
        expect(await hash(target), originalHash);
        expect(await backup.parent.list().toList(), isEmpty);
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
          'original_sha256': originalHash,
          'current_sha256': currentHash,
          'preserved_export_uri': exportUri,
          'checks': [
            'fresh_activity_reads_persisted_interrupted_journal',
            'startup_preserves_third_hash_target_and_original_backup',
            'reauthorization_does_not_overwrite_unknown_current_version',
            'unresolved_notice_cannot_discard_backup',
            'explicit_restore_retains_previous_current_version',
            'restored_original_sha256_exact',
            'retained_current_sha256_exact',
            'finish_rejects_unexported_distinct_version',
            'recovery_export_cancel_keeps_both_versions',
            'actual_system_picker_exports_preserved_version',
            'immediate_recovery_state_after_success_error_and_cancel',
            'no_target_retry_finishes_before_responding',
            'modified_export_blocks_finish_and_retains_all_versions',
            'verified_restored_export_reenables_safe_finish',
            'safe_finish_cleans_backups_only_after_verified_export',
            'completion_notice_clears_only_after_acknowledgement',
            'legacy_private_original_save_rejected_without_mutation',
          ],
        }),
      );
      await File('${support.path}/native_recovery_phase')
          .writeAsString('recovery_complete');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

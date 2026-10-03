import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
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
      const previewChannel = MethodChannel('audio_fixer/audio_preview');
      final preview = AudioPreviewController();
      final previewFile = File(fixture['preview_path'] as String);
      expect(await hash(previewFile), fixture['preview_sha256']);
      final previewTrack = AudioTrack(
        id: 'native-recovery-preview',
        fileName: 'native_preview_recovery.wav',
        localPath: previewFile.path,
        sizeBytes: await previewFile.length(),
        importedAt: DateTime.now(),
        durationMs: 60000,
      );
      Future<Map<String, dynamic>> previewState() async =>
          (await previewChannel.invokeMapMethod<String, dynamic>('getState'))!;
      Future<void> waitForPreview(String status) async {
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while ((await previewState())['status'] != status ||
            preview.status.name != status) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Native preview did not reach $status');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      }

      Future<void> holdDecoder() async {
        await preview.play(previewTrack);
        await waitForPreview('playing');
        await preview.pause();
        await waitForPreview('paused');
      }

      // Exercise the production Dart release barrier over the actual recovery
      // bridge. Separate controller tests verify that each UI action uses it.
      Future<String?> guardedRecovery(String method) =>
          preview.withWriteLock(() async {
            expect(preview.isBlocked, isTrue);
            expect((await previewState())['status'], 'stopped');
            await preview.play(previewTrack);
            expect(preview.track, isNull);
            expect((await previewState())['status'], 'stopped');
            return channel.invokeMethod<String>(method);
          });
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
      await holdDecoder();
      expect(await guardedRecovery('recoverExport'), isNotNull);
      expect(preview.isBlocked, isFalse);
      expect((await previewState())['status'], 'stopped');
      expect((await state())['status'], 'conflict');
      expect(await hash(target), currentHash);
      expect(await hash(backup), originalHash);
      expect((await state())['status'], 'conflict');
      expect((await state())['canRestore'], isTrue);
      expect((await state())['canFinish'], isFalse);
      await holdDecoder();
      await guardedRecovery('retryOriginalRecovery');
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
      await holdDecoder();
      expect(await guardedRecovery('restoreOriginalBackup'), contains('已恢复'));
      expect(preview.isBlocked, isFalse);
      expect((await previewState())['status'], 'stopped');
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
      await preview.stop();
      preview.dispose();
      await previewFile.delete();
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
          'preview_recovery': {
            'real_paused_decoder_released': true,
            'recovery_write_lock_blocks_play': true,
            'no_autoplay_after_recovery': true,
            'library_controller_wiring_exercised': false,
          },
          'checks': [
            'production_preview_lock_releases_before_native_recovery',
            'production_preview_lock_blocks_play_during_native_recovery',
            'recovery_unlock_does_not_resume_preview',
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

#!/usr/bin/env python3
"""Offline host-driver unit checks; these are not Android runtime evidence."""
from pathlib import Path
from contextlib import chdir, redirect_stdout
import io
import hashlib
import json
import tempfile
import wave
import subprocess
import unittest
from unittest.mock import Mock
import xml.etree.ElementTree as ET

from android_runtime_ci import AndroidRuntime, CHECKPOINTS, PACKAGE, PHASES, RECOVERY_PHASES, RECOVERY_CHECKPOINTS
from android_runtime_fixtures import BOUNDARY_DURATIONS_MS, generate_library_fixtures
from android_runtime_evidence import main as prepare_evidence


def node(resource='', text='', kind='android.widget.TextView', **attrs):
    return ET.Element('node', {'resource-id': resource, 'text': text,
                              'class': kind, 'package': 'com.android.documentsui',
                              'enabled': 'true', 'bounds': '[0,0][100,100]', **attrs})


class DialogDriverTest(unittest.TestCase):
    def setUp(self):
        self.runtime = AndroidRuntime('test-only', Path('/tmp/not-used'))
        self.runtime.adb = Mock()
        self.runtime.screenshot = Mock()
        self.runtime.tap = Mock()
        self.filename = node('android:id/title', 'native_fixture-fixed.mp3',
                             'android.widget.EditText')
        self.save = node('android:id/button1', 'SAVE', 'android.widget.Button')

    def test_all_native_commands_keep_disposable_qa_evidence_after_teardown(self):
        for test_file in ('integration_test/native_flow_test.dart',
                          'integration_test/native_recovery_test.dart'):
            command = self.runtime.test_command(test_file)
            self.assertEqual(command[:3], ['flutter', 'test', test_file])
            self.assertIn('--no-uninstall', command)
            self.assertNotIn('--uninstall', command)
            self.assertIn('--no-pub', command)
        self.assertEqual(self.runtime.test_command('fixture.dart', '--timeout', '11m')[-2:],
                         ['--timeout', '11m'])

    def test_native_json_read_uses_remote_exit_status(self):
        self.runtime.adb.return_value = subprocess.CompletedProcess([], 0, stdout='{"passed": true}')
        self.assertEqual(self.runtime.read_app_json('files/result.json'), {'passed': True})
        self.runtime.adb.assert_called_once_with(
            'shell', '-T', 'run-as', PACKAGE, 'cat', 'files/result.json')

    def test_missing_native_evidence_propagates_remote_failure(self):
        self.runtime.adb.side_effect = subprocess.CalledProcessError(1, ['adb'], stderr='unknown package')
        with self.assertRaises(subprocess.CalledProcessError):
            self.runtime.read_app_json('files/result.json')

    def test_phase_ignores_build_time_package_and_missing_file_diagnostics(self):
        for diagnostic in (
            "run-as: unknown package: " + PACKAGE,
            "cat: files/native_runtime_phase: No such file or directory",
            "unexpected_phase",
            "",
        ):
            with self.subTest(diagnostic=diagnostic):
                self.runtime.adb.return_value = subprocess.CompletedProcess(
                    [], 0, stdout=diagnostic + "\n")
                self.assertEqual(self.runtime.phase(), "")
        self.runtime.adb.assert_called_with(
            "shell", "-T", "run-as", PACKAGE, "cat",
            "files/native_runtime_phase", check=False)

    def test_phase_accepts_only_successful_known_app_phases(self):
        for phase in PHASES + CHECKPOINTS + RECOVERY_PHASES + RECOVERY_CHECKPOINTS + ("read_details", "complete", "recovery_complete"):
            with self.subTest(phase=phase):
                self.runtime.adb.return_value = subprocess.CompletedProcess(
                    [], 0, stdout=phase + "\n")
                self.assertEqual(self.runtime.phase(), phase)
                self.runtime.adb.return_value = subprocess.CompletedProcess(
                    [], 1, stdout=phase)
                self.assertEqual(self.runtime.phase(), "")

    def test_downloads_toolbar_title_is_never_tapped_as_drawer_root(self):
        toolbar = node('com.android.documentsui:id/toolbar')
        toolbar.append(node('android:id/title', 'Downloads'))
        nodes = [self.filename, self.save, *toolbar.iter('node')]
        self.assertTrue(self.runtime.act('save_confirm', nodes))
        self.runtime.tap.assert_called_once_with(self.save, 'save_confirm')

    def test_downloads_drawer_root_can_hide_save_filename(self):
        self.runtime.save_observed.add('save_confirm')
        roots = node('com.android.documentsui:id/roots_list')
        downloads = node('android:id/title', 'Downloads')
        roots.append(downloads)
        self.assertFalse(self.runtime.act('save_confirm', list(roots.iter('node'))))
        self.runtime.tap.assert_called_once_with(downloads, 'choose_downloads')

    def test_unobserved_save_dialog_cannot_select_drawer_root(self):
        roots = node('com.android.documentsui:id/roots_list')
        roots.append(node('android:id/title', 'Downloads'))
        self.assertFalse(self.runtime.act('save_confirm', list(roots.iter('node'))))
        self.runtime.tap.assert_not_called()

    def test_recovery_export_requires_exact_generated_version_filename(self):
        file_name = 'audio-fixer-recovery-preserved-1234abcd.mp3'
        expected = node('android:id/title', file_name, 'android.widget.EditText')
        toolbar = node('com.android.documentsui:id/toolbar')
        toolbar.append(node('android:id/title', 'Downloads'))
        self.assertFalse(self.runtime.act('recovery_export', [self.filename, self.save, *toolbar.iter('node')],
                                          file_name=file_name))
        self.runtime.tap.assert_not_called()
        self.assertTrue(self.runtime.act('recovery_export', [expected, self.save, *toolbar.iter('node')],
                                         file_name=file_name))
        self.runtime.tap.assert_called_once_with(self.save, 'recovery_export')

    def test_recovery_export_cancel_preserves_exact_filename_guard(self):
        file_name = 'audio-fixer-recovery-preserved-1234abcd.mp3'
        expected = node('android:id/title', file_name, 'android.widget.EditText')
        self.assertFalse(self.runtime.act('recovery_export_cancel', [self.filename, self.save],
                                          file_name=file_name))
        self.runtime.adb.assert_not_called()
        self.assertTrue(self.runtime.act('recovery_export_cancel', [expected, self.save],
                                         file_name=file_name))
        self.runtime.adb.assert_called_once_with('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    def test_save_in_other_directory_is_not_confirmed(self):
        toolbar = node('com.android.documentsui:id/toolbar')
        toolbar.append(node('android:id/title', 'Recent'))
        self.assertFalse(self.runtime.act('save_confirm', [self.filename, self.save, toolbar]))
        self.runtime.tap.assert_not_called()

    def test_cancel_requires_observed_filename(self):
        self.assertFalse(self.runtime.act('save_cancel', [self.save]))
        self.runtime.adb.assert_not_called()
        self.assertTrue(self.runtime.act('save_cancel', [self.filename, self.save]))
        self.runtime.adb.assert_called_once_with('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    def test_cancel_dismisses_keyboard_before_save_dialog(self):
        keyboard = node()
        keyboard.set('package', 'com.android.inputmethod.latin')
        self.assertFalse(self.runtime.act('save_cancel', [self.filename, keyboard]))
        self.runtime.screenshot.assert_not_called()

    def test_permission_taps_only_system_permission_controller(self):
        allow = node('com.android.permissioncontroller:id/permission_allow_button', 'Allow')
        self.assertFalse(self.runtime.act('permission_grant', [allow]))
        allow.set('package', 'com.android.permissioncontroller')
        self.assertTrue(self.runtime.act('permission_grant', [allow]))
        self.runtime.tap.assert_called_once_with(allow, 'permission_grant')


    def original_consent(self):
        package = 'com.android.providers.media.module'
        title = node('android:id/message', 'Allow Audio Fixer QA 0.3 to modify this audio file?',
                     package=package)
        allow = node('android:id/button1', 'Allow', 'android.widget.Button', package=package)
        deny = node('android:id/button2', "Don't allow", 'android.widget.Button', package=package)
        return title, allow, deny

    def test_original_confirm_requires_expected_system_surface_and_purpose(self):
        title, allow, deny = self.original_consent()
        self.assertTrue(self.runtime.act('original_confirm', [title, allow, deny]))
        self.runtime.tap.assert_called_once_with(allow, 'original_confirm')

    def test_original_cancel_uses_deny_not_allow(self):
        title, allow, deny = self.original_consent()
        self.assertTrue(self.runtime.act('original_cancel', [title, allow, deny]))
        self.runtime.tap.assert_called_once_with(deny, 'original_cancel')

    def test_original_button_alone_is_not_authorization_surface(self):
        _, allow, deny = self.original_consent()
        self.assertFalse(self.runtime.act('original_confirm', [allow, deny]))
        self.runtime.tap.assert_not_called()

    def test_original_wrong_app_or_delete_request_is_rejected(self):
        title, allow, deny = self.original_consent()
        for text in ['Allow Another App to modify this audio file?',
                     'Allow Audio Fixer QA 0.3 to delete this audio file?']:
            title.set('text', text)
            self.assertFalse(self.runtime.act('original_confirm', [title, allow, deny]))
        self.runtime.tap.assert_not_called()

    def test_original_fake_app_package_is_rejected(self):
        nodes = self.original_consent()
        for item in nodes:
            item.set('package', 'example.fake.media')
        self.assertFalse(self.runtime.act('original_confirm', list(nodes)))
        self.runtime.tap.assert_not_called()

    def test_original_duplicate_or_disabled_button_is_rejected(self):
        title, allow, deny = self.original_consent()
        self.assertFalse(self.runtime.act('original_confirm', [title, allow, allow, deny]))
        allow.set('enabled', 'false')
        self.assertFalse(self.runtime.act('original_confirm', [title, allow, deny]))
        self.runtime.tap.assert_not_called()


class NativeLibraryFixtureTest(unittest.TestCase):
    """Fixture integrity and boundaries, not native Android execution."""

    def test_wav_boundaries_and_scoped_synthetic_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = generate_library_fixtures(root)
            self.assertTrue(manifest['synthetic_only'])
            self.assertEqual(manifest['list_row_count'], 28)
            self.assertEqual(len(manifest['entries']), 34)
            self.assertEqual(json.loads((root / 'manifest.json').read_text()), manifest)
            entries = {entry['file_name']: entry for entry in manifest['entries']}
            self.assertEqual(len(entries), 34)
            for entry in manifest['entries']:
                with self.subTest(file=entry['file']):
                    path = root / entry['file']
                    self.assertTrue(path.is_relative_to(root))
                    self.assertTrue(entry['device_path'].startswith('/sdcard/Music/AudioFixerSynthetic/'))
                    self.assertNotIn('..', Path(entry['device_path']).parts)
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry['sha256'])
                    with wave.open(str(path), 'rb') as stream:
                        self.assertEqual(stream.getnchannels(), 1)
                        self.assertEqual(stream.getsampwidth(), 2)
                        self.assertEqual(stream.getframerate(), 8000)
                        self.assertEqual(stream.getnframes(), entry['duration_ms'] * 8)
                        self.assertEqual(len(stream.readframes(stream.getnframes())), entry['duration_ms'] * 16)
            for milliseconds in BOUNDARY_DURATIONS_MS:
                self.assertEqual(entries[f'native_duration_{milliseconds}.wav']['duration_ms'], milliseconds)
            self.assertEqual(entries['native_parent.wav']['file'], 'Exclude/native_parent.wav')
            self.assertEqual(entries['native_nested.wav']['file'], 'Exclude/Nested/native_nested.wav')
            self.assertEqual(entries['native_neighbor.wav']['file'], 'ExcludeNeighbor/native_neighbor.wav')

    def test_filter_manifest_is_evidence_but_audio_and_logs_are_not(self):
        with tempfile.TemporaryDirectory() as directory, chdir(directory):
            root = Path('build/android_runtime')
            (root / 'generated').mkdir(parents=True)
            (root / 'generated/manifest.json').write_text('{"synthetic_only": true}')
            generate_library_fixtures(root / 'library-fixtures')
            (root / 'private-file.log').write_text('Synthetic forbidden fixture')
            (root / 'app-debug.apk').write_bytes(b'Synthetic forbidden fixture')
            with redirect_stdout(io.StringIO()):
                prepare_evidence()
            evidence = root / 'evidence'
            self.assertEqual({str(path.relative_to(evidence))
                              for path in evidence.rglob('*') if path.is_file()},
                             {'manifest.json', 'library-fixtures/manifest.json'})
            manifest = json.loads((evidence / 'manifest.json').read_text())
            self.assertTrue(manifest['synthetic_only'])
            self.assertEqual(manifest['retention_days'], 1)
            self.assertEqual(len(manifest['files']), 1)

    def test_filter_checkpoints_are_explicit_and_unique(self):
        self.assertEqual(len(CHECKPOINTS), len(set(CHECKPOINTS)))
        self.assertTrue({'selection_toolbar_top', 'selection_toolbar_scrolled',
                         'library_filters_ready', 'library_filters_reloaded'}.issubset(CHECKPOINTS))


class IntegrationSourceContractTest(unittest.TestCase):
    """Static harness guards only; these do not claim Android UI execution."""

    def test_native_recovery_releases_active_before_terminal_replies(self):
        # Source protocol guard complements immediate Android state assertions.
        # It does not simulate threads, provider I/O, or native execution.
        root = Path(__file__).resolve().parents[1]
        source = (root / 'android/app/src/main/kotlin/com/audiofixer/audio_fixer'
                  / 'AudioWriteBridge.kt').read_text()

        def method(name, next_name):
            return source[source.index(f'    private fun {name}('):
                          source.index(f'    private fun {next_name}(')]

        for name, next_name, terminal in (
            ('completeActiveSuccess', 'completeActiveError', 'reply.success(value)'),
            ('completeActiveError', 'schedule', 'reply.error(code, message)'),
        ):
            with self.subTest(method=name):
                body = method(name, next_name)
                self.assertLess(body.index('active = false'), body.index(terminal))
        action = method('recoveryAction', 'exportRecoveryVersion')
        export = method('completeRecoveryExport', 'requestConsent')
        self.assertIn('completeActiveSuccess(reply, value)', action)
        self.assertIn('completeActiveError(reply,', action)
        self.assertIn('completeActiveSuccess(pending.reply, saved)', export)
        self.assertIn('completeActiveError(pending.reply,', export)
        self.assertIn('recoveryAction(reply) { recover() }',
                      method('retryOriginalRecovery', 'recoveryAction'))
        self.assertNotRegex(source, r'finally\s*\{\s*active\s*=\s*false')

    def test_localized_material_navigation_has_explicit_route_guards(self):
        root = Path(__file__).resolve().parents[1]
        for path in (root / 'integration_test').glob('*.dart'):
            with self.subTest(path=path.name):
                source = path.read_text()
                self.assertNotIn('await tester.pageBack(', source)
                self.assertNotIn("find.byTooltip('Back')", source)
                self.assertNotIn('find.byTooltip("Back")', source)
        main = (root / 'integration_test/native_flow_test.dart').read_text()
        guarded_navigation = """expect(find.byType(TrackDetailPage), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsNothing);"""
        self.assertIn(guarded_navigation, main)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Offline host-driver unit checks; these are not Android runtime evidence."""
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock
import xml.etree.ElementTree as ET

from android_runtime_ci import AndroidRuntime, CHECKPOINTS, PACKAGE, PHASES


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
        for phase in PHASES + CHECKPOINTS + ("read_details", "complete"):
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
        title = node('android:id/message', 'Allow Audio Fixer QA to modify this audio file?',
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
                     'Allow Audio Fixer QA to delete this audio file?']:
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


if __name__ == '__main__':
    unittest.main()

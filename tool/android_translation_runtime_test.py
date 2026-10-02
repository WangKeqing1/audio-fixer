#!/usr/bin/env python3
"""Offline host-contract tests, not Android/model-download evidence."""
import json
from pathlib import Path
import tempfile
import unittest

from android_translation_runtime import (
    INTERNET, MARKER, create_evidence, installed_permissions,
    result_from_log, signature_digest,
)


class TranslationProbeContractTest(unittest.TestCase):
    def test_pid_log_only_accepts_bounded_matching_synthetic_result(self):
        value = {'phase': 'offline', 'synthetic_only': True, 'passed': True}
        self.assertEqual(result_from_log('I/flutter: ' + MARKER + json.dumps(value), 'offline'), value)
        self.assertIsNone(result_from_log(MARKER + json.dumps(value), 'download'))
        self.assertIsNone(result_from_log('ordinary Flutter log', 'offline'))
        value['synthetic_only'] = False
        with self.assertRaises(RuntimeError):
            result_from_log(MARKER + json.dumps(value), 'offline')
        value['synthetic_only'] = True
        message = MARKER + json.dumps(value)
        with self.assertRaises(RuntimeError):
            result_from_log(message + '\n' + message, 'offline')

    def test_malformed_or_oversized_result_is_rejected(self):
        with self.assertRaises(json.JSONDecodeError):
            result_from_log(MARKER + '{truncated', 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log(MARKER + 'x' * 12_001, 'offline')

    def test_installed_permission_parse_uses_exact_request_block(self):
        dump = '''Package [com.audiofixer.audio_fixer.qa.v030]:
    requested permissions:
      android.permission.READ_MEDIA_AUDIO
      android.permission.ACCESS_NETWORK_STATE
    install permissions:
      android.permission.ACCESS_NETWORK_STATE: granted=true
'''
        self.assertNotIn(INTERNET, installed_permissions(dump))
        self.assertIn('android.permission.READ_MEDIA_AUDIO', installed_permissions(dump))
        self.assertIn(INTERNET, installed_permissions(dump.replace(
            '      android.permission.READ_MEDIA_AUDIO',
            '      android.permission.INTERNET\n      android.permission.READ_MEDIA_AUDIO')))
        with self.assertRaises(RuntimeError):
            installed_permissions(dump + dump)
        with self.assertRaises(RuntimeError):
            installed_permissions('unrelated output without a permission block')

    def test_cert_comparison_requires_verified_single_certificate(self):
        digest = 'a' * 64
        self.assertEqual(signature_digest('Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' + digest), digest)
        with self.assertRaises(RuntimeError):
            signature_digest('Number of signers: 2\nSigner #1 certificate SHA-256 digest: ' + digest)
        with self.assertRaises(RuntimeError):
            signature_digest('Number of signers: 1\nMissing digest')

    def test_evidence_excludes_apks_models_and_raw_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'offline.json').write_text('{"synthetic_only": true, "passed": true}')
            for name in ('offline-probe-local.apk', 'language-model.bin', 'logcat.txt'):
                (root / name).write_text('Forbidden synthetic fixture')
            create_evidence(root)
            self.assertEqual({path.name for path in (root / 'evidence').iterdir()},
                             {'offline.json', 'manifest.json'})
            self.assertEqual(json.loads((root / 'evidence/manifest.json').read_text())['retention_days'], 1)

    def test_evidence_rejects_non_synthetic_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'offline.json').write_text('{"synthetic_only": false}')
            with self.assertRaises(RuntimeError):
                create_evidence(root)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Offline host-contract tests, not Android/model-download evidence."""
import json
import base64
import hashlib
from pathlib import Path
import tempfile
import unittest

from android_translation_runtime import (
    INTERNET, MARKER, create_evidence, installed_permissions,
    result_from_log, signature_digest, safe_native_failure,
)


class TranslationProbeContractTest(unittest.TestCase):
    @staticmethod
    def frames(value, *, encoded=None):
        data = json.dumps(value, ensure_ascii=False).encode()
        encoded = encoded or base64.b64encode(data).decode()
        chunks = [encoded[index:index + 512] for index in range(0, len(encoded), 512)]
        digest = hashlib.sha256(data).hexdigest()
        return [f"{MARKER}v1|{value['phase']}|{digest}|{index}|{len(chunks)}|{chunk}"
                for index, chunk in enumerate(chunks)]

    def test_pid_log_reassembles_complete_synthetic_result_over_log_limit(self):
        value = {'phase': 'offline', 'synthetic_only': True, 'passed': True,
                 'translations': ['中文合成结果' * 100]}
        frames = self.frames(value)
        self.assertGreater(len(frames), 3)
        self.assertTrue(all(len(frame.encode()) < 700 for frame in frames))
        self.assertIsNone(result_from_log('\n'.join(frames[:-1]), 'offline'))
        self.assertEqual(result_from_log('\n'.join('I/flutter: ' + frame for frame in frames), 'offline'), value)
        self.assertEqual(result_from_log('\n'.join(reversed(frames)), 'offline'), value)
        self.assertEqual(result_from_log('\n'.join(frames + [frames[0]]), 'offline'), value)
        self.assertIsNone(result_from_log('\n'.join(frames), 'download'))
        self.assertIsNone(result_from_log('ordinary Flutter log', 'offline'))

    def test_conflicting_or_corrupt_frames_are_rejected(self):
        value = {'phase': 'offline', 'synthetic_only': True, 'passed': True,
                 'padding': 'a' * 1000}
        frames = self.frames(value)
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(frames + [frames[0][:-1] + 'Z']), 'offline')
        other = self.frames(dict(value, passed=False))
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(frames + other), 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join([frames[0].replace('|0|', '|99|', 1), *frames[1:]]), 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join([frames[0][:-1], *frames[1:]]), 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(frames[:-1] + [frames[-1][:-1] + 'A']), 'offline')

    def test_malformed_oversized_or_non_synthetic_payload_is_rejected(self):
        with self.assertRaises(RuntimeError):
            result_from_log(MARKER + '{truncated', 'offline')
        oversized = self.frames({'phase': 'offline', 'synthetic_only': True, 'padding': 'x' * 12_001})
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(oversized), 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(self.frames({'phase': 'offline', 'synthetic_only': False})), 'offline')
        with self.assertRaises(RuntimeError):
            result_from_log('\n'.join(self.frames({'phase': 'offline', 'synthetic_only': True}, encoded='%%%')), 'offline')

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

    def test_native_diagnostics_never_copy_messages_stack_or_input(self):
        value = safe_native_failure({
            'error_code': 'IDENTIFICATION_FAILED',
            'native_details': {
                'stage': 'create_language_identifier',
                'exceptionTypes': ['java.lang.NullPointerException', 'a' * 161, 'bad type', 'ignored.Fourth'],
                'mlKitErrorCode': 13,
                'message': 'Synthetic forbidden message',
                'stack': 'Synthetic forbidden stack',
                'lyrics': 'Synthetic forbidden input',
            },
        })
        self.assertEqual(value, {'error_code': 'IDENTIFICATION_FAILED', 'native_details': {
            'stage': 'create_language_identifier',
            'exceptionTypes': ['java.lang.NullPointerException'], 'mlKitErrorCode': 13,
        }})
        self.assertEqual(safe_native_failure({'error_code': 'bad code', 'native_details': {
            'stage': 'untrusted dynamic text', 'mlKitErrorCode': True,
        }}), {'error_code': 'PLATFORM_ERROR', 'native_details': {}})

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

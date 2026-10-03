#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from package_qa_delivery import package


class DeliveryPackageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.apk = self.root / 'signed.apk'
        self.data = bytes(range(251)) * 103
        self.apk.write_bytes(self.data)
        self.info = self.root / 'info.json'
        self.info.write_text(json.dumps({'bytes': len(self.data),
                                        'abi': 'arm64-v8a',
                                        'head_sha': 'test-head'}))

    def test_parts_reassemble_to_the_exact_signed_apk(self):
        output = self.root / 'delivery'
        result = package(self.apk, self.info, output, max_part_bytes=15000)
        pieces = []
        for index, part in enumerate(result['parts'], 1):
            directory = output / f'part-{index}'
            self.assertEqual(json.loads((directory / 'delivery-manifest.json')
                                        .read_text()), result)
            data = (directory / part['file_name']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), part['sha256'])
            self.assertEqual(len(data), part['bytes'])
            self.assertLessEqual(len(data), 15000)
            pieces.append(data)
        self.assertEqual(b''.join(pieces), self.data)
        self.assertEqual(hashlib.sha256(b''.join(pieces)).hexdigest(),
                         result['sha256'])
        self.assertEqual(result['apk_info']['head_sha'], 'test-head')

    def test_rejects_oversize_without_partial_output(self):
        output = self.root / 'delivery'
        with self.assertRaisesRegex(ValueError, 'limit'):
            package(self.apk, self.info, output, max_part_bytes=100)
        self.assertFalse(output.exists())

    def test_rejects_stale_identity(self):
        self.info.write_text(json.dumps({'bytes': 12, 'abi': 'arm64-v8a'}))
        with self.assertRaisesRegex(ValueError, 'identity'):
            package(self.apk, self.info, self.root / 'delivery')

    def test_refuses_to_mix_old_and_new_parts(self):
        output = self.root / 'delivery'
        output.mkdir()
        existing = output / 'old-part.bin'
        existing.write_bytes(b'old')
        with self.assertRaisesRegex(ValueError, 'stale'):
            package(self.apk, self.info, output)
        self.assertEqual(existing.read_bytes(), b'old')

    def test_rejects_symlink_input(self):
        link = self.root / 'linked.apk'
        link.symlink_to(self.apk)
        with self.assertRaisesRegex(ValueError, 'non-symlink'):
            package(link, self.info, self.root / 'delivery')


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Package one verified APK for clients with a 32 MiB artifact transfer limit.

The two artifacts contain byte ranges of the same signed APK, not rebuilt or
re-signed applications. Each includes a complete integrity/provenance manifest.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path


MAX_PART_BYTES = 31 * 1024 * 1024


def package(apk: Path, info_path: Path, output: Path,
            max_part_bytes: int = MAX_PART_BYTES) -> dict:
    if apk.is_symlink() or not apk.is_file():
        raise ValueError("APK must be a regular non-symlink file")
    size = apk.stat().st_size
    if not 2 <= size <= max_part_bytes * 2:
        raise ValueError("APK exceeds the two-part delivery limit")
    info = json.loads(info_path.read_text())
    if info['bytes'] != size or info['abi'] != 'arm64-v8a':
        raise ValueError("APK identity evidence does not match delivery input")
    if output.exists():
        raise ValueError("Delivery output must be new to avoid stale parts")
    data = apk.read_bytes()
    if len(data) != size:
        raise ValueError("APK changed during packaging")
    midpoint = (size + 1) // 2
    pieces = [data[:midpoint], data[midpoint:]]
    manifest = {
        'format_version': 1,
        'file_name': apk.name,
        'bytes': size,
        'sha256': hashlib.sha256(data).hexdigest(),
        'apk_info': info,
        'parts': [
            {'file_name': f'part-{index + 1}-of-2.bin',
             'bytes': len(part), 'sha256': hashlib.sha256(part).hexdigest()}
            for index, part in enumerate(pieces)
        ],
    }
    output.mkdir(parents=True)
    for index, part in enumerate(pieces):
        directory = output / f'part-{index + 1}'
        directory.mkdir()
        (directory / manifest['parts'][index]['file_name']).write_bytes(part)
        (directory / 'delivery-manifest.json').write_text(
            json.dumps(manifest, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    result = package(
        Path('build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'),
        Path('build/ci/apk-info.json'), Path('build/ci/apk-delivery'))
    print(json.dumps(result, indent=2))

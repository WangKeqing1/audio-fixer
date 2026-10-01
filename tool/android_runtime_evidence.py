#!/usr/bin/env python3
"""Copy only synthetic native-test screenshots and check summaries to CI evidence.

No APKs, audio files, raw logcat, raw compiler output, paths to user files,
credentials, or device dumps are allowed in the artifact directory.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct

from android_runtime_ci import CHECKPOINTS, PHASES, SMOKE_SCREENS


def main() -> None:
    root = Path('build/android_runtime')
    provenance = root / 'generated/manifest.json'
    if not provenance.exists():
        print('No generated synthetic fixture manifest; no evidence will be uploaded.')
        return
    assert json.loads(provenance.read_text())['synthetic_only'] is True
    evidence = root / 'evidence'
    evidence.mkdir(exist_ok=False)
    allowlist = [f'screenshots/{name}.png' for name in PHASES + CHECKPOINTS + SMOKE_SCREENS]
    allowlist += ['summary.json', 'native-test-result.json', 'native-ui-actions.json',
                  'source-baseline.json', 'independent-audio-check.json', 'packaged-smoke.json']
    manifest = {'synthetic_only': True, 'retention_days': 1,
                'commit': os.environ.get('GITHUB_SHA'), 'files': []}
    for relative in allowlist:
        source = root / relative
        if not source.exists():
            continue
        assert not source.is_symlink() and source.is_file()
        data = source.read_bytes()
        assert 0 < len(data) < 8 * 1024 * 1024
        if source.suffix == '.png':
            assert data.startswith(b'\x89PNG\r\n\x1a\n')
            width, height = struct.unpack('>II', data[16:24])
            assert 100 <= width <= 4096 and 100 <= height <= 4096
        else:
            json.loads(data)
        target = evidence / relative
        target.parent.mkdir(exist_ok=True, parents=True)
        shutil.copyfile(source, target)
        manifest['files'].append({'path': relative, 'bytes': len(data),
                                  'sha256': hashlib.sha256(data).hexdigest()})
    (evidence / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    actual = {str(path.relative_to(evidence)) for path in evidence.rglob('*') if path.is_file()}
    assert actual == {item['path'] for item in manifest['files']} | {'manifest.json'}
    print(f"Prepared {len(manifest['files'])} allowlisted synthetic evidence files; no audio or APKs")


if __name__ == '__main__':
    main()

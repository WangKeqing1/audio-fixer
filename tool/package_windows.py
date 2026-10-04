"""Build a portable Windows bundle only from a verified release build."""
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'build/windows/x64/runner/Release'
OUTPUT = ROOT / 'build/ci/windows'


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    required = [
        'audio_fixer.exe', 'flutter_windows.dll', 'data/app.so',
        'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
        'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    ]
    for name in required:
        path = RELEASE / name
        assert path.is_file() and path.stat().st_size > 0, f'Missing {name}'
    exe = (RELEASE / 'audio_fixer.exe').read_bytes()
    assert exe[:2] == b'MZ', 'Not a Windows executable'
    pe = struct.unpack_from('<I', exe, 0x3C)[0]
    assert exe[pe:pe + 4] == b'PE\0\0'
    assert struct.unpack_from('<H', exe, pe + 4)[0] == 0x8664, 'Not x64'
    smoke = json.loads((OUTPUT / 'release-smoke.json').read_text(encoding='utf-8-sig'))
    assert smoke['started'] is True
    version = re.search(r'^version:\s*([^+\s]+)', (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    readme = f'''Audio Fixer {version} - Windows x64 便携版\n\n1. 将整个 ZIP 解压到一个文件夹，再双击 audio_fixer.exe。\n2. 必须保留旁边的 DLL 和 data 文件夹，不能只移动 exe。\n3. 右上角文件夹按钮添加音乐目录，可扫描子文件夹。\n4. 选择音乐，查看已预选的可靠补全建议，再一次应用；已有资料和有分歧的结果默认保留。也可多选后统一预览并保存。\n5. 原文件保存前保留恢复备份并校验；有恢复提醒时先处理，不要手动删除应用数据。\n\nWindows 10/11 x64。使用 Windows 系统解码器试听，个别格式或缺少媒体组件时会提示不支持。Windows 版仍获取来源已有中文译文，暂不提供 Android ML Kit 本机机器翻译。\n本包未进行代码签名，Windows 可能显示未知发布者提示。无安装器、无管理员权限要求。\n应用缓存与任务存于用户的应用支持目录。使用时不会上传音频；在线查询会发送歌名、歌手、专辑和时长。\n\n源码提交：{commit}\n仓库：https://github.com/WangKeqing1/audio-fixer\n'''
    (RELEASE / '使用说明.txt').write_text(readme, encoding='utf-8-sig')
    files = sorted(p for p in RELEASE.rglob('*') if p.is_file() and p.suffix.lower() not in {'.pdb', '.exp', '.lib'} and p.name != 'build-manifest.json')
    manifest = {
        'version': version, 'commit': commit, 'platform': 'windows-x64',
        'optimized': True, 'code_signed': False,
        'run_id': os.environ.get('GITHUB_RUN_ID'),
        'files': {p.relative_to(RELEASE).as_posix(): {'bytes': p.stat().st_size, 'sha256': sha256(p)} for p in files},
    }
    manifest_path = RELEASE / 'build-manifest.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    files.append(manifest_path)
    archive = OUTPUT / f'audio-fixer-{version}-windows-x64.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for path in files:
            output.write(path, 'Audio Fixer/' + path.relative_to(RELEASE).as_posix())
    with zipfile.ZipFile(archive) as result:
        assert result.testzip() is None
        for name, info in manifest['files'].items():
            assert hashlib.sha256(result.read('Audio Fixer/' + name)).hexdigest() == info['sha256'], name
    result = {'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': sha256(archive), 'commit': commit, 'version': version}
    (OUTPUT / 'package.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

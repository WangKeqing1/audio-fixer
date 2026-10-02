#!/usr/bin/env python3
"""Launch the normal optimized QA app after the real native integration test.

This smoke uses lib/main.dart, not the integration harness, and never presses a
query or connection-test button. Screenshots contain the same synthetic media.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import time

from android_runtime_ci import AndroidRuntime, PACKAGE


def main() -> None:
    runtime = AndroidRuntime('emulator-5554', Path('build/android_runtime'))
    prior = json.loads((runtime.output / 'summary.json').read_text())
    assert prior['passed'] and prior['synthetic_only']
    apk = Path('build/app/outputs/flutter-apk/app-x86_64-release.apk')
    assert apk.is_file()
    runtime.adb('install', '-r', str(apk), timeout=90)
    runtime.adb('shell', 'am', 'force-stop', PACKAGE)
    launch = runtime.adb('shell', 'am', 'start', '-W', '-n',
                         PACKAGE + '/com.audiofixer.audio_fixer.MainActivity').stdout
    assert 'Status: ok' in launch, launch
    time.sleep(6)
    pid = runtime.adb('shell', 'pidof', PACKAGE).stdout.strip()
    assert re.fullmatch(r'\d+', pid), 'Packaged app process did not survive launch'
    activity = runtime.adb('shell', 'dumpsys', 'activity', 'activities').stdout
    assert any(PACKAGE in line and ('mResumedActivity' in line or 'topResumedActivity' in line)
               for line in activity.splitlines()), \
        'Normal app is not the resumed activity'
    native_logs = runtime.adb('logcat', '-d', '--pid=' + pid, '-t', '300').stdout
    assert 'FATAL EXCEPTION' not in native_logs and 'Unhandled Exception:' not in native_logs, \
        'Normal app emitted a fatal or unhandled exception during launch'
    runtime.screenshot('packaged_library')

    # UIAutomator may expose only the Flutter surface if platform semantics is
    # unavailable. Preserve the actual launch screenshot and say so explicitly,
    # rather than inventing a settings tap or changing accessibility settings.
    nodes = runtime.hierarchy()
    settings = [node for node in nodes if node.get('package') == PACKAGE
                and node.get('clickable') == 'true'
                and any(value == '设置' or value.startswith('设置\n')
                        for value in (node.get('text', ''), node.get('content-desc', '')))]
    settings_rendered = False
    if len(settings) == 1:
        runtime.tap(settings[0], 'packaged_settings')
        time.sleep(2)
        nodes = runtime.hierarchy()
        settings_rendered = any('补全内容' in (node.get('text', '') + node.get('content-desc', ''))
                                or '歌曲信息' in (node.get('text', '') + node.get('content-desc', ''))
                                for node in nodes)
        runtime.screenshot('packaged_settings')
        assert settings_rendered, 'Observed settings navigation did not render expected settings text'
    result = {'normal_entrypoint': 'lib/main.dart', 'optimized_release': True,
              'qa_identity': PACKAGE, 'debug_test_signing': True,
              'synthetic_only': True, 'launch_survived': True,
              'resumed_activity_verified': True, 'launch_exceptions': False,
              'online_query_buttons_pressed': False,
              'settings_semantics_verified': settings_rendered,
              'settings_limit': None if settings_rendered else 'No unique accessible Settings control; no coordinate guesses'}
    (runtime.output / 'packaged-smoke.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write('\n### Normal optimized QA entrypoint smoke\n')
            stream.write('- lib/main.dart launched and remained the resumed activity without launch exceptions\n')
            stream.write('- Actual packaged-app screenshot captured; no online query buttons pressed\n')
            stream.write(f"- Settings semantics verified: {settings_rendered}\n")


if __name__ == '__main__':
    main()

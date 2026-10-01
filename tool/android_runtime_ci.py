#!/usr/bin/env python3
"""Run a synthetic Android native test and independently verify pulled bytes.

The emulator must already be booted. This helper grants no permissions through
adb: it taps only the real, freshly inspected Android dialogs. It never uploads
media, screenshots, logs, APKs, or artifacts. All evidence stays under build/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET

from generate_audio_fixtures import generate
from validate_audio import compare, inspect

PACKAGE = "com.audiofixer.audio_fixer.qa"
SOURCE_DEVICE = "/sdcard/Music/AudioFixerSynthetic/native_fixture.mp3"
EXPORT_DEVICE = "/sdcard/Download/native_fixture-fixed.mp3"
PHASES = ("permission_deny", "permission_grant", "save_cancel", "save_confirm")
CHECKPOINTS = ("permission_denied_ready", "details_ready", "review_ready",
               "cancelled_ready", "saved_ready")
SMOKE_SCREENS = ("packaged_library", "packaged_settings")


class AndroidRuntime:
    def __init__(self, serial: str, output: Path):
        self.serial = serial
        self.output = output
        self.actions: list[dict] = []
        self.save_observed: set[str] = set()

    def adb(self, *args: str, timeout: int = 30, check: bool = True,
            binary: bool = False) -> subprocess.CompletedProcess:
        return subprocess.run(["adb", "-s", self.serial, *args],
                              capture_output=True, text=not binary,
                              timeout=timeout, check=check)

    def phase(self) -> str:
        result = self.adb("exec-out", "run-as", PACKAGE, "cat",
                          "files/native_runtime_phase", check=False)
        return result.stdout.strip() if result.returncode == 0 else ""

    def hierarchy(self) -> list[ET.Element]:
        # Fresh UI evidence supplies every coordinate; never hardcode a tap.
        self.adb("shell", "uiautomator", "dump", "/sdcard/runtime-window.xml")
        xml = self.adb("exec-out", "cat", "/sdcard/runtime-window.xml").stdout
        return list(ET.fromstring(xml).iter("node"))

    def screenshot(self, name: str) -> None:
        assert name in PHASES + CHECKPOINTS + SMOKE_SCREENS
        screenshots = self.output / "screenshots"
        screenshots.mkdir(exist_ok=True)
        data = self.adb("exec-out", "screencap", "-p", binary=True).stdout
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Android screenshot was not PNG data")
        (screenshots / f"{name}.png").write_bytes(data)

    def tap(self, node: ET.Element, phase: str) -> None:
        bounds = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
                              node.get("bounds", ""))
        if not bounds or node.get("enabled") != "true":
            raise RuntimeError(f"Refusing disabled or unbounded UI node in {phase}")
        x1, y1, x2, y2 = map(int, bounds.groups())
        if x2 <= x1 or y2 <= y1:
            raise RuntimeError(f"Refusing empty UI bounds in {phase}")
        self.adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
        self.actions.append({"phase": phase, "resource_id": node.get("resource-id"),
                             "text": node.get("text"), "bounds": node.get("bounds")})
        print(f"Native UI: {phase}: {node.get('resource-id')} {node.get('text')}", flush=True)

    def act(self, phase: str, nodes: list[ET.Element]) -> bool:
        if phase.startswith("permission_"):
            suffix = ("permission_deny_button" if phase == "permission_deny"
                      else "permission_allow_button")
            matches = [node for node in nodes
                       if node.get("package") in {"com.android.permissioncontroller",
                                                  "com.google.android.permissioncontroller"}
                       and node.get("resource-id", "").endswith(":id/" + suffix)]
            if len(matches) == 1:
                self.screenshot(phase)
                self.tap(matches[0], phase)
                return True
            return False

        document_nodes = [node for node in nodes
                          if node.get("package") == "com.android.documentsui"]
        # A create-document filename proves this is our expected save sheet.
        names = [node for node in document_nodes
                 if node.get("resource-id") == "android:id/title"
                 and node.get("class") == "android.widget.EditText"
                 and node.get("text") == "native_fixture-fixed.mp3"]
        if names:
            self.save_observed.add(phase)
        if phase == "save_confirm" and phase in self.save_observed:
            roots = [node for node in document_nodes
                     if node.get("resource-id") == "com.android.documentsui:id/roots_list"]
            downloads = [node for root in roots for node in root.iter("node")
                         if node.get("resource-id") == "android:id/title"
                         and node.get("text") == "Downloads"]
            if len(downloads) == 1:
                self.tap(downloads[0], "choose_downloads")
                return False
        if not names:
            return False
        if phase == "save_cancel":
            if any(node.get("package") == "com.android.inputmethod.latin" for node in nodes):
                self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
                return False
            self.screenshot(phase)
            self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
            self.actions.append({"phase": phase, "action": "back",
                                 "observed_filename": "native_fixture-fixed.mp3"})
            print("Native UI: cancelled the observed create-document sheet", flush=True)
            return True

        # Choose the actual Downloads root. Only tap controls observed in the
        # current hierarchy; all other providers/locations are out of scope.
        toolbars = [node for node in document_nodes
                    if node.get("resource-id") == "com.android.documentsui:id/toolbar"]
        toolbar_downloads = [node for toolbar in toolbars for node in toolbar.iter("node")
                             if node.get("text") == "Downloads"]
        if not toolbar_downloads:
            drawers = [node for node in document_nodes
                       if node.get("content-desc") in {"Show roots", "Open navigation drawer"}]
            if drawers:
                self.tap(drawers[0], "open_save_locations")
            return False
        saves = [node for node in document_nodes
                 if node.get("resource-id") == "android:id/button1"
                 and node.get("text", "").upper() == "SAVE"
                 and node.get("enabled") == "true"]
        if len(saves) == 1:
            self.screenshot(phase)
            self.tap(saves[0], phase)
            return True
        return False

    def seed(self) -> Path:
        fixtures = self.output / "generated"
        manifest = generate(fixtures)
        assert manifest["synthetic_only"] is True
        original = fixtures / "cover_without_lyrics_mp3.mp3"
        baseline = inspect(original)
        assert baseline["full_decode_ok"] and baseline["cover_count"] == 1
        assert not baseline["lyrics_present"]
        (self.output / "source-baseline.json").write_text(json.dumps(baseline, indent=2))
        self.adb("shell", "mkdir", "-p", "/sdcard/Music/AudioFixerSynthetic")
        self.adb("push", str(original), SOURCE_DEVICE)
        self.adb("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                 "-d", "file://" + SOURCE_DEVICE)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            result = self.adb("shell", "content", "query", "--uri",
                              "content://media/external/audio/media", "--projection",
                              "_id:_display_name:is_music", check=False)
            if any("_display_name=native_fixture.mp3" in line and "is_music=1" in line
                   for line in result.stdout.splitlines()):
                (self.output / "mediastore-seed.txt").write_text(result.stdout)
                print("Synthetic covered MP3 is indexed as music by Android MediaStore", flush=True)
                return original
            time.sleep(2)
        raise RuntimeError("Synthetic MP3 was not indexed in MediaStore within 60 seconds")

    def test(self) -> None:
        env = dict(os.environ, ORG_GRADLE_PROJECT_audioFixerQa="true")
        env.pop("AUDIO_FIXER_REAL_INPUTS", None)
        # A preceding release build excludes integration_test's native plugin.
        # Restore the debug registrant while enforcing the committed lockfile.
        subprocess.run(["flutter", "pub", "get", "--enforce-lockfile"],
                       env=env, check=True, timeout=180)
        command = ["flutter", "test", "integration_test/native_flow_test.dart", "-d", self.serial,
                   "--no-pub", "--reporter", "expanded", "--timeout", "8m"]
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        assert process.stdout is not None

        def log_output() -> None:
            with (self.output / "flutter-native-test.txt").open("w") as log:
                assert process.stdout is not None
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    print(line, end="", flush=True)

        reader = threading.Thread(target=log_output, daemon=True)
        reader.start()
        handled: list[str] = []
        captured: set[str] = set()
        last_phase = ""
        phase_started = time.monotonic()
        overall_deadline = time.monotonic() + 22 * 60
        try:
            while process.poll() is None:
                if time.monotonic() > overall_deadline:
                    raise RuntimeError("Android build/runtime exceeded its bounded 22-minute window")
                phase = self.phase()
                if phase != last_phase:
                    phase_started = time.monotonic()
                    last_phase = phase
                    if phase:
                        print(f"Native test phase: {phase}", flush=True)
                if phase and phase != "complete" and time.monotonic() - phase_started > 85:
                    raise RuntimeError(f"Native phase stalled: {phase}")
                if phase in CHECKPOINTS and phase not in captured:
                    self.screenshot(phase)
                    subprocess.run(["adb", "-s", self.serial, "shell", "-T", "run-as", PACKAGE,
                                    "tee", "files/native_runtime_ack"],
                                   input=phase, capture_output=True, text=True, check=True, timeout=15)
                    captured.add(phase)
                if phase in PHASES and phase not in handled:
                    if phase != PHASES[len(handled)]:
                        raise RuntimeError(f"Unexpected native dialog order: {handled} then {phase}")
                    try:
                        nodes = self.hierarchy()
                    except (subprocess.CalledProcessError, ET.ParseError) as error:
                        print(f"UI transition, will re-observe: {error}", flush=True)
                        time.sleep(1)
                        continue
                    if self.act(phase, nodes):
                        handled.append(phase)
                time.sleep(1)
            reader.join(timeout=5)
            if process.returncode:
                raise RuntimeError(f"Flutter native test failed with exit {process.returncode}")
            if handled != list(PHASES):
                raise RuntimeError(f"Not all actual Android dialogs were exercised: {handled}")
            if captured != set(CHECKPOINTS):
                raise RuntimeError(f"Missing synthetic app screenshot checkpoints: {captured}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            (self.output / "native-ui-actions.json").write_text(json.dumps(self.actions, indent=2))

    def verify(self, original: Path) -> None:
        result = json.loads(self.adb("exec-out", "run-as", PACKAGE, "cat",
                                     "files/native_runtime_result.json").stdout)
        assert result["passed"] and result["synthetic_only"]
        assert result["mocked_native_channels"] is False
        assert result["online_provider_calls"] == 0
        assert result["source_uri"].startswith("content://media/")
        assert result["export_uri"].startswith("content://")
        assert result["source_uri"] != result["export_uri"]
        (self.output / "native-test-result.json").write_text(json.dumps(result, indent=2))
        # The real system save UI was explicitly navigated to Downloads. Pull
        # from shared storage independently of the app's tagged temporary copy.
        found = self.adb("shell", "find", "/sdcard/Download", "-maxdepth", "1",
                         "-name", "native_fixture-fixed*.mp3").stdout.splitlines()
        assert found == [EXPORT_DEVICE], f"Unexpected export or cancellation leftovers: {found}"
        pulled_original = self.output / "source-after.mp3"
        pulled_export = self.output / "exported-from-system-save.mp3"
        self.adb("pull", SOURCE_DEVICE, str(pulled_original))
        self.adb("pull", EXPORT_DEVICE, str(pulled_export))
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest(original) == digest(pulled_original), "Android source bytes changed"
        assert digest(original) != digest(pulled_export), "Export did not add the selected tag"
        checked = compare(pulled_original, pulled_export,
                          expected_tags=result["expected_tags"],
                          expected_cover_sha256=result["cover_sha256"])
        (self.output / "independent-audio-check.json").write_text(json.dumps(checked, indent=2))
        assert checked["passed"], checked["checks"]
        summary = {"passed": True, "synthetic_only": True,
                   "native_checks": len(result["checks"]),
                   "real_system_dialogs": len(PHASES),
                   "independent_audio_checks": len(checked["checks"]),
                   "original_whole_file_sha256_unchanged": True,
                   "existing_cover_preserved": True,
                   "audio_uploaded": False}
        (self.output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a") as stream:
                stream.write("### Android native synthetic runtime: PASS\n")
                stream.write(f"- {summary['native_checks']} app/native checks; four real Android dialogs\n")
                stream.write(f"- {summary['independent_audio_checks']} independent FFmpeg checks\n")
                stream.write("- Original whole-file hash unchanged; encoded audio, decoded samples, and cover preserved\n")
                stream.write("- Synthetic fixtures only; no audio or APKs published\n")
                stream.write("- Allowlisted synthetic screenshots and sanitized check summaries retained for one day\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--output", type=Path, default=Path("build/android_runtime"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = AndroidRuntime(args.serial, args.output)
    original = runtime.seed()
    runtime.test()
    runtime.verify(original)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::Android native runtime validation failed: {error}", file=sys.stderr, flush=True)
        raise

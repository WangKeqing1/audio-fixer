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
UNAPPROVED_DEVICE = "/sdcard/Music/AudioFixerSynthetic/native_unapproved.mp3"
EXPORT_DEVICE = "/sdcard/Download/native_fixture-fixed.mp3"
PHASES = ("permission_deny", "permission_grant", "save_cancel", "save_confirm",
          "original_cancel", "original_confirm")
CHECKPOINTS = ("permission_denied_ready", "details_ready", "review_ready",
               "cancelled_ready", "exported_ready", "original_cancelled_ready",
               "bulk_review_ready", "saved_ready")
RECOVERY_PHASES = ("recovery_export",)
RECOVERY_CHECKPOINTS = ("recovery_export_corrupted", "recovery_export_restored")
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

    def test_command(self, test_file: str, *extra: str) -> list[str]:
        # Flutter 3.47 defaults to uninstalling integration apps during teardown.
        # Keep this disposable QA install so host-side private-file evidence,
        # fresh-Activity recovery setup and the normal packaged smoke survive.
        return ["flutter", "test", test_file, "-d", self.serial, "--no-pub",
                "--no-uninstall", "--reporter", "expanded", *extra]

    def read_app_json(self, relative_path: str) -> dict:
        # Shell v2 propagates run-as/cat errors instead of letting diagnostics be
        # mistaken for JSON when an app or evidence file is missing.
        result = self.adb("shell", "-T", "run-as", PACKAGE, "cat", relative_path)
        value = json.loads(result.stdout)
        if not isinstance(value, dict):
            raise RuntimeError("Expected a JSON object in native evidence: " + relative_path)
        return value

    def phase(self, path: str = "files/native_runtime_phase") -> str:
        # exec-out can return success while run-as reports an unknown package
        # during the initial APK build. Shell v2 propagates the remote status;
        # the allowlist also prevents diagnostics from becoming app phases.
        result = self.adb("shell", "-T", "run-as", PACKAGE, "cat",
                          path, check=False)
        value = result.stdout.strip()
        known = PHASES + CHECKPOINTS + RECOVERY_PHASES + RECOVERY_CHECKPOINTS + ("read_details", "complete", "recovery_complete")
        return value if result.returncode == 0 and value in known else ""

    def hierarchy(self) -> list[ET.Element]:
        # Fresh UI evidence supplies every coordinate; never hardcode a tap.
        self.adb("shell", "uiautomator", "dump", "/sdcard/runtime-window.xml")
        xml = self.adb("exec-out", "cat", "/sdcard/runtime-window.xml").stdout
        return list(ET.fromstring(xml).iter("node"))

    def screenshot(self, name: str) -> None:
        assert name in PHASES + CHECKPOINTS + RECOVERY_PHASES + SMOKE_SCREENS
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

    def act(self, phase: str, nodes: list[ET.Element],
            file_name: str = "native_fixture-fixed.mp3") -> bool:
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

        if phase in {"original_cancel", "original_confirm"}:
            # MediaStore's write-consent surface belongs to MediaProvider. A
            # system button alone is insufficient: require the QA app identity
            # and explicit audio-modification wording in this fresh hierarchy.
            media_nodes = [node for node in nodes if node.get("package") in {
                "com.android.providers.media.module", "com.google.android.providers.media.module",
                "com.android.providers.media"}]
            words = " ".join(node.get("text", "") for node in media_nodes).lower()
            if not ("audio fixer qa" in words and "modify" in words and "audio" in words):
                return False
            button_id = "android:id/button2" if phase == "original_cancel" else "android:id/button1"
            labels = {"don't allow", "don’t allow", "deny", "cancel"} if phase == "original_cancel" else {"allow"}
            buttons = [node for node in media_nodes
                       if node.get("resource-id") == button_id
                       and node.get("text", "").lower() in labels
                       and node.get("enabled") == "true"]
            if len(buttons) != 1:
                return False
            self.screenshot(phase)
            self.tap(buttons[0], phase)
            return True

        if phase not in {"save_cancel", "save_confirm", "recovery_export"}:
            return False
        document_nodes = [node for node in nodes
                          if node.get("package") == "com.android.documentsui"]
        # A create-document filename proves this is our expected save sheet.
        names = [node for node in document_nodes
                 if node.get("resource-id") == "android:id/title"
                 and node.get("class") == "android.widget.EditText"
                 and node.get("text") == file_name]
        if names:
            self.save_observed.add(phase)
        if phase in {"save_confirm", "recovery_export"} and phase in self.save_observed:
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
                                 "observed_filename": file_name})
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
        for destination in (SOURCE_DEVICE, UNAPPROVED_DEVICE):
            self.adb("push", str(original), destination)
            self.adb("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                     "-d", "file://" + destination)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            result = self.adb("shell", "content", "query", "--uri",
                              "content://media/external/audio/media", "--projection",
                              "_id:_display_name:is_music", check=False)
            if all(any("_display_name=" + name in line and "is_music=1" in line
                       for line in result.stdout.splitlines())
                   for name in ("native_fixture.mp3", "native_unapproved.mp3")):
                (self.output / "mediastore-seed.txt").write_text(result.stdout)
                print("Synthetic covered MP3 is indexed as music by Android MediaStore", flush=True)
                return original
            time.sleep(2)
        raise RuntimeError("Synthetic MP3 was not indexed in MediaStore within 60 seconds")

    def test(self) -> None:
        env = dict(os.environ, ORG_GRADLE_PROJECT_audioFixerQa="true")
        env.pop("AUDIO_FIXER_REAL_INPUTS", None)
        # A preceding release build excludes integration_test's native plugin.
        # Restore the debug registrant from cached packages only, enforcing the
        # committed lockfile without any dependency network requests.
        subprocess.run(["flutter", "pub", "get", "--offline", "--enforce-lockfile"],
                       env=env, check=True, timeout=180)
        command = self.test_command("integration_test/native_flow_test.dart", "--timeout", "11m")
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
                    if phase in {"exported_ready", "original_cancelled_ready"}:
                        pulled = self.output / (phase + ".mp3")
                        self.adb("pull", SOURCE_DEVICE, str(pulled))
                        baseline = self.output / "generated/cover_without_lyrics_mp3.mp3"
                        assert hashlib.sha256(pulled.read_bytes()).digest() == hashlib.sha256(baseline.read_bytes()).digest(), \
                            "Original bytes changed during export or cancelled write consent"
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

    def verify_recovery(self, original: Path) -> None:
        # The only fabricated input is an interrupted persisted state. The
        # recovery bridge, backup validation, truncating writer, fsync, reread,
        # cleanup and notice acknowledgement all execute on actual Android.
        self.adb("shell", "am", "force-stop", PACKAGE)
        app_root = self.adb("exec-out", "run-as", PACKAGE, "pwd").stdout.strip()
        assert app_root in {"/data/user/0/" + PACKAGE, "/data/data/" + PACKAGE}, app_root
        digest = hashlib.sha256(original.read_bytes()).hexdigest()
        target = app_root + "/files/audio/" + digest + ".audio"
        backup = app_root + "/no_backup/original_audio_backups/00000000-0000-4000-8000-000000000003.backup"
        values = {"stage": "writing", "target": "file://" + target,
                  "backup": backup, "originalHash": digest,
                  "outputHash": hashlib.sha256(b"synthetic interrupted tagged output").hexdigest()}
        document = ET.Element("map")
        for key, value in values.items():
            ET.SubElement(document, "string", {"name": key}).text = value
        journal = ET.tostring(document, encoding="utf-8", xml_declaration=True)
        current_bytes = original.read_bytes()[:32]
        current_hash = hashlib.sha256(current_bytes).hexdigest()
        assert current_bytes.startswith(b"ID3")
        export_name = "audio-fixer-recovery-preserved-" + current_hash[:8] + ".mp3"
        expected = json.dumps({"synthetic_only": True, "target_path": target,
                               "backup_path": backup, "original_sha256": digest,
                               "current_sha256": current_hash}).encode()
        self.adb("shell", "run-as", PACKAGE, "mkdir", "-p", "files/audio",
                 "no_backup/original_audio_backups", "shared_prefs")
        writes = {target: current_bytes, backup: original.read_bytes(),
                  "shared_prefs/audio_fixer_original_recovery.xml": journal,
                  "files/native_recovery_expected.json": expected}
        for destination, data in writes.items():
            subprocess.run(["adb", "-s", self.serial, "shell", "-T", "run-as", PACKAGE,
                            "tee", destination], input=data, capture_output=True,
                           check=True, timeout=30)
        env = dict(os.environ, ORG_GRADLE_PROJECT_audioFixerQa="true")
        env.pop("AUDIO_FIXER_REAL_INPUTS", None)
        process = subprocess.Popen(self.test_command("integration_test/native_recovery_test.dart"),
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        assert process.stdout is not None
        def log_recovery() -> None:
            with (self.output / "flutter-native-recovery.txt").open("w") as log:
                assert process.stdout is not None
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    print(line, end="", flush=True)
        reader = threading.Thread(target=log_recovery, daemon=True)
        reader.start()
        handled = False
        checked_exports: set[str] = set()
        deadline = time.monotonic() + 420
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError("Native conflict-recovery test exceeded seven minutes")
                phase = self.phase("files/native_recovery_phase")
                if phase in RECOVERY_CHECKPOINTS and phase not in checked_exports:
                    replacement = self.output / (phase + ".bin")
                    replacement.write_bytes(b"synthetic modified export" if phase == "recovery_export_corrupted" else current_bytes)
                    self.adb("push", str(replacement), "/sdcard/Download/" + export_name)
                    subprocess.run(["adb", "-s", self.serial, "shell", "-T", "run-as", PACKAGE,
                                    "tee", "files/native_recovery_ack"], input=phase,
                                   capture_output=True, text=True, check=True, timeout=15)
                    checked_exports.add(phase)
                if not handled and phase == "recovery_export":
                    try:
                        nodes = self.hierarchy()
                    except (subprocess.CalledProcessError, ET.ParseError):
                        time.sleep(1)
                        continue
                    handled = self.act("recovery_export", nodes, file_name=export_name)
                time.sleep(1)
            reader.join(timeout=5)
            if process.returncode:
                raise RuntimeError(f"Native conflict-recovery test failed with exit {process.returncode}")
            if not handled:
                raise RuntimeError("Native recovery did not exercise its actual preserved-version export picker")
            if checked_exports != set(RECOVERY_CHECKPOINTS):
                raise RuntimeError("Recovery did not revalidate its exported document before safe finish")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            (self.output / "native-ui-actions.json").write_text(json.dumps(self.actions, indent=2))
        result = self.read_app_json("files/native_recovery_result.json")
        assert result["passed"] and result["synthetic_only"]
        assert result["injected_interrupted_journal"] is True
        assert result["mocked_native_channels"] is False
        assert result["current_sha256"] == current_hash
        preserved_export = self.output / "preserved-current-export.mp3"
        self.adb("pull", "/sdcard/Download/" + export_name, str(preserved_export))
        assert preserved_export.read_bytes() == current_bytes, "Recovery export did not preserve the third-hash bytes"
        restored = self.adb("exec-out", "run-as", PACKAGE, "cat", target, binary=True).stdout
        assert hashlib.sha256(restored).hexdigest() == digest
        restored_file = self.output / "restored-private-fixture.mp3"
        restored_file.write_bytes(restored)
        assert inspect(restored_file)["full_decode_ok"]
        (self.output / "native-recovery-result.json").write_text(json.dumps(result, indent=2))
        summary = json.loads((self.output / "summary.json").read_text())
        summary["passed"] = True
        summary["status"] = "passed"
        summary["native_seeded_recovery_checks"] = len(result["checks"])
        summary["native_seeded_recovery_passed"] = True
        summary["native_preserved_version_export_sha256_exact"] = True
        summary["real_recovery_export_dialogs"] = len(RECOVERY_PHASES)
        summary["timed_process_crash_tested"] = False
        (self.output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                stream.write("- Native conflict recovery preserved unknown bytes, explicitly restored the original and exported the retained version exactly\n")
                stream.write("- This verifies recovery from persisted state, not crash-timing or MediaStore permission-loss behavior\n")

    def verify(self, original: Path) -> None:
        result = self.read_app_json("files/native_runtime_result.json")
        assert result["passed"] and result["synthetic_only"]
        assert result["mocked_native_channels"] is False
        assert result["online_provider_calls"] == 0
        assert result["source_uri"].startswith("content://media/")
        assert result["export_uri"].startswith("content://")
        assert result["source_uri"] != result["export_uri"]
        assert result["original_save_status"] == "savedOriginal"
        assert result["batch_saved_original"] == 1
        assert result["batch_skipped_unapproved"] == 1
        backups = self.adb("exec-out", "run-as", PACKAGE, "ls",
                           "no_backup/original_audio_backups").stdout.strip()
        assert not backups, "Verified original backup was not acknowledged after task persistence"
        journal = self.adb("exec-out", "run-as", PACKAGE, "cat",
                           "shared_prefs/audio_fixer_original_recovery.xml").stdout
        assert not any(item.get("name") == "stage" for item in ET.fromstring(journal)), \
            "Verified original journal is still pending despite successful persistence"
        (self.output / "native-test-result.json").write_text(json.dumps(result, indent=2))
        # The real system save UI was explicitly navigated to Downloads. Pull
        # from shared storage independently of the app's tagged temporary copy.
        found = self.adb("shell", "find", "/sdcard/Download", "-maxdepth", "1",
                         "-name", "native_fixture-fixed*.mp3").stdout.splitlines()
        assert found == [EXPORT_DEVICE], f"Unexpected export or cancellation leftovers: {found}"
        pulled_original = self.output / "source-after.mp3"
        pulled_export = self.output / "exported-from-system-save.mp3"
        pulled_unapproved = self.output / "unapproved-after.mp3"
        self.adb("pull", SOURCE_DEVICE, str(pulled_original))
        self.adb("pull", EXPORT_DEVICE, str(pulled_export))
        self.adb("pull", UNAPPROVED_DEVICE, str(pulled_unapproved))
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest(original) != digest(pulled_original), "Original save did not add the selected tag"
        assert digest(original) == digest(pulled_unapproved), "Unapproved selected song was modified"
        assert digest(original) != digest(pulled_export), "Export did not add the selected tag"
        checked = compare(original, pulled_export,
                          expected_tags=result["expected_tags"],
                          expected_cover_sha256=result["cover_sha256"])
        (self.output / "independent-audio-check.json").write_text(json.dumps(checked, indent=2))
        assert checked["passed"], checked["checks"]
        original_checked = compare(original, pulled_original,
                                   expected_tags=result["expected_tags"],
                                   expected_cover_sha256=result["cover_sha256"])
        (self.output / "independent-original-check.json").write_text(json.dumps(original_checked, indent=2))
        assert original_checked["passed"], original_checked["checks"]
        summary = {"passed": False, "status": "awaiting_native_recovery",
                   "original_flow_passed": True, "synthetic_only": True,
                   "native_checks": len(result["checks"]),
                   "real_system_dialogs": len(PHASES),
                   "independent_audio_checks": len(checked["checks"]),
                   "source_unchanged_after_export_and_cancel": True,
                   "original_saved_and_revalidated": True,
                   "verified_original_backup_acknowledged": True,
                   "unapproved_source_sha256_unchanged": True,
                   "independent_original_checks": len(original_checked["checks"]),
                   "existing_cover_preserved": True,
                   "audio_uploaded": False}
        (self.output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a") as stream:
                stream.write("### Android native original-save/export flow: PASS\n")
                stream.write(f"- {summary['native_checks']} app/native checks; six real Android dialogs\n")
                stream.write(f"- {summary['independent_audio_checks']} independent FFmpeg checks\n")
                stream.write("- Export/cancel and unapproved-song hashes unchanged; approved original updated with audio and cover preserved\n")
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
    runtime.verify_recovery(original)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::Android native runtime validation failed: {error}", file=sys.stderr, flush=True)
        raise

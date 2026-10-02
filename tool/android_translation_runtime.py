#!/usr/bin/env python3
"""Opt-in model-download then no-INTERNET APK acceptance on a disposable emulator.

No OS network settings are changed. Both AOT probe APKs use one package and
signer; adb install -r retains app-private models and the original-text sentinel.
Only compact, authored synthetic probe JSON and public APK identity facts enter
an explicit evidence allowlist. No APK, model, audio, raw logs, or credentials
are published by this script.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

PACKAGE = "com.audiofixer.audio_fixer.qa.v030"
INTERNET = "android.permission.INTERNET"
MARKER = "AUDIO_FIXER_TRANSLATION_RESULT:"
PHASES = ("download", "offline")
EVIDENCE = ("download.json", "offline.json", "summary.json")


def checked(command: list[str], *, timeout: int = 90, env: dict | None = None) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True,
                          timeout=timeout, env=env).stdout


def result_from_log(text: str, phase: str) -> dict | None:
    values = []
    for line in text.splitlines():
        if MARKER not in line:
            continue
        payload = line.split(MARKER, 1)[1].strip()
        if len(payload.encode()) > 12_000:
            raise RuntimeError("Probe result exceeded bounded synthetic contract")
        value = json.loads(payload)
        if not isinstance(value, dict) or value.get("phase") != phase:
            continue
        if value.get("synthetic_only") is not True:
            raise RuntimeError("Refusing non-synthetic probe evidence")
        values.append(value)
    if len(values) > 1:
        raise RuntimeError("Ambiguous repeated probe results")
    return values[0] if values else None


def installed_permissions(dump: str) -> set[str]:
    """Read the package's requested permission block, never a substring guess."""
    lines = dump.splitlines()
    matches = [index for index, line in enumerate(lines)
               if line.strip() == "requested permissions:"]
    if len(matches) != 1:
        raise RuntimeError("Expected one installed-package requested-permission block")
    index = matches[0]
    indent = len(lines[index]) - len(lines[index].lstrip())
    permissions = set()
    for line in lines[index + 1:]:
        if not line.strip():
            continue
        if len(line) - len(line.lstrip()) <= indent:
            break
        permission = line.strip()
        if not re.fullmatch(r"[A-Za-z0-9_.]+", permission):
            raise RuntimeError("Unexpected installed permission syntax")
        permissions.add(permission)
    if not permissions:
        raise RuntimeError("Missing installed requested permissions; cannot prove isolation")
    return permissions


def signature_digest(report: str) -> str:
    if "Number of signers: 1" not in report:
        raise RuntimeError("Probe requires one verified signer")
    hashes = re.findall(r"^Signer #1 certificate SHA-256 digest: ([a-f0-9]{64})$", report, re.M)
    if len(hashes) != 1:
        raise RuntimeError("Missing APK signing certificate fingerprint")
    return hashes[0]


def create_evidence(output: Path) -> None:
    evidence = output / "evidence"
    evidence.mkdir(exist_ok=False)
    files = []
    for name in EVIDENCE:
        source = output / name
        if not source.exists():
            continue
        if not source.is_file() or source.is_symlink():
            raise RuntimeError("Refusing non-file translation evidence")
        data = source.read_bytes()
        value = json.loads(data)
        if value.get("synthetic_only") is not True or len(data) > 32_000:
            raise RuntimeError("Refusing unexpected translation evidence")
        shutil.copyfile(source, evidence / name)
        files.append({"path": name, "bytes": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
    (evidence / "manifest.json").write_text(json.dumps({
        "synthetic_only": True, "retention_days": 1,
        "commit": os.environ.get("SOURCE_COMMIT") or os.environ.get("GITHUB_SHA"), "files": files,
    }, indent=2) + "\n")


class TranslationRuntime:
    def __init__(self, serial: str, output: Path):
        if not re.fullmatch(r"emulator-\d+", serial):
            raise RuntimeError("Only an explicitly disposable emulator is supported")
        self.serial = serial
        self.output = output
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        if not sdk:
            raise RuntimeError("ANDROID_HOME is required")
        self.build_tools = Path(sdk) / "build-tools/36.0.0"

    def adb(self, *arguments: str, timeout: int = 90) -> str:
        return checked(["adb", "-s", self.serial, *arguments], timeout=timeout)

    def build(self, phase: str) -> tuple[Path, dict]:
        if phase not in PHASES:
            raise ValueError("Unknown translation phase")
        env = dict(os.environ, ORG_GRADLE_PROJECT_audioFixerQa="true",
                   ORG_GRADLE_PROJECT_audioFixerTranslationProbe="true",
                   ORG_GRADLE_PROJECT_audioFixerTranslationOffline=str(phase == "offline").lower())
        env.pop("AUDIO_FIXER_REAL_INPUTS", None)
        command = ["flutter", "build", "apk", "--release", "--split-per-abi",
                   "--target-platform", "android-x64", "--target", "tool/native_translation_probe.dart",
                   f"--dart-define=AUDIO_FIXER_TRANSLATION_PROBE_PHASE={phase}", "--pub"]
        print(f"Building synthetic {phase} AOT probe; offline overlay={phase == 'offline'}", flush=True)
        subprocess.run(command, env=env, check=True, timeout=900, stdin=subprocess.DEVNULL)
        checked(["git", "diff", "--exit-code", "--", "pubspec.lock"])
        source = Path("build/app/outputs/flutter-apk/app-x86_64-release.apk")
        apk = self.output / f"{phase}-probe-local.apk"
        shutil.copyfile(source, apk)
        badging = checked([str(self.build_tools / "aapt"), "dump", "badging", str(apk)])
        if not re.search(rf"^package: name='{re.escape(PACKAGE)}' ", badging, re.M):
            raise RuntimeError("Unexpected probe application identity")
        if "native-code: 'x86_64'" not in badging or "application-debuggable" in badging:
            raise RuntimeError("Probe must be optimized non-debuggable x86_64 AOT")
        permissions = set(re.findall(r"^uses-permission(?:-sdk-\d+)?: name='([^']+)'", badging, re.M))
        if (INTERNET in permissions) != (phase == "download"):
            raise RuntimeError(f"Merged {phase} APK INTERNET permission is not as expected")
        merged_manifest = checked([str(self.build_tools / "aapt"), "dump", "xmltree", str(apk), "AndroidManifest.xml"])
        if "com.google.mlkit.common.internal.MlKitInitProvider" in merged_manifest:
            raise RuntimeError("Merged probe APK still auto-initializes ML Kit before explicit SDK use")
        signer = signature_digest(checked([str(self.build_tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)]))
        return apk, {"package": PACKAGE, "certificate_sha256": signer,
                     "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
                     "internet_declared": INTERNET in permissions,
                     "optimized_release": True, "debuggable": False,
                     "mlkit_auto_init_provider_absent": True}

    def run(self, phase: str, apk: Path, metadata: dict) -> dict:
        # Never uninstall or clear app data between phases. The sentinel proves
        # that the second install retained data, not merely that it used -r.
        installed = self.adb("install", "-r", str(apk), timeout=120)
        if "Success" not in installed:
            raise RuntimeError("Probe replacement was not confirmed by adb")
        dump = self.adb("shell", "dumpsys", "package", PACKAGE)
        permissions = installed_permissions(dump)
        if (INTERNET in permissions) != (phase == "download"):
            raise RuntimeError("Installed package INTERNET permission differs from intended phase")
        if phase == "offline" and re.search(r"android\.permission\.INTERNET:\s*granted=true", dump):
            raise RuntimeError("Installed offline package still has an INTERNET grant")
        print(f"Installed synthetic {phase} probe: INTERNET requested={INTERNET in permissions}", flush=True)
        self.adb("shell", "am", "force-stop", PACKAGE)
        started = self.adb("shell", "am", "start", "-W", "-n",
                           PACKAGE + "/com.audiofixer.audio_fixer.MainActivity")
        if "Status: ok" not in started:
            raise RuntimeError("Probe activity did not launch")
        pid = self.adb("shell", "pidof", PACKAGE).strip()
        if not re.fullmatch(r"\d+", pid):
            raise RuntimeError("Probe must have exactly one live process")
        deadline = time.monotonic() + (18 * 60 if phase == "download" else 5 * 60)
        while time.monotonic() < deadline:
            logs = self.adb("logcat", "-d", "--pid=" + pid, "-v", "raw", "-s", "flutter:I")
            result = result_from_log(logs, phase)
            if result is not None:
                result["apk"] = metadata
                result["installed_internet_requested"] = INTERNET in permissions
                result["installed_internet_granted"] = bool(re.search(
                    r"android\.permission\.INTERNET:\s*granted=true", dump))
                (self.output / f"{phase}.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
                if result.get("passed") is not True:
                    raise RuntimeError(f"Synthetic {phase} probe failed: {result.get('error', 'unknown failure')}")
                print(f"Synthetic {phase} probe passed {len(result.get('checks', []))} checks", flush=True)
                return result
            try:
                current_pid = self.adb("shell", "pidof", PACKAGE).strip()
            except subprocess.CalledProcessError as error:
                raise RuntimeError(f"Synthetic {phase} probe exited before producing a result") from error
            if current_pid != pid:
                raise RuntimeError("Probe process changed unexpectedly; result attribution is unsafe")
            time.sleep(3)
        raise RuntimeError(f"Synthetic {phase} probe did not finish in its bounded observation window")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--output", type=Path, default=Path("build/android_translation_runtime"))
    parser.add_argument("--allow-model-download", action="store_true",
                        help="Explicitly permit official ML Kit language-model downloads on this disposable emulator")
    args = parser.parse_args()
    if not args.allow_model_download:
        parser.error("--allow-model-download is required; no models are downloaded implicitly")
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = TranslationRuntime(args.serial, args.output)
    production_manifest = Path("android/app/src/main/AndroidManifest.xml")
    original_manifest_bytes = production_manifest.read_bytes()
    if b'android.permission.INTERNET' not in original_manifest_bytes:
        raise RuntimeError("Normal app manifest must retain its existing INTERNET declaration")
    try:
        download_apk, download_identity = runtime.build("download")
        download = runtime.run("download", download_apk, download_identity)
        offline_apk, offline_identity = runtime.build("offline")
        if offline_identity["package"] != download_identity["package"] or offline_identity["certificate_sha256"] != download_identity["certificate_sha256"]:
            raise RuntimeError("Refusing update with changed package/signing identity")
        offline = runtime.run("offline", offline_apk, offline_identity)
        if download["sentinel_sha256"] != offline["sentinel_sha256"]:
            raise RuntimeError("Probe update did not retain app-private original text")
        if offline.get("model_download_requested") is not False:
            raise RuntimeError("Offline probe attempted a model download")
        required = {f"{language}_real_native_chinese_translation" for language in ("en", "fr")}
        required |= {f"{language}_real_service_preserves_lrc_timestamps_and_offset" for language in ("en", "fr")}
        if not required.issubset(offline.get("checks", [])) or offline.get("mocked_native_channels") is not False:
            raise RuntimeError("Offline result omitted required real bridge/service acceptance checks")
        if offline.get("phase_specific_fresh_synthetic_inputs") is not True:
            raise RuntimeError("Offline inference did not use fresh synthetic input")
        if production_manifest.read_bytes() != original_manifest_bytes:
            raise RuntimeError("Probe build modified the production manifest")
        summary = {"passed": True, "synthetic_only": True,
                   "same_package_and_certificate": True, "app_private_sentinel_retained": True,
                   "offline_installed_internet_permission_absent": True,
                   "offline_real_native_translation": True,
                   "os_network_settings_changed": False,
                   "production_manifest_unmodified_by_probe": True,
                   "languages": ["en", "fr"], "models_or_apks_uploaded": False}
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        create_evidence(args.output)


if __name__ == "__main__":
    main()

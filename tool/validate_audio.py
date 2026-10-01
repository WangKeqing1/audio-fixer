#!/usr/bin/env python3
"""Offline audio readability and exact payload/decoded-sample preservation checks.

Examples:
  python3 tool/validate_audio.py audit build/test_samples/generated/*.mp3 --report build/test_samples/audit.json
  python3 tool/validate_audio.py compare ORIGINAL EXPORTED --report build/test_samples/compare.json

Only ffmpeg/ffprobe and Python's standard library are used. No audio is played,
uploaded, rewritten, or sent to an API. Entire audio streams are decoded, not
just the first seconds. Successful decoding is evidence of a playable stream,
not proof of playback on an Android device. Reports omit all tag values (and
therefore lyrics); do not commit reports about private user-supplied files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=300)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def audio_hash(path: Path, *, decode: bool) -> tuple[str | None, str]:
    args = ["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", str(path),
            "-map", "0:a:0", "-c:a", "pcm_s32le" if decode else "copy",
            "-f", "hash", "-hash", "sha256", "-"]
    result = run(args)
    if result.returncode or not result.stdout.startswith("SHA256="):
        return None, result.stderr.strip()[:1200]
    return result.stdout.strip().split("=", 1)[1], result.stderr.strip()[:1200]


def probe(path: Path) -> tuple[subprocess.CompletedProcess, dict]:
    result = run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)])
    return result, json.loads(result.stdout or "{}")


def tag_values(data: dict) -> dict:
    values = dict(data.get("format", {}).get("tags", {}))
    for stream in data.get("streams", []):
        if stream.get("codec_type") == "audio":
            values.update(stream.get("tags", {}))
    return {key.lower(): value for key, value in values.items()}


def selected_value(tags: dict, key: str) -> str | None:
    # ffprobe exposes language-qualified USLT as lyrics-und/lyrics-eng, while
    # generic TXXX lyrics appear as lyrics. Require one unambiguous nonblank
    # value across the aliases; conflicting old/new lyrics must fail validation.
    if key.lower() == "lyrics":
        values = {value for name, value in tags.items()
                  if (name == "lyrics" or name.startswith("lyrics-")) and value.strip()}
        return next(iter(values)) if len(values) == 1 else None
    return tags.get(key.lower())


def inspect(path: Path) -> dict:
    before = sha256_file(path)
    probe_result, data = probe(path)
    streams = data.get("streams", [])
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    covers = [s for s in streams if s.get("disposition", {}).get("attached_pic")]
    tags = tag_values(data)
    cover_hashes = []
    for cover in covers:
        cover_result = run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
                            "-map", f"0:{cover['index']}", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
        cover_hashes.append(cover_result.stdout.strip().split("=", 1)[1]
                            if cover_result.returncode == 0 and cover_result.stdout.startswith("SHA256=") else None)
    decoded_hash, decode_error = audio_hash(path, decode=True)
    packet_hash, packet_error = audio_hash(path, decode=False)
    result = {
        "file": path.name,
        "bytes": path.stat().st_size,
        "file_sha256": before,
        "source_unchanged": before == sha256_file(path),
        "probe_ok": probe_result.returncode == 0 and bool(audio),
        "full_decode_ok": decoded_hash is not None,
        "decoded_pcm_sha256": decoded_hash,
        "audio_packet_sha256": packet_hash,
        "duration_seconds": data.get("format", {}).get("duration"),
        "audio_streams": [{key: s.get(key) for key in
                           ("codec_name", "sample_rate", "channels", "channel_layout")}
                          for s in audio],
        "tag_keys": sorted(tags),
        "lyrics_present": any("lyric" in key.lower() for key in tags),
        "cover_count": len(covers),
        "cover_sha256": cover_hashes,
    }
    diagnostics = {"probe": probe_result.stderr.strip()[:1200], "decode": decode_error, "packets": packet_error}
    if any(diagnostics.values()):
        result["diagnostics"] = diagnostics
    return result


def compare(original: Path, exported: Path, *, allow_blank_tag_fill: bool = False,
            expected_tags: dict | None = None, expected_cover_sha256: str | None = None) -> dict:
    first, second = inspect(original), inspect(exported)
    before_tags = tag_values(probe(original)[1])
    after_tags = tag_values(probe(exported)[1])
    changed_tags = sorted(key for key, value in before_tags.items() if after_tags.get(key) != value)
    filled_blank_tags = [key for key in changed_tags if allow_blank_tag_fill and
                        key in {"title", "artist", "album", "lyrics"} and not before_tags[key].strip()]
    changed_tags = [key for key in changed_tags if key not in filled_blank_tags]
    mismatched_selected_tags = sorted(key for key, value in (expected_tags or {}).items()
                                     if selected_value(after_tags, key) != value)
    checks = {
        "selected_tag_values_match": not mismatched_selected_tags,
        "selected_cover_matches": expected_cover_sha256 is None or expected_cover_sha256 in second["cover_sha256"],
        "existing_covers_preserved": all(value is not None and value in second["cover_sha256"] for value in first["cover_sha256"]),
        "original_unchanged_during_check": first["source_unchanged"],
        "export_unchanged_during_check": second["source_unchanged"],
        "both_probe": first["probe_ok"] and second["probe_ok"],
        "both_fully_decode": first["full_decode_ok"] and second["full_decode_ok"],
        "existing_tag_values_preserved": not changed_tags,
        "audio_stream_parameters_match": first["audio_streams"] == second["audio_streams"],
        "encoded_audio_packets_identical": bool(first["audio_packet_sha256"]) and
            first["audio_packet_sha256"] == second["audio_packet_sha256"],
        "decoded_samples_identical": bool(first["decoded_pcm_sha256"]) and
            first["decoded_pcm_sha256"] == second["decoded_pcm_sha256"],
    }
    return {"passed": all(checks.values()), "checks": checks, "original": first, "exported": second, "changed_existing_tag_keys": changed_tags, "filled_blank_tag_keys": filled_blank_tags, "mismatched_selected_tag_keys": mismatched_selected_tags}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("inputs", nargs="+", type=Path)
    audit.add_argument("--report", type=Path)
    comparison = commands.add_parser("compare")
    comparison.add_argument("original", type=Path)
    comparison.add_argument("exported", type=Path)
    comparison.add_argument("--report", type=Path)
    comparison.add_argument("--allow-blank-tag-fill", action="store_true")
    comparison.add_argument("--expect-tags", type=Path, help="JSON expected tag map; values are never printed")
    comparison.add_argument("--expect-cover-sha256")
    options = parser.parse_args()
    if options.command == "compare":
        result = compare(options.original, options.exported, allow_blank_tag_fill=options.allow_blank_tag_fill,
                         expected_tags=json.loads(options.expect_tags.read_text(encoding="utf-8")) if options.expect_tags else None,
                         expected_cover_sha256=options.expect_cover_sha256)
        passed = result["passed"]
    else:
        rows = [inspect(path) for path in options.inputs]
        passed = all(row["probe_ok"] and row["full_decode_ok"] and row["source_unchanged"] for row in rows)
        result = {"passed": passed, "files": rows}
    serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if options.report:
        options.report.parent.mkdir(parents=True, exist_ok=True)
        options.report.write_text(serialized, encoding="utf-8")
        print(f"{'PASS' if passed else 'FAIL'}: {options.command}; report: {options.report}")
    else:
        print(serialized)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()

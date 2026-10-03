#!/usr/bin/env python3
"""Small offline WAV fixtures for native list/folder/duration acceptance.

8 kHz mono PCM gives exact integer-millisecond boundaries without codec delay.
Only authored silence is generated; no private inputs or network are used.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import wave

ROOT = "Music/AudioFixerSynthetic"
LIST_ROW_COUNT = 28
BOUNDARY_DURATIONS_MS = (59_999, 60_000, 60_001)


def generate_library_fixtures(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    specifications = [
        (f"Duration/native_duration_{milliseconds}.wav", milliseconds)
        for milliseconds in BOUNDARY_DURATIONS_MS
    ]
    specifications += [
        ("Exclude/native_parent.wav", 60_001),
        ("Exclude/Nested/native_nested.wav", 60_001),
        ("ExcludeNeighbor/native_neighbor.wav", 60_001),
    ]
    specifications += [(f"Queue/native_row_{index:02d}.wav", 250)
                       for index in range(LIST_ROW_COUNT)]
    entries = []
    for relative, milliseconds in specifications:
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(8_000)
            stream.writeframes(b"\x00\x00" * (milliseconds * 8))
        entries.append({
            "file": relative,
            "device_path": f"/sdcard/{ROOT}/{relative}",
            "file_name": path.name,
            "duration_ms": milliseconds,
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    manifest = {"synthetic_only": True, "encoding": "PCM s16le mono 8000 Hz",
                "list_row_count": LIST_ROW_COUNT, "entries": entries}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest

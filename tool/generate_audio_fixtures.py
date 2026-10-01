#!/usr/bin/env python3
"""Create small, copyright-free audio cases locally; never uses a network.

Requires Python 3, ffmpeg and ffprobe. Generated media stays in ignored build/.
Usage: python3 tool/generate_audio_fixtures.py [--output build/test_samples/generated]
The deterministic tone and metadata are synthetic. Encoder build differences may
change encoded bytes; the manifest records actual hashes for each generated run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

TITLE = "夜空 – Café 🎵"
ARTIST = "演奏者 / Sigur Rós"
ALBUM = "試験アルバム №1"
LYRICS = "[00:00.00]Synthetic fixture only\n[00:00.60]离线测试"
FORMATS = {
    "mp3": ["-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3"],
    "flac": ["-c:a", "flac"],
    "m4a": ["-c:a", "aac", "-b:a", "128k"],
    "wav": ["-c:a", "pcm_s16le"],
    "ogg": ["-c:a", "libvorbis", "-q:a", "4"],
    "opus": ["-c:a", "libopus", "-b:a", "96k"],
    "aiff": ["-c:a", "pcm_s16be", "-write_id3v2", "1"],
}


def run(args: list[str]) -> None:
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")


def png() -> bytes:
    """16x16 valid RGB PNG without Pillow or downloaded image assets."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(
            ">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\x00" + bytes([48, 104, 210]) * 16 for _ in range(16))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def generate(output: Path) -> dict:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg is required; install it from its official distribution")
    output.mkdir(parents=True, exist_ok=True)
    cover = output / "synthetic_cover.png"
    cover.write_bytes(png())
    entries = []

    def record(path: Path, kind: str, **extra: object) -> None:
        entries.append({"file": path.name, "kind": kind, "bytes": path.stat().st_size,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **extra})

    def encode(extension: str, name: str, tagged: bool, artwork: bool = False,
               long_title: bool = False, lyrics: bool = True, faststart: bool = False,
               id3_version: int = 3, id3v1: bool = False, duration: float = 1.2,
               blank_fields: bool = False) -> Path:
        path = output / f"{name}.{extension}"
        args = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", f"sine=frequency=523.25:sample_rate=44100:duration={duration}"]
        if artwork:
            args += ["-i", str(cover)]
        args += ["-map", "0:a:0", "-map_metadata", "-1", "-ac", "2"]
        if artwork:
            args += ["-map", "1:v:0", "-c:v", "copy", "-disposition:v", "attached_pic",
                     "-metadata:s:v", "title=Synthetic cover", "-metadata:s:v", "comment=Cover (front)"]
        args += FORMATS[extension]
        if extension == "mp3":
            args += ["-id3v2_version", str(id3_version), "-write_id3v1", "1" if id3v1 else "0"]
        if tagged:
            tags = {"title": TITLE if not long_title else TITLE + "x" * 8192,
                    "artist": ARTIST, "album": ALBUM, "date": "2024",
                    "track": "3/12", "disc": "1/2", "genre": "Synthetic", "lyrics": LYRICS}
            if blank_fields:
                tags.update({"title": "   ", "artist": "\t", "album": " \u00a0 ", "lyrics": " \n "})
            if not lyrics:
                del tags["lyrics"]
            for key, value in tags.items():
                args += ["-metadata", f"{key}={value}"]
        if faststart:
            args += ["-movflags", "+faststart"]
        args.append(str(path))
        run(args)
        record(path, "valid", format=extension, tagged=tagged, artwork=artwork,
               lyrics=tagged and lyrics, faststart=faststart, duration_seconds=duration,
               title_length=len(TITLE) + (8192 if long_title else 0) if tagged else 0)
        return path

    for extension in FORMATS:
        encode(extension, f"plain_{extension}", False)
        encode(extension, f"unicode_{extension}", True)
    for extension in ("mp3", "flac", "m4a"):
        encode(extension, f"cover_{extension}", True, artwork=True)
    for extension in ("mp3", "flac", "m4a"):
        encode(extension, f"blank_fields_{extension}", True, artwork=True, blank_fields=True)
    encode("mp3", "large_id3_mp3", True, long_title=True, lyrics=False)
    for extension in ("mp3", "flac", "m4a"):
        encode(extension, f"cover_without_lyrics_{extension}", True, artwork=True, lyrics=False)
    encode("m4a", "front_moov_m4a", False, faststart=True)
    encode("mp3", "id3v24_mp3", True, lyrics=False, id3_version=4)
    encode("mp3", "id3v1_tail_mp3", True, lyrics=False, id3v1=True)

    opus_path = encode("opus", "long_opus_44100", True, duration=12.0)
    # The original-input rate is informational in OpusHead. A legal 44100 hint
    # must not alter the fixed 48000-Hz granule clock (RFC 7845 section 5.1).
    opus_bytes = bytearray(opus_path.read_bytes())
    payload = 27 + opus_bytes[26]
    assert opus_bytes[payload:payload + 8] == b"OpusHead"
    opus_bytes[payload + 12:payload + 16] = struct.pack("<I", 44100)
    page_end = payload + sum(opus_bytes[27:payload])
    opus_bytes[22:26] = b"\x00" * 4
    checksum = 0
    for byte in opus_bytes[:page_end]:
        checksum ^= byte << 24
        for _ in range(8):
            checksum = ((checksum << 1) ^ (0x04C11DB7 if checksum & 0x80000000 else 0)) & 0xFFFFFFFF
    opus_bytes[22:26] = struct.pack("<I", checksum)
    opus_path.write_bytes(opus_bytes)
    entries[-1]["sha256"] = hashlib.sha256(opus_bytes).hexdigest()

    # FFmpeg emits an encoder-only ID3 tag even without descriptive metadata.
    # Strip that tag to exercise genuinely tagless MPEG and legacy ID3v1-only.
    encoded = (output / "plain_mp3.mp3").read_bytes()
    offset = 0
    if encoded[:3] == b"ID3":
        size = sum(encoded[6 + i] << (7 * (3 - i)) for i in range(4))
        offset = 10 + size
    raw = output / "raw_no_id3_mp3.mp3"
    raw.write_bytes(encoded[offset:])
    record(raw, "valid", format="mp3", tagged=False, artwork=False)
    legacy = output / "id3v1_only_mp3.mp3"
    def fixed(value: str, length: int) -> bytes:
        return value.encode("ascii").ljust(length, b"\x00")[:length]
    v1 = b"TAG" + fixed("Legacy title", 30) + fixed("Legacy artist", 30) + fixed("Legacy album", 30)
    v1 += b"2024" + fixed("Synthetic comment", 28) + bytes([0, 3, 12])
    assert len(v1) == 128
    legacy.write_bytes(encoded[offset:] + v1)
    record(legacy, "valid", format="mp3", tagged=True, artwork=False)

    # Preserve valid legacy Latin-1 INFO text when it is not valid UTF-8.
    def riff_chunk(name: bytes, payload: bytes) -> bytes:
        return name + struct.pack("<I", len(payload)) + payload + (b"\x00" if len(payload) % 2 else b"")
    wave_bytes = (output / "plain_wav.wav").read_bytes()
    legacy_info = b"INFO" + riff_chunk(b"INAM", b"Caf\xe9\x00")
    legacy_info += riff_chunk(b"IART", b"Fran\xe7ois\x00") + riff_chunk(b"IPRD", b"Ann\xe9e\x00")
    wave_body = wave_bytes[8:] + riff_chunk(b"LIST", legacy_info)
    latin1_wave = output / "latin1_wav.wav"
    latin1_wave.write_bytes(b"RIFF" + struct.pack("<I", len(wave_body)) + wave_body)
    record(latin1_wave, "valid", format="wav", tagged=True, artwork=False)

    original = output / "unicode_mp3.mp3"
    duplicate = output / "重命名 – duplicate.MP3"
    shutil.copyfile(original, duplicate)
    record(duplicate, "duplicate", same_as=original.name, format="mp3")

    # The file can have readable tags yet an unusable/truncated audio payload.
    truncated = output / "truncated_header.mp3"
    truncated.write_bytes(b"ID3\x04\x00\x00\x00\x00\x01\x00TIT2\x00")
    record(truncated, "invalid", expected_decode=False)
    malformed = output / "malformed.mp3"
    malformed.write_bytes(b"This is not an audio container.\x00\xff\x01" * 8)
    record(malformed, "invalid", expected_decode=False)
    empty = output / "empty.mp3"
    empty.write_bytes(b"")
    record(empty, "empty", expected_decode=False)
    unsupported = output / "unsupported.txt"
    unsupported.write_text("Offline fixture: unsupported extension\n", encoding="utf-8")
    record(unsupported, "unsupported", expected_decode=False)
    renamed = output / "wav_disguised_as_mp3.mp3"
    shutil.copyfile(output / "unicode_wav.wav", renamed)
    record(renamed, "disguised", same_as="unicode_wav.wav", format="wav")

    manifest = {"schema": 1, "synthetic_only": True,
                "metadata": {"title": TITLE, "artist": ARTIST, "album": ALBUM,
                             "year": 2024, "lyrics": LYRICS},
                "fixtures": entries}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                                          encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/test_samples/generated"))
    options = parser.parse_args()
    manifest = generate(options.output)
    print(f"Generated {len(manifest['fixtures'])} offline synthetic audio cases in {options.output}")


if __name__ == "__main__":
    main()

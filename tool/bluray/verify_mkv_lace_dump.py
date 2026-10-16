"""BUG-3453: verify libmpv's dump-cache keeps every frame of laced Matroska audio.

mkvmerge laces Opus eight frames per block and writes no DefaultDuration. mpv's
Matroska demuxer used to timestamp only the first frame of each lace, so the
stream recorder behind `dump-cache` (the online-video mining snapshot) had the
Matroska muxer reject the other seven ("non monotonically increasing dts ...
>= NOPTS" / "Failed writing packet") while still reporting success. The
snapshot kept about 1/8 of the audio and mined clips got 0.2-0.4 s of choppy
sound. patches/mkv-laced-audio-timestamps.patch fixes the demuxer.

This loads tests/laced-opus.mkv (6 s, mkvmerge, 8-frame Opus laces, no
DefaultDuration) with the given libmpv, dumps the whole cache to a new file and
fails if the recorder logged a write error. With --ffmpeg it also decodes the
dump and requires at least 90% of the cached span as real audio samples.

No window or audio device is opened.

python tool/bluray/verify_mkv_lace_dump.py --library <dir with libmpv-2.dll> [--ffmpeg ffmpeg]
"""
import argparse
import ctypes as C
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from probe_libmpv import Event, Log, Mpv

FIXTURE = Path(__file__).resolve().parent / "tests" / "laced-opus.mkv"
WRITE_ERRORS = ("Failed writing packet", "non monotonically increasing dts")


def drain(mpv, errors, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        event = mpv.lib.mpv_wait_event(mpv.handle, 0.05).contents
        if event.event_id == 0:
            continue
        if event.event_id == 2:
            log = C.cast(event.data, C.POINTER(Log)).contents
            text = log.text.decode("utf-8", "replace").strip()
            if any(marker in text for marker in WRITE_ERRORS):
                errors.append(f"[{log.prefix.decode()}] {text}")


def cached_range(mpv, seconds):
    errors = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        drain(mpv, errors, 0.2)
        state = mpv.get("demuxer-cache-state")
        if isinstance(state, dict) and state.get("eof"):
            ranges = state.get("seekable-ranges") or []
            if ranges:
                return ranges[0]["start"], ranges[0]["end"], errors
    raise RuntimeError("the fixture never became fully cached")


def decoded_ms(ffmpeg, path):
    # Fixed-format PCM: the final stats line's audio size is the real sample
    # count. The progress line's time= follows timestamps and stays full even
    # when most packets are missing.
    run = subprocess.run([ffmpeg, "-hide_banner", "-i", str(path), "-map", "0:a:0",
                          "-c:a", "pcm_s16le", "-ac", "1", "-ar", "16000",
                          "-f", "null", "-"], capture_output=True, text=True)
    match = re.findall(r"audio:\s*(\d+)\s*(?:kB|KiB)", run.stderr)
    if run.returncode != 0 or not match:
        raise RuntimeError(f"ffmpeg could not decode the dump:\n{run.stderr[-2000:]}")
    return int(match[-1]) * 1024 / 32


def verify(library, ffmpeg=None):
    os.add_dll_directory(str(Path(library).resolve()))
    mpv = Mpv(Path(library) / "libmpv-2.dll")
    try:
        for name, value in (("config", "no"), ("vo", "null"), ("ao", "null"),
                            ("terminal", "no"), ("idle", "yes"), ("pause", "yes"),
                            ("cache", "yes"), ("cache-secs", "60")):
            if mpv.option(name, value) < 0:
                raise RuntimeError(f"option failed: {name}")
        if mpv.lib.mpv_initialize(mpv.handle) < 0:
            raise RuntimeError("mpv_initialize failed")
        mpv.lib.mpv_request_log_messages(mpv.handle, b"error")
        mpv.command("loadfile", str(FIXTURE))
        start, end, errors = cached_range(mpv, 15)
        with tempfile.TemporaryDirectory() as temp:
            dump = Path(temp) / "dump.mkv"
            result = mpv.command("dump-cache", f"{start:.6f}", f"{end:.6f}", str(dump))
            drain(mpv, errors, 1.0)
            report = {"cached": [start, end], "dump_result": result,
                      "dump_bytes": dump.stat().st_size if dump.exists() else 0,
                      "write_errors": len(errors), "first_errors": errors[:3]}
            ok = result >= 0 and report["dump_bytes"] > 0 and not errors
            if ffmpeg and report["dump_bytes"]:
                report["decoded_ms"] = decoded_ms(ffmpeg, dump)
                report["cached_ms"] = (end - start) * 1000
                ok = ok and report["decoded_ms"] >= report["cached_ms"] * 0.9
            report["ok"] = ok
            return report
    finally:
        mpv.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--ffmpeg")
    args = parser.parse_args()
    report = verify(args.library, args.ffmpeg)
    print(json.dumps(report, indent=2))
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()

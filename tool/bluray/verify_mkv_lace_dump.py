"""Verify libmpv's dump-cache keeps every frame of mkvmerge Matroska files.

dump-cache is the online-video mining snapshot. Its stream recorder had the
Matroska muxer reject packets ("non monotonically increasing dts" / "Failed
writing packet") while still reporting success:

- BUG-3499: mkvmerge laces Opus eight frames per block and writes no
  DefaultDuration. mpv's Matroska demuxer timestamped only the first frame of
  each lace, so the snapshot kept about 1/8 of the audio and mined clips got
  0.2-0.4 s of choppy sound. patches/mkv-laced-audio-timestamps.patch fixes
  the demuxer. Fixture: tests/laced-opus.mkv (6 s, 8-frame Opus laces).
- BUG-3500: Matroska video has no DTS. With B-frames libavformat set DTS = PTS
  and rejected every reordered frame, so the snapshot of HEVC/H.264 was mostly
  undecodable (mined clips showed corrupted video). patches/recorder-video-dts.patch
  makes the recorder derive the DTS. Fixture: tests/open-gop-hevc.mkv (6 s,
  HEVC 10-bit open GOP with B-frames, AAC).

Each fixture is loaded with the given libmpv, the whole cache is dumped to a new
file, and the check fails if the recorder logged a write error. With --ffmpeg
it also decodes the dump and requires at least 90% of the cached span as real
audio samples / video frames.

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

TESTS = Path(__file__).resolve().parent / "tests"
# (fixture, decoded stream, units per second of the cached span)
FIXTURES = ((TESTS / "laced-opus.mkv", "audio", None),
            (TESTS / "open-gop-hevc.mkv", "video", 24000 / 1001))
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


def decoded_frames(ffmpeg, path):
    # Frames the decoder actually produced: pictures whose references were
    # dropped from the dump fail to decode and are not counted. ffmpeg-min has
    # no wrapped_avframe encoder, so the frames go through (tiny) MJPEG, in the
    # Matroska millisecond time base so no two frames round to the same tick.
    run = subprocess.run([ffmpeg, "-hide_banner", "-i", str(path), "-map", "0:v:0",
                          "-fps_mode", "passthrough", "-enc_time_base:v", "1/1000",
                          "-vf", "format=yuvj420p", "-c:v", "mjpeg", "-f", "null", "-"],
                         capture_output=True, text=True)
    match = re.findall(r"frame=\s*(\d+)", run.stderr)
    if run.returncode != 0 or not match:
        raise RuntimeError(f"ffmpeg could not decode the dump:\n{run.stderr[-2000:]}")
    return int(match[-1])


def verify_fixture(library, fixture, kind, rate, ffmpeg):
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
        mpv.command("loadfile", str(fixture))
        start, end, errors = cached_range(mpv, 15)
        with tempfile.TemporaryDirectory() as temp:
            dump = Path(temp) / "dump.mkv"
            result = mpv.command("dump-cache", f"{start:.6f}", f"{end:.6f}", str(dump))
            drain(mpv, errors, 1.0)
            report = {"fixture": fixture.name, "cached": [start, end], "dump_result": result,
                      "dump_bytes": dump.stat().st_size if dump.exists() else 0,
                      "write_errors": len(errors), "first_errors": errors[:3]}
            ok = result >= 0 and report["dump_bytes"] > 0 and not errors
            if ffmpeg and report["dump_bytes"]:
                if kind == "audio":
                    report["decoded_ms"] = decoded_ms(ffmpeg, dump)
                    report["cached_ms"] = (end - start) * 1000
                    ok = ok and report["decoded_ms"] >= report["cached_ms"] * 0.9
                else:
                    report["decoded_frames"] = decoded_frames(ffmpeg, dump)
                    report["cached_frames"] = (end - start) * rate
                    ok = ok and report["decoded_frames"] >= report["cached_frames"] * 0.9
            report["ok"] = ok
            return report
    finally:
        mpv.close()


def verify(library, ffmpeg=None):
    os.add_dll_directory(str(Path(library).resolve()))
    reports = [verify_fixture(library, fixture, kind, rate, ffmpeg)
               for fixture, kind, rate in FIXTURES]
    return {"fixtures": reports, "ok": all(report["ok"] for report in reports)}


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

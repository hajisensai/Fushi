"""Grabbing the current Game Mode frame.

gamescope publishes its composited output as a PipeWire video node named
`gamescope`; one buffer from it is exactly what the player sees. Measured on a
Steam Deck (2026-11-04): about 170 ms per frame with one gst-launch per capture.
A long-lived capture process would bring that to a few milliseconds; that is a
later optimisation, the OCR (~0.4-0.9 s) dominates for now.

Runs as the normal `deck` user: no root needed.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import Dict, Optional

GAMESCOPE_NODE = "gamescope"
CAPTURE_TIMEOUT_S = 5.0
JPEG_QUALITY = 85


class CaptureError(Exception):
    pass


def capture_env(base: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Environment for gst-launch from inside Decky's backend.

    Decky starts backends without a graphical session environment, and its
    bundled (PyInstaller) Python sets LD_LIBRARY_PATH to its own libraries,
    which breaks system GStreamer. Point at the user's PipeWire socket and drop
    the bundled library paths.
    """
    env = dict(os.environ if base is None else base)
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME"):
        env.pop(key, None)
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return env


def capture_command(gst: str, quality: int = JPEG_QUALITY) -> list:
    return [
        gst,
        "-q",
        "pipewiresrc",
        f"target-object={GAMESCOPE_NODE}",
        "do-timestamp=true",
        "num-buffers=1",
        "!",
        "videoconvert",
        "!",
        "jpegenc",
        f"quality={quality}",
        "!",
        "fdsink",
        "fd=1",
    ]


def capture_jpeg() -> bytes:
    """One JPEG of the current screen. Raises CaptureError with a readable reason."""
    gst = shutil.which("gst-launch-1.0", path=capture_env().get("PATH"))
    if gst is None:
        raise CaptureError("gst-launch-1.0 is not installed")
    try:
        done = subprocess.run(
            capture_command(gst),
            env=capture_env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=CAPTURE_TIMEOUT_S,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        raise CaptureError("screen capture timed out (is Game Mode running?)") from e
    if done.returncode != 0 or not done.stdout.startswith(b"\xff\xd8"):
        detail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["no output"]
        raise CaptureError(f"screen capture failed: {detail[0]}")
    return done.stdout

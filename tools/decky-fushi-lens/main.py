"""Decky Loader entry point for Fushi Lens.

Runs as the `deck` user (no root flag): screen capture, the back-button
reader and the local Lens server all work unprivileged. The real work lives in
py_modules/fushi_lens (plain stdlib Python, unit-tested off the Deck).
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, Dict, Optional

import decky  # provided by Decky Loader

from fushi_lens.capture import CaptureError
from fushi_lens.host import HostError
from fushi_lens.paddles import BUTTONS, PaddleWatcher
from fushi_lens.service import ConfigStore, LensService

SETTINGS_FILE = "settings.json"
DEFAULT_BUTTON = "L4"


def _load_settings(path: str) -> Dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _valid_region(region: Any) -> bool:
    """"x,y,w,h" with whole, non-negative numbers and a usable size."""
    if not isinstance(region, str):
        return False
    parts = region.split(",")
    if len(parts) != 4 or not all(p.strip().isdigit() for p in parts):
        return False
    _, _, w, h = (int(p) for p in parts)
    return w >= 8 and h >= 8


def _regions(settings: Dict[str, Any]) -> Dict[str, str]:
    raw = settings.get("regions")
    if not isinstance(raw, dict):
        return {}
    return {str(k): v for k, v in raw.items() if _valid_region(v)}


def _error(e: Exception) -> Dict[str, Any]:
    if isinstance(e, HostError):
        return {"ok": False, "error": e.reason, "detail": e.detail}
    return {"ok": False, "error": "capture" if isinstance(e, CaptureError) else "internal", "detail": str(e)}


class Plugin:
    service: Optional[LensService] = None
    paddles: Optional[PaddleWatcher] = None
    loop: Optional[asyncio.AbstractEventLoop] = None
    settings_path: str = ""
    settings: Dict[str, Any] = {}
    # The Lens screen is showing: the capture button then only closes it (the
    # frontend does that), it must not capture the Lens itself and reopen it.
    lens_open: bool = False

    async def _main(self) -> None:
        self.loop = asyncio.get_running_loop()
        settings_dir = decky.DECKY_PLUGIN_SETTINGS_DIR
        self.settings_path = os.path.join(settings_dir, SETTINGS_FILE)
        self.settings = _load_settings(self.settings_path)
        self.service = LensService(
            ConfigStore(os.path.join(settings_dir, "pairing.json")),
            os.path.join(decky.DECKY_PLUGIN_DIR, "web"),
        )
        self.service.start_server()
        button = self.settings.get("button") if self.settings.get("button") in BUTTONS else DEFAULT_BUTTON
        self.paddles = PaddleWatcher(self._on_paddle, button)
        self.paddles.start()
        decky.logger.info("Fushi Lens ready: %s", self.service.status())

    async def _unload(self) -> None:
        if self.paddles:
            self.paddles.stop()
        if self.service:
            self.service.stop_server()

    # Back button press (reader thread): grab the frame before Steam's UI
    # covers the game, then tell the frontend to open the Lens on it.
    def _on_paddle(self, _button: str) -> None:
        if self.lens_open:
            return
        if self.loop is not None:
            asyncio.run_coroutine_threadsafe(self._capture_and_emit(), self.loop)

    async def _capture_and_emit(self) -> None:
        try:
            info = await asyncio.to_thread(self.service.capture)
            await decky.emit("fushi_lens_frame", info)
        except Exception as e:  # noqa: BLE001 - reported to the UI
            await decky.emit("fushi_lens_error", _error(e))

    # ── frontend API ──────────────────────────────────────────────────

    async def status(self) -> Dict[str, Any]:
        status = self.service.status()
        status["button"] = self.paddles.button if self.paddles else DEFAULT_BUTTON
        status["buttonError"] = self.paddles.error if self.paddles else None
        status["touch"] = self.settings.get("touch") is True
        status["regions"] = _regions(self.settings)
        return status

    async def begin_pairing(self, address: str) -> Dict[str, Any]:
        try:
            return {"ok": True, **await asyncio.to_thread(self.service.begin_pairing, address)}
        except Exception as e:  # noqa: BLE001
            return _error(e)

    async def finish_pairing(self, pin: str) -> Dict[str, Any]:
        try:
            return {"ok": True, **await asyncio.to_thread(self.service.finish_pairing, pin or None)}
        except Exception as e:  # noqa: BLE001
            return _error(e)

    async def unpair(self) -> Dict[str, Any]:
        return {"ok": True, **self.service.unpair()}

    async def capture(self) -> Dict[str, Any]:
        """Capture now (the panel button; the frontend closes the panel first)."""
        try:
            return {"ok": True, **await asyncio.to_thread(self.service.capture)}
        except Exception as e:  # noqa: BLE001
            return _error(e)

    async def set_lens_open(self, is_open: bool) -> Dict[str, Any]:
        self.lens_open = bool(is_open)
        return {"ok": True}

    async def set_button(self, button: str) -> Dict[str, Any]:
        if button not in BUTTONS:
            return {"ok": False, "error": "button"}
        self.paddles.set_button(button)
        self.settings["button"] = button
        self._save_settings()
        return {"ok": True, "button": button}

    async def set_touch(self, enabled: bool) -> Dict[str, Any]:
        """Tap a character to look it up (off by default)."""
        self.settings["touch"] = bool(enabled)
        self._save_settings()
        return {"ok": True, "touch": self.settings["touch"]}

    async def set_region(self, appid: str, region: Optional[str]) -> Dict[str, Any]:
        """Save the reading area ("x,y,w,h" in frame pixels) for one game, or clear it."""
        regions = _regions(self.settings)
        key = str(appid)
        if region is None:
            regions.pop(key, None)
        elif _valid_region(region):
            regions[key] = region
        else:
            return {"ok": False, "error": "region"}
        self.settings["regions"] = regions
        self._save_settings()
        return {"ok": True, "regions": regions}

    def _save_settings(self) -> None:
        os.makedirs(os.path.dirname(self.settings_path), exist_ok=True)
        with open(self.settings_path, "w", encoding="utf-8") as f:
            json.dump(self.settings, f)

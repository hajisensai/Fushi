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

    async def set_button(self, button: str) -> Dict[str, Any]:
        if button not in BUTTONS:
            return {"ok": False, "error": "button"}
        self.paddles.set_button(button)
        self.settings["button"] = button
        os.makedirs(os.path.dirname(self.settings_path), exist_ok=True)
        with open(self.settings_path, "w", encoding="utf-8") as f:
            json.dump(self.settings, f)
        return {"ok": True, "button": button}

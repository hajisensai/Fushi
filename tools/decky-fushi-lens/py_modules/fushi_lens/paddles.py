"""Watching the Steam Deck back buttons (L4 / R4 / L5 / R5) from hidraw.

The Deck's built-in controller (Valve, VID 28DE PID 1205) sends 64-byte input
reports. The `deck` user can read its hidraw nodes (logind ACL), and hidraw
allows many readers, so watching it does not take input away from Steam or the
game. Layout (SDL `SDL_hidapi_steamdeck.c`, `ValveInReportHeader_t`):

  byte 0-1  report version     byte 2  type (9 = deck state)   byte 3  length
  byte 4-7  packet number
  byte 8-11 buttons, low dword      byte 12-15 buttons, high dword

Back buttons: L5 = low 0x8000, R5 = low 0x10000, L4 = high 0x200, R4 = high 0x400.
"""

from __future__ import annotations

import glob
import os
import select
import threading
from typing import Callable, Dict, List, Optional

VALVE_VID = 0x28DE
DECK_PID = 0x1205
REPORT_SIZE = 64
DECK_STATE = 9

# button name -> (dword index 0 = low / 1 = high, mask)
BUTTONS: Dict[str, tuple] = {
    "L4": (1, 0x00000200),
    "R4": (1, 0x00000400),
    "L5": (0, 0x00008000),
    "R5": (0, 0x00010000),
}


def pressed_buttons(report: bytes) -> Optional[frozenset]:
    """Names of the back buttons held in one report, or None if not a state report."""
    if len(report) < 16 or report[2] != DECK_STATE:
        return None
    low = int.from_bytes(report[8:12], "little")
    high = int.from_bytes(report[12:16], "little")
    words = (low, high)
    return frozenset(name for name, (word, mask) in BUTTONS.items() if words[word] & mask)


def deck_hidraw_nodes(sys_root: str = "/sys/class/hidraw") -> List[str]:
    """/dev/hidrawN nodes that belong to the Deck controller."""
    want = f"HID_ID=0003:{VALVE_VID:08X}:{DECK_PID:08X}"
    nodes = []
    for uevent in sorted(glob.glob(os.path.join(sys_root, "hidraw*", "device", "uevent"))):
        try:
            with open(uevent, encoding="ascii", errors="replace") as f:
                if want in f.read().upper():
                    nodes.append("/dev/" + uevent.split(os.sep)[-3])
        except OSError:
            continue
    return nodes


class PaddleWatcher:
    """Calls `on_press(button)` on each press edge of the chosen back button."""

    def __init__(self, on_press: Callable[[str], None], button: str = "L4") -> None:
        if button not in BUTTONS:
            raise ValueError(f"unknown button {button}")
        self.button = button
        self._on_press = on_press
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.error: Optional[str] = None

    def set_button(self, button: str) -> None:
        if button not in BUTTONS:
            raise ValueError(f"unknown button {button}")
        self.button = button

    def start(self) -> None:
        if self._thread is None or not self._thread.is_alive():
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name="fushi-lens-paddles", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        self._thread = None
        if thread is not None:
            thread.join(timeout=2)

    def _run(self) -> None:
        # Reopen after suspend / controller reconnect instead of giving up.
        while not self._stop.is_set():
            self._read_until_error()
            self._stop.wait(2.0)

    def _read_until_error(self) -> None:
        fds = []
        for node in deck_hidraw_nodes():
            try:
                fds.append(os.open(node, os.O_RDONLY | os.O_NONBLOCK))
            except OSError:
                continue
        if not fds:
            self.error = "no readable Steam Deck controller hidraw node"
            return
        self.error = None
        held = False
        try:
            while not self._stop.is_set():
                ready, _, _ = select.select(fds, [], [], 0.5)
                for fd in ready:
                    try:
                        report = os.read(fd, REPORT_SIZE)
                    except BlockingIOError:
                        continue
                    except OSError as e:  # controller went away (sleep / reconnect)
                        self.error = str(e)
                        return
                    buttons = pressed_buttons(report)
                    if buttons is None:
                        continue
                    now = self.button in buttons
                    if now and not held:
                        try:
                            self._on_press(self.button)
                        except Exception:  # noqa: BLE001 - never kill the reader
                            pass
                    held = now
        finally:
            for fd in fds:
                os.close(fd)

"""Run the Lens page in a desktop browser, without a Steam Deck.

Captures are replaced by image files you pass in (one per capture, cycling),
so the whole flow (OCR on the paired Fushi host, popup, mining) can be tried
on a PC. Pairing state is kept in a separate file from the Deck's.

  python scripts/dev_server.py pair <host[:port]>      # asks for the PIN
  python scripts/dev_server.py run frame1.jpg [frame2.jpg ...]
"""

from __future__ import annotations

import itertools
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PLUGIN, "py_modules"))

from fushi_lens.service import ConfigStore, LensService  # noqa: E402

CONFIG = os.environ.get("FUSHI_LENS_CONFIG") or os.path.join(PLUGIN, ".dev", "pairing.json")


def main(argv: list) -> int:
    if len(argv) < 2 or argv[0] not in ("pair", "run"):
        print(__doc__)
        return 2
    config = ConfigStore(CONFIG)
    if argv[0] == "pair":
        service = LensService(config, os.path.join(PLUGIN, "web"), device_name="Fushi Lens (dev)")
        info = service.begin_pairing(argv[1])
        print(f"Pairing with {info['host']} (certificate {info['fingerprint']}).")
        pin = input("PIN shown in Fushi: ").strip() if info["pinRequired"] else None
        print("Approve the device in Fushi if it asks...")
        print(service.finish_pairing(pin))
        return 0
    frames = []
    for path in argv[1:]:
        # The developer names the screenshots to replay on their own machine
        # (S8707: a dev tool's own CLI argument, not remote input).
        with open(path, "rb") as f:  # NOSONAR
            data = f.read()
        # Frames stand in for the gamescope capture, which is always JPEG.
        if not data.startswith(b"\xff\xd8"):
            print(f"{path}: not a JPEG (captures are JPEG)", file=sys.stderr)
            return 2
        frames.append(data)
    cycle = itertools.cycle(frames)
    service = LensService(config, os.path.join(PLUGIN, "web"), capture=lambda: next(cycle))
    port = int(os.environ.get("FUSHI_LENS_PORT", "0"))
    url = service.start_server(port)
    print(f"status: {service.status()}")
    print(f"open: {url}")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        service.stop_server()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

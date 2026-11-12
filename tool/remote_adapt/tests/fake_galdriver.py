"""测试用假驱动：与 gal_realgame_driver_itest.dart 同一套 cmd.txt / out.txt / done.txt 协议。"""

from __future__ import annotations

import os
import time
from datetime import datetime
from pathlib import Path


def main() -> None:
    d = Path(os.environ["GALDRIVER_DIR"])
    d.mkdir(parents=True, exist_ok=True)
    cmd = d / "cmd.txt"
    out = d / "out.txt"
    root = os.environ.get("FUSHI_TEST_ROOT", "")
    hidden = os.environ.get("FUSHI_TEST_HIDDEN", "")

    def emit(message: str) -> None:
        with out.open("a", encoding="utf-8") as fh:
            fh.write(f"[{datetime.now().isoformat()}] {message}\n")

    emit(f"home=true root={root} hidden={hidden}")
    seq = 0
    shot = 0
    while True:
        time.sleep(0.05)
        if not cmd.exists():
            continue
        raw = cmd.read_text(encoding="utf-8")
        cmd.unlink()
        for line in raw.split("\n"):
            line = line.strip()
            if not line:
                continue
            seq += 1
            op = line.split()[0]
            if op == "quit":
                emit(f"#{seq} quit")
                (d / "done.txt").write_text(str(seq))
                emit("exit")
                # 与独立运行的测试宿主一样：测试跑完进程不自己退出，等宿主结束。
                if os.environ.get("FAKE_DRIVER_LINGER"):
                    time.sleep(3600)
                return
            if op == "shot":
                shot += 1
                (d / f"shot_{shot}.png").write_bytes(b"\x89PNG fake")
                emit(f"#{seq} shot -> shot_{shot}.png")
            elif op == "slow":
                time.sleep(float(line.split()[1]))
                emit(f"#{seq} slow done")
            elif op == "crash":
                os._exit(3)
            else:
                emit(f"#{seq} ok {line}")
            (d / "done.txt").write_text(str(seq))


if __name__ == "__main__":
    main()

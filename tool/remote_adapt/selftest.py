"""本机端到端自测：真起 server.py（HTTP + Bearer），用官方 MCP 客户端调每个工具，
对一个会记录事件的靶子窗口核对坐标、键盘、触摸是否真的落到了该落的地方。

    python selftest.py            # 会短暂占用本机鼠标键盘（约 20 秒），期间别动
退出码 0 = 全部 PASS。
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
TOKEN = "selftest-" + os.urandom(8).hex()

TARGET_SRC = r'''
import ctypes, json, sys, time
ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
import tkinter as tk
log = open(sys.argv[1], "a", encoding="utf-8")
def emit(**kw):
    kw["t"] = time.time(); log.write(json.dumps(kw, ensure_ascii=False) + "\n"); log.flush()
root = tk.Tk(); root.title("remote-adapt-selftest-target")
root.geometry("640x420+160+160"); root.attributes("-topmost", True)
c = tk.Canvas(root, width=640, height=360, bg="#ff00ff", highlightthickness=0); c.pack()
c.create_rectangle(300, 160, 340, 200, fill="#00ff00", outline="")
e = tk.Entry(root, font=("Segoe UI", 14)); e.pack(fill="x")
for seq, name in (("<ButtonPress-1>", "down1"), ("<ButtonRelease-1>", "up1"), ("<ButtonPress-3>", "down3"),
                  ("<Double-Button-1>", "dbl1"), ("<B1-Motion>", "drag1")):
    c.bind(seq, lambda ev, n=name: emit(ev=n, x=ev.x_root, y=ev.y_root))
c.bind("<MouseWheel>", lambda ev: emit(ev="wheel", delta=ev.delta, x=ev.x_root, y=ev.y_root))
e.bind("<KeyRelease>", lambda ev: emit(ev="key", keysym=ev.keysym, text=e.get()))
def ready():
    root.lift(); root.focus_force()
    emit(ev="ready", canvas=[c.winfo_rootx(), c.winfo_rooty(), c.winfo_width(), c.winfo_height()],
         entry=[e.winfo_rootx(), e.winfo_rooty(), e.winfo_width(), e.winfo_height()])
root.after(300, ready)
root.after(120000, root.destroy)
root.mainloop()
'''


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Events:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.seen = 0

    def all(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        return [json.loads(ln) for ln in self.path.read_text(encoding="utf-8").splitlines() if ln.strip()]

    def new(self, wait_s: float = 1.5, until: str | None = None) -> list[dict[str, Any]]:
        deadline = time.time() + wait_s
        while True:
            evs = self.all()[self.seen :]
            if (until and any(e["ev"] == until for e in evs)) or time.time() > deadline:
                self.seen += len(evs)
                return evs
            time.sleep(0.05)


def fake_galdriver(directory: Path, stop: threading.Event) -> None:
    """模拟 gal_realgame_driver_itest 的文件协议：取走 cmd.txt、逐条写 out.txt / done.txt。"""
    from PIL import Image

    seq = 0
    out = directory / "out.txt"
    out.write_text("[t] home=true\n", encoding="utf-8")
    while not stop.is_set():
        cmd = directory / "cmd.txt"
        if not cmd.exists():
            time.sleep(0.25)
            continue
        raw = cmd.read_text(encoding="utf-8")
        cmd.unlink()
        for line in raw.split("\n"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            seq += 1
            op = line.split()[0]
            if op == "state":
                msg = f"#{seq} phase=capturing lines=3"
            elif op == "shot":
                png = directory / f"shot_{seq}.png"
                Image.new("RGB", (320, 200), "#3366ff").save(png)
                msg = f"#{seq} shot game hwnd=1 rect=[0,0,320,200] -> {png}"
            else:
                msg = f"#{seq} unknown: {line}"
            with open(out, "a", encoding="utf-8") as fh:
                fh.write(f"[t] {msg}\n")
            (directory / "done.txt").write_text(str(seq))


async def run() -> int:
    import httpx2
    from mcp import Client
    from mcp.client.streamable_http import streamable_http_client
    from PIL import Image

    tmp = Path(tempfile.mkdtemp(prefix="remote_adapt_selftest_"))
    events = Events(tmp / "events.jsonl")
    gal_dir = tmp / "galdriver"
    gal_dir.mkdir()
    port = free_port()
    url = f"http://127.0.0.1:{port}/mcp"

    server = subprocess.Popen(
        [sys.executable, str(HERE / "server.py"), "--host", "127.0.0.1", "--port", str(port), "--token", TOKEN,
         "--galdriver-dir", str(gal_dir)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    target = subprocess.Popen([sys.executable, "-c", TARGET_SRC, str(events.path)])
    stop = threading.Event()
    threading.Thread(target=fake_galdriver, args=(gal_dir, stop), daemon=True).start()
    results: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append((name, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}", flush=True)

    try:
        ready = events.new(wait_s=10, until="ready")
        ready_ev = next(e for e in ready if e["ev"] == "ready")
        cx, cy, cw, ch = ready_ev["canvas"]
        ex, ey, ew, eh = ready_ev["entry"]
        green = (cx + 320, cy + 180)  # 绿块中心（物理像素）

        for _ in range(50):
            try:
                r = httpx2.post(url, json={}, timeout=1)
                break
            except Exception:
                await asyncio.sleep(0.2)
        check("auth rejects missing token", r.status_code == 401, f"status={r.status_code}")

        http = httpx2.AsyncClient(headers={"Authorization": f"Bearer {TOKEN}"}, timeout=60)
        async with Client(streamable_http_client(url, http_client=http)) as client:
            async def call(name: str, **args: Any) -> list[Any]:
                res = await client.call_tool(name, args)
                if res.is_error:
                    raise RuntimeError(f"{name} error: {res.content}")
                return res.content

            tools = {t.name for t in (await client.list_tools()).tools}
            want = {"screenshot", "click", "move", "drag", "scroll", "type_text", "key", "touch_tap", "touch_hold",
                    "touch_swipe", "list_windows", "focus_window", "powershell", "galdriver", "view_image", "info"}
            check("list_tools", want <= tools, f"missing={sorted(want - tools)}")

            info = json.loads((await call("info"))[0].text)
            check("info", info["dpi_awareness"] in ("per_monitor_v2", "per_monitor"), f"dpi={info['dpi_awareness']} monitors={len(info['monitors'])}")

            wins = (await call("list_windows", filter="remote-adapt-selftest-target"))[0].text
            hwnd = json.loads(wins.splitlines()[0])["hwnd"]
            check("list_windows", "selftest-target" in wins, f"hwnd={hwnd}")
            focus = (await call("focus_window", hwnd=hwnd))[0].text
            check("focus_window", "ok" in focus, focus)

            # 全屏截图（缩小）→ 在图里找绿块 → 用 image 坐标点它 → 靶子收到的物理坐标应落在绿块里
            content = await call("screenshot", show_cursor=False)
            img = Image.open(io.BytesIO(base64.b64decode(content[1].data))).convert("RGB")
            px = img.load()
            hits = [(x, y) for y in range(img.height) for x in range(img.width)
                    if (lambda p: p[1] > 200 and p[0] < 60 and p[2] < 60)(px[x, y])]
            gx = sum(h[0] for h in hits) / max(1, len(hits))
            gy = sum(h[1] for h in hits) / max(1, len(hits))
            check("screenshot sees target", len(hits) > 4, f"{content[0].text[:90]}… green_px={len(hits)} at img {gx:.0f},{gy:.0f}")

            await call("click", x=gx, y=gy)
            evs = events.new(until="up1")
            d = next((e for e in evs if e["ev"] == "down1"), None)
            ok = d is not None and abs(d["x"] - green[0]) <= 20 and abs(d["y"] - green[1]) <= 20
            check("click image coords", ok, f"target got {d and (d['x'], d['y'])} want≈{green}")

            await call("click", x=green[0], y=green[1], coords="physical", button="right")
            evs = events.new(until="down3")
            d = next((e for e in evs if e["ev"] == "down3"), None)
            check("click physical exact", d is not None and (d["x"], d["y"]) == green, f"target got {d and (d['x'], d['y'])} want {green}")

            await call("click", x=cx + 100, y=cy + 100, coords="physical", count=2)
            evs = events.new(until="dbl1")
            check("double click", any(e["ev"] == "dbl1" for e in evs), f"events={[(e['ev'], round(e['t'] % 100, 3)) for e in evs]}")

            await call("drag", x1=cx + 50, y1=cy + 50, x2=cx + 250, y2=cy + 120, coords="physical", duration_ms=300)
            evs = events.new(until="up1")
            mv = [e for e in evs if e["ev"] == "drag1"]
            check("drag", len(mv) >= 3 and abs(mv[-1]["x"] - (cx + 250)) <= 2, f"motions={len(mv)} last={mv and (mv[-1]['x'], mv[-1]['y'])}")

            await call("scroll", x=cx + 200, y=cy + 200, coords="physical", dy=-2)
            evs = events.new(until="wheel")
            wh = [e for e in evs if e["ev"] == "wheel"]
            check("scroll", len(wh) == 2 and wh[0]["delta"] < 0, f"{[e['delta'] for e in wh]}")

            await call("click", x=ex + ew // 2, y=ey + eh // 2, coords="physical")
            events.new(wait_s=0.5)
            await call("type_text", text="かな漢字abc")
            await call("key", combo="end")
            evs = events.new(wait_s=1.5)
            texts = [e.get("text") for e in evs if e["ev"] == "key"]
            check("type_text unicode", bool(texts) and texts[-1] == "かな漢字abc", f"entry={texts[-1] if texts else None!r}")

            await call("key", combo="ctrl+a")
            await call("key", combo="backspace")
            evs = events.new(wait_s=1.0)
            texts = [e.get("text") for e in evs if e["ev"] == "key"]
            check("key combo", bool(texts) and texts[-1] == "", f"entry after ctrl+a,backspace={texts[-1] if texts else None!r}")

            out = (await call("touch_tap", x=green[0], y=green[1], coords="physical"))[0].text
            evs = events.new(wait_s=2.0, until="up1")
            d = next((e for e in evs if e["ev"] == "down1"), None)
            check("touch_tap → promoted click", d is not None and abs(d["x"] - green[0]) <= 2 and abs(d["y"] - green[1]) <= 2,
                  f"target got {d and (d['x'], d['y'])} ({out})")

            await call("touch_swipe", x1=cx + 60, y1=cy + 300, x2=cx + 400, y2=cy + 300, coords="physical", duration_ms=300)
            evs = events.new(wait_s=2.0, until="up1")
            check("touch_swipe", any(e["ev"] == "down1" for e in evs) and any(e["ev"] == "up1" for e in evs),
                  f"events={[e['ev'] for e in evs][:8]}")

            await call("touch_hold", x=cx + 500, y=cy + 80, coords="physical", duration_ms=900)
            evs = events.new(wait_s=2.0)
            check("touch_hold → long-press right click", any(e["ev"] == "down3" for e in evs), f"events={[e['ev'] for e in evs][:6]}")

            after = await call("move", x=green[0], y=green[1], coords="physical", screenshot_after=True, wait_ms=100)
            check("screenshot_after", len(after) == 3 and getattr(after[2], "type", "") == "image")

            region = await call("screenshot", region=[green[0] - 40, green[1] - 40, 80, 80], format="png", show_cursor=False)
            rimg = Image.open(io.BytesIO(base64.b64decode(region[1].data))).convert("RGB")
            check("region screenshot 1:1", rimg.size == (80, 80) and rimg.getpixel((40, 40))[1] > 200, f"size={rimg.size} center={rimg.getpixel((40, 40))}")

            ps = (await call("powershell", command="Write-Output '你好'; $PSVersionTable.PSVersion.Major"))[0].text
            check("powershell utf-8", "你好" in ps and "exit=0" in ps, ps.replace("\n", " | ")[:80])
            det = (await call("powershell", command="Write-Output detached-ok", detach=True))[0].text
            check("powershell detach", "detached pid=" in det, det[:80])

            gal = await call("galdriver", commands="state\nshot game", timeout_s=20)
            text = gal[0].text
            check("galdriver bridge", "phase=capturing" in text and "__mcp_done" not in text and len(gal) == 3
                  and gal[2].type == "image", text.replace("\n", " | ")[:140])
            vi = await call("view_image", path=str(next(gal_dir.glob("shot_*.png"))))
            check("view_image", vi[1].type == "image")
    finally:
        stop.set()
        target.terminate()
        server.terminate()
        try:
            out = server.communicate(timeout=5)[0].decode("utf-8", "replace")
            if any(not ok for _, ok, _ in results):
                print("--- server output ---\n" + out[-3000:])
        except Exception:
            pass

    failed = [n for n, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} PASS" + (f"  FAILED: {failed}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))

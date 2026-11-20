#!/usr/bin/env python3
"""R0（SRS 协议 4 换代，规划 §6）Windows 实测驱动：新旧真二进制轮流打开同一个持久数据根。

与 srs_old_binary.py 的区别：那边每次启动一个新运行目录、比对「拒绝且不写」；这里的数据根跨进程保留
（旧版本建库制卡 → 新版本迁移 → 旧版本再开 → ……），每一步由一个 JSON 步骤表驱动，证据（控制通道回应、
窗口截图、库文件 sha256、schema / 代际标记查询结果）写进 <run>/evidence.jsonl。

隔离与收尾沿用 srs_old_binary.App：FUSHI_TEST_ROOT / APPDATA / LOCALAPPDATA / TEMP / USERPROFILE / WebView2 /
FUSHI_CTL_DIR 全部指到运行目录；只按 PID 结束本缓存二进制下的进程，绝不按名字杀。

键盘输入：已发布版本的控制通道没有「作答」与「开始升级」入口，这两步用 PostMessage 往 Flutter 视图窗口发
WM_KEYDOWN / WM_KEYUP（不抢前台焦点）；发键前先给视图发 WM_SETFOCUS，让引擎把窗口当作已获焦（离屏窗口带
WS_EX_NOACTIVATE，从不真正激活）。截图用 PrintWindow(PW_RENDERFULLCONTENT)。

用法：
  python -I tool/srs_old_binary/r0_win.py --exe <fushi.exe> | --version <id>  --root <数据根目录>  --steps <steps.json>
步骤（JSON 数组，每项一个对象）：
  {"ctl": ["GET"|"POST", "/api/...", {body}?], "as": "名字"?, "timeout": 秒?}
  {"keys": ["enter","3",...], "gap": 0.6}
  {"shot": "名字"}
  {"sleep": 秒}
  {"wait_ctl": ["GET", "/api/...", null], "until": "json 文本里出现的子串", "max": 秒}
  {"quit": true}          （步骤表末尾不写也会收尾）
  {"kill": true}          （模拟崩溃 / 断电：按 PID 直接结束，不走 quit）
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import sqlite3
import struct
import sys
import time
import zlib
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import srs_old_binary as h  # noqa: E402

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

WM_SETFOCUS = 0x0007
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_CHAR = 0x0102
VK = {"enter": 0x0D, "space": 0x20, "tab": 0x09, "esc": 0x1B, "left": 0x25, "up": 0x26,
      "right": 0x27, "down": 0x28}
for _d in "0123456789":
    VK[_d] = ord(_d)
for _c in "abcdefghijklmnopqrstuvwxyz":
    VK[_c] = ord(_c.upper())

EnumWindowsProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)


def _class_name(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def top_windows(pid: int) -> list[int]:
    found: list[int] = []

    def cb(hwnd: int, _: int) -> bool:
        p = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and _class_name(hwnd) == "FLUTTER_RUNNER_WIN32_WINDOW":
            found.append(hwnd)
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return found


def flutter_view(top: int) -> int:
    found: list[int] = []

    def cb(hwnd: int, _: int) -> bool:
        if _class_name(hwnd) == "FLUTTERVIEW":
            found.append(hwnd)
        return True

    user32.EnumChildWindows(top, EnumWindowsProc(cb), 0)
    return found[0] if found else top


def send_keys(view: int, keys: list[str], gap: float) -> None:
    user32.PostMessageW(view, WM_SETFOCUS, 0, 0)
    time.sleep(0.3)
    for k in keys:
        vk = VK[k]
        scan = user32.MapVirtualKeyW(vk, 0)
        down = 1 | (scan << 16)
        up = down | (1 << 30) | (1 << 31)
        user32.PostMessageW(view, WM_KEYDOWN, vk, down)
        if len(k) == 1:
            user32.PostMessageW(view, WM_CHAR, ord(k), down)
        user32.PostMessageW(view, WM_KEYUP, vk, up)
        time.sleep(gap)


def _png(width: int, height: int, bgra: bytes) -> bytes:
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        row = bgra[y * stride:(y + 1) * stride]
        for x in range(0, stride, 4):
            raw += bytes((row[x + 2], row[x + 1], row[x], 255))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG), ("biPlanes", wt.WORD),
                ("biBitCount", wt.WORD), ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
                ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD),
                ("biClrImportant", wt.DWORD)]


def screenshot(top: int, out: Path, screen: bool = False) -> dict[str, Any]:
    rect = wt.RECT()
    user32.GetWindowRect(top, ctypes.byref(rect))
    w, hgt = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetWindowDC(top)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, hgt)
    gdi32.SelectObject(mdc, bmp)
    if screen:
        sdc = user32.GetDC(0)
        ok = gdi32.BitBlt(mdc, 0, 0, w, hgt, sdc, rect.left, rect.top, 0x00CC0020)  # SRCCOPY
        user32.ReleaseDC(0, sdc)
    else:
        ok = user32.PrintWindow(top, mdc, 2)  # PW_RENDERFULLCONTENT
    bi = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -hgt, 1, 32, 0, 0, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * hgt * 4)
    gdi32.GetDIBits(mdc, bmp, 0, hgt, buf, ctypes.byref(bi), 0)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(top, hdc)
    data = buf.raw
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(_png(w, hgt, data))
    nonblack = sum(1 for i in range(0, len(data), 4 * 97) if data[i] or data[i + 1] or data[i + 2])
    return {"path": str(out), "w": w, "h": hgt, "printwindow": bool(ok), "nonblack_samples": nonblack}


def file_hashes(d: Path) -> dict[str, str]:
    """数据根 `app-support/` 顶层每个文件（复习库、主库 `fushi.db`、偏好……）的 sha256。"""
    if not d.is_dir():
        return {}
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(d.iterdir()) if p.is_file()}


def main_schema(db: Path) -> Optional[int]:
    """主库 `fushi.db` 的 `PRAGMA user_version`（拷进临时目录只读打开）。旧版本遇到更大的号在初始化时整体拒绝。"""
    if not db.is_file():
        return None
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        for suf in ("", "-wal", "-shm"):
            src = Path(str(db) + suf)
            if src.is_file():
                shutil.copy2(src, Path(td) / (db.name + suf))
        con = sqlite3.connect(f"file:{Path(td) / db.name}?mode=ro", uri=True)
        try:
            return int(con.execute("PRAGMA user_version").fetchone()[0])
        finally:
            con.close()


def masked_hashes(d: Path) -> dict[str, str]:
    """`srs*` 文件抹掉 SQLite 文件头 24–27（改动计数）与 92–95（version-valid-for）后的 sha256：规划 D3 批准的已知例外
    （已发布版本拒绝更新的库时只改这两处）。两边这个值相同 = 除这两处外逐字节相同。"""
    if not d.is_dir():
        return {}
    out: dict[str, str] = {}
    for p in sorted(d.iterdir()):
        if p.is_file() and p.name.startswith("srs"):
            b = bytearray(p.read_bytes())
            if len(b) >= 100 and b[:16] == b"SQLite format 3\x00":
                b[24:28] = b"\x00" * 4
                b[92:96] = b"\x00" * 4
            out[p.name] = hashlib.sha256(bytes(b)).hexdigest()
    return out


def db_facts(db: Path) -> dict[str, Any]:
    """只读打开（immutable 拷贝）：schema 号、代际标记与关键表行数。"""
    if not db.is_file():
        return {"exists": False}
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        for suf in ("", "-wal", "-shm"):
            src = Path(str(db) + suf)
            if src.is_file():
                shutil.copy2(src, Path(td) / (db.name + suf))
        con = sqlite3.connect(f"file:{Path(td) / db.name}?mode=ro", uri=True)
        try:
            tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
            out: dict[str, Any] = {"exists": True, "user_version": con.execute("PRAGMA user_version").fetchone()[0]}
            if "srs_meta" in tables:
                out["srs_meta"] = {str(k): str(v)[:200] for k, v in con.execute("SELECT key, value FROM srs_meta")
                                   if not str(k).startswith("sync2_cursor")}
            out["counts"] = {}
            for t in tables:
                try:
                    out["counts"][t] = con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
                except sqlite3.Error as e:  # 内核注册的函数 / 虚表
                    out["counts"][t] = f"err: {e}"
            return out
        finally:
            con.close()


def remote_call(port: Optional[int], token: Optional[str], op: str, args: dict[str, Any],
                profile: Optional[str] = None) -> dict[str, Any]:
    """互联主机的远程复习端点（`POST /api/srs/remote/call`，共享主机口令走 HTTP Basic）。主机首次启用默认 TLS
    （自签证书），这里只连 127.0.0.1，不校验证书。"""
    import base64
    import ssl
    import urllib.error
    import urllib.request
    import uuid as _uuid
    if port is None or not token:
        return {"status": None, "error": "host not started / no --host-token"}
    body = json.dumps({"op": op, "args": args, "request": str(_uuid.uuid4()), "profile": profile}).encode()
    auth = base64.b64encode(f"r0:{token}".encode()).decode()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    last: dict[str, Any] = {}
    for scheme in ("https", "http"):
        req = urllib.request.Request(f"{scheme}://127.0.0.1:{port}/api/srs/remote/call", data=body, method="POST",
                                     headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
        try:
            with opener.open(req, timeout=60) as r:
                raw = r.read().decode("utf-8", "replace")
                return {"status": r.status, "scheme": scheme, "json": json.loads(raw)}
        except urllib.error.HTTPError as e:
            return {"status": e.code, "scheme": scheme, "error": e.read().decode("utf-8", "replace")[:500]}
        except (OSError, ValueError) as e:
            last = {"status": None, "scheme": scheme, "error": str(e)}
    return last


class R0App(h.App):
    """数据根固定在 --root（跨进程保留），其余隔离目录放在运行目录里。"""

    def __init__(self, v: dict[str, Any], run_dir: Path, root: Path, onscreen: bool) -> None:
        super().__init__(v, run_dir, onscreen=onscreen)
        self.data = root


def main() -> int:
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe")
    ap.add_argument("--version")
    ap.add_argument("--root", required=True)
    ap.add_argument("--steps", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--onscreen", action="store_true")
    ap.add_argument("--ready-timeout", type=float, default=240)
    ap.add_argument("--host-token", help="互联主机共享口令（与 --set-pref sync_server_password=<base64> 一致）")
    ap.add_argument("--set-pref", action="append", default=[],
                    help="启动前写进 fushi.db preferences（key=带类型前缀的值，例如 onboarding_completed=b:true）")
    a = ap.parse_args()
    v = h.local_build(a.exe) if a.exe else h.select_versions(a.version)[0]
    if not a.exe:
        h.fetch_one(v)
    root = Path(a.root).resolve()
    run_dir = h.cache_root() / "runs" / f"{h.now_tag()}-r0-{a.tag}"
    ev_path = run_dir / "evidence.jsonl"
    run_dir.mkdir(parents=True, exist_ok=True)
    support = root / "app-support"

    def ev(kind: str, **kw: Any) -> None:
        rec = {"t": time.strftime("%H:%M:%S"), "kind": kind, **kw}
        line = json.dumps(rec, ensure_ascii=False)
        print(line[:4000], flush=True)
        with ev_path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    ev("begin", version=v["id"], exe=str(h.app_exe(v)), root=str(root),
       before_hashes=file_hashes(support), before_masked=masked_hashes(support), main_schema=main_schema(support / "fushi.db"), srs_db=db_facts(support / "srs.db"),
       srs4_db=db_facts(support / "srs4.db"))
    app = R0App(v, run_dir, root, a.onscreen)
    if a.set_pref:
        prefs = dict(kv.split("=", 1) for kv in a.set_pref)
        if not (support / "fushi.db").is_file():
            # 全新数据根：先让这个版本自己建一次主库（与 srs_old_binary.py seed 相同），再写偏好。
            app.start(ready_timeout=a.ready_timeout)
            ev("bootstrap-quit", **app.quit())
        h.set_prefs(app, prefs)
        ev("prefs", prefs=prefs)
    try:
        st = app.start(ready_timeout=a.ready_timeout)
        ev("ready", status={k: st.get(k) for k in ("initialised", "version", "appVersion", "profile")})
    except Exception as e:  # noqa: BLE001 —— 起不来本身就是证据
        ev("start-failed", error=str(e))
        app.quit(timeout=30)
        ev("end", after_hashes=file_hashes(support), after_masked=masked_hashes(support))
        return 2
    assert app.proc is not None
    steps = json.loads(Path(a.steps).read_text(encoding="utf-8"))
    killed = False
    host_port: Optional[int] = None
    for i, s in enumerate(steps):
        if "ctl" in s:
            m, p, *b = s["ctl"]
            r = app.call(m, p, b[0] if b else None, timeout=s.get("timeout", 120))
            ev("ctl", i=i, name=s.get("as"), method=m, path=p, status=r["status"],
               json=r.get("json"), body=(r.get("body") or "")[:2000], error=r.get("error"))
        elif "wait_ctl" in s:
            m, p, b = s["wait_ctl"]
            deadline = time.time() + s.get("max", 120)
            r: dict[str, Any] = {}
            while time.time() < deadline:
                r = app.call(m, p, b)
                if s["until"] in json.dumps(r.get("json"), ensure_ascii=False) + (r.get("body") or ""):
                    break
                time.sleep(2)
            ev("wait_ctl", i=i, path=p, until=s["until"], status=r.get("status"), json=r.get("json"),
               matched=s["until"] in json.dumps(r.get("json"), ensure_ascii=False) + (r.get("body") or ""))
        elif "keys" in s:
            tops = top_windows(app.proc.pid)
            if not tops:
                ev("keys", i=i, error="no window")
                continue
            send_keys(flutter_view(tops[0]), s["keys"], s.get("gap", 0.6))
            ev("keys", i=i, keys=s["keys"])
        elif "shot" in s:
            tops = top_windows(app.proc.pid)
            if tops:
                ev("shot", i=i, **screenshot(tops[0], run_dir / "shots" / f"{a.tag}-{s['shot']}.png",
                                             screen=a.onscreen))
            else:
                ev("shot", i=i, error="no window")
        elif "host_start" in s:
            r = app.call("POST", "/api/admin/peers/host/start", {})
            host_port = (r.get("json") or {}).get("port")
            ev("host_start", i=i, status=r["status"], json=r.get("json"), body=r.get("body"))
        elif "remote" in s:
            res = remote_call(host_port, a.host_token, s["remote"], s.get("args", {}))
            ev("remote", i=i, op=s["remote"], args=s.get("args", {}), **res)
        elif "answer_cards" in s:
            # 已发布版本的真作答路径（SrsDbStore.answerAndStudy）：经互联主机的远程复习端点逐卡作答。
            lst = app.call("GET", "/api/admin/srs/notes", None, {"mode": "cards", "limit": "1000"})
            items = (lst.get("json") or {}).get("items") or []
            ratings = s["answer_cards"]
            hello = remote_call(host_port, a.host_token, "deckSummaries", {})
            profile = (hello.get("json") or {}).get("profile")
            for n, it in enumerate(items):
                cid = it.get("id") or it.get("cardId")
                rating = ratings[n % len(ratings)]
                res = remote_call(host_port, a.host_token, "answerAndStudy",
                                  {"card": cid, "rating": rating, "durationMs": 4000}, profile)
                ev("answer", i=i, card=cid, rating=rating, status=res.get("status"),
                   log=((res.get("json") or {}).get("result") or {}).get("log"), error=res.get("error"))
        elif "sleep" in s:
            time.sleep(s["sleep"])
        elif "kill" in s:
            h.kill_pids([app.proc.pid] + h.processes_under(h.app_exe(v).parent))
            time.sleep(2)
            killed = True
            ev("killed", i=i, pid=app.proc.pid)
            break
        elif "quit" in s:
            break
    if not killed:
        ev("quit", **app.quit())
    ev("end", after_hashes=file_hashes(support), after_masked=masked_hashes(support), main_schema=main_schema(support / "fushi.db"), srs_db=db_facts(support / "srs.db"),
       srs4_db=db_facts(support / "srs4.db"), run_dir=str(run_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

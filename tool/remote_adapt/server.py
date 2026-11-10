# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=2.3,<3", "dxcam>=0.3", "mss>=10", "pillow>=11", "numpy>=2", "uvicorn>=0.30"]
# ///
"""远程适配 MCP 服务：在朋友电脑的桌面会话里运行，让本机 Claude 像用 computer use 一样操作对方屏幕。

工具：screenshot / click / move / drag / scroll / type_text / key / touch_tap / touch_swipe /
touch_hold / list_windows / focus_window / powershell / galdriver / view_image / info。

用法（对方电脑，手动启动，不做自启动）：
    start.cmd                        # 以管理员身份运行；自动绑定本机 Tailscale 地址
    python server.py --host 127.0.0.1 --token test   # 本机自测
见同目录 README.md。
"""

from __future__ import annotations

import argparse
import base64
import hmac
import io
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Literal

sys.path.insert(0, str(Path(__file__).resolve().parent))

import desktop  # noqa: E402  必须先于其他截图 / 窗口相关库导入（设置 DPI 感知）
from geometry import Rect, View, fit_size  # noqa: E402

from mcp.server.mcpserver import Image, MCPServer  # noqa: E402

VERSION = "1.0.0"
STATE_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "fushi_remote_adapt"
DEFAULT_GALDRIVER_DIR = STATE_DIR / "galdriver"
MAX_OUTPUT_CHARS = 30_000

Coords = Literal["image", "physical"]


class State:
    capturer: desktop.Capturer
    worker: desktop.DesktopThread
    last_view: View | None = None
    last_shot_opts: dict[str, Any] = {}
    galdriver_dir: Path = DEFAULT_GALDRIVER_DIR


S = State()

mcp = MCPServer(
    name="remote-adapt",
    version=VERSION,
    instructions=(
        "操作一台远程 Windows 电脑的桌面（用于在朋友电脑上适配 galgame）。"
        "坐标默认是最近一次 screenshot 返回图像里的像素（coords='image'），服务端按缩放比换回物理像素；"
        "galdriver accept4 / calibrate 等驱动指令要的是物理屏幕像素，可传 coords='physical' 或用截图说明里的换算式。"
        "动作工具可带 screenshot_after=true 省一轮截图。截不到游戏画面时检查 info 里的 capture 后端。"
    ),
)


# ── 截图 ─────────────────────────────────────────────────────────────────────


def _encode(img: Any, fmt: str, quality: int) -> bytes:
    buf = io.BytesIO()
    if fmt == "png":
        img.save(buf, "PNG", optimize=False, compress_level=3)
    else:
        img.save(buf, "JPEG", quality=quality, optimize=True)
    return buf.getvalue()


def _draw_cursor(img: Any, view: View) -> None:
    from PIL import ImageDraw

    cx, cy = desktop.cursor_position()
    if not view.region.contains(cx, cy):
        return
    x, y = view.to_image(cx, cy)
    d = ImageDraw.Draw(img)
    for color, width in (("white", 5), ("red", 2)):
        d.line([(x - 10, y), (x + 10, y)], fill=color, width=width)
        d.line([(x, y - 10), (x, y + 10)], fill=color, width=width)


def _resolve_region(region: list[int] | None, monitor: int | None, window: int | None, client: bool) -> Rect:
    virtual = desktop.virtual_screen()
    if region:
        if len(region) != 4:
            raise ValueError("region 要 [left, top, width, height]（物理像素）")
        rect = Rect(*[int(v) for v in region])
    elif window:
        rect = desktop.client_rect(window) if client else desktop.window_rect(window)
    elif monitor is not None:
        mons = desktop.monitors()
        if not 0 <= monitor < len(mons):
            raise ValueError(f"monitor 只有 0..{len(mons) - 1}")
        rect = mons[monitor].rect
    else:
        rect = virtual
    clipped = rect.intersect(virtual)
    if clipped is None:
        raise ValueError(f"区域 {rect} 不在屏幕上（虚拟桌面 {virtual}）")
    return clipped


def _capture(region: list[int] | None, monitor: int | None, window: int | None, client: bool,
             max_size: int, fmt: str, quality: int, show_cursor: bool) -> list[Any]:
    rect = _resolve_region(region, monitor, window, client)
    t0 = time.perf_counter()
    img = S.capturer.grab(rect)
    w, h = fit_size(rect.width, rect.height, max_size)
    if (w, h) != (rect.width, rect.height):
        from PIL import Image as PILImage

        img = img.resize((w, h), PILImage.Resampling.LANCZOS)
    view = View(rect, w, h)
    if show_cursor:
        _draw_cursor(img, view)
    data = _encode(img, fmt, quality)
    S.last_view = view
    S.last_shot_opts = {"region": [rect.left, rect.top, rect.width, rect.height], "max_size": max_size,
                        "fmt": fmt, "quality": quality, "show_cursor": show_cursor}
    sx = rect.width / w
    fg = desktop.foreground_window()
    fg_desc = desktop.describe_window(fg) if fg else {}
    text = (
        f"image {w}x{h} ← physical [{rect.left},{rect.top},{rect.width},{rect.height}] "
        f"scale={view.scale:.4f}；physical_x = {rect.left} + (x+0.5)*{sx:.4f}，physical_y = {rect.top} + (y+0.5)*{rect.height / h:.4f}。"
        f" capture={S.capturer.last_backend} {int((time.perf_counter() - t0) * 1000)}ms {len(data) // 1024}KB"
        f" foreground={fg_desc.get('hwnd')} {fg_desc.get('exe')} \"{fg_desc.get('title', '')}\""
    )
    return [text, Image(data=data, format="png" if fmt == "png" else "jpeg")]


@mcp.tool(structured_output=False)
async def screenshot(
    region: list[int] | None = None,
    monitor: int | None = None,
    window: int | None = None,
    client: bool = False,
    max_size: int = 1568,
    format: Literal["jpeg", "png"] = "jpeg",
    quality: int = 80,
    show_cursor: bool = True,
) -> list[Any]:
    """截屏（DXGI 桌面复制，独占全屏游戏也能截）。默认整个虚拟桌面，长边缩到 max_size。

    region=[left,top,width,height] 物理像素，用来放大看细节（小区域 + 不缩放 = 原始像素）；
    monitor=显示器序号；window=hwnd 截该窗口所在矩形（client=true 只截客户区，游戏坐标原点）。
    之后动作工具里的 image 坐标都按这次截图换算。红十字是当前光标位置。
    """
    return await S.worker.run(_capture, region, monitor, window, client, max_size, format, quality, show_cursor)


async def _after(screenshot_after: bool, wait_ms: int, summary: str) -> list[Any]:
    if not screenshot_after:
        return [summary]
    if wait_ms > 0:
        import asyncio

        await asyncio.sleep(wait_ms / 1000)
    opts = S.last_shot_opts or {"region": None, "max_size": 1568, "fmt": "jpeg", "quality": 80, "show_cursor": True}
    shot = await S.worker.run(_capture, opts["region"], None, None, False, opts["max_size"], opts["fmt"],
                              opts["quality"], opts["show_cursor"])
    return [summary, *shot]


def _phys(x: float, y: float, coords: Coords) -> tuple[int, int]:
    if coords == "physical":
        return int(x), int(y)
    if S.last_view is None:
        raise ValueError("还没有截图：先调 screenshot，或传 coords='physical'")
    return S.last_view.to_physical(x, y)


def _target_note(px: int, py: int) -> str:
    hwnd = desktop.window_at(px, py)
    if not hwnd:
        return ""
    d = desktop.describe_window(hwnd)
    note = f" 目标窗口 {d['hwnd']} {d['exe']} \"{d['title']}\""
    if d["elevated"] in ("yes", "denied") and not desktop.is_admin():
        note += "（目标可能以管理员运行而本服务不是：UIPI 会吞掉注入，请用管理员身份重启服务）"
    return note


# ── 鼠标 / 键盘 ───────────────────────────────────────────────────────────────


def _with_modifiers(modifiers: list[str], scancode: bool, fn: Any) -> None:
    vks = [desktop.parse_key(m) for m in modifiers]
    pressed: list[int] = []
    try:
        for vk in vks:
            desktop._send([desktop._key_input(vk, False, scancode)], "modifier down")
            pressed.append(vk)
        fn()
    finally:
        for vk in reversed(pressed):
            desktop._send([desktop._key_input(vk, True, scancode)], "modifier up")


@mcp.tool(structured_output=False)
async def click(
    x: float,
    y: float,
    coords: Coords = "image",
    button: Literal["left", "right", "middle"] = "left",
    count: int = 1,
    hold_ms: int = 30,
    modifiers: list[str] | None = None,
    screenshot_after: bool = False,
    wait_ms: int = 400,
) -> list[Any]:
    """在 (x,y) 点击（SendInput 真实鼠标）。count=2 双击；modifiers 如 ["shift"] 按住修饰键点击。"""
    px, py = _phys(x, y, coords)
    await S.worker.run(_with_modifiers, modifiers or [], False,
                       lambda: desktop.click(px, py, button, max(1, count), hold_ms))
    return await _after(screenshot_after, wait_ms, f"{button} x{count} @ physical {px},{py}.{_target_note(px, py)}")


@mcp.tool(structured_output=False)
async def move(x: float, y: float, coords: Coords = "image", screenshot_after: bool = False, wait_ms: int = 300) -> list[Any]:
    """移动光标到 (x,y)（悬停 / Shift 悬浮查词前置）。"""
    px, py = _phys(x, y, coords)
    await S.worker.run(desktop.move_mouse, px, py)
    return await _after(screenshot_after, wait_ms, f"moved to physical {px},{py}")


@mcp.tool(structured_output=False)
async def drag(
    x1: float, y1: float, x2: float, y2: float,
    coords: Coords = "image",
    button: Literal["left", "right", "middle"] = "left",
    duration_ms: int = 400,
    screenshot_after: bool = False,
    wait_ms: int = 300,
) -> list[Any]:
    """按住鼠标从 (x1,y1) 拖到 (x2,y2)。"""
    a = _phys(x1, y1, coords)
    b = _phys(x2, y2, coords)
    await S.worker.run(desktop.drag, a, b, button, duration_ms)
    return await _after(screenshot_after, wait_ms, f"drag {a} → {b}")


@mcp.tool(structured_output=False)
async def scroll(
    x: float, y: float, dy: int = 0, dx: int = 0,
    coords: Coords = "image",
    screenshot_after: bool = False,
    wait_ms: int = 300,
) -> list[Any]:
    """在 (x,y) 滚轮：dy>0 向上、dy<0 向下；dx>0 向右。单位是滚轮格。"""
    px, py = _phys(x, y, coords)
    await S.worker.run(desktop.scroll, px, py, dy, dx)
    return await _after(screenshot_after, wait_ms, f"scroll dy={dy} dx={dx} @ {px},{py}")


@mcp.tool(structured_output=False)
async def type_text(text: str, screenshot_after: bool = False, wait_ms: int = 300) -> list[Any]:
    """向前台窗口输入文本（Unicode 直接上屏，不经输入法；\\n 发回车）。"""
    await S.worker.run(desktop.type_text, text)
    return await _after(screenshot_after, wait_ms, f"typed {len(text)} chars")


@mcp.tool(structured_output=False)
async def key(
    combo: str,
    repeat: int = 1,
    hold_ms: int = 50,
    scancode: bool = False,
    screenshot_after: bool = False,
    wait_ms: int = 300,
) -> list[Any]:
    """按组合键，如 "enter"、"ctrl+s"、"alt+f4"、"shift"、"vk:0x41"。

    hold_ms 是按住时长（长按 Ctrl 快进之类）；DirectInput 老游戏收不到时用 scancode=true。
    """
    def _run() -> None:
        for i in range(max(1, repeat)):
            desktop.key_combo(combo, hold_ms, scancode)
            if i + 1 < repeat:
                time.sleep(0.05)

    await S.worker.run(_run)
    return await _after(screenshot_after, wait_ms, f"key {combo} x{repeat}")


# ── 触摸 ─────────────────────────────────────────────────────────────────────


@mcp.tool(structured_output=False)
async def touch_tap(x: float, y: float, coords: Coords = "image", hold_ms: int = 60,
                    screenshot_after: bool = False, wait_ms: int = 400) -> list[Any]:
    """真实触摸点按（InjectTouchInput PT_TOUCH），用于第④条触摸验收；SendInput 鼠标不能代替。"""
    px, py = _phys(x, y, coords)
    await S.worker.run(desktop.touch_path, [(px, py)], hold_ms)
    return await _after(screenshot_after, wait_ms, f"touch tap @ {px},{py} {hold_ms}ms.{_target_note(px, py)}")


@mcp.tool(structured_output=False)
async def touch_hold(x: float, y: float, duration_ms: int = 900, coords: Coords = "image",
                     screenshot_after: bool = False, wait_ms: int = 400) -> list[Any]:
    """触摸长按（按住期间每 16ms 发 UPDATE 帧保持触点）。"""
    px, py = _phys(x, y, coords)
    await S.worker.run(desktop.touch_path, [(px, py)], duration_ms)
    return await _after(screenshot_after, wait_ms, f"touch hold @ {px},{py} {duration_ms}ms")


@mcp.tool(structured_output=False)
async def touch_swipe(x1: float, y1: float, x2: float, y2: float, duration_ms: int = 300,
                      coords: Coords = "image", screenshot_after: bool = False, wait_ms: int = 400) -> list[Any]:
    """触摸滑动：(x1,y1) 按下，duration_ms 内匀速滑到 (x2,y2) 抬起。"""
    a = _phys(x1, y1, coords)
    b = _phys(x2, y2, coords)
    await S.worker.run(desktop.touch_path, [a, b], duration_ms)
    return await _after(screenshot_after, wait_ms, f"touch swipe {a} → {b} {duration_ms}ms")


# ── 窗口 ─────────────────────────────────────────────────────────────────────


@mcp.tool(structured_output=False)
async def list_windows(filter: str | None = None, include_untitled: bool = False) -> str:
    """列出可见顶层窗口（Z 序，前台在前）：hwnd、标题、类名、进程、是否提权、窗口 / 客户区物理矩形、DPI。"""
    wins = await S.worker.run(desktop.list_windows, include_untitled)
    if filter:
        f = filter.lower()
        wins = [w for w in wins if f in w["title"].lower() or f in w["exe"].lower() or f in w["class"].lower()]
    return "\n".join(json.dumps(w, ensure_ascii=False) for w in wins) or "（没有匹配的窗口）"


@mcp.tool(structured_output=False)
async def focus_window(hwnd: int, screenshot_after: bool = False, wait_ms: int = 300) -> list[Any]:
    """把窗口切到前台（最小化的先还原）。"""
    ok = await S.worker.run(desktop.focus_window, hwnd)
    return await _after(screenshot_after, wait_ms, f"focus {hwnd} foreground={'ok' if ok else 'FAILED（前台锁拒绝）'}")


# ── 命令 ─────────────────────────────────────────────────────────────────────

_PS_PRELUDE = (
    "$ProgressPreference='SilentlyContinue';"
    "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding;"
)


def _ps_args(command: str) -> list[str]:
    encoded = base64.b64encode((_PS_PRELUDE + command).encode("utf-16-le")).decode()
    return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]


def _clip(text: str) -> str:
    if len(text) <= MAX_OUTPUT_CHARS:
        return text
    half = MAX_OUTPUT_CHARS // 2
    return f"{text[:half]}\n…（省略 {len(text) - MAX_OUTPUT_CHARS} 字符）…\n{text[-half:]}"


def _run_powershell(command: str, timeout_s: float, detach: bool, cwd: str | None) -> str:
    flags = subprocess.CREATE_NO_WINDOW
    if detach:
        jobs = STATE_DIR / "jobs"
        jobs.mkdir(parents=True, exist_ok=True)
        log = jobs / f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.log"
        with open(log, "wb") as fh:
            proc = subprocess.Popen(_ps_args(command), stdout=fh, stderr=subprocess.STDOUT, cwd=cwd,
                                    creationflags=flags | subprocess.CREATE_NEW_PROCESS_GROUP)
        return f"detached pid={proc.pid} log={log}（用 powershell 'Get-Content -Tail 50 \"{log}\"' 看输出）"
    proc = subprocess.Popen(_ps_args(command), stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, creationflags=flags)
    try:
        out, err = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        out, err = proc.communicate()
        return _clip(f"TIMEOUT after {timeout_s}s（进程树已结束）\n{out.decode('utf-8', 'replace')}\n[stderr]\n{err.decode('utf-8', 'replace')}")
    text = out.decode("utf-8", "replace")
    if err:
        text += "\n[stderr]\n" + err.decode("utf-8", "replace")
    return _clip(f"exit={proc.returncode}\n{text}")


@mcp.tool(structured_output=False)
async def powershell(command: str, timeout_s: float = 60, detach: bool = False, cwd: str | None = None) -> str:
    """在对方桌面会话里执行 PowerShell（拉起的程序显示在对方屏幕上）。输出 UTF-8。

    detach=true 后台运行、立即返回 pid 与日志路径（长时间进程，如拉起 galdriver 测试宿主）。
    """
    import asyncio

    return await asyncio.to_thread(_run_powershell, command, timeout_s, detach, cwd)


# ── galdriver ────────────────────────────────────────────────────────────────

_SHOT_RE = re.compile(r"-> (\S+\.png)\s*$", re.MULTILINE)


def _read_from(path: Path, offset: int) -> tuple[str, int]:
    if not path.exists():
        return "", 0
    size = path.stat().st_size
    if size < offset:  # 驱动重启后 out.txt 被重建
        offset = 0
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read()
    return data.decode("utf-8", "replace"), offset + len(data)


def _galdriver(commands: str, timeout_s: float, directory: Path, shot_max_size: int) -> list[Any]:
    directory.mkdir(parents=True, exist_ok=True)
    cmd_file = directory / "cmd.txt"
    out_file = directory / "out.txt"
    lines = [ln.strip() for ln in commands.splitlines() if ln.strip() and not ln.strip().startswith("#")]
    if not lines:
        raise ValueError("没有指令")
    # 驱动对未知指令回 `#n unknown: <原文>`：用一条带随机串的未知指令做完成标记，新旧驱动都适用，不依赖 done.txt 序号。
    marker = f"__mcp_done_{uuid.uuid4().hex[:12]}"
    _, offset = _read_from(out_file, 0)
    payload = "\n".join([*lines, marker]) + "\n"
    if cmd_file.exists():  # 驱动还没取走上一批：追加
        with open(cmd_file, "a", encoding="utf-8") as fh:
            fh.write(payload)
    else:
        tmp = directory / f"cmd.{uuid.uuid4().hex[:6]}.tmp"
        tmp.write_text(payload, encoding="utf-8")
        os.replace(tmp, cmd_file)
    deadline = time.monotonic() + timeout_s
    collected = ""
    pos = offset
    while time.monotonic() < deadline:
        chunk, pos = _read_from(out_file, pos)
        collected += chunk
        if marker in collected:
            break
        time.sleep(0.2)
    else:
        pending = cmd_file.exists()
        return [_clip(collected) + (
            f"\nTIMEOUT {timeout_s}s：" + ("cmd.txt 一直没被取走——驱动没在跑或 GALDRIVER_DIR 不是 " + str(directory)
                                         if pending else "驱动已取走指令但还没执行完，可再调 galdriver 'state' 看进度")
        )]
    body = "\n".join(ln for ln in collected.splitlines() if marker not in ln)
    result: list[Any] = [_clip(body)]
    for match in _SHOT_RE.finditer(body):
        png = Path(match.group(1))
        if png.exists():
            result.extend(_image_file(png, shot_max_size))
    return result


def _image_file(path: Path, max_size: int) -> list[Any]:
    from PIL import Image as PILImage

    with PILImage.open(path) as im:
        im = im.convert("RGB")
        w, h = fit_size(im.width, im.height, max_size)
        note = f"{path.name} {im.width}x{im.height}"
        if (w, h) != im.size:
            note += f" → {w}x{h}（scale={w / im.width:.4f}；图像坐标不能直接用于 click）"
            im = im.resize((w, h), PILImage.Resampling.LANCZOS)
        return [note, Image(data=_encode(im, "jpeg", 85), format="jpeg")]


@mcp.tool(structured_output=False)
async def galdriver(commands: str, timeout_s: float = 180, dir: str | None = None, shot_max_size: int = 1568) -> list[Any]:
    """透传 galgame 真机驱动（gal_realgame_driver_itest）指令，等它执行完返回 out.txt 新增内容；
    `shot` 产出的 PNG 一并作为图片返回。多条指令用换行分隔，如 "fakeanki\\naccept4 1304 1590"。

    指令表见驱动文件头（launch/launchoff/attach/thread/state/calibrate/accept4/mine/shot/click…）。
    accept4/calibrate/click 的坐标是物理屏幕像素：从截图换算，或先 move(coords='image') 再看 info 的 cursor。
    """
    import asyncio

    directory = Path(dir) if dir else S.galdriver_dir
    return await asyncio.to_thread(_galdriver, commands, timeout_s, directory, shot_max_size)


@mcp.tool(structured_output=False)
async def view_image(path: str, max_size: int = 1568) -> list[Any]:
    """读取对方电脑上的图片文件（驱动截图、游戏截图、日志图）。"""
    import asyncio

    return await asyncio.to_thread(_image_file, Path(path), max_size)


# ── info ─────────────────────────────────────────────────────────────────────


def _info() -> str:
    fg = desktop.foreground_window()
    gd = S.galdriver_dir
    info = {
        "version": VERSION,
        "host": platform.node(),
        "windows": platform.version(),
        "user": os.environ.get("USERNAME"),
        "session_id": _session_id(),
        "admin": desktop.is_admin(),
        "dpi_awareness": desktop.DPI_AWARENESS,
        "virtual_screen": list(vars(desktop.virtual_screen()).values()),
        "monitors": [{"index": m.index, "device": m.device, "rect": [m.rect.left, m.rect.top, m.rect.width, m.rect.height],
                      "primary": m.primary} for m in desktop.monitors()],
        "cursor": desktop.cursor_position(),
        "foreground": desktop.describe_window(fg) if fg else None,
        "digitizer": hex(desktop.digitizer_flags()),
        "capture": {"last": S.capturer.last_backend, "last_error": S.capturer.last_error},
        "galdriver_dir": str(gd),
        "galdriver_out_exists": (gd / "out.txt").exists(),
        "last_view": None if S.last_view is None else {
            "region": list(vars(S.last_view.region).values()), "image": [S.last_view.image_w, S.last_view.image_h]},
    }
    return json.dumps(info, ensure_ascii=False, indent=1)


def _session_id() -> int:
    sid = desktop.wintypes.DWORD()
    desktop.kernel32.ProcessIdToSessionId(os.getpid(), desktop.ctypes.byref(sid))
    return sid.value


@mcp.tool(structured_output=False)
async def info() -> str:
    """服务状态：是否管理员（UIPI）、DPI 感知、显示器物理矩形、光标、前台窗口、截图后端、galdriver 目录。"""
    return await S.worker.run(_info)


# ── HTTP / 鉴权 / 启动 ────────────────────────────────────────────────────────


class BearerAuth:
    """纯 ASGI 中间件：每个 HTTP 请求必须带 `Authorization: Bearer <token>`（常量时间比较）。"""

    def __init__(self, app: Any, token: str) -> None:
        self.app = app
        self.expected = f"Bearer {token}".encode()

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] == "http":
            got = dict(scope.get("headers") or []).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain"), (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": b"unauthorized"})
                return
        await self.app(scope, receive, send)


def _tailscale_exe() -> str | None:
    found = shutil.which("tailscale")
    if found:
        return found
    default = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tailscale" / "tailscale.exe"
    return str(default) if default.exists() else None


def tailscale_self() -> tuple[str | None, str | None]:
    """(Tailscale IPv4, MagicDNS 名)。未安装 / 未登录返回 (None, None)。"""
    exe = _tailscale_exe()
    if not exe:
        return None, None
    try:
        out = subprocess.run([exe, "status", "--json", "--self=true", "--peers=false"], capture_output=True,
                             timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
        status = json.loads(out.stdout.decode("utf-8", "replace"))
    except Exception:
        return None, None
    self_node = status.get("Self") or {}
    ips = [ip for ip in self_node.get("TailscaleIPs") or [] if ":" not in ip]
    dns = (self_node.get("DNSName") or "").rstrip(".") or None
    return (ips[0] if ips else None), dns


def load_token(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("REMOTE_ADAPT_TOKEN"):
        return os.environ["REMOTE_ADAPT_TOKEN"]
    path = STATE_DIR / "token"
    if path.exists() and path.read_text(encoding="utf-8").strip():
        return path.read_text(encoding="utf-8").strip()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    path.write_text(token, encoding="utf-8")
    return token


def build_app(token: str) -> Any:
    # 无状态 + JSON 响应：服务重启后客户端不需要重连会话，工具调用一来一回最省。
    app = mcp.streamable_http_app(stateless_http=True, json_response=True, host="0.0.0.0")
    return BearerAuth(app, token)


def main() -> None:
    parser = argparse.ArgumentParser(description="远程适配 MCP 服务（截图 / 鼠标键盘 / 触摸 / PowerShell / galdriver）")
    parser.add_argument("--host", default="auto", help="监听地址；auto=本机 Tailscale IPv4（默认，不监听局域网 / 公网）")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", help="Bearer token；缺省读 REMOTE_ADAPT_TOKEN 或 %%LOCALAPPDATA%%\\fushi_remote_adapt\\token（没有就生成）")
    parser.add_argument("--name", help="在 Claude 侧注册的服务名（只影响打印的注册命令），缺省用机器名")
    parser.add_argument("--galdriver-dir", default=os.environ.get("GALDRIVER_DIR") or str(DEFAULT_GALDRIVER_DIR))
    parser.add_argument("--capture", choices=["dxgi", "gdi"], default="dxgi")
    args = parser.parse_args()
    # 输出被重定向到文件 / 管道时用的是系统 ANSI 代码页（GBK、CP932），不能编码的字符替换掉而不是崩。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    ts_ip, ts_dns = tailscale_self()
    host = args.host
    if host == "auto":
        if not ts_ip:
            sys.exit("找不到 Tailscale 地址：先装 Tailscale 并登录（tailscale up），或显式传 --host。")
        host = ts_ip
    token = load_token(args.token)
    S.capturer = desktop.Capturer(args.capture)
    S.worker = desktop.DesktopThread()
    S.galdriver_dir = Path(args.galdriver_dir)

    name = args.name or re.sub(r"[^a-z0-9-]", "-", platform.node().lower()).strip("-") or "remote"
    reach = ts_dns if (ts_dns and host == ts_ip) else host
    print(f"remote-adapt {VERSION}  监听 http://{host}:{args.port}/mcp  admin={desktop.is_admin()} dpi={desktop.DPI_AWARENESS}")
    if not desktop.is_admin():
        print("  [!] 非管理员：以管理员身份运行的游戏收不到点击（UIPI）。用 start.cmd 启动会自动提权。")
    print("  在你那边注册（token 只发给你自己，别贴到公开地方）：")
    print(f"    claude mcp add --transport http {name} http://{reach}:{args.port}/mcp --header \"Authorization: Bearer {token}\"")
    print("  Ctrl+C 停止。")

    import uvicorn

    uvicorn.run(build_app(token), host=host, port=args.port, log_level="warning", timeout_keep_alive=75)


if __name__ == "__main__":
    main()

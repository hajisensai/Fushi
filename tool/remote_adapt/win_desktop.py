"""Windows 桌面原语：截图、鼠标、键盘、触摸注入、前台窗口信息。

只在被控端（志愿者电脑）的**交互桌面会话**里使用。服务会话（ssh / Windows 服务）
里调用 SendInput / BitBlt 不会作用到用户看到的桌面，所以 agent 必须由登录用户启动。

坐标一律是虚拟桌面的物理像素：进程启动时声明 Per-Monitor-V2 DPI 感知，系统不再按
缩放比改写坐标，和 galdriver `accept4` 用的是同一个坐标系。
"""

from __future__ import annotations

import ctypes
import io
import sys
import threading
import time
from ctypes import wintypes
from dataclasses import dataclass
from typing import Optional

if sys.platform != "win32":  # pragma: no cover - 被控端只有 Windows
    raise ImportError("win_desktop 只能在 Windows 上导入")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


def enable_dpi_awareness() -> str:
    """声明 Per-Monitor-V2 DPI 感知；必须在任何窗口 / 截图调用之前执行。"""
    try:
        # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
        user32.SetProcessDpiAwarenessContext.restype = wintypes.BOOL
        user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        if user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            return "per_monitor_v2"
    except AttributeError:
        pass
    try:
        ctypes.WinDLL("shcore").SetProcessDpiAwareness(2)
        return "per_monitor"
    except (AttributeError, OSError):
        pass
    user32.SetProcessDPIAware()
    return "system"


# ── 屏幕几何 ────────────────────────────────────────────────────────────────

SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79
SM_DIGITIZER = 94
SM_MAXIMUMTOUCHES = 95


def virtual_screen() -> tuple[int, int, int, int]:
    """虚拟桌面 (left, top, width, height)，物理像素。"""
    return (
        user32.GetSystemMetrics(SM_XVIRTUALSCREEN),
        user32.GetSystemMetrics(SM_YVIRTUALSCREEN),
        user32.GetSystemMetrics(SM_CXVIRTUALSCREEN),
        user32.GetSystemMetrics(SM_CYVIRTUALSCREEN),
    )


def touch_capabilities() -> dict[str, int]:
    return {
        "digitizer": user32.GetSystemMetrics(SM_DIGITIZER),
        "max_touches": user32.GetSystemMetrics(SM_MAXIMUMTOUCHES),
    }


def monitors() -> list[dict[str, int]]:
    """mss 的显示器列表：[0] 是整个虚拟桌面，[1..] 是各显示器。"""
    with _mss_instance() as sct:
        return [dict(m) for m in sct.monitors]


def _mss_instance() -> object:
    import mss

    factory = getattr(mss, "MSS", None) or mss.mss
    return factory()


# ── 前台窗口 ────────────────────────────────────────────────────────────────

user32.GetForegroundWindow.restype = wintypes.HWND
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [
    wintypes.HWND,
    ctypes.POINTER(wintypes.DWORD),
]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]


def window_info(hwnd: int) -> dict[str, object]:
    if not hwnd:
        return {"hwnd": 0}
    title = ctypes.create_unicode_buffer(512)
    cls = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, title, 512)
    user32.GetClassNameW(hwnd, cls, 256)
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return {
        "hwnd": int(hwnd),
        "title": title.value,
        "class": cls.value,
        "pid": int(pid.value),
        "rect": [rect.left, rect.top, rect.right, rect.bottom],
    }


def foreground_window() -> dict[str, object]:
    return window_info(user32.GetForegroundWindow() or 0)


# ── 截图 ────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Capture:
    """一次截图：编码后的图片 + 截图坐标 → 物理坐标的换算。"""

    data: bytes
    mime: str
    origin_x: int
    origin_y: int
    physical_width: int
    physical_height: int
    width: int
    height: int
    nearly_black: bool

    @property
    def scale(self) -> float:
        """物理像素 / 截图像素。"""
        return self.physical_width / self.width

    def to_physical(self, x: float, y: float) -> tuple[int, int]:
        return (
            self.origin_x + round(x * self.scale),
            self.origin_y + round(y * self.scale),
        )


def capture_screen(
    monitor: int = 1,
    max_width: int = 1280,
    image_format: str = "jpeg",
    quality: int = 70,
    region: Optional[tuple[int, int, int, int]] = None,
) -> Capture:
    """截取显示器（0=整个虚拟桌面，1=主显示器…）或物理坐标区域 (l, t, w, h)。

    用 GDI BitBlt（mss）。Win10+ 绝大多数「全屏」游戏经 DWM 合成，能截到；真正
    独占全屏的老游戏可能是黑帧——[Capture.nearly_black] 会标出来，这时改用
    galdriver 的 `shot game`（WGC 抓窗口）。
    """
    from PIL import Image, ImageStat

    with _mss_instance() as sct:
        if region is not None:
            left, top, w, h = region
            box = {"left": left, "top": top, "width": w, "height": h}
        else:
            if monitor < 0 or monitor >= len(sct.monitors):
                raise ValueError(
                    f"monitor={monitor} 不存在，可选 0..{len(sct.monitors) - 1}"
                )
            box = dict(sct.monitors[monitor])
        shot = sct.grab(box)
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    phys_w, phys_h = img.size
    extrema = ImageStat.Stat(img.convert("L")).extrema[0]
    nearly_black = extrema[1] < 12
    if max_width and phys_w > max_width:
        new_h = max(1, round(phys_h * max_width / phys_w))
        img = img.resize((max_width, new_h), Image.LANCZOS)
    buf = io.BytesIO()
    fmt = image_format.lower()
    if fmt in ("jpg", "jpeg"):
        img.save(buf, format="JPEG", quality=quality, optimize=True)
        mime = "image/jpeg"
    else:
        img.save(buf, format="PNG", optimize=True)
        mime = "image/png"
    return Capture(
        data=buf.getvalue(),
        mime=mime,
        origin_x=box["left"],
        origin_y=box["top"],
        physical_width=phys_w,
        physical_height=phys_h,
        width=img.size[0],
        height=img.size[1],
        nearly_black=nearly_black,
    )


# ── SendInput ───────────────────────────────────────────────────────────────

ULONG_PTR = ctypes.c_size_t

INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x01000
MOUSEEVENTF_VIRTUALDESK = 0x4000
MOUSEEVENTF_ABSOLUTE = 0x8000

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.MapVirtualKeyW.restype = wintypes.UINT

# 所有输入串行：两个工具调用交错发 down/up 会造成卡键。
_input_lock = threading.Lock()


def _send(inputs: list[INPUT]) -> None:
    arr = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        err = ctypes.get_last_error()
        raise OSError(
            f"SendInput 只发出 {sent}/{len(inputs)} 个事件 (err={err})；"
            "目标若以管理员身份运行，agent 也要以管理员身份运行（UIPI）"
        )


def _mouse(flags: int, dx: int = 0, dy: int = 0, data: int = 0) -> INPUT:
    inp = INPUT(type=INPUT_MOUSE)
    inp.u.mi = MOUSEINPUT(dx, dy, ctypes.c_uint32(data).value, flags, 0, 0)
    return inp


def _abs_move(x: int, y: int) -> INPUT:
    vl, vt, vw, vh = virtual_screen()
    nx = round((x - vl) * 65535 / max(1, vw - 1))
    ny = round((y - vt) * 65535 / max(1, vh - 1))
    return _mouse(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny
    )


_BUTTONS = {
    "left": (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
    "right": (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
    "middle": (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
}


def _move_exact(x: int, y: int) -> None:
    # 绝对坐标归一化到 0..65535 会有 ±1 像素误差；先发移动事件让程序收到 WM_MOUSEMOVE，
    # 再 SetCursorPos 把光标钉到精确像素。
    _send([_abs_move(x, y)])
    user32.SetCursorPos(x, y)


def mouse_move(x: int, y: int) -> None:
    with _input_lock:
        _move_exact(x, y)


def mouse_click(
    x: int,
    y: int,
    button: str = "left",
    count: int = 1,
    modifiers: Optional[list[str]] = None,
    hold_ms: int = 0,
) -> None:
    if button not in _BUTTONS:
        raise ValueError(f"button 只能是 {sorted(_BUTTONS)}")
    down, up = _BUTTONS[button]
    mods = [_vk_of(m) for m in (modifiers or [])]
    with _input_lock:
        for vk in mods:
            _send([_key_input(vk, up=False)])
        try:
            _move_exact(x, y)
            time.sleep(0.03)
            for i in range(count):
                _send([_mouse(down)])
                if hold_ms:
                    time.sleep(hold_ms / 1000)
                else:
                    time.sleep(0.02)
                _send([_mouse(up)])
                if i + 1 < count:
                    time.sleep(0.06)
        finally:
            for vk in reversed(mods):
                _send([_key_input(vk, up=True)])


def mouse_drag(
    x1: int, y1: int, x2: int, y2: int, button: str = "left", duration_ms: int = 400
) -> None:
    down, up = _BUTTONS[button]
    steps = max(2, duration_ms // 16)
    with _input_lock:
        _move_exact(x1, y1)
        time.sleep(0.03)
        _send([_mouse(down)])
        try:
            for i in range(1, steps + 1):
                t = i / steps
                _send([_abs_move(round(x1 + (x2 - x1) * t), round(y1 + (y2 - y1) * t))])
                time.sleep(duration_ms / 1000 / steps)
            user32.SetCursorPos(x2, y2)
        finally:
            _send([_mouse(up)])


def mouse_scroll(x: int, y: int, dy: int = 0, dx: int = 0) -> None:
    """dy>0 向上滚，单位是「格」（120）。"""
    with _input_lock:
        _move_exact(x, y)
        if dy:
            _send([_mouse(MOUSEEVENTF_WHEEL, data=dy * 120)])
        if dx:
            _send([_mouse(MOUSEEVENTF_HWHEEL, data=dx * 120)])


# ── 键盘 ────────────────────────────────────────────────────────────────────

_VK_NAMES: dict[str, int] = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "return": 0x0D,
    "shift": 0x10, "ctrl": 0x11, "control": 0x11, "alt": 0x12, "menu": 0x12,
    "pause": 0x13, "capslock": 0x14, "esc": 0x1B, "escape": 0x1B,
    "space": 0x20, "pageup": 0x21, "pagedown": 0x22, "end": 0x23, "home": 0x24,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "printscreen": 0x2C, "insert": 0x2D, "delete": 0x2E, "del": 0x2E,
    "win": 0x5B, "lwin": 0x5B, "rwin": 0x5C, "apps": 0x5D,
    "lshift": 0xA0, "rshift": 0xA1, "lctrl": 0xA2, "rctrl": 0xA3,
    "lalt": 0xA4, "ralt": 0xA5,
}
for _i in range(1, 25):
    _VK_NAMES[f"f{_i}"] = 0x6F + _i
for _i in range(10):
    _VK_NAMES[f"num{_i}"] = 0x60 + _i

# 需要 KEYEVENTF_EXTENDEDKEY 的键（方向键、Ins/Del/Home/End/PgUp/PgDn、右侧修饰键、Win）。
_EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E,
             0x5B, 0x5C, 0x5D, 0xA3, 0xA5}


def _vk_of(name: str) -> int:
    key = name.strip().lower()
    if key in _VK_NAMES:
        return _VK_NAMES[key]
    if key.startswith("vk") and key[2:]:
        return int(key[2:], 0)
    if len(key) == 1 and key.isalnum():
        return ord(key.upper())
    raw = name.strip()
    if len(raw) == 1:
        user32.VkKeyScanW.argtypes = [wintypes.WCHAR]
        user32.VkKeyScanW.restype = ctypes.c_short
        vk = user32.VkKeyScanW(raw)
        if vk != -1:
            return vk & 0xFF
    raise ValueError(f"不认识的键名: {name!r}")


def _key_input(vk: int, up: bool) -> INPUT:
    # 同时带 VK 与扫描码：DirectInput / raw input 只认扫描码的游戏也能收到。
    scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
    flags = KEYEVENTF_KEYUP if up else 0
    if vk in _EXTENDED:
        flags |= KEYEVENTF_EXTENDEDKEY
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.u.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return inp


def press_keys(combo: str, hold_ms: int = 30, repeat: int = 1) -> None:
    """按组合键，如 `enter`、`ctrl+s`、`alt+f4`、`vk0x5A`。"""
    vks = [_vk_of(part) for part in combo.split("+") if part.strip()]
    if not vks:
        raise ValueError("空的组合键")
    with _input_lock:
        for r in range(repeat):
            for vk in vks:
                _send([_key_input(vk, up=False)])
            time.sleep(hold_ms / 1000)
            for vk in reversed(vks):
                _send([_key_input(vk, up=True)])
            if r + 1 < repeat:
                time.sleep(0.05)


def type_text(text: str, interval_ms: int = 5) -> None:
    """按 Unicode 逐字输入（不经输入法）。换行发 Enter。"""
    with _input_lock:
        for ch in text:
            if ch == "\n":
                _send([_key_input(0x0D, False), _key_input(0x0D, True)])
            else:
                for unit in _utf16_units(ch):
                    down = INPUT(type=INPUT_KEYBOARD)
                    down.u.ki = KEYBDINPUT(0, unit, KEYEVENTF_UNICODE, 0, 0)
                    up = INPUT(type=INPUT_KEYBOARD)
                    up.u.ki = KEYBDINPUT(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, 0)
                    _send([down, up])
            if interval_ms:
                time.sleep(interval_ms / 1000)


def _utf16_units(ch: str) -> list[int]:
    raw = ch.encode("utf-16-le")
    return [int.from_bytes(raw[i : i + 2], "little") for i in range(0, len(raw), 2)]


# ── 触摸注入（InjectTouchInput, PT_TOUCH）──────────────────────────────────

PT_TOUCH = 2
POINTER_FLAG_INRANGE = 0x00000002
POINTER_FLAG_INCONTACT = 0x00000004
POINTER_FLAG_DOWN = 0x00010000
POINTER_FLAG_UPDATE = 0x00020000
POINTER_FLAG_UP = 0x00040000
TOUCH_MASK_CONTACTAREA = 0x1
TOUCH_MASK_ORIENTATION = 0x2
TOUCH_MASK_PRESSURE = 0x4
TOUCH_FEEDBACK_DEFAULT = 0x1


class POINTER_INFO(ctypes.Structure):
    _fields_ = [
        ("pointerType", wintypes.DWORD),
        ("pointerId", ctypes.c_uint32),
        ("frameId", ctypes.c_uint32),
        ("pointerFlags", wintypes.DWORD),
        ("sourceDevice", wintypes.HANDLE),
        ("hwndTarget", wintypes.HWND),
        ("ptPixelLocation", wintypes.POINT),
        ("ptHimetricLocation", wintypes.POINT),
        ("ptPixelLocationRaw", wintypes.POINT),
        ("ptHimetricLocationRaw", wintypes.POINT),
        ("dwTime", wintypes.DWORD),
        ("historyCount", ctypes.c_uint32),
        ("InputData", ctypes.c_int32),
        ("dwKeyStates", wintypes.DWORD),
        ("PerformanceCount", ctypes.c_uint64),
        ("ButtonChangeType", ctypes.c_int),
    ]


class POINTER_TOUCH_INFO(ctypes.Structure):
    _fields_ = [
        ("pointerInfo", POINTER_INFO),
        ("touchFlags", ctypes.c_uint32),
        ("touchMask", ctypes.c_uint32),
        ("rcContact", wintypes.RECT),
        ("rcContactRaw", wintypes.RECT),
        ("orientation", ctypes.c_uint32),
        ("pressure", ctypes.c_uint32),
    ]


_touch_ready = False


def _ensure_touch() -> None:
    global _touch_ready
    if _touch_ready:
        return
    user32.InitializeTouchInjection.argtypes = [ctypes.c_uint32, wintypes.DWORD]
    user32.InitializeTouchInjection.restype = wintypes.BOOL
    user32.InjectTouchInput.argtypes = [
        ctypes.c_uint32,
        ctypes.POINTER(POINTER_TOUCH_INFO),
    ]
    user32.InjectTouchInput.restype = wintypes.BOOL
    if not user32.InitializeTouchInjection(1, TOUCH_FEEDBACK_DEFAULT):
        raise OSError(f"InitializeTouchInjection 失败 err={ctypes.get_last_error()}")
    _touch_ready = True


def _touch_frame(x: int, y: int, flags: int) -> None:
    info = POINTER_TOUCH_INFO()
    info.pointerInfo.pointerType = PT_TOUCH
    info.pointerInfo.pointerId = 0
    info.pointerInfo.pointerFlags = flags
    info.pointerInfo.ptPixelLocation = wintypes.POINT(x, y)
    info.touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_ORIENTATION | TOUCH_MASK_PRESSURE
    info.rcContact = wintypes.RECT(x - 2, y - 2, x + 2, y + 2)
    info.orientation = 90
    info.pressure = 32000
    if not user32.InjectTouchInput(1, ctypes.byref(info)):
        raise OSError(
            f"InjectTouchInput 失败 err={ctypes.get_last_error()}"
            "（1460=按住期间没按时发 UPDATE 帧被系统取消）"
        )


_CONTACT = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT


def touch_gesture(points: list[tuple[int, int]], duration_ms: int) -> None:
    """按下第一个点，在 duration_ms 内经过各点，最后在末点抬起。

    按住期间每 ~16 ms 发一帧 UPDATE（不发约 0.5 s 后系统取消触点，报 1460）。
    单点 + 短时长 = 点按；单点 + 长时长 = 长按；多点 = 滑动。
    """
    if not points:
        raise ValueError("至少一个点")
    with _input_lock:
        _ensure_touch()
        x0, y0 = points[0]
        _touch_frame(x0, y0, POINTER_FLAG_DOWN | _CONTACT)
        frames = max(1, duration_ms // 16)
        path = points if len(points) > 1 else points * 2
        segs = len(path) - 1
        cx, cy = x0, y0
        start = time.perf_counter()
        for f in range(1, frames + 1):
            t = f / frames
            pos = t * segs
            i = min(int(pos), segs - 1)
            local = pos - i
            (ax, ay), (bx, by) = path[i], path[i + 1]
            cx, cy = round(ax + (bx - ax) * local), round(ay + (by - ay) * local)
            target = start + f * 0.016
            delay = target - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            _touch_frame(cx, cy, POINTER_FLAG_UPDATE | _CONTACT)
        _touch_frame(cx, cy, POINTER_FLAG_UP)

"""Windows 桌面操作：Per-Monitor DPI、DXGI 截图、SendInput 鼠标键盘、InjectTouchInput 触摸、窗口枚举。

所有坐标都是**物理屏幕像素**（本进程声明 Per-Monitor-V2 DPI Aware，系统不再按缩放虚拟化坐标），
与 galdriver `accept4` / `click` 的坐标同一口径。

import 本模块即设置 DPI 感知，必须在创建任何窗口 / 截图对象之前 import。
"""

from __future__ import annotations

import ctypes
import os
import sys
import threading
import time
from ctypes import wintypes
from dataclasses import dataclass
from typing import Any, Callable

from geometry import Rect, interpolate, normalize_absolute

if sys.platform != "win32":  # pragma: no cover
    raise ImportError("desktop.py 只支持 Windows")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
dwmapi = ctypes.WinDLL("dwmapi")
shell32 = ctypes.WinDLL("shell32")

# ── DPI ─────────────────────────────────────────────────────────────────────

_DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = ctypes.c_void_p(-4)


def _enable_dpi_awareness() -> str:
    user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
    user32.SetProcessDpiAwarenessContext.restype = wintypes.BOOL
    if user32.SetProcessDpiAwarenessContext(_DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2):
        return "per_monitor_v2"
    # 已被设置过（例如 manifest）时返回 ERROR_ACCESS_DENIED；查询实际值。
    get_ctx = user32.GetThreadDpiAwarenessContext
    get_ctx.restype = ctypes.c_void_p
    get_aw = user32.GetAwarenessFromDpiAwarenessContext
    get_aw.argtypes = [ctypes.c_void_p]
    get_aw.restype = ctypes.c_int
    awareness = get_aw(get_ctx())
    return {0: "unaware", 1: "system_aware", 2: "per_monitor"}.get(awareness, f"unknown({awareness})")


DPI_AWARENESS = _enable_dpi_awareness()

# ── 结构体 ───────────────────────────────────────────────────────────────────

ULONG_PTR = ctypes.c_size_t


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
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


class POINTER_INFO(ctypes.Structure):
    _fields_ = [
        ("pointerType", ctypes.c_uint32),
        ("pointerId", ctypes.c_uint32),
        ("frameId", ctypes.c_uint32),
        ("pointerFlags", ctypes.c_uint32),
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


class MONITORINFOEXW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("rcMonitor", wintypes.RECT),
        ("rcWork", wintypes.RECT),
        ("dwFlags", wintypes.DWORD),
        ("szDevice", wintypes.WCHAR * 32),
    ]


INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x1000
MOUSEEVENTF_VIRTUALDESK = 0x4000
MOUSEEVENTF_ABSOLUTE = 0x8000
_BUTTON_FLAGS: dict[str, tuple[int, int]] = {
    "left": (0x0002, 0x0004),
    "right": (0x0008, 0x0010),
    "middle": (0x0020, 0x0040),
}
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008

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

user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT
user32.InitializeTouchInjection.argtypes = [ctypes.c_uint32, wintypes.DWORD]
user32.InitializeTouchInjection.restype = wintypes.BOOL
user32.InjectTouchInput.argtypes = [ctypes.c_uint32, ctypes.POINTER(POINTER_TOUCH_INFO)]
user32.InjectTouchInput.restype = wintypes.BOOL
user32.GetCursorPos.argtypes = [ctypes.POINTER(wintypes.POINT)]
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.GetForegroundWindow.restype = wintypes.HWND
user32.WindowFromPoint.argtypes = [wintypes.POINT]
user32.WindowFromPoint.restype = wintypes.HWND
user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetAncestor.restype = wintypes.HWND
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetMonitorInfoW.argtypes = [wintypes.HMONITOR, ctypes.POINTER(MONITORINFOEXW)]
user32.VkKeyScanW.argtypes = [wintypes.WCHAR]
user32.VkKeyScanW.restype = ctypes.c_short
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.MapVirtualKeyW.restype = wintypes.UINT
user32.GetSystemMetrics.argtypes = [ctypes.c_int]
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsIconic.argtypes = [wintypes.HWND]
user32.IsWindow.argtypes = [wintypes.HWND]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.BringWindowToTop.argtypes = [wintypes.HWND]
user32.GetDpiForWindow.argtypes = [wintypes.HWND]
user32.GetDpiForWindow.restype = wintypes.UINT
dwmapi.DwmGetWindowAttribute.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
advapi32.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
shell32.IsUserAnAdmin.restype = wintypes.BOOL


def _check_sent(sent: int, expected: int, what: str) -> None:
    if sent != expected:
        err = ctypes.get_last_error()
        hint = "（目标窗口以管理员身份运行而本服务不是时，UIPI 会拦截注入）" if err == 5 else ""
        raise OSError(f"{what}: SendInput 只送出 {sent}/{expected}，GetLastError={err}{hint}")


def _send(inputs: list[INPUT], what: str) -> None:
    arr = (INPUT * len(inputs))(*inputs)
    _check_sent(user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT)), len(inputs), what)


# ── 屏幕几何 ─────────────────────────────────────────────────────────────────


def virtual_screen() -> Rect:
    return Rect(
        user32.GetSystemMetrics(76),
        user32.GetSystemMetrics(77),
        user32.GetSystemMetrics(78),
        user32.GetSystemMetrics(79),
    )


@dataclass(frozen=True)
class Monitor:
    index: int
    device: str
    rect: Rect
    primary: bool


def monitors() -> list[Monitor]:
    result: list[Monitor] = []
    proc_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

    def _cb(hmon: int, _hdc: int, _rect: Any, _lp: int) -> bool:
        info = MONITORINFOEXW()
        info.cbSize = ctypes.sizeof(MONITORINFOEXW)
        if user32.GetMonitorInfoW(hmon, ctypes.byref(info)):
            r = info.rcMonitor
            result.append(
                Monitor(len(result), info.szDevice, Rect(r.left, r.top, r.right - r.left, r.bottom - r.top), bool(info.dwFlags & 1))
            )
        return True

    user32.EnumDisplayMonitors(None, None, proc_type(_cb), 0)
    return result


def cursor_position() -> tuple[int, int]:
    pt = wintypes.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    return pt.x, pt.y


def is_admin() -> bool:
    return bool(shell32.IsUserAnAdmin())


def digitizer_flags() -> int:
    return user32.GetSystemMetrics(94)  # SM_DIGITIZER


# ── 截图 ─────────────────────────────────────────────────────────────────────


class Capturer:
    """DXGI 桌面复制（dxcam）为主：独占全屏的老游戏用 BitBlt 截出来是黑的，DXGI 能截到。

    显示模式变化（游戏独占全屏改分辨率）时输出尺寸会变，按显示器矩形签名重建；
    DXGI 不可用（远程桌面会话、驱动问题）时退到 mss（GDI BitBlt）。
    """

    def __init__(self, backend: str = "dxgi") -> None:
        self._backend = backend
        self._lock = threading.Lock()
        self._cameras: list[tuple[Rect, Any]] = []
        self._signature: tuple[Rect, ...] = ()
        self._mss: Any = None
        self.last_backend = ""
        self.last_error = ""

    def _monitor_signature(self) -> tuple[Rect, ...]:
        return tuple(sorted((m.rect for m in monitors()), key=lambda r: (r.left, r.top)))

    def _release_cameras(self) -> None:
        for _, cam in self._cameras:
            try:
                cam.release()
            except Exception:
                pass
        self._cameras = []

    def _build_cameras(self) -> None:
        import dxcam  # 延迟导入：mss-only 时不需要

        self._release_cameras()
        for device_idx in range(4):
            found_on_device = False
            for output_idx in range(8):
                try:
                    cam = dxcam.create(
                        device_idx=device_idx,
                        output_idx=output_idx,
                        output_color="RGB",
                        processor_backend="numpy",
                    )
                except IndexError:
                    break
                except Exception as exc:  # 该输出未接桌面等
                    self.last_error = f"dxcam.create({device_idx},{output_idx}): {exc}"
                    continue
                found_on_device = True
                dc = cam._output.desc.DesktopCoordinates  # dxcam 未公开桌面坐标的 API
                self._cameras.append((Rect(dc.left, dc.top, dc.right - dc.left, dc.bottom - dc.top), cam))
            if not found_on_device and device_idx > 0:
                break

    def _grab_dxgi(self, region: Rect) -> Any:
        from PIL import Image

        signature = self._monitor_signature()
        if signature != self._signature or not self._cameras:
            self._build_cameras()
            self._signature = signature
        if not self._cameras:
            raise RuntimeError(f"没有可用的 DXGI 输出 {self.last_error}")
        canvas = Image.new("RGB", (region.width, region.height))
        covered = False
        for out_rect, cam in self._cameras:
            part = out_rect.intersect(region)
            if part is None:
                continue
            local = (part.left - out_rect.left, part.top - out_rect.top, part.right - out_rect.left, part.bottom - out_rect.top)
            frame = cam.grab(region=local, new_frame_only=False)
            deadline = time.monotonic() + 0.5
            while frame is None and time.monotonic() < deadline:
                time.sleep(0.016)
                frame = cam.grab(region=local, new_frame_only=True)
            if frame is None:
                raise RuntimeError(f"DXGI 输出 {out_rect} 0.5s 内没有帧")
            canvas.paste(Image.fromarray(frame), (part.left - region.left, part.top - region.top))
            covered = True
        if not covered:
            raise ValueError(f"区域 {region} 不在任何显示器上")
        return canvas

    def _grab_mss(self, region: Rect) -> Any:
        import mss
        from PIL import Image

        if self._mss is None:
            self._mss = mss.mss()
        shot = self._mss.grab({"left": region.left, "top": region.top, "width": region.width, "height": region.height})
        return Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

    def grab(self, region: Rect) -> Any:
        """截取物理区域，返回 PIL RGB 图。"""
        with self._lock:
            if self._backend == "dxgi":
                try:
                    img = self._grab_dxgi(region)
                    self.last_backend = "dxgi"
                    return img
                except ValueError:
                    raise
                except Exception as exc:
                    # 访问丢失（模式切换 / UAC 安全桌面）后下次重建
                    self.last_error = f"{type(exc).__name__}: {exc}"
                    self._release_cameras()
                    self._signature = ()
            img = self._grab_mss(region)
            self.last_backend = "gdi" + (f"（DXGI 失败：{self.last_error}）" if self._backend == "dxgi" else "")
            return img


# ── 鼠标 ─────────────────────────────────────────────────────────────────────


def _mouse_input(flags: int, dx: int = 0, dy: int = 0, data: int = 0) -> INPUT:
    inp = INPUT(type=INPUT_MOUSE)
    inp.mi = MOUSEINPUT(dx, dy, ctypes.c_uint32(data).value, flags, 0, 0)
    return inp


def move_mouse(x: int, y: int) -> None:
    """移到物理坐标 (x, y)：发一次绝对移动（游戏走 raw input / 消息时能看到 WM_MOUSEMOVE），
    再 SetCursorPos 精确落点（65535 归一化有 ±1px 舍入）。"""
    nx, ny = normalize_absolute(x, y, virtual_screen())
    _send([_mouse_input(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny)], "move")
    user32.SetCursorPos(x, y)


def mouse_button(button: str, down: bool) -> None:
    flags = _BUTTON_FLAGS[button][0 if down else 1]
    _send([_mouse_input(flags)], f"{button} {'down' if down else 'up'}")


def click(x: int, y: int, button: str = "left", count: int = 1, hold_ms: int = 30, interval_ms: int = 80) -> None:
    move_mouse(x, y)
    time.sleep(0.03)
    for i in range(count):
        mouse_button(button, True)
        time.sleep(hold_ms / 1000)
        mouse_button(button, False)
        if i + 1 < count:
            time.sleep(interval_ms / 1000)


def drag(start: tuple[int, int], end: tuple[int, int], button: str = "left", duration_ms: int = 400) -> None:
    move_mouse(*start)
    time.sleep(0.03)
    mouse_button(button, True)
    steps = max(2, duration_ms // 16)
    try:
        for pt in interpolate(start, end, steps)[1:]:
            time.sleep(duration_ms / 1000 / steps)
            move_mouse(*pt)
        time.sleep(0.03)
    finally:
        mouse_button(button, False)


def scroll(x: int, y: int, notches_y: int = 0, notches_x: int = 0) -> None:
    """notches_y > 0 向上滚，notches_x > 0 向右滚；每格 WHEEL_DELTA=120。"""
    move_mouse(x, y)
    time.sleep(0.03)
    for _ in range(abs(notches_y)):
        _send([_mouse_input(MOUSEEVENTF_WHEEL, data=120 if notches_y > 0 else -120)], "wheel")
        time.sleep(0.03)
    for _ in range(abs(notches_x)):
        _send([_mouse_input(MOUSEEVENTF_HWHEEL, data=120 if notches_x > 0 else -120)], "hwheel")
        time.sleep(0.03)


# ── 键盘 ─────────────────────────────────────────────────────────────────────

_EXTENDED_VKS = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90, 0xA3, 0xA5}

KEY_NAMES: dict[str, int] = {
    "ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "menu": 0x12,
    "win": 0x5B, "lwin": 0x5B, "rwin": 0x5C, "apps": 0x5D,
    "lctrl": 0xA2, "rctrl": 0xA3, "lshift": 0xA0, "rshift": 0xA1, "lalt": 0xA4, "ralt": 0xA5,
    "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B, "tab": 0x09, "space": 0x20,
    "backspace": 0x08, "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "ins": 0x2D,
    "home": 0x24, "end": 0x23, "pageup": 0x21, "pgup": 0x21, "pagedown": 0x22, "pgdn": 0x22,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "printscreen": 0x2C, "pause": 0x13, "capslock": 0x14, "numlock": 0x90, "scrolllock": 0x91,
}
KEY_NAMES.update({f"f{i}": 0x6F + i for i in range(1, 25)})
KEY_NAMES.update({f"num{i}": 0x60 + i for i in range(10)})


def parse_key(name: str) -> int:
    key = name.strip().lower()
    if key in KEY_NAMES:
        return KEY_NAMES[key]
    if key.startswith("vk:") or key.startswith("0x"):
        return int(key.split(":", 1)[-1], 0)
    if key.isdigit() and len(key) > 1:
        return int(key)
    if len(name.strip()) == 1:
        ch = name.strip()
        if ch.isalnum() and ch.isascii():
            return ord(ch.upper())
        vk = user32.VkKeyScanW(ch)
        if vk != -1:
            return vk & 0xFF
    raise ValueError(f"未知按键名 {name!r}（可用名字、单个字符、vk:0x41）")


def _key_input(vk: int, up: bool, scancode: bool) -> INPUT:
    scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
    flags = KEYEVENTF_KEYUP if up else 0
    if vk in _EXTENDED_VKS:
        flags |= KEYEVENTF_EXTENDEDKEY
    if scancode:
        # DirectInput 游戏只看扫描码
        flags |= KEYEVENTF_SCANCODE
        vk = 0
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return inp


def key_combo(combo: str, hold_ms: int = 50, scancode: bool = False) -> None:
    """按下并释放组合键，例如 "ctrl+shift+esc"、"enter"、"alt+f4"。"""
    vks = [parse_key(part) for part in combo.split("+") if part.strip()]
    if not vks:
        raise ValueError("空按键")
    pressed: list[int] = []
    try:
        for vk in vks:
            _send([_key_input(vk, False, scancode)], f"key down {vk:#x}")
            pressed.append(vk)
            time.sleep(0.01)
        time.sleep(hold_ms / 1000)
    finally:
        for vk in reversed(pressed):
            _send([_key_input(vk, True, scancode)], f"key up {vk:#x}")
            time.sleep(0.01)


def type_text(text: str, interval_ms: int = 5) -> None:
    """按 UTF-16 码元逐字发 KEYEVENTF_UNICODE（中文 / 日文直接上屏，不经输入法）；换行发 Enter。"""
    for ch in text:
        if ch == "\n":
            key_combo("enter", hold_ms=10)
            continue
        if ch == "\r":
            continue
        data = ch.encode("utf-16-le")
        for i in range(0, len(data), 2):
            unit = int.from_bytes(data[i : i + 2], "little")
            down = INPUT(type=INPUT_KEYBOARD)
            down.ki = KEYBDINPUT(0, unit, KEYEVENTF_UNICODE, 0, 0)
            up = INPUT(type=INPUT_KEYBOARD)
            up.ki = KEYBDINPUT(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, 0)
            _send([down, up], f"type {ch!r}")
        if interval_ms:
            time.sleep(interval_ms / 1000)


# ── 触摸 ─────────────────────────────────────────────────────────────────────

_touch_ready = False
_TOUCH_FRAME_S = 0.016  # 按住期间约每 16ms 一帧 UPDATE，否则约 0.5s 后注入超时（1460），触点被系统取消


def _ensure_touch() -> None:
    global _touch_ready
    if _touch_ready:
        return
    if not user32.InitializeTouchInjection(10, TOUCH_FEEDBACK_DEFAULT):
        raise OSError(f"InitializeTouchInjection 失败 GetLastError={ctypes.get_last_error()}")
    _touch_ready = True


def _touch_frame(x: int, y: int, flags: int, pointer_id: int = 0) -> None:
    info = POINTER_TOUCH_INFO()
    info.pointerInfo.pointerType = PT_TOUCH
    info.pointerInfo.pointerId = pointer_id
    info.pointerInfo.ptPixelLocation = wintypes.POINT(x, y)
    info.pointerInfo.pointerFlags = flags
    info.touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_ORIENTATION | TOUCH_MASK_PRESSURE
    info.rcContact = wintypes.RECT(x - 2, y - 2, x + 2, y + 2)
    info.orientation = 90
    info.pressure = 32000
    if not user32.InjectTouchInput(1, ctypes.byref(info)):
        err = ctypes.get_last_error()
        hint = "（UIPI：目标以管理员身份运行）" if err == 5 else ""
        raise OSError(f"InjectTouchInput({x},{y},flags={flags:#x}) 失败 GetLastError={err}{hint}")


def touch_path(points: list[tuple[int, int]], duration_ms: int) -> None:
    """一根手指：在 points[0] 按下，duration_ms 内沿折线经过其余点，在最后一点抬起。"""
    _ensure_touch()
    if not points:
        raise ValueError("触摸路径为空")
    frames = max(1, int(duration_ms / 1000 / _TOUCH_FRAME_S))
    if len(points) == 1:
        path = [points[0]] * (frames + 1)
    else:
        segs = len(points) - 1
        per = max(1, frames // segs)
        path = [points[0]]
        for a, b in zip(points, points[1:]):
            path.extend(interpolate(a, b, per)[1:])
    contact = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT
    _touch_frame(*path[0], contact | POINTER_FLAG_DOWN)
    last = path[0]
    try:
        for pt in path[1:]:
            time.sleep(_TOUCH_FRAME_S)
            _touch_frame(*pt, contact | POINTER_FLAG_UPDATE)
            last = pt
    finally:
        _touch_frame(*last, POINTER_FLAG_UP)


# ── 窗口 ─────────────────────────────────────────────────────────────────────


def _window_text(hwnd: int) -> str:
    n = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def _class_name(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def _process_info(pid: int) -> tuple[str, str]:
    """(exe 路径, 是否提权：yes / no / denied)。打不开令牌通常说明对方提权而本服务没有。"""
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return "", "denied"
    try:
        size = wintypes.DWORD(1024)
        buf = ctypes.create_unicode_buffer(1024)
        exe = buf.value if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)) else ""
        token = wintypes.HANDLE()
        if not advapi32.OpenProcessToken(handle, 0x0008, ctypes.byref(token)):  # TOKEN_QUERY
            return exe, "denied"
        try:
            elevated = wintypes.DWORD()
            ret = wintypes.DWORD()
            ok = advapi32.GetTokenInformation(token, 20, ctypes.byref(elevated), 4, ctypes.byref(ret))  # TokenElevation
            return exe, ("yes" if elevated.value else "no") if ok else "denied"
        finally:
            kernel32.CloseHandle(token)
    finally:
        kernel32.CloseHandle(handle)


def window_rect(hwnd: int) -> Rect:
    """可见边框（DWM 扩展边框，不含不可见的缩放阴影边）。"""
    r = wintypes.RECT()
    if dwmapi.DwmGetWindowAttribute(hwnd, 9, ctypes.byref(r), ctypes.sizeof(r)) != 0:  # DWMWA_EXTENDED_FRAME_BOUNDS
        user32.GetWindowRect(hwnd, ctypes.byref(r))
    return Rect(r.left, r.top, r.right - r.left, r.bottom - r.top)


def client_rect(hwnd: int) -> Rect:
    r = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(r))
    origin = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    return Rect(origin.x, origin.y, r.right - r.left, r.bottom - r.top)


def describe_window(hwnd: int) -> dict[str, Any]:
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    exe, elevated = _process_info(pid.value)
    wr = window_rect(hwnd)
    cr = client_rect(hwnd)
    return {
        "hwnd": hwnd,
        "title": _window_text(hwnd),
        "class": _class_name(hwnd),
        "pid": pid.value,
        "exe": os.path.basename(exe) if exe else "",
        "elevated": elevated,
        "minimized": bool(user32.IsIconic(hwnd)),
        "window": [wr.left, wr.top, wr.width, wr.height],
        "client": [cr.left, cr.top, cr.width, cr.height],
        "dpi": user32.GetDpiForWindow(hwnd),
    }


def list_windows(include_untitled: bool = False) -> list[dict[str, Any]]:
    hwnds: list[int] = []
    proc_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def _cb(hwnd: int, _lp: int) -> bool:
        if user32.IsWindowVisible(hwnd) and (include_untitled or user32.GetWindowTextLengthW(hwnd) > 0):
            hwnds.append(hwnd)
        return True

    user32.EnumWindows(proc_type(_cb), 0)  # Z 序，前台在前
    return [describe_window(h) for h in hwnds]


def foreground_window() -> int:
    return user32.GetForegroundWindow() or 0


def window_at(x: int, y: int) -> int:
    hwnd = user32.WindowFromPoint(wintypes.POINT(x, y))
    return user32.GetAncestor(hwnd, 2) if hwnd else 0  # GA_ROOT


def focus_window(hwnd: int) -> bool:
    if not user32.IsWindow(hwnd):
        raise ValueError(f"hwnd {hwnd} 不存在")
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    # 前台锁：只有「最近收到输入」的进程能抢前台；先发一次 Alt 让本进程获得该资格（系统限制，非症状掩盖）。
    key_combo("alt", hold_ms=1)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.1)
    return foreground_window() == hwnd


# ── 串行执行器 ───────────────────────────────────────────────────────────────


class DesktopThread:
    """所有桌面输入 / 截图在同一条线程上串行执行：输入不会交错，触摸注入状态也只初始化一次。"""

    def __init__(self) -> None:
        from concurrent.futures import ThreadPoolExecutor

        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="desktop")

    async def run(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
        import asyncio

        return await asyncio.wrap_future(self._pool.submit(fn, *args, **kwargs))

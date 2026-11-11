"""被控端 agent：主动连上网关，执行截图 / 输入 / 命令 / 文件 / galdriver 请求。

必须由登录用户在**桌面会话**里启动（志愿者双击「双击开始适配.exe」）：
服务会话里 SendInput、截图、拉起的窗口都到不了用户看到的桌面。

    双击开始适配.exe                      读同目录 agent.json（打包时已写好地址和 token）
    python fleet_agent.py --config x.json

窗口里逐条打印收到的操作，志愿者随时能看到在做什么；关掉窗口即断开。
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import ctypes
import getpass
import json
import os
import platform
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

import websockets
from websockets.asyncio.client import connect

import fleet_protocol as proto
from galdriver_host import GalDriverHost

AGENT_VERSION = "1.0.1"
OUTPUT_LIMIT = 60_000


def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def default_machine_name() -> str:
    """没在 agent.json 里写 name 时用电脑名；只留网关认可的字符（字母数字、_、-）。"""
    raw = os.environ.get("COMPUTERNAME") or socket.gethostname()
    name = re.sub(r"[^\w-]", "-", raw).strip("-")[:64]
    return name or "pc"


@dataclass
class AgentConfig:
    gateway: str
    token: str
    name: str
    workdir: Path
    galdriver_exe: Optional[Path]
    galdriver_args: list[str]
    seed_support_dir: Optional[str]
    seed_documents_dir: Optional[str]
    # 网关自签证书（PEM），打包时写入；连接时只信任这一张。
    gateway_cert: Optional[str] = None

    @staticmethod
    def load(path: Path) -> "AgentConfig":
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
        base = path.resolve().parent
        workdir = Path(os.path.expandvars(raw.get("workdir") or str(base / "work")))
        exe_raw = raw.get("galdriver_exe", str(base / "driver" / "fushi.exe"))
        exe = Path(os.path.expandvars(exe_raw)) if exe_raw else None
        if exe is not None and not exe.is_absolute():
            exe = base / exe
        for key in ("gateway", "token", "gateway_cert"):
            if not raw.get(key):
                raise SystemExit(f"agent.json 缺 {key}（请重新解压完整的压缩包）")
        return AgentConfig(
            gateway=raw["gateway"],
            token=raw["token"],
            name=raw.get("name") or default_machine_name(),
            workdir=workdir,
            galdriver_exe=exe,
            galdriver_args=list(raw.get("galdriver_args") or []),
            seed_support_dir=raw.get("seed_support_dir"),
            seed_documents_dir=raw.get("seed_documents_dir"),
            gateway_cert=raw["gateway_cert"],
        )


# 控制台输出只由这个后台线程写：志愿者在窗口里点一下（快速编辑选择态）、按 Ctrl+S 或
# 拖滚动条都会让 WriteConsole 阻塞；若在事件循环线程里同步 print，整个 asyncio 循环随之
# 卡死、心跳超时被网关判掉线。队列有界，满了丢最旧之外的新行，绝不反压网络。
_LOG_QUEUE: "queue.Queue[str]" = queue.Queue(maxsize=2000)
_log_dropped = 0


def _log_writer() -> None:
    global _log_dropped
    while True:
        line = _LOG_QUEUE.get()
        dropped, _log_dropped = _log_dropped, 0
        try:
            if dropped:
                print(f"…（控制台繁忙，省略 {dropped} 行）", flush=True)
            print(line, flush=True)
        except Exception:  # noqa: BLE001 - 控制台已关 / 被重定向坏掉时日志丢弃即可
            pass


threading.Thread(target=_log_writer, name="console-log", daemon=True).start()


def log(message: str) -> None:
    global _log_dropped
    try:
        _LOG_QUEUE.put_nowait(f"[{time.strftime('%H:%M:%S')}] {message}")
    except queue.Full:
        _log_dropped += 1


def disable_console_quick_edit() -> bool:
    """关掉控制台「快速编辑模式」：否则鼠标一点窗口就进入选择态，进程写控制台被挂起。"""
    if sys.platform != "win32":
        return False
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.GetStdHandle(-10)  # STD_INPUT_HANDLE
    mode = ctypes.c_uint32()
    if not handle or handle == -1 or not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
        return False  # 没有控制台（被重定向 / 无窗口）
    enable_quick_edit, enable_extended_flags = 0x0040, 0x0080
    new_mode = (mode.value & ~enable_quick_edit) | enable_extended_flags
    return bool(kernel32.SetConsoleMode(handle, new_mode))


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (AttributeError, OSError):
        return False


class Agent:
    def __init__(self, config: AgentConfig, desktop: Any) -> None:
        self.config = config
        # desktop 是 win_desktop 模块；测试里换成假实现。
        self.desktop = desktop
        self.dpi_mode = desktop.enable_dpi_awareness()
        config.workdir.mkdir(parents=True, exist_ok=True)
        self.galdriver = GalDriverHost(
            exe=config.galdriver_exe,
            workdir=config.workdir,
            exe_args=config.galdriver_args,
        )
        self.last_capture: Any = None
        self._send_lock = asyncio.Lock()
        self._handlers: dict[str, Callable[[dict[str, Any]], Any]] = {
            "info": self.op_info,
            "screenshot": self.op_screenshot,
            "click": self.op_click,
            "move": self.op_move,
            "drag": self.op_drag,
            "scroll": self.op_scroll,
            "key": self.op_key,
            "type": self.op_type,
            "touch": self.op_touch,
            "powershell": self.op_powershell,
            "file_write": self.op_file_write,
            "file_read": self.op_file_read,
            "list_dir": self.op_list_dir,
            "galdriver_start": self.op_galdriver_start,
            "galdriver": self.op_galdriver,
            "galdriver_stop": self.op_galdriver_stop,
            "galdriver_status": self.op_galdriver_status,
            "self_update": self.op_self_update,
        }

    # ── 信息 ────────────────────────────────────────────────────────────────

    def op_info(self, _: dict[str, Any]) -> dict[str, Any]:
        return {
            "agent_version": AGENT_VERSION,
            "protocol": proto.PROTOCOL_VERSION,
            "hostname": socket.gethostname(),
            "user": getpass.getuser(),
            "os": platform.platform(),
            "is_admin": is_admin(),
            "dpi_awareness": self.dpi_mode,
            "virtual_screen": list(self.desktop.virtual_screen()),
            "monitors": self.desktop.monitors(),
            "touch": self.desktop.touch_capabilities(),
            "foreground": self.desktop.foreground_window(),
            "workdir": str(self.config.workdir),
            "galdriver": {
                "exe": str(self.config.galdriver_exe),
                "exists": bool(
                    self.config.galdriver_exe and self.config.galdriver_exe.exists()
                ),
                "running": self.galdriver.running(),
            },
        }

    # ── 坐标 ────────────────────────────────────────────────────────────────

    def _point(self, args: dict[str, Any], xk: str = "x", yk: str = "y") -> tuple[int, int]:
        x, y = args[xk], args[yk]
        space = args.get("coords", "screenshot")
        if space == "physical":
            return round(x), round(y)
        if space != "screenshot":
            raise ValueError("coords 只能是 screenshot 或 physical")
        if self.last_capture is None:
            raise ValueError("还没有截图，无法换算截图坐标；先 screenshot 或用 coords=physical")
        return self.last_capture.to_physical(x, y)

    def _after(self, args: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
        """动作后可选地等一会儿再截图，省一轮往返。"""
        if args.get("screenshot_after"):
            time.sleep(max(0, int(args.get("settle_ms", 400))) / 1000)
            result["screenshot"] = self._capture(
                {"monitor": args.get("monitor", None), "max_width": args.get("max_width", 1280)}
            )
        return result

    # ── 截图 ────────────────────────────────────────────────────────────────

    def _capture(self, args: dict[str, Any]) -> dict[str, Any]:
        region = args.get("region")
        monitor = args.get("monitor")
        if monitor is None:
            # 沿用上一次的显示器，保证动作后截图与之前的坐标系一致。
            monitor = getattr(self, "_last_monitor", 1)
        cap = self.desktop.capture_screen(
            monitor=int(monitor),
            max_width=int(args.get("max_width", 1280)),
            image_format=args.get("format", "jpeg"),
            quality=int(args.get("quality", 70)),
            region=tuple(region) if region else None,
        )
        self.last_capture = cap
        self._last_monitor = int(monitor)
        return {
            "image_b64": proto.b64e(cap.data),
            "mime": cap.mime,
            "width": cap.width,
            "height": cap.height,
            "scale": cap.scale,
            "origin": [cap.origin_x, cap.origin_y],
            "physical_size": [cap.physical_width, cap.physical_height],
            "nearly_black": cap.nearly_black,
            "foreground": self.desktop.foreground_window(),
        }

    def op_screenshot(self, args: dict[str, Any]) -> dict[str, Any]:
        return self._capture(args)

    # ── 输入 ────────────────────────────────────────────────────────────────

    def op_click(self, args: dict[str, Any]) -> dict[str, Any]:
        x, y = self._point(args)
        self.desktop.mouse_click(
            x,
            y,
            button=args.get("button", "left"),
            count=int(args.get("count", 1)),
            modifiers=args.get("modifiers") or None,
            hold_ms=int(args.get("hold_ms", 0)),
        )
        return self._after(args, {"physical": [x, y], "foreground": self.desktop.foreground_window()})

    def op_move(self, args: dict[str, Any]) -> dict[str, Any]:
        x, y = self._point(args)
        self.desktop.mouse_move(x, y)
        return self._after(args, {"physical": [x, y]})

    def op_drag(self, args: dict[str, Any]) -> dict[str, Any]:
        x1, y1 = self._point(args, "x", "y")
        x2, y2 = self._point(args, "x2", "y2")
        self.desktop.mouse_drag(
            x1, y1, x2, y2,
            button=args.get("button", "left"),
            duration_ms=int(args.get("duration_ms", 400)),
        )
        return self._after(args, {"from": [x1, y1], "to": [x2, y2]})

    def op_scroll(self, args: dict[str, Any]) -> dict[str, Any]:
        x, y = self._point(args)
        self.desktop.mouse_scroll(x, y, dy=int(args.get("dy", 0)), dx=int(args.get("dx", 0)))
        return self._after(args, {"physical": [x, y]})

    def op_key(self, args: dict[str, Any]) -> dict[str, Any]:
        self.desktop.press_keys(
            args["keys"],
            hold_ms=int(args.get("hold_ms", 30)),
            repeat=int(args.get("repeat", 1)),
        )
        return self._after(args, {"keys": args["keys"], "foreground": self.desktop.foreground_window()})

    def op_type(self, args: dict[str, Any]) -> dict[str, Any]:
        self.desktop.type_text(args["text"])
        return self._after(args, {"typed_chars": len(args["text"])})

    def op_touch(self, args: dict[str, Any]) -> dict[str, Any]:
        action = args.get("action", "tap")
        start = self._point(args)
        if action == "tap":
            points, duration = [start], int(args.get("duration_ms", 60))
        elif action == "hold":
            points, duration = [start], int(args.get("duration_ms", 1000))
        elif action == "swipe":
            points, duration = [start, self._point(args, "x2", "y2")], int(args.get("duration_ms", 300))
        else:
            raise ValueError("touch action 只能是 tap / hold / swipe")
        self.desktop.touch_gesture(points, duration)
        return self._after(
            args,
            {"action": action, "points": [list(p) for p in points], "foreground": self.desktop.foreground_window()},
        )

    # ── 命令 ────────────────────────────────────────────────────────────────

    def op_powershell(self, args: dict[str, Any]) -> dict[str, Any]:
        script = (
            "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
            "$OutputEncoding=[Text.Encoding]::UTF8;"
            "$ProgressPreference='SilentlyContinue';\n" + args["command"]
        )
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        timeout = float(args.get("timeout_s", 120))
        cwd = args.get("cwd") or str(self.config.workdir)
        started = time.monotonic()
        try:
            proc = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-EncodedCommand", encoded],
                cwd=cwd,
                capture_output=True,
                timeout=timeout,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except subprocess.TimeoutExpired as exc:
            return {
                "exit_code": None,
                "timed_out": True,
                "stdout": _clip(exc.stdout),
                "stderr": _clip(exc.stderr),
                "elapsed_s": round(time.monotonic() - started, 2),
            }
        return {
            "exit_code": proc.returncode,
            "timed_out": False,
            "stdout": _clip(proc.stdout),
            "stderr": _clip(proc.stderr),
            "elapsed_s": round(time.monotonic() - started, 2),
        }

    # ── 文件 ────────────────────────────────────────────────────────────────

    def op_file_write(self, args: dict[str, Any]) -> dict[str, Any]:
        path = Path(os.path.expandvars(args["path"]))
        path.parent.mkdir(parents=True, exist_ok=True)
        part = path.with_name(path.name + ".part")
        data = proto.b64d(args["data_b64"])
        mode = "wb" if int(args.get("offset", 0)) == 0 else "r+b"
        with part.open(mode) as fh:
            fh.seek(int(args.get("offset", 0)))
            fh.write(data)
        if args.get("final"):
            os.replace(part, path)
            return {"path": str(path), "size": path.stat().st_size}
        return {"written": len(data)}

    def op_file_read(self, args: dict[str, Any]) -> dict[str, Any]:
        path = Path(os.path.expandvars(args["path"]))
        offset = int(args.get("offset", 0))
        length = min(int(args.get("length", proto.FILE_CHUNK)), proto.FILE_CHUNK)
        size = path.stat().st_size
        with path.open("rb") as fh:
            fh.seek(offset)
            data = fh.read(length)
        return {
            "data_b64": proto.b64e(data),
            "size": size,
            "eof": offset + len(data) >= size,
        }

    def op_list_dir(self, args: dict[str, Any]) -> dict[str, Any]:
        path = Path(os.path.expandvars(args["path"]))
        entries = []
        for child in sorted(path.iterdir())[: int(args.get("limit", 500))]:
            st = child.stat()
            entries.append(
                {"name": child.name, "dir": child.is_dir(), "size": st.st_size, "mtime": int(st.st_mtime)}
            )
        return {"path": str(path), "entries": entries}

    # ── galdriver ───────────────────────────────────────────────────────────

    def op_galdriver_start(self, args: dict[str, Any]) -> dict[str, Any]:
        seed_s = args.get("seed_support_dir")
        seed_d = args.get("seed_documents_dir")
        if args.get("seed_from_config"):
            seed_s = seed_s or self.config.seed_support_dir
            seed_d = seed_d or self.config.seed_documents_dir
        return self.galdriver.start(
            seed_support_dir=seed_s,
            seed_documents_dir=seed_d,
            reset_test_root=bool(args.get("reset_test_root", False)),
            hidden=bool(args.get("hidden", True)),
            extra_env=args.get("env") or None,
            ready_timeout_s=float(args.get("ready_timeout_s", 180)),
        )

    def op_galdriver(self, args: dict[str, Any]) -> dict[str, Any]:
        return self.galdriver.command(args["command"], timeout_s=float(args.get("timeout_s", 300)))

    def op_galdriver_stop(self, _: dict[str, Any]) -> dict[str, Any]:
        return self.galdriver.stop()

    def op_galdriver_status(self, _: dict[str, Any]) -> dict[str, Any]:
        return self.galdriver.status()

    # ── 自更新 ──────────────────────────────────────────────────────────────

    def op_self_update(self, args: dict[str, Any]) -> dict[str, Any]:
        """用已推送到本机的新 exe 替换自己并重启（只对打包后的 exe 有效）。"""
        if not getattr(sys, "frozen", False):
            raise RuntimeError("脚本模式下不自更新；直接改源码后重启 agent")
        new_exe = Path(os.path.expandvars(args["new_exe"]))
        if not new_exe.is_file():
            raise FileNotFoundError(new_exe)
        cur = Path(sys.executable).resolve()
        script = self.config.workdir / "self_update.cmd"
        script.write_text(
            "@echo off\r\n"
            f":wait\r\ntasklist /FI \"PID eq {os.getpid()}\" | find \"{os.getpid()}\" >nul "
            "&& (timeout /t 1 /nobreak >nul & goto wait)\r\n"
            f"move /Y \"{new_exe}\" \"{cur}\"\r\n"
            f"start \"\" \"{cur}\"\r\n",
            encoding="ascii",
        )
        subprocess.Popen(
            ["cmd", "/c", str(script)],
            creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
            close_fds=True,
        )
        # 处理函数跑在工作线程里：先让应答发出去，再退出进程。
        threading.Timer(1.5, lambda: os._exit(0)).start()
        return {"restarting": True, "from": str(new_exe), "to": str(cur)}

    # ── 连接循环 ────────────────────────────────────────────────────────────

    async def _handle(self, ws: Any, msg: dict[str, Any]) -> None:
        rid = msg.get("id")
        op = msg.get("op", "")
        args = msg.get("args") or {}
        handler = self._handlers.get(op)
        shown = {k: v for k, v in args.items() if k not in ("data_b64", "command")}
        if "command" in args:
            shown["command"] = str(args["command"])[:120]
        log(f"← {op} {json.dumps(shown, ensure_ascii=False)[:200]}")
        if handler is None:
            reply = {"type": "res", "id": rid, "ok": False, "error": f"未知操作 {op}"}
        else:
            try:
                result = await asyncio.to_thread(handler, args)
                reply = {"type": "res", "id": rid, "ok": True, "result": result}
            except Exception as exc:  # 把错误原样回给调用方，不吞
                log(f"  ✗ {op}: {exc}")
                reply = {
                    "type": "res",
                    "id": rid,
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "trace": traceback.format_exc()[-2000:],
                }
        async with self._send_lock:
            await ws.send(proto.encode(reply))

    async def run_once(self) -> None:
        # 只走 wss + 固定证书：明文 ws 会泄露 token，且无法确认对面真是网关。
        if not self.config.gateway.startswith("wss://") or not self.config.gateway_cert:
            raise SystemExit(f"网关地址必须是 wss:// 且带 gateway_cert：{self.config.gateway}")
        headers = {"Authorization": f"Bearer {self.config.token}"}
        async with connect(
            self.config.gateway,
            ssl=proto.pinned_client_context(self.config.gateway_cert),
            additional_headers=headers,
            max_size=proto.MAX_FRAME_BYTES,
            ping_interval=20,
            ping_timeout=60,
            open_timeout=15,
        ) as ws:
            info = await asyncio.to_thread(self.op_info, {})
            await ws.send(
                proto.encode(
                    {"type": "hello", "protocol": proto.PROTOCOL_VERSION, "name": self.config.name, "info": info}
                )
            )
            log(f"已连上网关 {self.config.gateway}，机器名 {self.config.name}。关掉本窗口即断开。")
            tasks: set[asyncio.Task] = set()
            async for raw in ws:
                msg = proto.decode(raw)
                if msg["type"] == "reject":
                    raise SystemExit(f"网关拒绝连接：{msg.get('reason')}")
                if msg["type"] == "req":
                    task = asyncio.create_task(self._handle(ws, msg))
                    tasks.add(task)
                    task.add_done_callback(tasks.discard)

    async def run_forever(self) -> None:
        backoff = 2.0
        while True:
            started = time.monotonic()
            try:
                await self.run_once()
                log("网关关闭了连接")
            except SystemExit:
                raise
            except (OSError, websockets.exceptions.WebSocketException, asyncio.TimeoutError) as exc:
                log(f"连接网关失败/断开：{exc}")
            # 网络断开属于外部不可控：退避重连（2s → 60s），连上并稳定一分钟后归位。
            if time.monotonic() - started > 60:
                backoff = 2.0
            log(f"{backoff:.0f}s 后重连")
            await asyncio.sleep(backoff)
            backoff = min(60.0, backoff * 2)


def _clip(data: Optional[bytes]) -> str:
    if not data:
        return ""
    text = data.decode("utf-8", errors="replace")
    if len(text) > OUTPUT_LIMIT:
        return f"…（截断，原长 {len(text)}）\n" + text[-OUTPUT_LIMIT:]
    return text


def _single_instance(name: str) -> object:
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateMutexW(None, False, f"Local\\fushi-adapt-agent-{name}")
    if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        raise SystemExit("本机已有一个同名 agent 在运行")
    return handle


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(description="Fushi 远程适配 agent（被控端）")
    parser.add_argument("--config", type=Path, default=app_dir() / "agent.json")
    args = parser.parse_args(argv)
    # 控制台走 WriteConsoleW 不受影响；输出被重定向到文件时固定 UTF-8，免得按系统 ANSI 码页乱码。
    if not sys.stdout.isatty():
        sys.stdout.reconfigure(encoding="utf-8")
    if not args.config.exists():
        raise SystemExit(f"找不到配置 {args.config}（请重新解压完整的压缩包）")
    config = AgentConfig.load(args.config)
    import win_desktop

    _mutex = _single_instance(config.name)  # noqa: F841 - 进程存活期间持有
    if sys.platform == "win32":
        ctypes.windll.kernel32.SetConsoleTitleW(f"Fushi 远程适配 agent - {config.name}（关闭即断开）")
        disable_console_quick_edit()
    agent = Agent(config, win_desktop)
    log(f"Fushi 远程适配 agent {AGENT_VERSION}  机器名={config.name}  管理员={is_admin()}")
    asyncio.run(agent.run_forever())


def run_and_pause_on_error(entry: Callable[[], None]) -> None:
    """双击运行时窗口出错会直接消失，志愿者看不到原因：出错先停住等回车。"""
    try:
        entry()
    except KeyboardInterrupt:
        pass
    except BaseException as exc:  # noqa: BLE001 - 顶层兜底只为把错误留在屏幕上
        code = getattr(exc, "code", None)
        if isinstance(exc, SystemExit) and code in (None, 0):
            raise
        print(f"\n出错：{code if isinstance(exc, SystemExit) else repr(exc)}", flush=True)
        if getattr(sys, "frozen", False):
            input("按回车关闭窗口…")
        raise SystemExit(1) from None


if __name__ == "__main__":
    run_and_pause_on_error(main)

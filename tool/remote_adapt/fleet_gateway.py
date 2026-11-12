"""远程适配网关（主控端）：志愿者电脑上的 agent 主动连进来，本机的 Claude 会话通过一个 MCP 服务操作它们。

    python fleet_gateway.py            # 或主控端包里的 fushi-fleet-gateway.exe

* agent 侧：WebSocket over TLS，本机监听 48765（路由器把公网 8765 转发过来；本机 8765 被 Fushi 自己占用），
  Bearer token 认证；
  网关用自签证书（~/.fushi-fleet/gateway.crt），证书写进志愿者包，agent 只信任它。
* Claude 侧：MCP Streamable HTTP `http://127.0.0.1:8766/mcp`，只监听本机回环。
* token：主控端包里与 exe 同目录的 token.txt，否则 ~/.fushi-fleet/token（不存在就生成）。

一个 Claude 会话即可同时操作所有在线机器：每个工具用 machine 参数点名，不同机器的调用可并行。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import secrets
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from http import HTTPStatus
from pathlib import Path
from typing import Any, Callable, Optional

from mcp.server.fastmcp import FastMCP, Image
from mcp.server.fastmcp.exceptions import ToolError
from websockets.asyncio.server import ServerConnection, serve

import fleet_protocol as proto

MACHINE_NAME = re.compile(r"[\w-]{1,64}")


# ── agent 连接 ──────────────────────────────────────────────────────────────


class AgentGone(ToolError):
    pass


@dataclass
class AgentConn:
    name: str
    ws: ServerConnection
    info: dict[str, Any]
    connected_at: float = field(default_factory=time.time)
    _next_id: int = 0
    _pending: dict[int, asyncio.Future] = field(default_factory=dict)

    async def request(self, op: str, args: dict[str, Any], timeout_s: float) -> dict[str, Any]:
        self._next_id += 1
        rid = self._next_id
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        try:
            await self.ws.send(proto.encode({"type": "req", "id": rid, "op": op, "args": args}))
            msg = await asyncio.wait_for(fut, timeout_s)
        except asyncio.TimeoutError:
            raise ToolError(f"{self.name}: {op} 超过 {timeout_s:.0f}s 没有应答") from None
        finally:
            self._pending.pop(rid, None)
        if not msg.get("ok"):
            raise ToolError(f"{self.name}: {op} 失败：{msg.get('error')}\n{msg.get('trace', '')}".rstrip())
        return msg.get("result") or {}

    def resolve(self, msg: dict[str, Any]) -> None:
        fut = self._pending.get(msg.get("id"))
        if fut is not None and not fut.done():
            fut.set_result(msg)

    def fail_all(self, reason: str) -> None:
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(AgentGone(f"{self.name}: {reason}"))


class Fleet:
    def __init__(self, token: str, audit_dir: Optional[Path]) -> None:
        self.token = token
        self.agents: dict[str, AgentConn] = {}
        self.audit_dir = audit_dir
        if audit_dir:
            audit_dir.mkdir(parents=True, exist_ok=True)

    def audit(self, machine: str, op: str, args: dict[str, Any], note: str = "") -> None:
        if not self.audit_dir:
            return
        shown = {k: (v if k != "data_b64" else f"<{len(v)} b64>") for k, v in args.items()}
        line = json.dumps(
            {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "op": op, "args": shown, "note": note},
            ensure_ascii=False,
        )
        with (self.audit_dir / f"{machine}.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    async def process_request(self, connection: ServerConnection, request: Any) -> Any:
        if request.path != proto.AGENT_PATH:
            return connection.respond(HTTPStatus.NOT_FOUND, "not found\n")
        auth = request.headers.get("Authorization", "")
        if not secrets.compare_digest(auth, f"Bearer {self.token}"):
            return connection.respond(HTTPStatus.UNAUTHORIZED, "bad token\n")
        return None

    async def handle_agent(self, ws: ServerConnection) -> None:
        try:
            hello = proto.decode(await asyncio.wait_for(ws.recv(), 20))
        except (asyncio.TimeoutError, ValueError):
            await ws.close(1008, "expected hello")
            return
        if hello.get("type") != "hello" or hello.get("protocol") != proto.PROTOCOL_VERSION:
            await ws.send(
                proto.encode(
                    {
                        "type": "reject",
                        "reason": f"协议版本不符：agent={hello.get('protocol')} 网关={proto.PROTOCOL_VERSION}，请更新 agent",
                    }
                )
            )
            await ws.close(1008, "protocol mismatch")
            return
        name = str(hello.get("name") or "").strip()
        # 机器名会拼进审计文件名：只允许字母数字（含中日文）、下划线、连字符，杜绝路径穿越。
        if not MACHINE_NAME.fullmatch(name):
            await ws.send(proto.encode({"type": "reject", "reason": f"机器名不合法：{name!r}（只能用字母数字、_、-，≤64 字）"}))
            await ws.close(1008, "bad name")
            return
        old = self.agents.get(name)
        conn = AgentConn(name=name, ws=ws, info=hello.get("info") or {})
        self.agents[name] = conn
        if old is not None:
            old.fail_all("被同名的新连接替换")
            await old.ws.close(1000, "replaced")
        self.audit(name, "connect", {"remote": str(ws.remote_address)})
        try:
            async for raw in ws:
                msg = proto.decode(raw)
                if msg.get("type") == "res":
                    conn.resolve(msg)
        except Exception:  # 连接异常断开：下面统一清理并记审计
            pass
        finally:
            conn.fail_all("agent 断开")
            if self.agents.get(name) is conn:
                del self.agents[name]
            self.audit(name, "disconnect", {})

    def agent(self, machine: str) -> AgentConn:
        conn = self.agents.get(machine)
        if conn is None:
            online = ", ".join(sorted(self.agents)) or "（无）"
            raise ToolError(f"{machine} 不在线。在线机器：{online}")
        return conn

    async def call(self, machine: str, op: str, args: dict[str, Any], timeout_s: float = 90) -> dict[str, Any]:
        conn = self.agent(machine)
        self.audit(machine, op, args)
        return await conn.request(op, args, timeout_s)


# ── MCP ─────────────────────────────────────────────────────────────────────


def _shot_content(result: dict[str, Any]) -> list[Any]:
    """把 agent 的截图结果拆成 MCP 图片 + 一行说明。"""
    if "image_b64" in result:
        shot: Optional[dict[str, Any]] = result
        action: Optional[dict[str, Any]] = None
    else:
        shot = result.pop("screenshot", None)
        action = result
    out: list[Any] = []
    if action is not None:
        out.append(json.dumps(action, ensure_ascii=False))
    if shot is not None:
        data = proto.b64d(shot["image_b64"])
        fmt = "png" if shot.get("mime") == "image/png" else "jpeg"
        out.append(Image(data=data, format=fmt))
        meta = {k: v for k, v in shot.items() if k not in ("mime", "image_b64")}
        hint = ""
        if meta.get("nearly_black"):
            hint = "  ⚠ 截图几乎全黑：可能是独占全屏，改用 galdriver `shot game`（WGC）"
        out.append("screenshot " + json.dumps(meta, ensure_ascii=False) + hint)
    return out


def build_mcp(fleet: Fleet, host: str, port: int) -> FastMCP:
    mcp = FastMCP(
        "fleet",
        instructions=(
            "操作社区志愿者的 Windows 电脑做 galgame 内嵌查词适配。先 list_machines 看谁在线，"
            "之后每个操作用 machine 指定机器；不同机器的操作可以并行发。坐标默认是该机器最近一次截图里的像素"
            "（coords='screenshot'），accept4 等物理坐标用 coords='physical'。"
            "适配验收优先用 galdriver 指令（state / lines / accept4 返回文字，省额度），"
            "截图只在需要看画面时用。游戏截图、台词不得写进仓库。"
        ),
        host=host,
        port=port,
        max_request_body_size=8 * 1024 * 1024,
    )

    @mcp.tool(structured_output=False)
    async def list_machines() -> str:
        """列出在线机器：系统、分辨率、触屏、是否管理员、驱动是否就绪。"""
        rows = []
        for name, conn in sorted(fleet.agents.items()):
            info = conn.info
            rows.append(
                {
                    "machine": name,
                    "online_s": round(time.time() - conn.connected_at),
                    "os": info.get("os"),
                    "user": info.get("user"),
                    "is_admin": info.get("is_admin"),
                    "virtual_screen": info.get("virtual_screen"),
                    "monitors": info.get("monitors"),
                    "touch": info.get("touch"),
                    "galdriver": info.get("galdriver"),
                    "agent_version": info.get("agent_version"),
                }
            )
        return json.dumps(rows, ensure_ascii=False, indent=1) if rows else "没有在线机器"

    @mcp.tool(structured_output=False)
    async def machine_info(machine: str) -> str:
        """刷新并返回机器信息（显示器、前台窗口、驱动状态等）。"""
        result = await fleet.call(machine, "info", {})
        fleet.agent(machine).info = result
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def screenshot(
        machine: str,
        monitor: int = 1,
        max_width: int = 1280,
        region: Optional[list[int]] = None,
        format: str = "jpeg",
        quality: int = 70,
    ) -> list[Any]:
        """截屏。monitor: 0=整个虚拟桌面，1=主显示器，2..=其它显示器；region=[左,上,宽,高]
        物理像素只截一块（看小字用，配合 max_width=0 不缩放）。之后的 coords='screenshot'
        坐标都相对这张图。"""
        args: dict[str, Any] = {"monitor": monitor, "max_width": max_width, "format": format, "quality": quality}
        if region:
            args["region"] = region
        return _shot_content(await fleet.call(machine, "screenshot", args))

    def _action_args(base: dict[str, Any], screenshot_after: bool, settle_ms: int) -> dict[str, Any]:
        args = {k: v for k, v in base.items() if v is not None}
        if screenshot_after:
            args["screenshot_after"] = True
            args["settle_ms"] = settle_ms
        return args

    @mcp.tool(structured_output=False)
    async def click(
        machine: str,
        x: float,
        y: float,
        button: str = "left",
        count: int = 1,
        modifiers: Optional[list[str]] = None,
        hold_ms: int = 0,
        coords: str = "screenshot",
        screenshot_after: bool = False,
        settle_ms: int = 400,
    ) -> list[Any]:
        """鼠标点击（SendInput）。button=left/right/middle，count=2 双击，modifiers 如 ["shift"]。
        screenshot_after=true 在 settle_ms 后顺带截图（省一轮）。"""
        args = _action_args(
            {"x": x, "y": y, "button": button, "count": count, "modifiers": modifiers,
             "hold_ms": hold_ms, "coords": coords},
            screenshot_after, settle_ms,
        )
        return _shot_content(await fleet.call(machine, "click", args))

    @mcp.tool(structured_output=False)
    async def move(machine: str, x: float, y: float, coords: str = "screenshot",
                   screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """移动鼠标（悬停）。"""
        args = _action_args({"x": x, "y": y, "coords": coords}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, "move", args))

    @mcp.tool(structured_output=False)
    async def drag(machine: str, x: float, y: float, x2: float, y2: float,
                   button: str = "left", duration_ms: int = 400, coords: str = "screenshot",
                   screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """按住拖动。"""
        args = _action_args(
            {"x": x, "y": y, "x2": x2, "y2": y2, "button": button, "duration_ms": duration_ms, "coords": coords},
            screenshot_after, settle_ms,
        )
        return _shot_content(await fleet.call(machine, "drag", args))

    @mcp.tool(structured_output=False)
    async def scroll(machine: str, x: float, y: float, dy: int = -3, dx: int = 0,
                     coords: str = "screenshot", screenshot_after: bool = False,
                     settle_ms: int = 400) -> list[Any]:
        """滚轮，dy>0 向上、dy<0 向下，单位是格。"""
        args = _action_args({"x": x, "y": y, "dy": dy, "dx": dx, "coords": coords}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, "scroll", args))

    @mcp.tool(structured_output=False)
    async def key(machine: str, keys: str, hold_ms: int = 30, repeat: int = 1,
                  screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """按键 / 组合键：enter、space、esc、ctrl+s、alt+f4、f5、vk0x5A…（同时发 VK 与扫描码）。"""
        args = _action_args({"keys": keys, "hold_ms": hold_ms, "repeat": repeat}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, "key", args))

    @mcp.tool(structured_output=False)
    async def type_text(machine: str, text: str, screenshot_after: bool = False,
                        settle_ms: int = 400) -> list[Any]:
        """按 Unicode 逐字输入文本（不经输入法），\\n 发回车。"""
        args = _action_args({"text": text}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, "type", args, timeout_s=300))

    @mcp.tool(structured_output=False)
    async def touch(machine: str, action: str, x: float, y: float,
                    x2: Optional[float] = None, y2: Optional[float] = None,
                    duration_ms: Optional[int] = None, coords: str = "screenshot",
                    screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """真实触摸注入（InjectTouchInput, PT_TOUCH）。action=tap / hold（长按，默认 1000ms）/
        swipe（到 x2,y2）。内嵌查词第④条「点击不推进」的触摸验收用它。"""
        args = _action_args(
            {"action": action, "x": x, "y": y, "x2": x2, "y2": y2, "duration_ms": duration_ms, "coords": coords},
            screenshot_after, settle_ms,
        )
        return _shot_content(await fleet.call(machine, "touch", args))

    @mcp.tool(structured_output=False)
    async def powershell(machine: str, command: str, timeout_s: int = 120,
                         cwd: Optional[str] = None) -> str:
        """在对方桌面会话里跑 PowerShell（UTF-8 输出）。Start-Process 拉起的程序会出现在对方屏幕上。"""
        args = {"command": command, "timeout_s": timeout_s}
        if cwd:
            args["cwd"] = cwd
        result = await fleet.call(machine, "powershell", args, timeout_s=timeout_s + 30)
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def put_file(machine: str, local_path: str, remote_path: str) -> str:
        """把本机文件推到对方电脑（分块，原子落盘）。推目录请先打 zip 再用 powershell Expand-Archive。"""
        src = Path(local_path)
        if not src.is_file():
            raise ToolError(f"本机找不到文件 {src}")
        size = src.stat().st_size
        offset = 0
        result: dict[str, Any] = {}
        with src.open("rb") as fh:
            while True:
                chunk = fh.read(proto.FILE_CHUNK)
                final = offset + len(chunk) >= size
                result = await fleet.call(
                    machine, "file_write",
                    {"path": remote_path, "offset": offset, "data_b64": proto.b64e(chunk), "final": final},
                    timeout_s=180,
                )
                offset += len(chunk)
                if final:
                    break
        return json.dumps({"sent": size, **result}, ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def get_file(machine: str, remote_path: str, local_path: str) -> str:
        """把对方电脑上的文件拉回本机（例如 galdriver 的 shot_n.png、日志）。"""
        dst = Path(local_path)
        dst.parent.mkdir(parents=True, exist_ok=True)
        part = dst.with_name(dst.name + ".part")
        offset = 0
        with part.open("wb") as fh:
            while True:
                res = await fleet.call(
                    machine, "file_read",
                    {"path": remote_path, "offset": offset, "length": proto.FILE_CHUNK},
                    timeout_s=180,
                )
                data = proto.b64d(res["data_b64"])
                fh.write(data)
                offset += len(data)
                if res["eof"] or not data:
                    break
        part.replace(dst)
        return json.dumps({"saved": str(dst), "size": offset}, ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def list_dir(machine: str, path: str, limit: int = 500) -> str:
        """列对方电脑上的目录。"""
        return json.dumps(
            await fleet.call(machine, "list_dir", {"path": path, "limit": limit}),
            ensure_ascii=False, indent=1,
        )

    @mcp.tool(structured_output=False)
    async def galdriver_start(
        machine: str,
        seed_from_config: bool = False,
        seed_support_dir: Optional[str] = None,
        seed_documents_dir: Optional[str] = None,
        reset_test_root: bool = False,
        hidden: bool = True,
        ready_timeout_s: int = 180,
    ) -> str:
        """在对方电脑拉起 galgame 真机驱动（数据隔离在 agent 工作目录的 test-root，不碰真实 Fushi 数据）。
        查词需要词典时 seed_from_config=true（或给 seed_*_dir）把对方真实数据目录复制进测试根。"""
        args = {
            "seed_from_config": seed_from_config,
            "seed_support_dir": seed_support_dir,
            "seed_documents_dir": seed_documents_dir,
            "reset_test_root": reset_test_root,
            "hidden": hidden,
            "ready_timeout_s": ready_timeout_s,
        }
        result = await fleet.call(machine, "galdriver_start", args, timeout_s=ready_timeout_s + 600)
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver(machine: str, command: str, timeout_s: int = 300) -> str:
        """发一条真机驱动指令并等它执行完，返回输出：launch <exe> / attach / thread / state /
        lines / profile / calibrate / fakeanki / accept4 <x> <y> [ox oy] / shot game|card /
        windows / click / key / wait / stop … （完整列表见 gal_realgame_driver_itest.dart 文件头）。
        新截图文件名在 new_shots，用 get_file 拉回 <workdir>\\galdriver\\shot_n.png。"""
        result = await fleet.call(
            machine, "galdriver", {"command": command, "timeout_s": timeout_s}, timeout_s=timeout_s + 30
        )
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver_status(machine: str) -> str:
        """驱动进程状态与 out.txt 末尾。"""
        return json.dumps(await fleet.call(machine, "galdriver_status", {}), ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver_stop(machine: str) -> str:
        """让驱动 quit（超时则结束进程）。"""
        return json.dumps(await fleet.call(machine, "galdriver_stop", {}, timeout_s=60), ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def update_agent(machine: str, local_exe: str) -> str:
        """把本机新编的 fushi-adapt-agent.exe 推过去并让 agent 自我替换重启。"""
        remote = (fleet.agent(machine).info.get("workdir") or "%TEMP%") + "\\fushi-adapt-agent.new.exe"
        await put_file(machine, local_exe, remote)
        result = await fleet.call(machine, "self_update", {"new_exe": remote})
        return json.dumps(result, ensure_ascii=False)

    return mcp


def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def load_or_create_token(path: Path) -> str:
    """读 token；文件不存在就生成一个（打包脚本把同一个 token 写进志愿者包）。"""
    if path.exists():
        token = path.read_text(encoding="utf-8-sig").strip()
        if len(token) < 16:
            raise SystemExit(f"{path} 里的 token 太短（至少 16 字符）")
        return token
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    path.write_text(token, encoding="utf-8")
    return token


# 本机 8765 被 Fushi 自己的服务占用，网关默认监听 48765；对外端口由路由器映射（志愿者连公网 8765）。
DEFAULT_AGENT_PORT = 48765

CERT_NAME = "gateway.crt"
KEY_NAME = "gateway.key"


def load_or_create_cert(cert_dir: Path) -> tuple[Path, Path]:
    """网关的自签证书（EC P-256，10 年）。证书 PEM 由打包脚本写进志愿者包，agent 只认它。"""
    cert_path, key_path = cert_dir / CERT_NAME, cert_dir / KEY_NAME
    if cert_path.exists() and key_path.exists():
        return cert_path, key_path
    import datetime

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fushi-fleet-gateway")])
    now = datetime.datetime.now(datetime.timezone.utc)
    ski = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_cert_sign=True, crl_sign=False, content_commitment=False,
                key_encipherment=False, data_encipherment=False, key_agreement=False,
                encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("fushi-fleet-gateway")]), critical=False)
        .add_extension(ski, critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(ski), critical=False)
        .sign(key, hashes.SHA256())
    )
    cert_dir.mkdir(parents=True, exist_ok=True)
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        )
    )
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return cert_path, key_path


def server_ssl_context(cert_path: Path, key_path: Path) -> "ssl.SSLContext":
    import ssl

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_path, key_path)
    return ctx


def default_cert_dir() -> Path:
    # 主控端包里证书与 exe 同目录；源码运行时用用户目录。
    return app_dir() if (app_dir() / CERT_NAME).exists() else Path("~/.fushi-fleet").expanduser()


def default_token_file() -> Path:
    bundled = app_dir() / "token.txt"
    return bundled if bundled.exists() else Path("~/.fushi-fleet/token").expanduser()


FIREWALL_RULE = "Fushi remote adapt gateway"


def _run_quiet(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )


def setup_local(agent_port: int, mcp_port: int) -> None:
    """首次运行的本机准备：放行入站端口、把 MCP 注册进 Claude Code。都做过就什么也不动。"""
    if sys.platform == "win32":
        shown = _run_quiet(["netsh", "advfirewall", "firewall", "show", "rule", f"name={FIREWALL_RULE}"])
        if shown.returncode != 0:
            added = _run_quiet([
                "netsh", "advfirewall", "firewall", "add", "rule", f"name={FIREWALL_RULE}",
                "dir=in", "action=allow", "protocol=TCP", f"localport={agent_port}",
            ])
            if added.returncode == 0:
                print(f"[fleet] 已放行防火墙入站 TCP {agent_port}", flush=True)
            else:
                print(f"[fleet] ⚠ 防火墙放行失败（需要管理员）：{added.stdout.strip()}", flush=True)
    url = f"http://127.0.0.1:{mcp_port}/mcp"
    claude = shutil.which("claude")
    if claude is None:
        print(f"[fleet] ⚠ 没找到 claude 命令，手动注册一次：claude mcp add --scope user --transport http fleet {url}",
              flush=True)
        return
    if _run_quiet([claude, "mcp", "get", "fleet"]).returncode == 0:
        return
    added = _run_quiet([claude, "mcp", "add", "--scope", "user", "--transport", "http", "fleet", url])
    if added.returncode == 0:
        print("[fleet] 已把 fleet 注册进 Claude Code（新开的会话生效）", flush=True)
    else:
        print(f"[fleet] ⚠ 注册 MCP 失败：{(added.stdout + added.stderr).strip()}", flush=True)


async def serve_all(args: argparse.Namespace) -> None:
    token = args.token or load_or_create_token(Path(args.token_file).expanduser())
    fleet = Fleet(token, Path(args.audit_dir).expanduser() if args.audit_dir else None)
    mcp = build_mcp(fleet, args.mcp_host, args.mcp_port)
    cert_path, key_path = load_or_create_cert(Path(args.cert_dir).expanduser())
    async with serve(
        fleet.handle_agent,
        args.agent_host,
        args.agent_port,
        ssl=server_ssl_context(cert_path, key_path),
        process_request=fleet.process_request,
        max_size=proto.MAX_FRAME_BYTES,
        ping_interval=20,
        ping_timeout=60,
    ):
        print(f"[fleet] 等志愿者连入：端口 {args.agent_port}", flush=True)
        print(f"[fleet] Claude 用的 MCP：http://{args.mcp_host}:{args.mcp_port}/mcp", flush=True)
        print("[fleet] 保持本窗口打开；关掉即全部断开。", flush=True)
        await mcp.run_streamable_http_async()


def bundled_agent_port() -> int:
    """主控端包里 gateway.json 的 agent_port（打包时按路由器转发目标写入），没有就用默认值。"""
    path = app_dir() / "gateway.json"
    if path.exists():
        return int(json.loads(path.read_text(encoding="utf-8-sig")).get("agent_port", DEFAULT_AGENT_PORT))
    return DEFAULT_AGENT_PORT


def main(argv: Optional[list[str]] = None) -> None:
    if not sys.stdout.isatty():
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Fushi 远程适配网关（主控端）")
    parser.add_argument("--agent-host", default="0.0.0.0")
    parser.add_argument("--agent-port", type=int, default=bundled_agent_port())
    parser.add_argument("--mcp-host", default="127.0.0.1")
    parser.add_argument("--mcp-port", type=int, default=8766)
    parser.add_argument("--token", default=None)
    parser.add_argument("--token-file", default=str(default_token_file()))
    parser.add_argument("--cert-dir", default=str(default_cert_dir()))
    parser.add_argument("--print-token", action="store_true", help="打印 token（没有就生成）后退出")
    parser.add_argument("--print-cert", action="store_true", help="打印网关证书 PEM（没有就生成）后退出")
    parser.add_argument("--audit-dir", default="~/.fushi-fleet/audit")
    parser.add_argument("--no-setup", action="store_true", help="不自动放行防火墙、不注册 MCP")
    args = parser.parse_args(argv)
    if args.print_token:
        print(load_or_create_token(Path(args.token_file).expanduser()))
        return
    if args.print_cert:
        cert_path, _ = load_or_create_cert(Path(args.cert_dir).expanduser())
        print(cert_path.read_text(encoding="ascii").strip())
        return
    if sys.platform == "win32":
        import ctypes

        ctypes.windll.kernel32.SetConsoleTitleW("Fushi 远程适配网关（关闭即断开所有志愿者）")
    if not args.no_setup:
        setup_local(args.agent_port, args.mcp_port)
    asyncio.run(serve_all(args))


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

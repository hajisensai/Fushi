"""机群网关：志愿者电脑上的 agent 主动连进来，本机的 Claude 会话通过一个 MCP 服务操作它们。

    python fleet_gateway.py --agent-host 100.x.y.z --token-file %USERPROFILE%\\.fushi-fleet\\token

* agent 侧：WebSocket `ws://<agent-host>:<agent-port>/agent`，Bearer token 认证。
  agent-host 填本机的 Tailscale 地址（或 0.0.0.0）。
* Claude 侧：MCP Streamable HTTP `http://127.0.0.1:<mcp-port>/mcp`，只监听本机回环。
  注册一次：`claude mcp add --scope user --transport http fleet http://127.0.0.1:8766/mcp`

同时有多个 Claude 会话在操作不同机器，所以每台机器有**独占租约**：先 claim_machine
拿到 lease，之后所有操作都带上它；别的会话对这台机器的操作会被拒绝。租约空闲超过
TTL 自动过期（会话中途死掉不会永久占着机器）。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import secrets
import time
from dataclasses import dataclass, field
from http import HTTPStatus
from pathlib import Path
from typing import Any, Optional

from mcp.server.fastmcp import FastMCP, Image
from mcp.server.fastmcp.exceptions import ToolError
from websockets.asyncio.server import ServerConnection, serve

import fleet_protocol as proto

DEFAULT_LEASE_TTL_S = 30 * 60
MACHINE_NAME = re.compile(r"[\w-]{1,64}")


# ── 租约 ────────────────────────────────────────────────────────────────────


@dataclass
class Lease:
    token: str
    holder: str
    claimed_at: float
    last_used: float


class LeaseTable:
    """机器 → 独占租约。纯内存；网关重启后所有租约作废（agent 也会重连）。"""

    def __init__(self, ttl_s: float = DEFAULT_LEASE_TTL_S, clock: Any = time.monotonic) -> None:
        self.ttl_s = ttl_s
        self._clock = clock
        self._leases: dict[str, Lease] = {}

    def _live(self, machine: str) -> Optional[Lease]:
        lease = self._leases.get(machine)
        if lease is not None and self._clock() - lease.last_used > self.ttl_s:
            del self._leases[machine]
            return None
        return lease

    def holder(self, machine: str) -> Optional[dict[str, Any]]:
        lease = self._live(machine)
        if lease is None:
            return None
        now = self._clock()
        return {
            "holder": lease.holder,
            "held_s": round(now - lease.claimed_at),
            "idle_s": round(now - lease.last_used),
            "expires_in_s": round(self.ttl_s - (now - lease.last_used)),
        }

    def claim(self, machine: str, holder: str, steal: bool = False) -> str:
        holder = holder.strip()
        if not holder:
            raise ToolError("holder 不能为空：写你的会话名 / 任务名，方便别人知道谁占着")
        lease = self._live(machine)
        now = self._clock()
        if lease is not None:
            if lease.holder == holder:
                # 同一持有者重复 claim（例如上下文压缩后丢了 lease）：续上原租约。
                lease.last_used = now
                return lease.token
            if not steal:
                raise ToolError(
                    f"{machine} 正被「{lease.holder}」占用（空闲 {round(now - lease.last_used)}s）。"
                    "确认对方已不用再传 steal=true"
                )
        token = secrets.token_urlsafe(12)
        self._leases[machine] = Lease(token, holder, now, now)
        return token

    def check(self, machine: str, token: str) -> None:
        lease = self._live(machine)
        if lease is None:
            raise ToolError(f"{machine} 没有有效租约（可能已过期），先 claim_machine")
        if not secrets.compare_digest(lease.token, token or ""):
            raise ToolError(f"lease 不对：{machine} 当前由「{lease.holder}」持有")
        lease.last_used = self._clock()

    def release(self, machine: str, token: str) -> bool:
        lease = self._live(machine)
        if lease is None:
            return False
        if not secrets.compare_digest(lease.token, token or ""):
            raise ToolError(f"lease 不对：{machine} 当前由「{lease.holder}」持有")
        del self._leases[machine]
        return True


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
    def __init__(self, token: str, leases: LeaseTable, audit_dir: Optional[Path]) -> None:
        self.token = token
        self.leases = leases
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

    async def call(
        self, machine: str, lease: str, op: str, args: dict[str, Any], timeout_s: float = 90
    ) -> dict[str, Any]:
        self.leases.check(machine, lease)
        conn = self.agent(machine)
        self.audit(machine, op, args, note=self.leases.holder(machine)["holder"])
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
            "操作社区志愿者的 Windows 电脑做 galgame 内嵌查词适配。先 list_machines，"
            "再 claim_machine 拿 lease（每台机器同一时间只归一个会话），之后所有操作都带 "
            "machine + lease，做完 release_machine。坐标默认是最近一次截图里的像素"
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
        """列出在线机器：系统、分辨率、触屏、是否管理员、驱动是否就绪、谁占着。"""
        rows = []
        for name, conn in sorted(fleet.agents.items()):
            info = conn.info
            rows.append(
                {
                    "machine": name,
                    "lease": fleet.leases.holder(name),
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
    async def claim_machine(machine: str, holder: str, steal: bool = False) -> str:
        """独占一台机器，返回 lease。holder 写会话名/任务名（如「siglus 适配」）。
        同一 holder 再 claim 会拿回原 lease；steal=true 强占别人的（确认对方已不用）。"""
        fleet.agent(machine)
        token = fleet.leases.claim(machine, holder, steal)
        fleet.audit(machine, "claim", {"holder": holder, "steal": steal})
        return json.dumps({"machine": machine, "lease": token, "ttl_s": fleet.leases.ttl_s}, ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def release_machine(machine: str, lease: str) -> str:
        """释放租约。"""
        ok = fleet.leases.release(machine, lease)
        fleet.audit(machine, "release", {})
        return "released" if ok else "本来就没有租约"

    @mcp.tool(structured_output=False)
    async def machine_info(machine: str, lease: str) -> str:
        """刷新并返回机器信息（显示器、前台窗口、驱动状态等）。"""
        result = await fleet.call(machine, lease, "info", {})
        fleet.agent(machine).info = result
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def screenshot(
        machine: str,
        lease: str,
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
        return _shot_content(await fleet.call(machine, lease, "screenshot", args))

    def _action_args(base: dict[str, Any], screenshot_after: bool, settle_ms: int) -> dict[str, Any]:
        args = {k: v for k, v in base.items() if v is not None}
        if screenshot_after:
            args["screenshot_after"] = True
            args["settle_ms"] = settle_ms
        return args

    @mcp.tool(structured_output=False)
    async def click(
        machine: str,
        lease: str,
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
        return _shot_content(await fleet.call(machine, lease, "click", args))

    @mcp.tool(structured_output=False)
    async def move(machine: str, lease: str, x: float, y: float, coords: str = "screenshot",
                   screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """移动鼠标（悬停）。"""
        args = _action_args({"x": x, "y": y, "coords": coords}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, lease, "move", args))

    @mcp.tool(structured_output=False)
    async def drag(machine: str, lease: str, x: float, y: float, x2: float, y2: float,
                   button: str = "left", duration_ms: int = 400, coords: str = "screenshot",
                   screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """按住拖动。"""
        args = _action_args(
            {"x": x, "y": y, "x2": x2, "y2": y2, "button": button, "duration_ms": duration_ms, "coords": coords},
            screenshot_after, settle_ms,
        )
        return _shot_content(await fleet.call(machine, lease, "drag", args))

    @mcp.tool(structured_output=False)
    async def scroll(machine: str, lease: str, x: float, y: float, dy: int = -3, dx: int = 0,
                     coords: str = "screenshot", screenshot_after: bool = False,
                     settle_ms: int = 400) -> list[Any]:
        """滚轮，dy>0 向上、dy<0 向下，单位是格。"""
        args = _action_args({"x": x, "y": y, "dy": dy, "dx": dx, "coords": coords}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, lease, "scroll", args))

    @mcp.tool(structured_output=False)
    async def key(machine: str, lease: str, keys: str, hold_ms: int = 30, repeat: int = 1,
                  screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """按键 / 组合键：enter、space、esc、ctrl+s、alt+f4、f5、vk0x5A…（同时发 VK 与扫描码）。"""
        args = _action_args({"keys": keys, "hold_ms": hold_ms, "repeat": repeat}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, lease, "key", args))

    @mcp.tool(structured_output=False)
    async def type_text(machine: str, lease: str, text: str, screenshot_after: bool = False,
                        settle_ms: int = 400) -> list[Any]:
        """按 Unicode 逐字输入文本（不经输入法），\\n 发回车。"""
        args = _action_args({"text": text}, screenshot_after, settle_ms)
        return _shot_content(await fleet.call(machine, lease, "type", args, timeout_s=300))

    @mcp.tool(structured_output=False)
    async def touch(machine: str, lease: str, action: str, x: float, y: float,
                    x2: Optional[float] = None, y2: Optional[float] = None,
                    duration_ms: Optional[int] = None, coords: str = "screenshot",
                    screenshot_after: bool = False, settle_ms: int = 400) -> list[Any]:
        """真实触摸注入（InjectTouchInput, PT_TOUCH）。action=tap / hold（长按，默认 1000ms）/
        swipe（到 x2,y2）。内嵌查词第④条「点击不推进」的触摸验收用它。"""
        args = _action_args(
            {"action": action, "x": x, "y": y, "x2": x2, "y2": y2, "duration_ms": duration_ms, "coords": coords},
            screenshot_after, settle_ms,
        )
        return _shot_content(await fleet.call(machine, lease, "touch", args))

    @mcp.tool(structured_output=False)
    async def powershell(machine: str, lease: str, command: str, timeout_s: int = 120,
                         cwd: Optional[str] = None) -> str:
        """在对方桌面会话里跑 PowerShell（UTF-8 输出）。Start-Process 拉起的程序会出现在对方屏幕上。"""
        args = {"command": command, "timeout_s": timeout_s}
        if cwd:
            args["cwd"] = cwd
        result = await fleet.call(machine, lease, "powershell", args, timeout_s=timeout_s + 30)
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def put_file(machine: str, lease: str, local_path: str, remote_path: str) -> str:
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
                    machine, lease, "file_write",
                    {"path": remote_path, "offset": offset, "data_b64": proto.b64e(chunk), "final": final},
                    timeout_s=180,
                )
                offset += len(chunk)
                if final:
                    break
        return json.dumps({"sent": size, **result}, ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def get_file(machine: str, lease: str, remote_path: str, local_path: str) -> str:
        """把对方电脑上的文件拉回本机（例如 galdriver 的 shot_n.png、日志）。"""
        dst = Path(local_path)
        dst.parent.mkdir(parents=True, exist_ok=True)
        part = dst.with_name(dst.name + ".part")
        offset = 0
        with part.open("wb") as fh:
            while True:
                res = await fleet.call(
                    machine, lease, "file_read",
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
    async def list_dir(machine: str, lease: str, path: str, limit: int = 500) -> str:
        """列对方电脑上的目录。"""
        return json.dumps(
            await fleet.call(machine, lease, "list_dir", {"path": path, "limit": limit}),
            ensure_ascii=False, indent=1,
        )

    @mcp.tool(structured_output=False)
    async def galdriver_start(
        machine: str,
        lease: str,
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
        result = await fleet.call(machine, lease, "galdriver_start", args, timeout_s=ready_timeout_s + 600)
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver(machine: str, lease: str, command: str, timeout_s: int = 300) -> str:
        """发一条真机驱动指令并等它执行完，返回输出：launch <exe> / attach / thread / state /
        lines / profile / calibrate / fakeanki / accept4 <x> <y> [ox oy] / shot game|card /
        windows / click / key / wait / stop … （完整列表见 gal_realgame_driver_itest.dart 文件头）。
        新截图文件名在 new_shots，用 get_file 拉回 <workdir>\\galdriver\\shot_n.png。"""
        result = await fleet.call(
            machine, lease, "galdriver", {"command": command, "timeout_s": timeout_s}, timeout_s=timeout_s + 30
        )
        return json.dumps(result, ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver_status(machine: str, lease: str) -> str:
        """驱动进程状态与 out.txt 末尾。"""
        return json.dumps(await fleet.call(machine, lease, "galdriver_status", {}), ensure_ascii=False, indent=1)

    @mcp.tool(structured_output=False)
    async def galdriver_stop(machine: str, lease: str) -> str:
        """让驱动 quit（超时则结束进程）。"""
        return json.dumps(await fleet.call(machine, lease, "galdriver_stop", {}, timeout_s=60), ensure_ascii=False)

    @mcp.tool(structured_output=False)
    async def update_agent(machine: str, lease: str, local_exe: str) -> str:
        """把本机新编的 fushi-adapt-agent.exe 推过去并让 agent 自我替换重启（重连后租约仍有效）。"""
        remote = (fleet.agent(machine).info.get("workdir") or "%TEMP%") + "\\fushi-adapt-agent.new.exe"
        await put_file(machine, lease, local_exe, remote)
        result = await fleet.call(machine, lease, "self_update", {"new_exe": remote})
        return json.dumps(result, ensure_ascii=False)

    return mcp


async def serve_all(args: argparse.Namespace) -> None:
    token = args.token or Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()
    if len(token) < 16:
        raise SystemExit("token 太短（至少 16 字符）；用 --init-token 生成")
    fleet = Fleet(token, LeaseTable(args.lease_ttl), Path(args.audit_dir).expanduser() if args.audit_dir else None)
    mcp = build_mcp(fleet, args.mcp_host, args.mcp_port)
    async with serve(
        fleet.handle_agent,
        args.agent_host,
        args.agent_port,
        process_request=fleet.process_request,
        max_size=proto.MAX_FRAME_BYTES,
        ping_interval=20,
        ping_timeout=60,
    ):
        print(f"[fleet] agent 入口 ws://{args.agent_host}:{args.agent_port}{proto.AGENT_PATH}", flush=True)
        print(f"[fleet] MCP 入口 http://{args.mcp_host}:{args.mcp_port}/mcp", flush=True)
        await mcp.run_streamable_http_async()


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(description="Fushi 远程适配机群网关（本机）")
    parser.add_argument("--agent-host", default="0.0.0.0", help="agent 连入地址，建议填本机 Tailscale IP")
    parser.add_argument("--agent-port", type=int, default=8765)
    parser.add_argument("--mcp-host", default="127.0.0.1")
    parser.add_argument("--mcp-port", type=int, default=8766)
    parser.add_argument("--token", default=None)
    parser.add_argument("--token-file", default="~/.fushi-fleet/token")
    parser.add_argument("--init-token", action="store_true", help="生成 token 写入 --token-file 后退出")
    parser.add_argument("--lease-ttl", type=float, default=DEFAULT_LEASE_TTL_S)
    parser.add_argument("--audit-dir", default="~/.fushi-fleet/audit")
    args = parser.parse_args(argv)
    if args.init_token:
        path = Path(args.token_file).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            raise SystemExit(f"{path} 已存在，不覆盖")
        path.write_text(secrets.token_urlsafe(32), encoding="utf-8")
        print(f"token 已写入 {path}")
        return
    asyncio.run(serve_all(args))


if __name__ == "__main__":
    main()

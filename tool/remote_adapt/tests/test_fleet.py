"""远程适配机群：租约、驱动宿主、网关 ↔ agent ↔ MCP 端到端。

    python -m pytest tool/remote_adapt/tests -q
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import socket
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import fleet_agent  # noqa: E402
import fleet_gateway  # noqa: E402
import win_desktop  # noqa: E402
from galdriver_host import GalDriverError, GalDriverHost  # noqa: E402
from mcp.server.fastmcp.exceptions import ToolError  # noqa: E402

FAKE_DRIVER = HERE / "fake_galdriver.py"


# ── 租约 ────────────────────────────────────────────────────────────────────


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_lease_exclusive_and_reclaim_by_same_holder() -> None:
    clock = Clock()
    table = fleet_gateway.LeaseTable(ttl_s=60, clock=clock)
    token = table.claim("a", "siglus")
    assert table.claim("a", "siglus") == token  # 同一持有者拿回原租约
    with pytest.raises(ToolError, match="正被「siglus」占用"):
        table.claim("a", "bgi")
    with pytest.raises(ToolError, match="lease 不对"):
        table.check("a", "wrong")
    table.check("a", token)
    stolen = table.claim("a", "bgi", steal=True)
    assert stolen != token
    with pytest.raises(ToolError):
        table.check("a", token)


def test_lease_expires_after_idle_ttl_but_use_refreshes() -> None:
    clock = Clock()
    table = fleet_gateway.LeaseTable(ttl_s=60, clock=clock)
    token = table.claim("a", "x")
    clock.now += 50
    table.check("a", token)  # 续期
    clock.now += 50
    table.check("a", token)
    clock.now += 61
    with pytest.raises(ToolError, match="没有有效租约"):
        table.check("a", token)
    assert table.claim("a", "y")


def test_lease_requires_holder() -> None:
    with pytest.raises(ToolError, match="holder"):
        fleet_gateway.LeaseTable().claim("a", "  ")


# ── Win32 结构体布局（与 SDK 头一致，否则 SendInput / InjectTouchInput 静默失败）──


@pytest.mark.skipif(ctypes.sizeof(ctypes.c_void_p) != 8, reason="只校验 x64 布局")
def test_win32_struct_sizes_x64() -> None:
    assert ctypes.sizeof(win_desktop.INPUT) == 40
    assert ctypes.sizeof(win_desktop.POINTER_INFO) == 96
    assert ctypes.sizeof(win_desktop.POINTER_TOUCH_INFO) == 144


def test_key_names() -> None:
    assert win_desktop._vk_of("enter") == 0x0D
    assert win_desktop._vk_of("Ctrl") == 0x11
    assert win_desktop._vk_of("f5") == 0x74
    assert win_desktop._vk_of("a") == ord("A")
    assert win_desktop._vk_of("vk0x5A") == 0x5A
    with pytest.raises(ValueError):
        win_desktop._vk_of("nosuchkey")


def test_real_screen_capture_and_mapping() -> None:
    cap = win_desktop.capture_screen(monitor=1, max_width=640)
    assert cap.width == 640 or cap.physical_width <= 640
    assert cap.data[:2] == b"\xff\xd8"  # JPEG
    x, y = cap.to_physical(cap.width, cap.height)
    assert x == cap.origin_x + cap.physical_width
    assert abs(y - (cap.origin_y + cap.physical_height)) <= 2


# ── 驱动宿主 ────────────────────────────────────────────────────────────────


def _host(tmp_path: Path) -> GalDriverHost:
    return GalDriverHost(exe=Path(sys.executable), workdir=tmp_path, exe_args=[str(FAKE_DRIVER)])


def test_galdriver_roundtrip(tmp_path: Path) -> None:
    host = _host(tmp_path)
    ready = host.start(ready_timeout_s=20)
    try:
        assert "home=true" in ready["ready"]
        assert f"root={tmp_path / 'test-root'}" in ready["ready"]
        assert "hidden=1" in ready["ready"]
        r1 = host.command("state", timeout_s=10)
        assert "#1 ok state" in r1["output"]
        r2 = host.command("shot game", timeout_s=10)
        assert r2["new_shots"] == ["shot_1.png"]
        assert "#1" not in r2["output"]  # 只返回本条指令新增的输出
        with pytest.raises(GalDriverError, match="单行"):
            host.command("a\nb")
        with pytest.raises(GalDriverError, match="已在运行"):
            host.start()
    finally:
        stopped = host.stop(timeout_s=10)
    assert stopped["how"] == "quit"
    assert not host.running()


def test_galdriver_timeout_and_crash_are_reported(tmp_path: Path) -> None:
    host = _host(tmp_path)
    host.start(ready_timeout_s=20)
    try:
        with pytest.raises(GalDriverError, match="内指令未完成"):
            host.command("slow 3", timeout_s=0.5)
        # 慢指令跑完后协议恢复同步
        assert "ok next" in host.command("next", timeout_s=10)["output"]
        with pytest.raises(GalDriverError, match="退出"):
            host.command("crash", timeout_s=10)
    finally:
        host.stop(timeout_s=5)


def test_galdriver_seed_copies_only_into_empty_root(tmp_path: Path) -> None:
    real = tmp_path / "real-support"
    (real / "dicts").mkdir(parents=True)
    (real / "dicts" / "jmdict.db").write_text("x")
    host = GalDriverHost(exe=Path(sys.executable), workdir=tmp_path / "w", exe_args=[str(FAKE_DRIVER)])
    ready = host.start(seed_support_dir=str(real), ready_timeout_s=20)
    host.stop(timeout_s=5)
    assert (host.test_root / "app-support" / "dicts" / "jmdict.db").exists()
    assert any("app-support <-" in s for s in ready["seeded"])
    again = host.start(seed_support_dir=str(real), ready_timeout_s=20)
    host.stop(timeout_s=5)
    assert any("跳过" in s for s in again["seeded"])


def test_galdriver_stop_ends_lingering_host(tmp_path: Path) -> None:
    host = _host(tmp_path)
    host.start(ready_timeout_s=20, extra_env={"FAKE_DRIVER_LINGER": "1"})
    stopped = host.stop(timeout_s=10)
    assert stopped["how"] == "quit"
    assert not host.running()


def test_galdriver_missing_exe(tmp_path: Path) -> None:
    host = GalDriverHost(exe=tmp_path / "nope.exe", workdir=tmp_path)
    with pytest.raises(GalDriverError, match="找不到驱动"):
        host.start()


# ── 端到端：网关 + 两个 agent + 真 MCP 客户端 ──────────────────────────────


class FakeDesktop:
    """替身桌面：截图返回固定图，输入只记录不真的发。"""

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple, dict]] = []

    def enable_dpi_awareness(self) -> str:
        return "fake"

    def virtual_screen(self) -> tuple[int, int, int, int]:
        return (0, 0, 2560, 1440)

    def monitors(self) -> list[dict[str, int]]:
        return [{"left": 0, "top": 0, "width": 2560, "height": 1440}] * 2

    def touch_capabilities(self) -> dict[str, int]:
        return {"digitizer": 0xC1, "max_touches": 10}

    def foreground_window(self) -> dict[str, Any]:
        return {"hwnd": 1, "class": "FakeGame", "title": "game"}

    def capture_screen(self, **kwargs: Any) -> win_desktop.Capture:
        self.calls.append(("capture", (), kwargs))
        return win_desktop.Capture(
            data=b"\xff\xd8fakejpeg", mime="image/jpeg", origin_x=0, origin_y=0,
            physical_width=2560, physical_height=1440, width=1280, height=720, nearly_black=False,
        )

    def __getattr__(self, name: str) -> Any:
        def record(*args: Any, **kwargs: Any) -> None:
            self.calls.append((name, args, kwargs))
        return record


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _wait_for(predicate: Any, timeout: float = 10) -> None:
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while not predicate():
        if loop.time() > end:
            raise AssertionError("等待超时")
        await asyncio.sleep(0.05)


def _text(result: Any) -> str:
    return "\n".join(c.text for c in result.content if getattr(c, "type", "") == "text")


@pytest.mark.asyncio
async def test_end_to_end(tmp_path: Path) -> None:
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    from websockets.asyncio.server import serve

    token = "t" * 32
    agent_port, mcp_port = _free_port(), _free_port()
    fleet = fleet_gateway.Fleet(token, fleet_gateway.LeaseTable(), tmp_path / "audit")
    mcp = fleet_gateway.build_mcp(fleet, "127.0.0.1", mcp_port)

    desktops: dict[str, FakeDesktop] = {}
    agent_tasks: list[asyncio.Task] = []

    async with serve(
        fleet.handle_agent, "127.0.0.1", agent_port,
        process_request=fleet.process_request, max_size=fleet_gateway.proto.MAX_FRAME_BYTES,
    ):
        server_task = asyncio.create_task(mcp.run_streamable_http_async())
        for name in ("pc-a", "pc-b"):
            cfg = fleet_agent.AgentConfig(
                gateway=f"ws://127.0.0.1:{agent_port}/agent", token=token, name=name,
                workdir=tmp_path / name, galdriver_exe=Path(sys.executable),
                galdriver_args=[str(FAKE_DRIVER)], seed_support_dir=None, seed_documents_dir=None,
            )
            desktops[name] = FakeDesktop()
            agent_tasks.append(asyncio.create_task(fleet_agent.Agent(cfg, desktops[name]).run_once()))
        await _wait_for(lambda: len(fleet.agents) == 2)

        # 错 token 被拒
        bad = fleet_agent.AgentConfig(
            gateway=f"ws://127.0.0.1:{agent_port}/agent", token="x" * 32, name="evil",
            workdir=tmp_path / "evil", galdriver_exe=None, galdriver_args=[],
            seed_support_dir=None, seed_documents_dir=None,
        )
        with pytest.raises(Exception, match="401"):
            await fleet_agent.Agent(bad, FakeDesktop()).run_once()
        # 机器名会拼进审计文件路径：带路径分隔符的名字被拒
        traversal = fleet_agent.AgentConfig(
            gateway=f"ws://127.0.0.1:{agent_port}/agent", token=token, name="..\\..\\evil",
            workdir=tmp_path / "evil2", galdriver_exe=None, galdriver_args=[],
            seed_support_dir=None, seed_documents_dir=None,
        )
        with pytest.raises(SystemExit, match="机器名不合法"):
            await fleet_agent.Agent(traversal, FakeDesktop()).run_once()
        assert sorted(fleet.agents) == ["pc-a", "pc-b"]
        assert fleet_gateway.MACHINE_NAME.fullmatch("小明-pc_2")

        try:
            await asyncio.sleep(0.3)
            async with streamablehttp_client(f"http://127.0.0.1:{mcp_port}/mcp") as (r, w, _):
                async with ClientSession(r, w) as s:
                    await s.initialize()
                    tools = {t.name for t in (await s.list_tools()).tools}
                    assert {"claim_machine", "screenshot", "touch", "galdriver", "put_file"} <= tools

                    rows = json.loads(_text(await s.call_tool("list_machines", {})))
                    assert [r["machine"] for r in rows] == ["pc-a", "pc-b"]
                    assert rows[0]["touch"]["digitizer"] == 0xC1

                    lease_a = json.loads(_text(await s.call_tool(
                        "claim_machine", {"machine": "pc-a", "holder": "siglus"})))["lease"]
                    denied = await s.call_tool("claim_machine", {"machine": "pc-a", "holder": "bgi"})
                    assert denied.isError and "siglus" in _text(denied)
                    lease_b = json.loads(_text(await s.call_tool(
                        "claim_machine", {"machine": "pc-b", "holder": "bgi"})))["lease"]
                    wrong = await s.call_tool("screenshot", {"machine": "pc-a", "lease": lease_b})
                    assert wrong.isError

                    # 截图 → 图片内容 + 元数据；之后截图坐标按 2 倍换算成物理坐标
                    shot = await s.call_tool("screenshot", {"machine": "pc-a", "lease": lease_a})
                    kinds = [c.type for c in shot.content]
                    assert kinds == ["image", "text"]
                    assert shot.content[0].mimeType == "image/jpeg"
                    clicked = await s.call_tool("click", {
                        "machine": "pc-a", "lease": lease_a, "x": 100, "y": 50, "screenshot_after": True,
                        "settle_ms": 0})
                    assert json.loads(clicked.content[0].text)["physical"] == [200, 100]
                    assert [c.type for c in clicked.content] == ["text", "image", "text"]
                    name, args, kwargs = [c for c in desktops["pc-a"].calls if c[0] == "mouse_click"][0]
                    assert args == (200, 100) and kwargs["button"] == "left"

                    # pc-b 没截过图：截图坐标无法换算，必须报错而不是乱点
                    nocap = await s.call_tool("click", {"machine": "pc-b", "lease": lease_b, "x": 1, "y": 1})
                    assert nocap.isError and "还没有截图" in _text(nocap)
                    await s.call_tool("touch", {"machine": "pc-b", "lease": lease_b, "action": "swipe",
                                                "x": 10, "y": 20, "x2": 300, "y2": 20, "coords": "physical"})
                    gesture = [c for c in desktops["pc-b"].calls if c[0] == "touch_gesture"][0]
                    assert gesture[1] == ([(10, 20), (300, 20)], 300)

                    ps = json.loads(_text(await s.call_tool("powershell", {
                        "machine": "pc-a", "lease": lease_a, "command": "Write-Output '日本語 ok'"})))
                    assert ps["exit_code"] == 0 and "日本語 ok" in ps["stdout"]

                    # 文件往返（跨块）
                    src = tmp_path / "big.bin"
                    payload = bytes(range(256)) * (fleet_gateway.proto.FILE_CHUNK // 256 + 300)
                    src.write_bytes(payload)
                    remote = str(tmp_path / "pc-a" / "in" / "big.bin")
                    await s.call_tool("put_file", {"machine": "pc-a", "lease": lease_a,
                                                   "local_path": str(src), "remote_path": remote})
                    back = tmp_path / "back.bin"
                    await s.call_tool("get_file", {"machine": "pc-a", "lease": lease_a,
                                                   "remote_path": remote, "local_path": str(back)})
                    assert back.read_bytes() == payload

                    # 驱动：启动 → 指令 → 停止
                    started = json.loads(_text(await s.call_tool(
                        "galdriver_start", {"machine": "pc-a", "lease": lease_a, "ready_timeout_s": 20})))
                    assert "home=true" in started["ready"]
                    res = json.loads(_text(await s.call_tool(
                        "galdriver", {"machine": "pc-a", "lease": lease_a, "command": "shot game"})))
                    assert res["new_shots"] == ["shot_1.png"]
                    stop = json.loads(_text(await s.call_tool(
                        "galdriver_stop", {"machine": "pc-a", "lease": lease_a})))
                    assert stop["how"] == "quit"

                    assert _text(await s.call_tool(
                        "release_machine", {"machine": "pc-a", "lease": lease_a})) == "released"
                    # 释放后别人可以拿
                    await s.call_tool("claim_machine", {"machine": "pc-a", "holder": "bgi"})

            audit = (tmp_path / "audit" / "pc-a.jsonl").read_text(encoding="utf-8")
            assert '"op": "click"' in audit and '"note": "siglus"' in audit
        finally:
            for t in agent_tasks:
                t.cancel()
            server_task.cancel()
            await asyncio.gather(*agent_tasks, server_task, return_exceptions=True)

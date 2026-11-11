"""远程适配机群：驱动宿主、网关 ↔ agent ↔ MCP 端到端。

    python -m pytest tool/remote_adapt/tests -q
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import socket
import ssl
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

FAKE_DRIVER = HERE / "fake_galdriver.py"


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
    fleet = fleet_gateway.Fleet(token, tmp_path / "audit")
    mcp = fleet_gateway.build_mcp(fleet, "127.0.0.1", mcp_port)
    cert_path, key_path = fleet_gateway.load_or_create_cert(tmp_path / "cert")
    pem = cert_path.read_text(encoding="ascii")
    url = f"wss://127.0.0.1:{agent_port}/agent"

    desktops: dict[str, FakeDesktop] = {}
    agent_tasks: list[asyncio.Task] = []

    async with serve(
        fleet.handle_agent, "127.0.0.1", agent_port,
        ssl=fleet_gateway.server_ssl_context(cert_path, key_path),
        process_request=fleet.process_request, max_size=fleet_gateway.proto.MAX_FRAME_BYTES,
    ):
        server_task = asyncio.create_task(mcp.run_streamable_http_async())
        for name in ("pc-a", "pc-b"):
            cfg = fleet_agent.AgentConfig(
                gateway=url, token=token, name=name,
                workdir=tmp_path / name, galdriver_exe=Path(sys.executable),
                galdriver_args=[str(FAKE_DRIVER)], seed_support_dir=None, seed_documents_dir=None,
                gateway_cert=pem,
            )
            desktops[name] = FakeDesktop()
            agent_tasks.append(asyncio.create_task(fleet_agent.Agent(cfg, desktops[name]).run_once()))
        await _wait_for(lambda: len(fleet.agents) == 2)

        # 错 token 被拒
        bad = fleet_agent.AgentConfig(
            gateway=url, token="x" * 32, name="evil",
            workdir=tmp_path / "evil", galdriver_exe=None, galdriver_args=[],
            seed_support_dir=None, seed_documents_dir=None, gateway_cert=pem,
        )
        with pytest.raises(Exception, match="401"):
            await fleet_agent.Agent(bad, FakeDesktop()).run_once()
        # 机器名会拼进审计文件路径：带路径分隔符的名字被拒
        traversal = fleet_agent.AgentConfig(
            gateway=url, token=token, name="..\\..\\evil",
            workdir=tmp_path / "evil2", galdriver_exe=None, galdriver_args=[],
            seed_support_dir=None, seed_documents_dir=None, gateway_cert=pem,
        )
        with pytest.raises(SystemExit, match="机器名不合法"):
            await fleet_agent.Agent(traversal, FakeDesktop()).run_once()
        # 冒充的网关（证书不是打包时固定的那张）：TLS 握手失败，agent 不会把 token 发过去
        other_cert, _ = fleet_gateway.load_or_create_cert(tmp_path / "other-cert")
        spoofed = fleet_agent.AgentConfig(
            gateway=url, token=token, name="pc-c", workdir=tmp_path / "pc-c", galdriver_exe=None,
            galdriver_args=[], seed_support_dir=None, seed_documents_dir=None,
            gateway_cert=other_cert.read_text(encoding="ascii"),
        )
        with pytest.raises(ssl.SSLCertVerificationError):
            await fleet_agent.Agent(spoofed, FakeDesktop()).run_once()
        # 明文 ws:// 直接拒绝
        plain = fleet_agent.AgentConfig(
            gateway=f"ws://127.0.0.1:{agent_port}/agent", token=token, name="pc-d",
            workdir=tmp_path / "pc-d", galdriver_exe=None, galdriver_args=[],
            seed_support_dir=None, seed_documents_dir=None, gateway_cert=pem,
        )
        with pytest.raises(SystemExit, match="wss://"):
            await fleet_agent.Agent(plain, FakeDesktop()).run_once()
        assert sorted(fleet.agents) == ["pc-a", "pc-b"]
        assert fleet_gateway.MACHINE_NAME.fullmatch("小明-pc_2")

        try:
            await asyncio.sleep(0.3)
            async with streamablehttp_client(f"http://127.0.0.1:{mcp_port}/mcp") as (r, w, _):
                async with ClientSession(r, w) as s:
                    await s.initialize()
                    tools = {t.name for t in (await s.list_tools()).tools}
                    assert {"list_machines", "screenshot", "touch", "galdriver", "put_file"} <= tools

                    rows = json.loads(_text(await s.call_tool("list_machines", {})))
                    assert [r["machine"] for r in rows] == ["pc-a", "pc-b"]
                    assert rows[0]["touch"]["digitizer"] == 0xC1

                    # 不存在的机器：报错并列出在线机器
                    missing = await s.call_tool("screenshot", {"machine": "pc-z"})
                    assert missing.isError and "pc-a, pc-b" in _text(missing)
                    # 一个会话并行操作两台机器
                    both = await asyncio.gather(
                        s.call_tool("machine_info", {"machine": "pc-a"}),
                        s.call_tool("machine_info", {"machine": "pc-b"}),
                    )
                    assert all(not r.isError for r in both)

                    # 截图 → 图片内容 + 元数据；之后截图坐标按 2 倍换算成物理坐标
                    shot = await s.call_tool("screenshot", {"machine": "pc-a"})
                    kinds = [c.type for c in shot.content]
                    assert kinds == ["image", "text"]
                    assert shot.content[0].mimeType == "image/jpeg"
                    clicked = await s.call_tool("click", {
                        "machine": "pc-a", "x": 100, "y": 50, "screenshot_after": True,
                        "settle_ms": 0})
                    assert json.loads(clicked.content[0].text)["physical"] == [200, 100]
                    assert [c.type for c in clicked.content] == ["text", "image", "text"]
                    name, args, kwargs = [c for c in desktops["pc-a"].calls if c[0] == "mouse_click"][0]
                    assert args == (200, 100) and kwargs["button"] == "left"

                    # pc-b 没截过图：截图坐标无法换算，必须报错而不是乱点
                    nocap = await s.call_tool("click", {"machine": "pc-b", "x": 1, "y": 1})
                    assert nocap.isError and "还没有截图" in _text(nocap)
                    await s.call_tool("touch", {"machine": "pc-b", "action": "swipe",
                                                "x": 10, "y": 20, "x2": 300, "y2": 20, "coords": "physical"})
                    gesture = [c for c in desktops["pc-b"].calls if c[0] == "touch_gesture"][0]
                    assert gesture[1] == ([(10, 20), (300, 20)], 300)

                    ps = json.loads(_text(await s.call_tool("powershell", {
                        "machine": "pc-a", "command": "Write-Output '日本語 ok'"})))
                    assert ps["exit_code"] == 0 and "日本語 ok" in ps["stdout"]

                    # 文件往返（跨块）
                    src = tmp_path / "big.bin"
                    payload = bytes(range(256)) * (fleet_gateway.proto.FILE_CHUNK // 256 + 300)
                    src.write_bytes(payload)
                    remote = str(tmp_path / "pc-a" / "in" / "big.bin")
                    await s.call_tool("put_file", {"machine": "pc-a",
                                                   "local_path": str(src), "remote_path": remote})
                    back = tmp_path / "back.bin"
                    await s.call_tool("get_file", {"machine": "pc-a",
                                                   "remote_path": remote, "local_path": str(back)})
                    assert back.read_bytes() == payload

                    # 驱动：启动 → 指令 → 停止
                    started = json.loads(_text(await s.call_tool(
                        "galdriver_start", {"machine": "pc-a", "ready_timeout_s": 20})))
                    assert "home=true" in started["ready"]
                    res = json.loads(_text(await s.call_tool(
                        "galdriver", {"machine": "pc-a", "command": "shot game"})))
                    assert res["new_shots"] == ["shot_1.png"]
                    stop = json.loads(_text(await s.call_tool(
                        "galdriver_stop", {"machine": "pc-a"})))
                    assert stop["how"] == "quit"


            audit = (tmp_path / "audit" / "pc-a.jsonl").read_text(encoding="utf-8")
            assert '"op": "click"' in audit and '"op": "connect"' in audit
        finally:
            for t in agent_tasks:
                t.cancel()
            server_task.cancel()
            await asyncio.gather(*agent_tasks, server_task, return_exceptions=True)


def test_log_never_blocks_event_loop_when_console_is_stuck(monkeypatch: pytest.MonkeyPatch) -> None:
    """快速编辑选择态下写控制台会挂起；log() 只入队，不能把阻塞带进 asyncio 循环。"""
    import queue as _queue
    import time as _time

    stuck: "_queue.Queue[str]" = _queue.Queue(maxsize=3)  # 没有消费者 = 控制台一直卡着
    monkeypatch.setattr(fleet_agent, "_LOG_QUEUE", stuck)
    monkeypatch.setattr(fleet_agent, "_log_dropped", 0)
    start = _time.monotonic()
    for i in range(50):
        fleet_agent.log(f"line {i}")
    assert _time.monotonic() - start < 0.5
    assert stuck.qsize() == 3
    assert fleet_agent._log_dropped == 47


def test_disable_console_quick_edit_without_console_is_harmless() -> None:
    # pytest 下 stdin 不是控制台：应安静返回 False，而不是抛错。
    assert fleet_agent.disable_console_quick_edit() in (True, False)


def test_self_update_command_survives_non_ascii_and_quotes() -> None:
    import base64 as _b64

    new_exe = Path(r"X:\fushi-adapt-志愿者-20261111\work\new agent's.exe")
    cur = Path(r"X:\fushi-adapt-志愿者-20261111\双击开始适配.exe")
    encoded = fleet_agent.self_update_command(1234, new_exe, cur)
    script = _b64.b64decode(encoded).decode("utf-16-le")
    assert "Wait-Process -Id 1234" in script
    assert r"'X:\fushi-adapt-志愿者-20261111\work\new agent''s.exe'" in script
    assert r"Start-Process -FilePath 'X:\fushi-adapt-志愿者-20261111\双击开始适配.exe'" in script

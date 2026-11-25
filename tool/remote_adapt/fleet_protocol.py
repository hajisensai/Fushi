"""网关 ↔ agent 的线协议（WebSocket 文本帧，JSON）。

    agent 连上后先发   {"type": "hello", "protocol": N, "name": ..., "info": {...}}
    网关请求           {"type": "req", "id": 7, "op": "click", "args": {...}}
    agent 应答         {"type": "res", "id": 7, "ok": true, "result": {...}}
                       {"type": "res", "id": 7, "ok": false, "error": "..."}

二进制（截图、文件块）放进 result / args 的 base64 字段。协议版本不一致时网关拒绝
连接并把原因发回 agent，agent 打印后退出，不静默降级。
"""

from __future__ import annotations

import base64
import json
from typing import Any

PROTOCOL_VERSION = 1

# 单帧上限。文件按 FILE_CHUNK 切块，base64 后约 1.34 倍，远低于上限。
MAX_FRAME_BYTES = 32 * 1024 * 1024
FILE_CHUNK = 4 * 1024 * 1024

AGENT_PATH = "/agent"


def encode(message: dict[str, Any]) -> str:
    return json.dumps(message, ensure_ascii=False, separators=(",", ":"))


def decode(raw: str | bytes) -> dict[str, Any]:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    value = json.loads(raw)
    if not isinstance(value, dict) or "type" not in value:
        raise ValueError(f"不是协议消息: {str(raw)[:200]}")
    return value


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))


def pinned_client_context(cert_pem: str) -> "ssl.SSLContext":
    """agent 只信任打包时写进 agent.json 的那一张网关证书（自签，不依赖公共 CA）。

    走公网时网关可能被 DNS 劫持或中间人冒充；冒充者能让 agent 以管理员身份执行任意命令，
    所以必须验证服务端身份。证书已固定，主机名无需再比对。
    """
    import ssl

    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cadata=cert_pem)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx

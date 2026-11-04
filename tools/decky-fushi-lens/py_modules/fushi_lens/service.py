"""Fushi Lens state: the paired host, captured frames, and the local web server.

The Lens screen inside Steam is a web page (an iframe in the plugin's Steam
route). It cannot talk to the Fushi host directly: the host's self-signed
certificate would be rejected by Steam's browser, and the device token must not
live in page script. So the page talks to a small HTTP server on 127.0.0.1 run
by this backend, and this backend talks to the host with the pinned certificate
and the token. Every URL carries a random per-run secret path segment, so other
local programs or pages cannot use the server.

Page-facing routes (all under /s/<secret>/):
  GET  web/<file>          static Lens page and Fushi popup assets
  GET  frame/<id>.jpg      a captured frame
  POST capture             grab the screen now -> {frameId, width, height}
  POST ocr                 {frameId, region?} -> the host's /api/ocr/screen reply
  GET|POST api/<path>      forwarded to the host's /api/<path> (allowlist only)
  GET  status              {paired, host}
"""

from __future__ import annotations

import json
import mimetypes
import os
import secrets
import threading
import uuid
from collections import OrderedDict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, Optional, Tuple
from urllib.parse import parse_qsl, urlencode, urlsplit

from .capture import CaptureError, capture_jpeg
from .host import HostClient, HostError

# Host endpoints the popup and the Lens page may reach through the proxy. The
# same set Fushi's browser extension uses for lookups and mining.
FORWARD_POST = {
    "lookup/dictionary",
    "lookup/dictionary/styles",
    "lookup/dictionary/media",
    "lookup/audio",
    "lookup/audio/list",
    "mine",
    "duplicate",
    "srs/term-status",
    "srs/term-status-batch",
}
FORWARD_GET = {"lookup/audio/file", "media/dictionary"}

MAX_FRAMES = 12
MAX_BODY_BYTES = 32 * 1024 * 1024


def jpeg_size(data: bytes) -> Tuple[int, int]:
    """(width, height) from a JPEG's SOF marker; (0, 0) if not found."""
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            return 0, 0
        marker = data[i + 1]
        length = int.from_bytes(data[i + 2 : i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            height = int.from_bytes(data[i + 5 : i + 7], "big")
            width = int.from_bytes(data[i + 7 : i + 9], "big")
            return width, height
        i += 2 + length
    return 0, 0


class ConfigStore:
    """The pairing (host address, pinned fingerprint, token) in one JSON file."""

    def __init__(self, path: str) -> None:
        self.path = path

    def load(self) -> Dict[str, Any]:
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self, data: Dict[str, Any]) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)


class LensService:
    def __init__(
        self,
        config: ConfigStore,
        web_root: str,
        *,
        capture: Callable[[], bytes] = capture_jpeg,
        device_name: str = "Steam Deck (Fushi Lens)",
    ) -> None:
        self._config = config
        self._web_root = os.path.realpath(web_root)
        self._capture = capture
        self._device_name = device_name
        self._lock = threading.Lock()
        self._frames: "OrderedDict[str, bytes]" = OrderedDict()
        self._pending_pair: Optional[Tuple[HostClient, Dict[str, Any]]] = None
        self._secret = secrets.token_urlsafe(24)
        self._server: Optional[ThreadingHTTPServer] = None
        data = config.load()
        self._device_id = data.get("deviceId") or str(uuid.uuid4())
        self._host: Optional[HostClient] = None
        if data.get("hostUrl") and data.get("token") and data.get("fingerprint") is not None:
            self._host = HostClient(data["hostUrl"], fingerprint=data["fingerprint"] or None, token=data["token"])

    # ── pairing ───────────────────────────────────────────────────────

    def status(self) -> Dict[str, Any]:
        host = self._host
        return {
            "paired": host is not None,
            "host": host.base_url if host else None,
            "pairing": self._pending_pair is not None,
            "lensUrl": self.lens_url(),
        }

    def begin_pairing(self, address: str) -> Dict[str, Any]:
        client = HostClient(address)
        session = client.start_pairing(self._device_name, self._device_id)
        self._pending_pair = (client, session)
        return {"pinRequired": session["pinRequired"], "host": client.base_url, "fingerprint": client.fingerprint}

    def finish_pairing(self, pin: Optional[str]) -> Dict[str, Any]:
        pending = self._pending_pair
        if pending is None:
            raise HostError("no_pairing")
        client, session = pending
        try:
            client.confirm_pairing(session, pin)
        finally:
            self._pending_pair = None
        self._host = client
        self._config.save(
            {
                "deviceId": self._device_id,
                "hostUrl": client.base_url,
                "fingerprint": client.fingerprint or "",
                "token": client.token,
            }
        )
        return self.status()

    def unpair(self) -> Dict[str, Any]:
        self._host = None
        self._config.save({"deviceId": self._device_id})
        return self.status()

    def _require_host(self) -> HostClient:
        host = self._host
        if host is None:
            raise HostError("unpaired")
        return host

    # ── frames ────────────────────────────────────────────────────────

    def capture(self) -> Dict[str, Any]:
        data = self._capture()
        frame_id = secrets.token_hex(8)
        with self._lock:
            self._frames[frame_id] = data
            while len(self._frames) > MAX_FRAMES:
                self._frames.popitem(last=False)
        width, height = jpeg_size(data)
        return {"frameId": frame_id, "width": width, "height": height}

    def frame(self, frame_id: str) -> Optional[bytes]:
        with self._lock:
            return self._frames.get(frame_id)

    def ocr(self, frame_id: str, region: Optional[str] = None) -> Dict[str, Any]:
        data = self.frame(frame_id)
        if data is None:
            raise HostError("no_frame")
        return self._require_host().screen_ocr(data, "image/jpeg", region)

    # ── local web server ──────────────────────────────────────────────

    def start_server(self, port: int = 0) -> str:
        if self._server is None:
            handler = _make_handler(self)
            self._server = ThreadingHTTPServer(("127.0.0.1", port), handler)
            self._server.daemon_threads = True
            threading.Thread(target=self._server.serve_forever, name="fushi-lens-http", daemon=True).start()
        return self.lens_url() or ""

    def stop_server(self) -> None:
        server = self._server
        self._server = None
        if server is not None:
            server.shutdown()
            server.server_close()

    def base_url(self) -> Optional[str]:
        if self._server is None:
            return None
        return f"http://127.0.0.1:{self._server.server_address[1]}/s/{self._secret}/"

    def lens_url(self) -> Optional[str]:
        base = self.base_url()
        return base + "web/lens.html" if base else None

    # used by the handler
    @property
    def secret(self) -> str:
        return self._secret

    def static_file(self, rel: str) -> Optional[str]:
        path = os.path.realpath(os.path.join(self._web_root, rel))
        if not path.startswith(self._web_root + os.sep) or not os.path.isfile(path):
            return None
        return path

    def forward(self, method: str, api_path: str, query: str, body: Optional[bytes], content_type: Optional[str]):
        host = self._require_host()
        headers = {"Content-Type": content_type} if content_type else {}
        # The page never holds the device token; requests are authenticated
        # here with Basic auth, so drop any placeholder `token=` the popup's
        # media URLs carry.
        query = urlencode([(k, v) for k, v in parse_qsl(query, keep_blank_values=True) if k != "token"])
        return host.request(method, "/api/" + api_path + (f"?{query}" if query else ""), body, headers)


def _make_handler(service: LensService):
    class Handler(BaseHTTPRequestHandler):
        server_version = "FushiLens/1"

        def log_message(self, fmt: str, *args: Any) -> None:  # quiet
            pass

        def _send(self, status: int, body: bytes, content_type: str, extra: Optional[Dict[str, str]] = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, status: int, payload: Any) -> None:
            self._send(status, json.dumps(payload).encode("utf-8"), "application/json")

        def _error(self, e: Exception) -> None:
            if isinstance(e, HostError):
                status = HTTPStatus.UNAUTHORIZED if e.reason in ("unpaired", "unauthorized") else HTTPStatus.BAD_GATEWAY
                self._json(status, {"error": e.reason, "detail": e.detail})
            elif isinstance(e, CaptureError):
                self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "capture", "detail": str(e)})
            else:
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "internal", "detail": str(e)})

        def _route(self) -> Optional[Tuple[str, str]]:
            parts = urlsplit(self.path)
            prefix = f"/s/{service.secret}/"
            if not parts.path.startswith(prefix):
                return None
            return parts.path[len(prefix) :], parts.query

        def _body(self) -> Optional[bytes]:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY_BYTES:
                return None
            return self.rfile.read(length) if length else b""

        def do_GET(self) -> None:  # noqa: N802
            route = self._route()
            if route is None:
                self._send(404, b"not found", "text/plain")
                return
            rel, query = route
            try:
                if rel == "status":
                    self._json(200, service.status())
                elif rel.startswith("web/"):
                    path = service.static_file(rel[4:])
                    if path is None:
                        self._send(404, b"not found", "text/plain")
                        return
                    with open(path, "rb") as f:
                        data = f.read()
                    ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
                    if ctype.startswith("text/") or ctype.endswith("javascript"):
                        ctype += "; charset=utf-8"
                    self._send(200, data, ctype)
                elif rel.startswith("frame/") and rel.endswith(".jpg"):
                    data = service.frame(rel[len("frame/") : -len(".jpg")])
                    if data is None:
                        self._send(404, b"no such frame", "text/plain")
                    else:
                        self._send(200, data, "image/jpeg")
                elif rel.startswith("api/") and rel[4:] in FORWARD_GET:
                    res = service.forward("GET", rel[4:], query, None, None)
                    self._send(res.status, res.body, res.headers.get("content-type", "application/octet-stream"))
                else:
                    self._send(404, b"not found", "text/plain")
            except Exception as e:  # noqa: BLE001 - request boundary
                self._error(e)

        do_HEAD = do_GET

        def do_POST(self) -> None:  # noqa: N802
            route = self._route()
            if route is None:
                self._send(404, b"not found", "text/plain")
                return
            rel, query = route
            body = self._body()
            if body is None:
                self._send(413, b"too large", "text/plain")
                return
            try:
                if rel == "capture":
                    self._json(200, service.capture())
                elif rel == "ocr":
                    req = json.loads(body.decode("utf-8") or "{}")
                    self._json(200, service.ocr(str(req.get("frameId", "")), req.get("region")))
                elif rel.startswith("api/") and rel[4:] in FORWARD_POST:
                    res = service.forward("POST", rel[4:], query, body, self.headers.get("Content-Type"))
                    self._send(res.status, res.body, res.headers.get("content-type", "application/json"))
                else:
                    self._send(404, b"not found", "text/plain")
            except Exception as e:  # noqa: BLE001 - request boundary
                self._error(e)

    return Handler

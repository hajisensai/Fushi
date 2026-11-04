"""Talking to a paired Fushi host (the desktop app or fushi_server).

Fushi hosts serve HTTPS with a self-signed certificate. Trust is the
certificate's SHA-256 fingerprint, pinned at pairing time (trust on first use),
the same rule the Fushi clients follow (`fushi_pinning_http.dart`). After
pairing, every request carries the per-device token as the Basic password.

Pairing is Fushi's pair/v2 protocol (`fushi_pair_v2_client.dart`):
POST /api/pair/v2 {name, clientNonce, clientDeviceId} -> {sessionId, hostNonce,
pinRequired}; then POST /api/pair/v2/confirm {sessionId, pinProof} where
pinProof = hex(HMAC-SHA256(PIN, clientNonce + "|" + hostNonce)). The PIN never
goes over the wire, and the host also asks its user to approve the device.

Standard library only: Decky runs plugin backends on its own bundled Python.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.client
import json
import secrets
import ssl
from dataclasses import dataclass
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlsplit


class HostError(Exception):
    """A request to the host failed; `reason` is machine-readable."""

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


def fingerprint_of_der(der: bytes) -> str:
    """SHA-256 of a DER certificate as colon-separated lowercase hex."""
    digest = hashlib.sha256(der).digest()
    return ":".join(f"{b:02x}" for b in digest)


def normalize_fingerprint(value: str) -> str:
    return "".join(value.split()).replace(":", "").lower()


def generate_nonce() -> str:
    """24 random bytes, base64url without padding (same as the Dart client)."""
    return base64.urlsafe_b64encode(secrets.token_bytes(24)).decode("ascii").rstrip("=")


def compute_pin_proof(pin: str, client_nonce: str, host_nonce: str) -> str:
    message = f"{client_nonce}|{host_nonce}".encode("utf-8")
    return hmac.new(pin.encode("utf-8"), message, hashlib.sha256).hexdigest()


def normalize_base_url(value: str) -> str:
    """Accepts `host`, `host:port`, or a full http(s) URL; defaults to https:38765."""
    text = value.strip().rstrip("/")
    if not text:
        raise HostError("address", "empty address")
    if "://" not in text:
        text = "https://" + text
    parts = urlsplit(text)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise HostError("address", value)
    port = parts.port or 38765
    host = parts.hostname
    if ":" in host:  # IPv6 literal
        host = f"[{host}]"
    return f"{parts.scheme}://{host}:{port}"


@dataclass
class Response:
    status: int
    headers: Dict[str, str]
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


class HostClient:
    """One host address, optionally pinned to a certificate fingerprint."""

    def __init__(
        self,
        base_url: str,
        *,
        fingerprint: Optional[str] = None,
        token: Optional[str] = None,
        timeout: float = 15.0,
    ) -> None:
        self.base_url = normalize_base_url(base_url)
        self.fingerprint = fingerprint
        self.token = token
        self.timeout = timeout

    # ── transport ─────────────────────────────────────────────────────

    def _connection(self) -> Tuple[http.client.HTTPConnection, str]:
        parts = urlsplit(self.base_url)
        if parts.scheme == "http":
            return http.client.HTTPConnection(parts.hostname, parts.port, timeout=self.timeout), ""
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # Self-signed host certificate: chain validation is replaced by the
        # fingerprint check in `request` (pinning), exactly like the Dart client.
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        return (
            http.client.HTTPSConnection(parts.hostname, parts.port, timeout=self.timeout, context=context),
            "https",
        )

    def request(
        self,
        method: str,
        path: str,
        body: Optional[bytes] = None,
        headers: Optional[Dict[str, str]] = None,
        *,
        authenticated: bool = True,
    ) -> Response:
        conn, scheme = self._connection()
        try:
            try:
                conn.connect()
            except OSError as e:
                raise HostError("unreachable", str(e)) from e
            if scheme == "https":
                der = conn.sock.getpeercert(binary_form=True)  # type: ignore[union-attr]
                actual = fingerprint_of_der(der or b"")
                if self.fingerprint is None:
                    # First contact (pairing): remember what we saw; pairing
                    # then checks it against the host's own report.
                    self.fingerprint = actual
                elif normalize_fingerprint(actual) != normalize_fingerprint(self.fingerprint):
                    raise HostError("tls", "host certificate changed")
            all_headers = dict(headers or {})
            if authenticated:
                if not self.token:
                    raise HostError("unpaired")
                basic = base64.b64encode(f"fushi-lens:{self.token}".encode("utf-8")).decode("ascii")
                all_headers["Authorization"] = f"Basic {basic}"
            try:
                conn.request(method, path, body=body, headers=all_headers)
                raw = conn.getresponse()
                data = raw.read()
            except (OSError, http.client.HTTPException) as e:
                raise HostError("unreachable", str(e)) from e
            return Response(raw.status, {k.lower(): v for k, v in raw.getheaders()}, data)
        finally:
            conn.close()

    def post_json(self, path: str, payload: Any, *, authenticated: bool = True) -> Response:
        return self.request(
            "POST",
            path,
            json.dumps(payload).encode("utf-8"),
            {"Content-Type": "application/json"},
            authenticated=authenticated,
        )

    # ── pairing ───────────────────────────────────────────────────────

    def start_pairing(self, device_name: str, device_id: str) -> Dict[str, Any]:
        """Step 1. Returns {sessionId, hostNonce, pinRequired, clientNonce}."""
        client_nonce = generate_nonce()
        res = self.post_json(
            "/api/pair/v2",
            {"name": device_name, "clientNonce": client_nonce, "clientDeviceId": device_id},
            authenticated=False,
        )
        if res.status != 200:
            raise HostError(_reason_of(res, {403: "unavailable", 429: "rate_limited"}.get(res.status, "error")))
        body = res.json()
        if not body.get("sessionId") or not body.get("hostNonce"):
            raise HostError("error", "pairing session missing fields")
        return {
            "sessionId": body["sessionId"],
            "hostNonce": body["hostNonce"],
            "pinRequired": body.get("pinRequired", True) is not False,
            "clientNonce": client_nonce,
        }

    def confirm_pairing(self, session: Dict[str, Any], pin: Optional[str]) -> str:
        """Step 2. Returns the per-device token and stores it on this client."""
        payload: Dict[str, Any] = {"sessionId": session["sessionId"]}
        if session["pinRequired"]:
            if not pin:
                raise HostError("pin")
            payload["pinProof"] = compute_pin_proof(pin, session["clientNonce"], session["hostNonce"])
        res = self.post_json("/api/pair/v2/confirm", payload, authenticated=False)
        if res.status != 200:
            raise HostError(
                _reason_of(res, {401: "pin", 403: "declined", 429: "rate_limited"}.get(res.status, "error"))
            )
        body = res.json()
        token = body.get("token")
        if not token:
            raise HostError("error", "no token in pairing reply")
        reported = body.get("hostFingerprint")
        if reported and self.fingerprint and normalize_fingerprint(reported) != normalize_fingerprint(self.fingerprint):
            # The certificate we talked to is not the one the host says it has:
            # someone is in the middle. Do not keep the token.
            raise HostError("tls", "fingerprint mismatch during pairing")
        self.token = token
        return token

    # ── API helpers ───────────────────────────────────────────────────

    def capabilities(self) -> Dict[str, Any]:
        res = self.request("GET", "/api/capabilities")
        if res.status == 401:
            raise HostError("unauthorized")
        if res.status != 200:
            raise HostError("error", f"capabilities HTTP {res.status}")
        return res.json()

    def screen_ocr(self, image: bytes, content_type: str, region: Optional[str] = None) -> Dict[str, Any]:
        path = "/api/ocr/screen" + (f"?region={region}" if region else "")
        res = self.request("POST", path, image, {"Content-Type": content_type})
        if res.status != 200:
            raise HostError(
                {401: "unauthorized", 404: "no_screen_ocr", 503: "ocr_unavailable"}.get(res.status, "error"),
                res.body.decode("utf-8", "replace")[:200],
            )
        return res.json()


def _reason_of(res: Response, fallback: str) -> str:
    try:
        reason = res.json().get("reason")
        if isinstance(reason, str) and reason:
            return reason
    except (ValueError, AttributeError):
        pass
    return fallback

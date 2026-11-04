"""Unit tests for the Fushi Lens backend (stdlib only).

  python -m unittest discover -s tools/decky-fushi-lens/tests
"""

from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "py_modules"))

from fushi_lens import capture, host, paddles, service  # noqa: E402


def _jpeg(width: int, height: int) -> bytes:
    # SOI, APP0 (16 bytes), SOF0 with the size, EOI. Enough for jpeg_size.
    app0 = b"\xff\xe0" + (16).to_bytes(2, "big") + b"JFIF\x00" + b"\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0" + (17).to_bytes(2, "big") + b"\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big")
    sof += b"\x03" + b"\x01\x11\x00\x02\x11\x01\x03\x11\x01"
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


class HostProtocolTest(unittest.TestCase):
    def test_pin_proof_matches_dart_client(self):
        # fushi_pair_v2_client.dart: hex(HMAC-SHA256(key = PIN, msg = clientNonce|hostNonce)).
        expected = hmac.new(b"123456", b"abc|xyz", hashlib.sha256).hexdigest()
        self.assertEqual(host.compute_pin_proof("123456", "abc", "xyz"), expected)

    def test_nonce_is_unpadded_base64url_of_24_bytes(self):
        nonce = host.generate_nonce()
        self.assertEqual(len(nonce), 32)
        self.assertNotIn("=", nonce)
        self.assertTrue(set(nonce) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))

    def test_fingerprint_format_and_normalization(self):
        fp = host.fingerprint_of_der(b"cert")
        self.assertEqual(fp.count(":"), 31)
        self.assertEqual(host.normalize_fingerprint(fp.upper()), hashlib.sha256(b"cert").hexdigest())

    def test_base_url_defaults(self):
        self.assertEqual(host.normalize_base_url("192.168.1.5"), "https://192.168.1.5:38765")
        self.assertEqual(host.normalize_base_url("pc.local:9000/"), "https://pc.local:9000")
        self.assertEqual(host.normalize_base_url("http://10.0.0.2:1"), "http://10.0.0.2:1")
        self.assertEqual(host.normalize_base_url("fe80::1".join("[]")), "https://[fe80::1]:38765")
        with self.assertRaises(host.HostError):
            host.normalize_base_url("  ")
        with self.assertRaises(host.HostError):
            host.normalize_base_url("ftp://x")


class FakeHost(host.HostClient):
    """Records requests and answers from a table instead of the network."""

    def __init__(self, replies):
        super().__init__("192.168.1.5", fingerprint="aa:bb", token="tok")
        self.replies = replies
        self.calls = []

    def request(self, method, path, body=None, headers=None, *, authenticated=True, timeout=None):
        self.calls.append((method, path, body, dict(headers or {}), authenticated, timeout))
        status, payload = self.replies.get(path.split("?")[0], (404, {}))
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return host.Response(status, {"content-type": "application/json"}, data)


class PairingTest(unittest.TestCase):
    def test_confirm_sends_proof_and_rejects_fingerprint_mismatch(self):
        client = FakeHost({"/api/pair/v2/confirm": (200, {"token": "t1", "hostFingerprint": "AA:BB"})})
        session = {"sessionId": "s", "hostNonce": "h", "clientNonce": "c", "pinRequired": True}
        self.assertEqual(client.confirm_pairing(session, "4321"), "t1")
        payload = json.loads(client.calls[0][2])
        self.assertEqual(payload["pinProof"], host.compute_pin_proof("4321", "c", "h"))
        self.assertFalse(client.calls[0][4])
        # The host holds confirm open until its user approves: wait like the Dart client.
        self.assertEqual(client.calls[0][5], host.PAIRING_TIMEOUT_S)

        evil = FakeHost({"/api/pair/v2/confirm": (200, {"token": "t2", "hostFingerprint": "cc:dd"})})
        evil.token = None
        with self.assertRaises(host.HostError) as err:
            evil.confirm_pairing(session, "4321")
        self.assertEqual(err.exception.reason, "tls")
        self.assertIsNone(evil.token)

    def test_wrong_pin_and_missing_pin(self):
        client = FakeHost({"/api/pair/v2/confirm": (401, {})})
        session = {"sessionId": "s", "hostNonce": "h", "clientNonce": "c", "pinRequired": True}
        with self.assertRaises(host.HostError) as err:
            client.confirm_pairing(session, "0000")
        self.assertEqual(err.exception.reason, "pin")
        with self.assertRaises(host.HostError):
            client.confirm_pairing(session, None)

    def test_screen_ocr_error_reasons(self):
        for status, reason in ((404, "no_screen_ocr"), (503, "ocr_unavailable"), (401, "unauthorized")):
            client = FakeHost({"/api/ocr/screen": (status, b"x")})
            with self.assertRaises(host.HostError) as err:
                client.screen_ocr(b"img", "image/jpeg")
            self.assertEqual(err.exception.reason, reason)
        for status, body, reason in (
            (403, {"reason": "lens_consent"}, "lens_consent"),
            (502, {"reason": "engine_failed", "detail": "offline"}, "engine_failed"),
            (403, b"not json", "error"),
        ):
            client = FakeHost({"/api/ocr/screen": (status, body)})
            with self.assertRaises(host.HostError) as err:
                client.screen_ocr(b"img", "image/jpeg")
            self.assertEqual(err.exception.reason, reason)
        ok = FakeHost({"/api/ocr/screen": (200, {"lines": []})})
        self.assertEqual(ok.screen_ocr(b"img", "image/jpeg", "1,2,3,4"), {"lines": []})
        self.assertEqual(ok.calls[0][1], "/api/ocr/screen?region=1,2,3,4")


class CaptureTest(unittest.TestCase):
    @unittest.skipUnless(hasattr(os, "getuid"), "capture runs on Linux only")
    def test_env_drops_bundled_library_paths(self):
        env = capture.capture_env({"LD_LIBRARY_PATH": "/tmp/_MEI", "PYTHONHOME": "x", "PATH": "/usr/bin"})
        self.assertNotIn("LD_LIBRARY_PATH", env)
        self.assertNotIn("PYTHONHOME", env)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertIn("XDG_RUNTIME_DIR", env)

    def test_command_targets_gamescope_once(self):
        cmd = capture.capture_command("gst-launch-1.0")
        self.assertIn("target-object=gamescope", cmd)
        self.assertIn("num-buffers=1", cmd)
        self.assertEqual(cmd[-2:], ["fdsink", "fd=1"])


class PaddleTest(unittest.TestCase):
    @staticmethod
    def report(low=0, high=0, kind=paddles.DECK_STATE):
        r = bytearray(64)
        r[0], r[2], r[3] = 1, kind, 64
        r[8:12] = low.to_bytes(4, "little")
        r[12:16] = high.to_bytes(4, "little")
        return bytes(r)

    def test_back_buttons(self):
        self.assertEqual(paddles.pressed_buttons(self.report(high=0x200)), frozenset({"L4"}))
        self.assertEqual(paddles.pressed_buttons(self.report(high=0x400)), frozenset({"R4"}))
        self.assertEqual(paddles.pressed_buttons(self.report(low=0x8000 | 0x10000)), frozenset({"L5", "R5"}))
        # D-pad right/left share L4/R4's bit values but live in the low word.
        self.assertEqual(paddles.pressed_buttons(self.report(low=0x200 | 0x400)), frozenset())
        self.assertIsNone(paddles.pressed_buttons(self.report(kind=1)))
        self.assertIsNone(paddles.pressed_buttons(b"\x01\x00"))

    def test_hidraw_discovery(self):
        with tempfile.TemporaryDirectory() as root:
            for name, hid in (("hidraw0", "0003:0000046D:0000C52B"), ("hidraw2", "0003:000028DE:00001205")):
                os.makedirs(os.path.join(root, name, "device"))
                with open(os.path.join(root, name, "device", "uevent"), "w") as f:
                    f.write(f"DRIVER=hid-steam\nHID_ID={hid}\n")
            self.assertEqual(paddles.deck_hidraw_nodes(root), ["/dev/hidraw2"])

    def test_unknown_button_rejected(self):
        with self.assertRaises(ValueError):
            paddles.PaddleWatcher(lambda b: None, "A")


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.web = os.path.join(self.tmp.name, "web")
        os.makedirs(self.web)
        with open(os.path.join(self.web, "lens.html"), "w") as f:
            f.write("<p>lens</p>")
        with open(os.path.join(self.tmp.name, "secret.txt"), "w") as f:
            f.write("no")
        self.config = service.ConfigStore(os.path.join(self.tmp.name, "cfg", "lens.json"))
        self.svc = service.LensService(self.config, self.web, capture=lambda: _jpeg(1280, 800))
        self.base = self.svc.start_server()
        self.base = self.base[: -len("web/lens.html")]

    def tearDown(self):
        self.svc.stop_server()
        self.tmp.cleanup()

    def fetch(self, path, data=None, base=None):
        url = (base or self.base) + path
        req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=5) as res:
                return res.status, res.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_jpeg_size(self):
        self.assertEqual(service.jpeg_size(_jpeg(1280, 800)), (1280, 800))
        self.assertEqual(service.jpeg_size(b"\xff\xd8garbage"), (0, 0))

    def test_secret_path_and_static_files(self):
        self.assertEqual(self.fetch("web/lens.html")[0], 200)
        wrong = self.base.replace(self.svc.secret, "guess")
        self.assertEqual(self.fetch("web/lens.html", base=wrong)[0], 404)
        self.assertEqual(self.fetch("web/../secret.txt")[0], 404)
        self.assertEqual(self.fetch("web/%2e%2e/secret.txt")[0], 404)

    def test_capture_then_frame(self):
        status, body = self.fetch("capture", b"{}")
        self.assertEqual(status, 200)
        info = json.loads(body)
        self.assertEqual((info["width"], info["height"]), (1280, 800))
        status, img = self.fetch(f"frame/{info['frameId']}.jpg")
        self.assertEqual((status, img[:2]), (200, b"\xff\xd8"))
        self.assertEqual(self.fetch("frame/nope.jpg")[0], 404)

    def test_unpaired_requests_are_401(self):
        status, body = self.fetch("api/lookup/dictionary", b'{"term":"x"}')
        self.assertEqual(status, 401)
        self.assertEqual(json.loads(body)["error"], "unpaired")

    def test_proxy_allowlist_and_token_stripping(self):
        fake = FakeHost({"/api/lookup/dictionary": (200, {"popupJson": "[]"}), "/api/media/dictionary": (200, b"png")})
        self.svc._host = fake
        status, body = self.fetch("api/lookup/dictionary", b'{"term":"x"}')
        self.assertEqual((status, json.loads(body)), (200, {"popupJson": "[]"}))
        # Not on the allowlist: never forwarded (pairing, admin, sync...).
        self.assertEqual(self.fetch("api/pair/v2", b"{}")[0], 404)
        self.assertEqual(self.fetch("api/peers")[0], 404)
        self.fetch("api/media/dictionary?dictionary=d&path=a.png&token=lens")
        self.assertEqual(fake.calls[-1][1], "/api/media/dictionary?dictionary=d&path=a.png")
        self.assertEqual(len(fake.calls), 2)

    def test_pairing_is_persisted_and_restored(self):
        pending = FakeHost({"/api/pair/v2/confirm": (200, {"token": "t9"})})
        pending.token = None
        self.svc._pending_pair = (pending, {"sessionId": "s", "hostNonce": "h", "clientNonce": "c", "pinRequired": False})
        self.assertTrue(self.svc.finish_pairing(None)["paired"])
        saved = self.config.load()
        self.assertEqual((saved["token"], saved["fingerprint"]), ("t9", "aa:bb"))
        again = service.LensService(self.config, self.web)
        self.assertTrue(again.status()["paired"])
        self.assertEqual(again._device_id, saved["deviceId"])
        again.unpair()
        self.assertNotIn("token", self.config.load())


if __name__ == "__main__":
    unittest.main()

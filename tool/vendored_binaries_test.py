#!/usr/bin/env python3
"""Standalone tests for tool/vendored_binaries.py (standard library only).

Run:  python3 tool/vendored_binaries_test.py
Exits non-zero on any failure. Run by
fushi/test/build/vendored_binaries_manifest_guard_test.dart, so CI
(ci-config-gate, unit-tests) and the dist_test workers enforce it.

Covers:
  * `identity` writes LF-only bytes (names.sh hashes them into store names that
    must not depend on the runner OS);
  * the network retry: HTTP 5xx / truncated bodies are retried and logged,
    HTTP 4xx and content mismatches are not retried;
  * the shared cache: several processes materializing the same entry from an
    empty cache download it exactly once and all succeed (cross-process lock),
    and a waiter past its timeout fails loudly naming the lock file.
"""

from __future__ import annotations

import contextlib
import hashlib
import http.server
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Callable, Iterator, Optional

HERE: Path = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# The local test server must not be reached through a developer's proxy.
for _name in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY", "all_proxy"):
    os.environ.pop(_name, None)
os.environ["NO_PROXY"] = os.environ["no_proxy"] = "127.0.0.1,localhost"

import vendored_binaries as vb  # noqa: E402

PAYLOAD: bytes = os.urandom(300_000)
PAYLOAD_SHA: str = hashlib.sha256(PAYLOAD).hexdigest()


class _Server:
    """Threaded HTTP server whose response per request is chosen by `behaviour`."""

    def __init__(self, behaviour: Callable[[int, http.server.BaseHTTPRequestHandler], None]) -> None:
        self.hits: int = 0
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 (http.server API)
                with outer._lock:
                    outer.hits += 1
                    hit = outer.hits
                behaviour(hit, self)

            def log_message(self, format: str, *args: object) -> None:  # noqa: A002
                pass

        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._httpd.daemon_threads = True
        self.url: str = f"http://127.0.0.1:{self._httpd.server_address[1]}/asset"
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def __enter__(self) -> "_Server":
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()


def _send(handler: http.server.BaseHTTPRequestHandler, body: bytes, *, length: Optional[int] = None,
          chunk_delay: float = 0.0) -> None:
    handler.send_response(200)
    handler.send_header("Content-Length", str(len(body) if length is None else length))
    handler.end_headers()
    for start in range(0, len(body), 64 * 1024):
        handler.wfile.write(body[start : start + 64 * 1024])
        handler.wfile.flush()
        if chunk_delay:
            time.sleep(chunk_delay)


def _entry(url: str, data: bytes = PAYLOAD) -> dict:
    return {
        "path": "third_party/test/asset.bin",
        "group": "test",
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "url": url,
    }


@contextlib.contextmanager
def _captured_log() -> Iterator[list[str]]:
    lines: list[str] = []
    original = vb.log
    vb.log = lines.append  # type: ignore[assignment]
    try:
        yield lines
    finally:
        vb.log = original  # type: ignore[assignment]


class IdentityTest(unittest.TestCase):
    def test_identity_is_lf_only_bytes(self) -> None:
        result = subprocess.run(
            [sys.executable, str(HERE / "vendored_binaries.py"), "identity", "native/galgame_hook"],
            capture_output=True,
            check=True,
        )
        self.assertNotIn(b"\r", result.stdout)
        lines = result.stdout.decode("utf-8").splitlines()
        self.assertGreaterEqual(len(lines), 1)
        for line in lines:
            path, sha = line.split(" ")
            self.assertTrue(path.startswith("native/galgame_hook/"), line)
            self.assertRegex(sha, r"^[0-9a-f]{64}$")
        self.assertTrue(result.stdout.endswith(b"\n"))


class DownloadRetryTest(unittest.TestCase):
    def setUp(self) -> None:
        self._backoff = vb.RETRY_BACKOFF_SECONDS
        vb.RETRY_BACKOFF_SECONDS = 0.0
        self._tmp = tempfile.TemporaryDirectory(prefix="vendored-test-")
        self.dest = Path(self._tmp.name) / "out.bin"

    def tearDown(self) -> None:
        vb.RETRY_BACKOFF_SECONDS = self._backoff
        self._tmp.cleanup()

    def test_5xx_then_success_is_retried_and_logged(self) -> None:
        def behaviour(hit: int, handler: http.server.BaseHTTPRequestHandler) -> None:
            if hit == 1:
                handler.send_error(503)
            else:
                _send(handler, PAYLOAD)

        with _Server(behaviour) as server, _captured_log() as lines:
            vb.download(server.url, self.dest, _entry(server.url))
        self.assertEqual(server.hits, 2)
        self.assertEqual(self.dest.read_bytes(), PAYLOAD)
        self.assertTrue(any("attempt 1/3" in l and "503" in l and "retrying" in l for l in lines), lines)

    def test_truncated_body_is_retried(self) -> None:
        def behaviour(hit: int, handler: http.server.BaseHTTPRequestHandler) -> None:
            if hit == 1:
                # Announce the full length, send half, close: IncompleteRead.
                _send(handler, PAYLOAD[: len(PAYLOAD) // 2], length=len(PAYLOAD))
                handler.close_connection = True
            else:
                _send(handler, PAYLOAD)

        with _Server(behaviour) as server, _captured_log() as lines:
            vb.download(server.url, self.dest, _entry(server.url))
        self.assertEqual(server.hits, 2)
        self.assertTrue(any("attempt 1/3" in l for l in lines), lines)

    def test_persistent_5xx_gives_up_after_bounded_attempts(self) -> None:
        with _Server(lambda hit, handler: handler.send_error(502)) as server, _captured_log() as lines:
            with self.assertRaises(vb.VendoredError):
                vb.download(server.url, self.dest, _entry(server.url))
        self.assertEqual(server.hits, vb.DOWNLOAD_ATTEMPTS)
        self.assertEqual(len([l for l in lines if "download attempt" in l]), vb.DOWNLOAD_ATTEMPTS)
        self.assertIn("giving up", lines[-1])

    def test_4xx_is_not_retried(self) -> None:
        with _Server(lambda hit, handler: handler.send_error(404)) as server, _captured_log():
            with self.assertRaisesRegex(vb.VendoredError, "HTTP 404"):
                vb.download(server.url, self.dest, _entry(server.url))
        self.assertEqual(server.hits, 1)

    def test_content_mismatch_is_not_retried(self) -> None:
        wrong = bytes(reversed(PAYLOAD))
        with _Server(lambda hit, handler: _send(handler, wrong)) as server, _captured_log() as lines:
            with self.assertRaisesRegex(vb.VendoredError, "does not match the manifest"):
                vb.download(server.url, self.dest, _entry(server.url))
        self.assertEqual(server.hits, 1)
        self.assertFalse(any("download attempt" in l for l in lines), lines)


_CHILD = r"""
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import vendored_binaries as vb
vb.ROOT = Path(sys.argv[2])
entry = json.loads(sys.argv[4])
print(vb.materialize(entry, Path(sys.argv[3])), flush=True)
"""


class SharedCacheTest(unittest.TestCase):
    def test_parallel_processes_download_once_and_all_succeed(self) -> None:
        workers = 4
        with tempfile.TemporaryDirectory(prefix="vendored-cache-test-") as tmp, _Server(
            # Slow body so the processes overlap while the first one downloads.
            lambda hit, handler: _send(handler, PAYLOAD, chunk_delay=0.05)
        ) as server:
            cache = Path(tmp) / "cache"
            entry = _entry(server.url)
            env = dict(os.environ)
            children = [
                subprocess.Popen(
                    [sys.executable, "-c", _CHILD, str(HERE), str(Path(tmp) / f"root{i}"), str(cache),
                     json.dumps(entry)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                for i in range(workers)
            ]
            results = [child.communicate(timeout=120) for child in children]
            for child, (out, err) in zip(children, results):
                self.assertEqual(child.returncode, 0, err.decode("utf-8", "replace"))
            actions = sorted(out.decode().strip().splitlines()[-1] for out, _ in results)
            self.assertEqual(actions, ["fetched"] + ["fetched from cache"] * (workers - 1))
            self.assertEqual(server.hits, 1, "the shared cache entry must be downloaded once")
            for i in range(workers):
                target = Path(tmp) / f"root{i}" / entry["path"]
                self.assertEqual(target.read_bytes(), PAYLOAD)
                leftovers = [p.name for p in target.parent.iterdir() if p.name != target.name]
                self.assertEqual(leftovers, [], "staging files must not be left behind")
            self.assertEqual((cache / PAYLOAD_SHA).read_bytes(), PAYLOAD)
            self.assertEqual([p for p in cache.iterdir() if p.suffix == ".part"], [])

    def test_lock_wait_times_out_loudly(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vendored-lock-test-") as tmp:
            cache = Path(tmp)
            held = threading.Event()
            release = threading.Event()

            def holder() -> None:
                with vb.cache_lock(cache, PAYLOAD_SHA):
                    held.set()
                    release.wait(10)

            thread = threading.Thread(target=holder)
            with _captured_log() as lines:
                thread.start()
                self.assertTrue(held.wait(10))
                started = time.monotonic()
                try:
                    with self.assertRaisesRegex(vb.VendoredError, r"timed out .*\.lock"):
                        with vb.cache_lock(cache, PAYLOAD_SHA, timeout=0.5):
                            self.fail("acquired a lock another holder has")
                finally:
                    release.set()
                    thread.join(10)
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue(any("waiting for" in l for l in lines), lines)
            # Released by its holder: the next taker gets it at once.
            with vb.cache_lock(cache, PAYLOAD_SHA, timeout=1):
                pass


if __name__ == "__main__":
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=2)
    result = runner.run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    print(f"ran {result.testsRun} test(s)")
    sys.exit(0 if result.wasSuccessful() and result.testsRun > 0 else 1)

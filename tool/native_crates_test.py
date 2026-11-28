#!/usr/bin/env python3
"""Tests for tool/native_crates.py (the native registry reader and the one source-key function).

  python tool/native_crates_test.py        (stdlib unittest; no third-party packages)

What is pinned:
  * the real native/crates.json passes `check` (registry matches the tree);
  * the source key of a crate is the same value from every entry point on the same tree:
      - `native_crates.py key <crate>`            (fushi/tool/dist_test/worker_*.sh call this verbatim),
      - `native_crates.py tree-key $(paths ...)`  (the source part of .github/actions/native-store-names/names.sh),
      - `tool/native_libs.ps1 -PrintKeys`         (local stamps; only where Windows PowerShell exists);
  * the key changes when an external source changes (BUG-4988), and does not change for a Markdown edit;
  * uncommitted input changes make `key --require-clean` refuse (exit 3, no output).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import List

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tool" / "native_crates.py"


def run(args: List[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


class RealRegistryTest(unittest.TestCase):
    def test_registry_matches_tree(self) -> None:
        proc = run([sys.executable, str(TOOL), "check"], ROOT, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", "replace"))

    def test_lists_are_not_empty(self) -> None:
        for flag in ("--host-test", "--android-local", "--ios-umbrella"):
            out = run([sys.executable, str(TOOL), "list", flag], ROOT).stdout.decode().split()
            self.assertTrue(out, flag)


class SourceKeyFixtureTest(unittest.TestCase):
    """A throwaway git repo with the real tool files and a two-crate registry."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="native-crates-test-"))
        repo = self.tmp
        (repo / "tool").mkdir()
        for name in ("native_crates.py", "native_libs.ps1", "python3.ps1"):
            shutil.copy2(ROOT / "tool" / name, repo / "tool" / name)
        registry = {
            "schema": 1,
            "crates": [
                {
                    "name": "fushi_a",
                    "language": "rust",
                    "host_test_lib": True,
                    "build": {"windows": "b.ps1", "linux": "b.sh", "macos": "b.sh"},
                    "platforms": {},
                },
                {
                    "name": "fushi_b",
                    "language": "rust",
                    "host_test_lib": True,
                    "test_features": "raw_sql",
                    "external_sources": ["native/fushi_a/src/shared.rs"],
                    "build": {"windows": "b.ps1", "linux": "b.sh", "macos": "b.sh"},
                    "platforms": {},
                },
            ],
        }
        (repo / "native").mkdir()
        (repo / "native" / "crates.json").write_text(json.dumps(registry), encoding="utf-8")
        for crate in ("fushi_a", "fushi_b"):
            src = repo / "native" / crate / "src"
            src.mkdir(parents=True)
            (src / "lib.rs").write_text(f"// {crate}\n", encoding="utf-8")
            (repo / "native" / crate / "README.md").write_text("readme\n", encoding="utf-8")
        (repo / "native" / "fushi_a" / "src" / "shared.rs").write_text("pub fn f() {}\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.git("config", "core.autocrlf", "false")
        self.commit("init")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args: str) -> str:
        return run(["git", *args], self.tmp).stdout.decode()

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def tool(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return run([sys.executable, str(self.tmp / "tool" / "native_crates.py"), *args], self.tmp, check=check)

    def key(self, crate: str, *flags: str) -> str:
        return self.tool("key", crate, *flags).stdout.decode().strip()

    def test_entry_points_agree(self) -> None:
        for crate in ("fushi_a", "fushi_b"):
            key = self.key(crate)
            self.assertRegex(key, r"^[0-9a-f]{64}$")
            paths = self.tool("paths", crate).stdout.decode().split()
            self.assertEqual(self.tool("tree-key", *paths).stdout.decode().strip(), key, crate)
        self.assertEqual(self.key("fushi_b", "--features"), self.key("fushi_b") + "+raw_sql")
        powershell = shutil.which("powershell") or shutil.which("pwsh")
        if powershell is None:
            self.skipTest("no PowerShell: tool/native_libs.ps1 -PrintKeys not exercised on this host")
        out = run(
            [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.tmp / "tool" / "native_libs.ps1"), "-PrintKeys"],
            self.tmp,
        ).stdout.decode()
        printed = dict(line.split(" ", 1) for line in out.splitlines() if line.strip())
        self.assertEqual(printed, {"fushi_a": self.key("fushi_a"), "fushi_b": self.key("fushi_b")})

    def test_external_source_changes_key(self) -> None:
        before_a, before_b = self.key("fushi_a"), self.key("fushi_b")
        (self.tmp / "native" / "fushi_a" / "src" / "shared.rs").write_text("pub fn g() {}\n", encoding="utf-8")
        self.commit("shared")
        self.assertNotEqual(self.key("fushi_b"), before_b, "BUG-4988: external source edit must change the key")
        self.assertNotEqual(self.key("fushi_a"), before_a)

    def test_markdown_does_not_change_key(self) -> None:
        before = self.key("fushi_a")
        (self.tmp / "native" / "fushi_a" / "README.md").write_text("changed\n", encoding="utf-8")
        self.commit("readme")
        self.assertEqual(self.key("fushi_a"), before)

    def test_dirty_input_refuses(self) -> None:
        (self.tmp / "native" / "fushi_a" / "src" / "shared.rs").write_text("dirty\n", encoding="utf-8")
        for crate in ("fushi_a", "fushi_b"):
            proc = self.tool("key", crate, "--require-clean", check=False)
            self.assertEqual(proc.returncode, 3, crate)
            self.assertEqual(proc.stdout, b"", crate)

    def test_missing_input_fails(self) -> None:
        registry = json.loads((self.tmp / "native" / "crates.json").read_text(encoding="utf-8"))
        registry["crates"][1]["external_sources"] = ["native/fushi_a/src/gone.rs"]
        (self.tmp / "native" / "crates.json").write_text(json.dumps(registry), encoding="utf-8")
        proc = self.tool("key", "fushi_b", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(b"gone.rs", proc.stderr)


if __name__ == "__main__":
    unittest.main()

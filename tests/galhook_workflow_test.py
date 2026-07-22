#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "galhook.py"


class GalhookWorkflowTest(unittest.TestCase):
    def test_probe_bundle_contains_metadata_but_no_game_payload(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            executable = root / "sample.exe"
            executable.write_bytes(b"MZ" + bytes(126))
            (root / "scenario.ks").write_text("copyrighted fixture stand-in", encoding="utf-8")
            output = root / "probe.zip"
            subprocess.run(
                [sys.executable, str(TOOL), "probe", str(executable), "--output", str(output)],
                check=True,
                capture_output=True,
                text=True,
            )
            with zipfile.ZipFile(output) as bundle:
                self.assertEqual(sorted(bundle.namelist()), ["README.txt", "diagnostic.json"])
                report = json.loads(bundle.read("diagnostic.json"))
            self.assertFalse(report["privacy"]["copyright_payloads_included"])
            self.assertEqual(report["privacy"]["game_root"], "<game-root>")
            self.assertNotIn("copyrighted fixture stand-in", json.dumps(report))

    def test_new_scaffolds_and_registers_native_and_dart_guards(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "hook"
            hibiki = Path(raw) / "app"
            (root / "hook" / "generated").mkdir(parents=True)
            (root / "tests").mkdir()
            (root / "CMakeLists.txt").write_text("enable_testing()\n", encoding="utf-8")
            for name in (
                "adapter_includes.inc",
                "adapter_startup.inc",
                "adapter_shutdown.inc",
                "adapter_module.inc",
                "adapter_fields.inc",
            ):
                (root / "hook" / "generated" / name).write_text("// generated\n", encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "new",
                    "sample_engine",
                    "--root",
                    str(root),
                    "--hibiki-root",
                    str(hibiki),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertTrue((root / "profiles" / "sample_engine.json").is_file())
            self.assertTrue((root / "hook" / "adapters" / "sample_engine_adapter.inc").is_file())
            self.assertIn("hibiki_sample_engine_adapter_test", (root / "CMakeLists.txt").read_text())
            self.assertIn("sample_engine_.install", (root / "hook" / "generated" / "adapter_startup.inc").read_text())
            self.assertTrue((hibiki / "hibiki" / "test" / "mining" / "sample_engine_pairing_test.dart").is_file())

    def test_replay_covers_filter_dedup_pairing_fallback_and_cleanup(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(TOOL), "replay", str(ROOT / "tests" / "fixtures" / "workflow_replay.json")],
            check=True,
            capture_output=True,
            text=True,
        )
        report = json.loads(completed.stdout)
        self.assertEqual(report["duplicate_text_events"], 1)
        self.assertEqual(report["thread_filtered_events"], 1)
        self.assertEqual(
            [card["audio_backend"] for card in report["cards"]],
            ["resource_audio", "pcm", "loopback"],
        )
        self.assertTrue(report["session_clean"])

    @unittest.skipUnless(sys.platform == "win32", "PowerShell wrapper is Windows-only")
    def test_powershell_wrapper_dispatches_replay(self) -> None:
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "tool" / "galhook.ps1"),
                "replay",
                str(ROOT / "tests" / "fixtures" / "workflow_replay.json"),
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()

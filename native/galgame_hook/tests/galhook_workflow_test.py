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
            fushi_root = Path(raw) / "app"
            (root / "hook" / "generated").mkdir(parents=True)
            (root / "tests").mkdir()
            (root / "CMakeLists.txt").write_text("enable_testing()\n", encoding="utf-8")
            for name in (
                "profile_includes.inc",
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
                    "--fushi-root",
                    str(fushi_root),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertTrue((root / "profiles" / "sample_engine.json").is_file())
            self.assertTrue((root / "hook" / "adapters" / "sample_engine_adapter.inc").is_file())
            self.assertIn("fushi_sample_engine_adapter_test", (root / "CMakeLists.txt").read_text())
            self.assertIn(
                "sample_engine_profile.h",
                (root / "hook" / "generated" / "profile_includes.inc").read_text(),
            )
            self.assertIn("sample_engine_.install", (root / "hook" / "generated" / "adapter_startup.inc").read_text())
            self.assertTrue((fushi_root / "fushi" / "test" / "mining" / "sample_engine_pairing_test.dart").is_file())

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

    def test_leaf_aquaplus_replay_uses_only_synthetic_text_and_pcm_metadata(
        self,
    ) -> None:
        fixture = ROOT / "tests" / "fixtures" / "leaf_aquaplus_replay.json"
        completed = subprocess.run(
            [sys.executable, str(TOOL), "replay", str(fixture)],
            check=True,
            capture_output=True,
            text=True,
        )
        report = json.loads(completed.stdout)
        self.assertEqual(
            report["cards"],
            [
                {
                    "text_id": "synthetic-leaf-line",
                    "audio_backend": "pcm",
                    "audio_id": "synthetic-leaf-pcm",
                }
            ],
        )
        self.assertEqual(report["duplicate_text_events"], 1)
        self.assertEqual(report["thread_filtered_events"], 1)
        self.assertTrue(report["session_clean"])

        fixture_data = json.loads(fixture.read_text(encoding="utf-8"))
        self.assertEqual(fixture_data["status"], "implemented_unverified")
        pcm = next(
            event for event in fixture_data["events"] if event["kind"] == "pcm"
        )
        self.assertEqual(
            {
                "format": pcm["format"],
                "sample_rate_hz": pcm["sample_rate_hz"],
                "channels": pcm["channels"],
                "bits_per_sample": pcm["bits_per_sample"],
            },
            {
                "format": "s16le",
                "sample_rate_hz": 48000,
                "channels": 1,
                "bits_per_sample": 16,
            },
        )

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



class GuardRegistryTest(unittest.TestCase):
    """run_guards.ps1 的清单是人工维护的，漏登记 = 守卫静默失效。

    assert_liveness_guard_test.py 就是这么丢的：文件写好了、断言是对的，
    但从没被任何 CI 入口执行，于是 generic_input_shield_test.cpp 的 47 条
    assert 在 Release 下空跑了整整一个发布周期都没人发现（BUG-2025）。

    这条守卫用目录枚举而不是再写一份名单：新增 tests/<x>_test.py 时它自动
    进入扫描面，不需要任何人记得同步第二处。
    """

    def test_every_python_guard_is_registered_in_run_guards(self) -> None:
        runner = (ROOT / "tools" / "run_guards.ps1").read_text(encoding="utf-8")
        discovered = {p.name for p in (ROOT / "tests").glob("*_test.py")}
        self.assertGreater(len(discovered), 5, "guard discovery looks broken")
        missing = sorted(
            name for name in discovered
            if f"tests/{name}" not in runner
        )
        self.assertEqual(
            missing,
            [],
            "这些守卫存在但没被 tools/run_guards.ps1 执行，等于没写："
            f"{missing}。把它们加进 run_guards.ps1 的 Invoke-Checked 清单。",
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

from galhook_evidence import (  # noqa: E402
    BOUNDARIES,
    OFFLINE_GATES,
    decode_diagnostics,
    load_diag_constants,
    new_evidence,
    validate_evidence,
)

TOOL = TOOLS / "galhook.py"


def _mark_boundary(document: dict, boundary_id: str, status: str) -> None:
    row = next(item for item in document["boundaries"] if item["id"] == boundary_id)
    row["status"] = status
    row["evidence"] = [f"evidence:{boundary_id}"] if status in {"pass", "fail"} else []


def _complete_evidence(audio_boundary: str = "resource_observed") -> dict:
    document = new_evidence("sample_engine")
    document["task"].update(
        {
            "game_name": "Redacted Sample",
            "game_version": "1.0",
            "original_failure_path": "Steam cold launch",
            "support_status": "verified",
        }
    )
    document["identity"] = {
        "original_launch": {
            "method": "steam://run/redacted",
            "launcher": "Steam",
            "original_path_reproduced": True,
        },
        "process": {
            "pid": 4242,
            "parent_pid": 100,
            "architecture": "x86",
            "started_at": "2026-07-23T12:00:00+08:00",
        },
        "artifacts": {
            "executable": {
                "path": "<redacted>/game.exe",
                "sha256": "a" * 64,
                "architecture": "x86",
            },
            "target_module": {
                "path": "<redacted>/engine.dll",
                "sha256": "b" * 64,
                "architecture": "x86",
            },
            "injector": {
                "path": "<redacted>/injector.exe",
                "sha256": "c" * 64,
                "architecture": "x86",
            },
            "hook_dll": {
                "path": "<redacted>/hook.dll",
                "sha256": "d" * 64,
                "architecture": "x86",
            },
        },
    }
    events = [
        "process_start",
        "injection",
        "target_module_loaded",
        "helper_loaded",
        "hook_installed",
        "helper_ready",
        "ipc_ready",
        "first_text",
        "text_thread_selected",
        {
            "resource_observed": "first_resource",
            "pcm_observed": "first_pcm",
            "loopback_observed": "first_loopback",
        }[audio_boundary],
        "paired",
        "screenshot",
        "card_written",
    ]
    document["timeline"] = [
        {
            "at_ms": index * 10,
            "event": event,
            "pid": 4242,
            "evidence": f"runtime-ledger.json#{index + 1}",
        }
        for index, event in enumerate(events)
    ]
    for boundary in BOUNDARIES:
        status = "pass"
        if boundary in {"resource_observed", "pcm_observed", "loopback_observed"}:
            status = "pass" if boundary == audio_boundary else "not_applicable"
        _mark_boundary(document, boundary, status)
    document["stages"] = {
        "observed": {"status": "pass", "evidence": ["runtime-ledger.json"]},
        "implemented": {
            "status": "pass",
            "change_refs": ["commit:abc123"],
            "guard_refs": ["test:adapter-negative"],
        },
        "offline": {
            "status": "pass",
            "commands": [
                {
                    "gate": gate,
                    "command": f"verified-command-for-{gate}",
                    "exit_code": 0,
                    "evidence": f"{gate}.log",
                }
                for gate in OFFLINE_GATES
            ],
            "architectures": ["x86", "x64"],
            "production_replay": True,
        },
        "runtime": {
            "status": "pass",
            "session_id": "redacted-session-1",
            "evidence": ["runtime-ledger.json"],
        },
        "e2e": {
            "status": "pass",
            "session_id": "redacted-session-1",
            "text_source": "selected-thread-7",
            "audio_layer": audio_boundary,
            "pairing_evidence": "pair.json",
            "screenshot_evidence": "shot.sha256",
            "card_evidence": "card-id:redacted",
        },
        "release": {
            "status": "pass",
            "manifest_ref": "engine-support.yaml#sample_engine",
            "generated_matrix_check": "exit:0",
            "proved_capabilities": [
                {
                    "ref": f"audio:sample_{audio_boundary}",
                    "proof_boundary": audio_boundary,
                    "evidence": "runtime-ledger.json#audio-capability",
                }
            ],
            "proved_engine_claims": [],
        },
    }
    return document


class EvidenceContractTest(unittest.TestCase):
    def test_init_round_trip_is_structurally_valid_but_proves_no_stage(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw) / "evidence.json"
            subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "evidence",
                    "init",
                    "sample_engine",
                    "--output",
                    str(output),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            completed = subprocess.run(
                [sys.executable, str(TOOL), "verify-evidence", str(output)],
                check=True,
                capture_output=True,
                text=True,
            )
            report = json.loads(completed.stdout)
            self.assertTrue(report["valid"])
            self.assertIsNone(report["highest_proven_stage"])
            self.assertFalse(report["release_eligible"])

    def test_complete_native_e2e_evidence_is_release_eligible(self) -> None:
        report = validate_evidence(_complete_evidence())
        self.assertEqual([], report["errors"])
        self.assertEqual("release", report["highest_proven_stage"])
        self.assertTrue(report["release_eligible"])

    def test_loopback_only_cannot_upgrade_engine_support(self) -> None:
        report = validate_evidence(_complete_evidence("loopback_observed"))
        self.assertFalse(report["valid"])
        self.assertTrue(
            any("loopback is fallback only" in error for error in report["errors"])
        )
        self.assertFalse(report["release_eligible"])

    def test_release_audio_layer_must_be_the_native_layer_used_by_e2e(self) -> None:
        document = _complete_evidence("resource_observed")
        _mark_boundary(document, "loopback_observed", "pass")
        document["stages"]["e2e"]["audio_layer"] = "loopback_observed"
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertTrue(
            any("loopback is fallback only" in error for error in report["errors"])
        )
        self.assertFalse(report["release_eligible"])

    def test_first_failed_boundary_stops_later_claims(self) -> None:
        document = new_evidence("sample_engine")
        _mark_boundary(document, "process_found", "pass")
        _mark_boundary(document, "helper_ready", "fail")
        _mark_boundary(document, "ipc_ready", "pass")
        document["first_failed_boundary"] = "helper_ready"
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertTrue(
            any("must be not_run after" in error for error in report["errors"])
        )

    def test_stage_skipping_and_require_stage_fail_closed(self) -> None:
        document = new_evidence("sample_engine")
        document["stages"]["e2e"]["status"] = "pass"
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "invalid.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "verify-evidence",
                    str(path),
                    "--require-stage",
                    "runtime",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(2, completed.returncode)
        report = json.loads(completed.stdout)
        self.assertFalse(report["valid"])
        self.assertTrue(any("cannot pass" in error for error in report["errors"]))
        self.assertTrue(any("required stage runtime" in error for error in report["errors"]))

    def test_boolean_values_cannot_satisfy_string_evidence_fields(self) -> None:
        document = _complete_evidence()
        document["identity"]["artifacts"]["hook_dll"]["path"] = False
        document["stages"]["runtime"]["session_id"] = False
        document["stages"]["e2e"]["pairing_evidence"] = False
        document["stages"]["release"]["manifest_ref"] = False
        document["stages"]["offline"]["commands"][0]["exit_code"] = False
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(any("hook_dll.path is required" in error for error in report["errors"]))
        self.assertTrue(any("exit_code must be 0" in error for error in report["errors"]))

    def test_boolean_schema_version_and_unsupported_architecture_fail_closed(self) -> None:
        document = _complete_evidence()
        document["schema_version"] = True
        document["identity"]["process"]["architecture"] = "arm64"
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(any("schema_version" in error for error in report["errors"]))
        self.assertTrue(any("architecture" in error for error in report["errors"]))

    def test_injected_artifacts_must_match_target_architecture(self) -> None:
        document = _complete_evidence()
        document["identity"]["artifacts"]["injector"]["architecture"] = "x64"
        document["identity"]["artifacts"]["hook_dll"]["architecture"] = "x64"
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(
            any("injector.architecture" in error for error in report["errors"])
        )
        self.assertTrue(
            any("hook_dll.architecture" in error for error in report["errors"])
        )

    def test_injector_and_hook_dll_cannot_alias_the_same_artifact(self) -> None:
        document = _complete_evidence()
        document["identity"]["artifacts"]["injector"] = dict(
            document["identity"]["artifacts"]["hook_dll"]
        )
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(
            any("injector and hook_dll" in error for error in report["errors"])
        )

    def test_runtime_timeline_is_bound_to_target_pid_and_required_events(self) -> None:
        document = _complete_evidence()
        document["timeline"] = [
            {
                "at_ms": 0,
                "event": "process_start",
                "pid": 9999,
                "evidence": "wrong-process.log#1",
            },
            {
                "at_ms": 1,
                "event": "injection",
                "pid": 9999,
                "evidence": "wrong-process.log#2",
            },
        ]
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(
            any("for identity.process.pid" in error for error in report["errors"])
        )

    def test_timeline_semantic_order_cannot_be_reversed(self) -> None:
        document = _complete_evidence()
        times = {
            "helper_ready": 0,
            "injection": 10,
            "process_start": 50,
        }
        for row in document["timeline"]:
            if row["event"] in times:
                row["at_ms"] = times[row["event"]]
            else:
                row["at_ms"] += 100
        document["timeline"].sort(key=lambda row: row["at_ms"])
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertFalse(report["release_eligible"])
        self.assertTrue(
            any(
                "cannot precede process_start" in error
                or "attach_or_injection <= helper_loaded" in error
                for error in report["errors"]
            )
        )

    def test_offline_stage_requires_every_named_gate(self) -> None:
        document = _complete_evidence()
        document["stages"]["offline"]["commands"] = [
            {
                "gate": "workflow_tests",
                "command": "python tests",
                "exit_code": 0,
                "evidence": "tests.log",
            }
        ]
        report = validate_evidence(document)
        self.assertFalse(report["valid"])
        self.assertTrue(any("missing gates" in error for error in report["errors"]))

    def test_diagnostic_decoder_uses_header_constants_and_reports_unknown_bits(self) -> None:
        constants = load_diag_constants(ROOT / "include" / "voice_hook_ipc.h")
        report = decode_diagnostics(
            constants,
            {
                "hookdiag": 0x00000001,
                "hookio": 0x80000020,
                "lunadiag": 0x10000000,
            },
        )
        self.assertEqual(
            ["kDiagStartupAudioHooksReady"],
            [item["name"] for item in report["hookdiag"]["set"]],
        )
        self.assertIn(
            "kDiagQlieVorbisHooksReady",
            [item["name"] for item in report["hookio"]["set"]],
        )
        self.assertEqual("0x80000000", report["hookio"]["unknown_bits"])
        self.assertIn(
            "kDiagSiglusOvkHooksReady",
            [item["name"] for item in report["lunadiag"]["set"]],
        )

    def test_check_dry_run_lists_native_matrix_without_creating_builds(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fake_root = Path(raw)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "check",
                    "--root",
                    str(fake_root),
                    "--native",
                    "--dry-run",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            report = json.loads(completed.stdout)
            self.assertTrue(report["native"])
            self.assertTrue(any("-A x64" in command for command in report["commands"]))
            self.assertTrue(any("-A Win32" in command for command in report["commands"]))
            self.assertFalse((fake_root / "build").exists())


if __name__ == "__main__":
    unittest.main()

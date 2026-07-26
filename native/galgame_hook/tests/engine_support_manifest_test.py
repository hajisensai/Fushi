#!/usr/bin/env python3
"""P0 contract tests for the generated engine support matrix."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

from evidence_contract_test import _complete_evidence


ROOT = Path(__file__).resolve().parents[1]


def load_generator() -> ModuleType:
    path = ROOT / "tools" / "generate_engine_support.py"
    spec = importlib.util.spec_from_file_location("generate_engine_support", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load_generator()


def _prove_engine_claim(document: dict, claim: str, value: object) -> None:
    document["stages"]["release"]["proved_engine_claims"].append(
        {
            "claim": claim,
            "value_sha256": GENERATOR._canonical_sha256(value),
            "evidence": f"release-ledger#{claim}",
        }
    )


class EngineSupportManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = GENERATOR.load_manifest(ROOT / "engine-support.yaml")
        GENERATOR.validate_manifest(self.manifest)
        self.engines = {item["id"]: item for item in self.manifest["engines"]}

    def test_generated_document_is_current(self) -> None:
        expected = GENERATOR.render_manifest(self.manifest)
        output = ROOT / self.manifest["generated_document"]
        self.assertEqual(expected, output.read_text(encoding="utf-8"))

    def test_phase_zero_baseline_is_explicit(self) -> None:
        self.assertTrue(
            {
                "siglus",
                "reallive",
                "kirikiri_z",
                "xaudio2_directsound",
                "renpy_ffmpeg",
                "unity_il2cpp",
            }.issubset(self.engines),
            "The P0 baseline must remain present as later adapters are added.",
        )

        siglus = self.engines["siglus"]
        self.assertEqual("verified", siglus["current_status"])
        self.assertEqual(
            "D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059",
            siglus["verified_games"][0]["executable_sha256"],
        )
        self.assertTrue(siglus["audio"]["priority"][0]["clean_voice"])

        kirikiri = self.engines["kirikiri_z"]
        self.assertEqual("partial", kirikiri["current_status"])
        directsound = next(
            item
            for item in kirikiri["audio"]["priority"]
            if item["kind"] == "directsound_pcm"
        )
        self.assertFalse(directsound["clean_voice"])
        self.assertTrue(
            any("equivalent to loopback" in item for item in kirikiri["known_limitations"])
        )

        generic = self.engines["xaudio2_directsound"]
        self.assertEqual("verified", generic["current_status"])
        self.assertIn(
            "xaudio2_9.dll",
            generic["detection"]["runtime_modules"]["values"],
        )

        reallive = self.engines["reallive"]
        self.assertEqual("implemented_unverified", reallive["current_status"])
        self.assertEqual([], reallive["verified_games"])
        self.assertEqual([], reallive["detection"]["hashes"]["values"])
        self.assertTrue(
            any("not evidence" in item for item in reallive["known_limitations"])
        )

        renpy = self.engines["renpy_ffmpeg"]
        self.assertEqual("implemented_unverified", renpy["current_status"])
        self.assertTrue(renpy["process_strategy"]["follow_child_processes"])
        self.assertEqual("ffmpeg_resource_event", renpy["audio"]["priority"][0]["kind"])
        self.assertTrue(
            any("fell back to loopback" in item for item in renpy["known_limitations"])
        )

        unity = self.engines["unity_il2cpp"]
        self.assertEqual("verified", unity["current_status"])
        self.assertEqual(
            "unity_audioclip_resource", unity["audio"]["priority"][0]["kind"]
        )
        self.assertTrue(
            any("Unity Mono" in item for item in unity["known_limitations"])
        )

    def test_nonempty_recognition_signatures_have_sample_evidence(self) -> None:
        for engine in self.engines.values():
            for field in GENERATOR.SIGNATURE_FIELDS:
                group = engine["detection"][field]
                if group["values"]:
                    self.assertIn(
                        group["evidence"]["kind"],
                        {"real_sample", "runtime_observation"},
                    )

    def test_support_status_and_capability_promotions_require_evidence(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "verified"
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "support_evidence"
        ):
            GENERATOR.validate_manifest(self.manifest)

        self.manifest = GENERATOR.load_manifest(ROOT / "engine-support.yaml")
        reallive = next(
            item for item in self.manifest["engines"] if item["id"] == "reallive"
        )
        reallive["audio"]["priority"][0]["status"] = "verified"
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "support_evidence"
        ):
            GENERATOR.validate_manifest(self.manifest)

    def test_boolean_schema_version_is_rejected(self) -> None:
        self.manifest["schema_version"] = True
        with self.assertRaisesRegex(GENERATOR.ManifestError, "schema_version"):
            GENERATOR.validate_manifest(self.manifest)

    def test_structured_release_evidence_allows_a_scoped_promotion(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "partial"
        reallive["audio"]["priority"][0]["status"] = "partial"
        document = _complete_evidence()
        document["task"]["engine_id"] = "reallive"
        document["task"]["support_status"] = "partial"
        document["stages"]["release"][
            "manifest_ref"
        ] = "engine-support.yaml#reallive"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:visual_arts_ovk_resource"
        _prove_engine_claim(document, "support_status", "partial")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "reallive-release.json"
            payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
            evidence_path.write_text(payload, encoding="utf-8")
            reallive["support_evidence"] = [{
                "file": "evidence/reallive-release.json",
                "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
                "capability_refs": ["audio:visual_arts_ovk_resource"],
                "engine_claim_refs": ["support_status"],
            }]
            GENERATOR.validate_manifest(self.manifest, root)
            rendered = GENERATOR.render_manifest(self.manifest, root)
            self.assertIn("evidence/reallive-release.json", rendered)
            self.assertIn("audio:visual_arts_ovk_resource", rendered)

    def test_support_evidence_is_engine_bound_and_hash_pinned(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "partial"
        reallive["audio"]["priority"][0]["status"] = "partial"
        document = _complete_evidence()
        document["task"]["support_status"] = "partial"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:visual_arts_ovk_resource"
        _prove_engine_claim(document, "support_status", "partial")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "wrong-engine.json"
            payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
            evidence_path.write_text(payload, encoding="utf-8")
            reallive["support_evidence"] = [{
                "file": "evidence/wrong-engine.json",
                "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
                "capability_refs": ["audio:visual_arts_ovk_resource"],
                "engine_claim_refs": ["support_status"],
            }]
            with self.assertRaisesRegex(
                GENERATOR.ManifestError, "task.engine_id mismatch"
            ):
                GENERATOR.validate_manifest(self.manifest, root)

    def test_pcm_e2e_cannot_prove_a_resource_capability(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "partial"
        reallive["audio"]["priority"][0]["status"] = "partial"
        document = _complete_evidence("pcm_observed")
        document["task"]["engine_id"] = "reallive"
        document["task"]["support_status"] = "partial"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:visual_arts_ovk_resource"
        _prove_engine_claim(document, "support_status", "partial")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "wrong-layer.json"
            evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            reallive["support_evidence"] = [{
                "file": "evidence/wrong-layer.json",
                "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
                "capability_refs": ["audio:visual_arts_ovk_resource"],
                "engine_claim_refs": ["support_status"],
            }]
            with self.assertRaisesRegex(
                GENERATOR.ManifestError, "proof boundary mismatch"
            ):
                GENERATOR.validate_manifest(self.manifest, root)

    def test_multiple_evidence_files_accumulate_distinct_audio_layers(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "partial"
        reallive["audio"]["priority"][0]["status"] = "partial"
        reallive["audio"]["priority"][1]["status"] = "partial"
        resource_document = _complete_evidence("resource_observed")
        pcm_document = _complete_evidence("pcm_observed")
        records = []
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            for filename, document, ref in (
                (
                    "resource.json",
                    resource_document,
                    "audio:visual_arts_ovk_resource",
                ),
                (
                    "pcm.json",
                    pcm_document,
                    "audio:xaudio2_or_directsound_pcm",
                ),
            ):
                document["task"]["engine_id"] = "reallive"
                document["task"]["support_status"] = "partial"
                document["stages"]["release"]["proved_capabilities"][0][
                    "ref"
                ] = ref
                if filename == "resource.json":
                    _prove_engine_claim(document, "support_status", "partial")
                evidence_path = evidence_dir / filename
                evidence_path.write_text(
                    json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8",
                )
                records.append(
                    {
                        "file": f"evidence/{filename}",
                        "sha256": hashlib.sha256(
                            evidence_path.read_bytes()
                        ).hexdigest(),
                        "capability_refs": [ref],
                        "engine_claim_refs": (
                            ["support_status"] if filename == "resource.json" else []
                        ),
                    }
                )
            reallive["support_evidence"] = records
            GENERATOR.validate_manifest(self.manifest, root)

    def test_new_verified_game_must_match_hash_pinned_runtime_identity(self) -> None:
        reallive = self.engines["reallive"]
        reallive["current_status"] = "partial"
        reallive["audio"]["priority"][0]["status"] = "partial"
        document = _complete_evidence("resource_observed")
        document["task"]["engine_id"] = "reallive"
        document["task"]["support_status"] = "partial"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:visual_arts_ovk_resource"
        _prove_engine_claim(document, "support_status", "partial")
        game = {
            "name": "Redacted Sample",
            "architecture": "x86",
            "engine_version": "1.0",
            "verified_on": "2026-07-23",
            "evidence": "hash-pinned release evidence",
            "executable_sha256": "a" * 64,
        }
        reallive["verified_games"].append(game)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "game.json"
            evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            record = {
                "file": "evidence/game.json",
                "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
                "capability_refs": ["audio:visual_arts_ovk_resource"],
                "engine_claim_refs": ["support_status"],
                "verified_game_ref": GENERATOR._canonical_sha256(game),
            }
            reallive["support_evidence"] = [record]
            GENERATOR.validate_manifest(self.manifest, root)

            game["engine_version"] = "999"
            record["verified_game_ref"] = GENERATOR._canonical_sha256(game)
            with self.assertRaisesRegex(
                GENERATOR.ManifestError, "verified game version mismatch"
            ):
                GENERATOR.validate_manifest(self.manifest, root)

    def test_legacy_capability_semantics_are_hash_pinned(self) -> None:
        kirikiri = self.engines["kirikiri_z"]
        directsound = next(
            item
            for item in kirikiri["audio"]["priority"]
            if item["kind"] == "directsound_pcm"
        )
        directsound["clean_voice"] = True
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "support_evidence"
        ):
            GENERATOR.validate_manifest(self.manifest)

    def test_legacy_process_and_limit_claims_are_hash_pinned(self) -> None:
        qlie = self.engines["qlie_filepack"]
        qlie["process_strategy"]["attach"] = "verified_all_attach_paths"
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "support_evidence"
        ):
            GENERATOR.validate_manifest(self.manifest)

        self.manifest = GENERATOR.load_manifest(ROOT / "engine-support.yaml")
        qlie = next(
            item for item in self.manifest["engines"] if item["id"] == "qlie_filepack"
        )
        qlie["known_limitations"] = []
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "immutable"
        ):
            GENERATOR.validate_manifest(self.manifest)

    def test_unrelated_audio_evidence_cannot_wash_a_process_strategy_change(self) -> None:
        qlie = self.engines["qlie_filepack"]
        qlie["process_strategy"]["attach"] = "verified_all_attach_paths"
        document = _complete_evidence("pcm_observed")
        document["task"]["engine_id"] = "qlie_filepack"
        document["task"]["support_status"] = "partial"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:qlie_wuvorbis_per_source_pcm"
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "unrelated-audio.json"
            evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            qlie["support_evidence"] = [
                {
                    "file": "evidence/unrelated-audio.json",
                    "sha256": hashlib.sha256(
                        evidence_path.read_bytes()
                    ).hexdigest(),
                    "capability_refs": [
                        "audio:qlie_wuvorbis_per_source_pcm"
                    ],
                    "engine_claim_refs": [],
                }
            ]
            with self.assertRaisesRegex(
                GENERATOR.ManifestError, "missing changed engine claims"
            ):
                GENERATOR.validate_manifest(self.manifest, root)

            _prove_engine_claim(
                document, "process_strategy", qlie["process_strategy"]
            )
            evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            qlie["support_evidence"][0]["sha256"] = hashlib.sha256(
                evidence_path.read_bytes()
            ).hexdigest()
            qlie["support_evidence"][0]["engine_claim_refs"] = [
                "process_strategy"
            ]
            GENERATOR.validate_manifest(self.manifest, root)

    def test_new_supported_engine_must_prove_each_engine_level_claim(self) -> None:
        new_engine = copy.deepcopy(self.engines["reallive"])
        new_engine["id"] = "new_engine"
        new_engine["current_status"] = "partial"
        new_engine["family"] = {"id": "fabricated", "relation": "unproved"}
        new_engine["process_strategy"]["attach"] = "works_everywhere"
        new_engine["audio"]["priority"][0]["status"] = "partial"
        self.manifest["engines"].append(new_engine)
        document = _complete_evidence("resource_observed")
        document["task"]["engine_id"] = "new_engine"
        document["task"]["support_status"] = "partial"
        document["stages"]["release"]["proved_capabilities"][0][
            "ref"
        ] = "audio:visual_arts_ovk_resource"
        _prove_engine_claim(document, "support_status", "partial")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            evidence_dir = root / "evidence"
            evidence_dir.mkdir()
            evidence_path = evidence_dir / "new-engine.json"
            evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            new_engine["support_evidence"] = [
                {
                    "file": "evidence/new-engine.json",
                    "sha256": hashlib.sha256(
                        evidence_path.read_bytes()
                    ).hexdigest(),
                    "capability_refs": ["audio:visual_arts_ovk_resource"],
                    "engine_claim_refs": ["support_status"],
                }
            ]
            with self.assertRaisesRegex(
                GENERATOR.ManifestError, "missing changed engine claims"
            ):
                GENERATOR.validate_manifest(self.manifest, root)

    def test_conservative_status_and_append_only_limit_updates_are_allowed(self) -> None:
        kirikiri = self.engines["kirikiri_z"]
        kirikiri["current_status"] = "implemented_unverified"
        kirikiri["known_limitations"].append("New conservative limitation.")
        GENERATOR.validate_manifest(self.manifest)

        self.manifest = GENERATOR.load_manifest(ROOT / "engine-support.yaml")
        kirikiri = next(
            item for item in self.manifest["engines"] if item["id"] == "kirikiri_z"
        )
        kirikiri["detection"]["hashes"] = {
            "values": ["A" * 64],
            "evidence": {
                "kind": "runtime_observation",
                "reference": "redacted runtime hash observation",
            },
        }
        GENERATOR.validate_manifest(self.manifest)


if __name__ == "__main__":
    unittest.main()

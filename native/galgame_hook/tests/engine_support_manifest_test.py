#!/usr/bin/env python3
"""P0 contract tests for the generated engine support matrix."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

from evidence_contract_test import _complete_evidence


ROOT = Path(__file__).resolve().parents[1]
WA2_EXACT_SHA256 = (
    "005E71107ED70E662C41CB526879CDCF0B9486E067C0E5A306308688C17409ED"
)


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

    def test_leaf_aquaplus_support_is_exact_hash_and_unverified(self) -> None:
        leaf = self.engines["leaf_aquaplus"]
        profile_document = json.loads(
            (ROOT / "profiles" / "leaf_aquaplus.json").read_text(encoding="utf-8")
        )
        profile_header = (
            ROOT / "hook" / "adapters" / "leaf_aquaplus_profile.h"
        ).read_text(encoding="utf-8")
        digest_match = re.search(
            r"kWhiteAlbum2LeafAquaplusProfile\s*=\s*\{\s*\{(?P<digest>.*?)\}"
            r"\s*,\s*kLeafAquaplusPeMachineI386\s*,\s*32u\s*,\s*0x734430u",
            profile_header,
            re.DOTALL,
        )
        self.assertIsNotNone(digest_match)
        assert digest_match is not None
        profile_digest = bytes(
            int(value, 16)
            for value in re.findall(r"0x([0-9a-fA-F]{2})", digest_match["digest"])
        ).hex().upper()

        self.assertEqual("implemented_unverified", leaf["current_status"])
        self.assertEqual([], leaf["verified_games"])
        self.assertEqual(
            [
                {
                    "algorithm": "sha256",
                    "scope": "game_executable",
                    "value": WA2_EXACT_SHA256,
                    "version": "WHITE ALBUM2 bundled edition (version not recorded)",
                }
            ],
            leaf["detection"]["hashes"]["values"],
        )
        self.assertEqual(
            [WA2_EXACT_SHA256.lower()],
            profile_document["detection"]["executable_sha256"],
        )
        self.assertEqual(WA2_EXACT_SHA256, profile_digest)
        self.assertIn(
            "constexpr uint16_t kLeafAquaplusPeMachineI386 = 0x014cu;",
            profile_header,
        )
        self.assertTrue(
            all(
                capability["status"] == "implemented_unverified"
                for capability in leaf["text"]["capabilities"]
                + leaf["audio"]["priority"]
            )
        )
        self.assertIn(
            "tests/fixtures/leaf_aquaplus_replay.json", leaf["fixture_paths"]
        )
        self.assertIn(
            "tests/leaf_d3d_trace_export_test.cpp", leaf["test_paths"]
        )

    def test_hunex_gge_profile_is_structural_generic_and_unverified(self) -> None:
        hunex = self.engines["hunex_gge"]
        profile_document = json.loads(
            (ROOT / "profiles" / "hunex_gge.json").read_text(encoding="utf-8")
        )
        profile_header = (
            ROOT / "hook" / "adapters" / "hunex_gge_profile.h"
        ).read_text(encoding="utf-8")
        title_profile = profile_document["profile_metadata"]["title_profiles"][0]

        self.assertEqual("implemented_unverified", hunex["current_status"])
        self.assertEqual([], hunex["verified_games"])
        self.assertEqual([], hunex["detection"]["hashes"]["values"])
        self.assertEqual([], hunex["detection"]["directory_files_all"]["values"])
        self.assertEqual(
            [], profile_document["detection"]["executable_sha256"]
        )
        self.assertEqual([], profile_document["detection"]["module_sha256"])
        self.assertEqual("WoH.exe", title_profile["executable_name"])
        self.assertEqual("data04000.hfa", title_profile["voice_archive_name"])
        self.assertFalse(title_profile["family_invariant"])
        self.assertIn("structural HFA/HW validation", title_profile["admission"])
        self.assertIn("MatchesHunexGgeTitleProfile", profile_header)
        self.assertIn("IsHunexGgeVoiceArchivePath", profile_header)
        self.assertNotIn("ExecutableSha256", profile_header)
        self.assertNotIn("executable_sha256", profile_header)

        resource = hunex["audio"]["priority"][0]
        self.assertEqual("hunex_hfa_hw_ogg_resource", resource["kind"])
        self.assertEqual("implemented_unverified", resource["status"])
        self.assertEqual("not_verified", resource["clean_voice"])
        self.assertIn("tests/hunex_gge_adapter_test.cpp", hunex["test_paths"])
        self.assertTrue(
            any(
                "resource_observed" in limitation
                for limitation in hunex["known_limitations"]
            )
        )
        self.assertTrue(
            any(
                "not a HUNEX-family invariant" in limitation
                for limitation in hunex["known_limitations"]
            )
        )

    def test_hunex_geometry_graduation_is_recorded_with_unverified_gates(self) -> None:
        # The exact geometry provider was deliberately graduated out of
        # observation-only, which deleted generate_engine_support.py's
        # "must not OfferReady/PublishHit" assertion. Pin the graduation record
        # and the still-unverified gates together, in one known_limitations
        # entry, so a later edit cannot keep the promotion while dropping the
        # caveat -- and so this guard cannot be satisfied by narrative that
        # only states one of the two.
        hunex = self.engines["hunex_gge"]
        lookup = next(
            record
            for record in self.manifest["lookup_support"]["engines"]
            if record["engine_id"] == "hunex_gge"
        )
        self.assertIn("engine_exact_layout", lookup["geometry"]["providers"])
        self.assertEqual("implemented_unverified", lookup["geometry"]["status"])
        self.assertEqual("implemented_unverified", hunex["current_status"])
        self.assertEqual(
            "not_verified", hunex["audio"]["priority"][0]["clean_voice"]
        )
        self.assertEqual([], hunex["verified_games"])
        required = (
            "observation-only",
            "OfferReady/PublishHit",
            "implemented_unverified",
            "not_verified",
        )
        self.assertTrue(
            any(
                all(token in limitation for token in required)
                for limitation in hunex["known_limitations"]
            ),
            "one known_limitations entry must record the graduation out of "
            "observation-only together with the gates that stay unverified",
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

    def test_lookup_matrix_is_windows_only_no_ocr_and_excludes_audio_backend(self) -> None:
        lookup = self.manifest["lookup_support"]
        self.assertEqual(["windows_x86", "windows_x64"], lookup["platforms"])
        self.assertEqual("forbidden", lookup["ocr_policy"])
        self.assertFalse(lookup["experimental_providers_default_enabled"])
        ids = {record["engine_id"] for record in lookup["engines"]}
        self.assertEqual(GENERATOR.LOOKUP_ACCEPTANCE_ENGINE_IDS, ids)
        self.assertNotIn("xaudio2_directsound", ids)
        for record in lookup["engines"]:
            self.assertEqual(
                {"geometry", "verified_shield", "risky_left_click"},
                set(GENERATOR.LOOKUP_EVIDENCE_AREAS).intersection(record),
            )

    def test_lookup_native_publishers_and_manifest_have_bidirectional_parity(self) -> None:
        source_pairs = GENERATOR.discover_production_lookup_provider_pairs(ROOT)
        hunex_pair = (
            "kLookupGeometryProviderEngineExactLayout",
            "kLookupGeometryProviderIdHunexGge",
        )
        self.assertIn(
            hunex_pair,
            source_pairs,
            "HUNEX exact provider must remain visible to manifest parity",
        )
        GENERATOR.validate_manifest(self.manifest, ROOT)

        hunex = next(
            record
            for record in self.manifest["lookup_support"]["engines"]
            if record["engine_id"] == "hunex_gge"
        )
        hunex["geometry"]["providers"].remove("engine_exact_layout")
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "lookup provider manifest parity drift"
        ):
            GENERATOR.validate_manifest(self.manifest, ROOT)

    def test_smash_fzmedia_exact_provider_is_bound_to_lookup_matrix(self) -> None:
        # 16-engine lookup matrix: smash/fzmedia joins with the exact provider
        # id 15 bound to engine_exact_layout, and nothing else may claim it.
        self.assertEqual(16, len(GENERATOR.LOOKUP_ACCEPTANCE_ENGINE_IDS))
        self.assertIn("smash_fzmedia", GENERATOR.LOOKUP_ACCEPTANCE_ENGINE_IDS)
        smash_pair = (
            "kLookupGeometryProviderEngineExactLayout",
            "kLookupGeometryProviderIdSmashFzmedia",
        )
        self.assertEqual(
            ("smash_fzmedia", "engine_exact_layout"),
            GENERATOR.LOOKUP_NATIVE_PROVIDER_MANIFEST_BINDINGS[smash_pair],
        )
        self.assertIn(
            smash_pair, GENERATOR.discover_production_lookup_provider_pairs(ROOT)
        )
        smash = next(
            record
            for record in self.manifest["lookup_support"]["engines"]
            if record["engine_id"] == "smash_fzmedia"
        )
        self.assertIn("engine_exact_layout", smash["geometry"]["providers"])
        for area in GENERATOR.LOOKUP_EVIDENCE_AREAS:
            self.assertEqual("implemented_unverified", smash[area]["status"])

    def test_lookup_claim_cannot_be_promoted_without_real_build_gates(self) -> None:
        siglus = next(
            record
            for record in self.manifest["lookup_support"]["engines"]
            if record["engine_id"] == "siglus"
        )
        siglus["verified_shield"]["status"] = "verified"
        siglus["verified_shield"]["scope"] = "exact_build"
        siglus["verified_shield"]["build_evidence"] = []
        with self.assertRaisesRegex(
            GENERATOR.ManifestError, "independent real build"
        ):
            GENERATOR.validate_manifest(self.manifest)

    def test_lookup_experimental_geometry_is_observation_only(self) -> None:
        tyrano = next(
            record
            for record in self.manifest["lookup_support"]["engines"]
            if record["engine_id"] == "tyrano_nwjs"
        )
        tyrano["geometry"]["providers"].append("pixel_template_experimental")
        tyrano["geometry"]["status"] = "partial"
        tyrano["geometry"]["scope"] = "exact_build"
        tyrano["geometry"]["build_evidence"] = [
            {
                "exe_sha256": "A" * 64,
                "positive_probes": 200,
                "negative_samples": 100,
                "stale_generation_cases": 100,
                "same_session_card_e2e": 3,
                "wrong_character_hits": 0,
                "negative_false_publish": 0,
                "stale_hits": 0,
            }
        ]
        with self.assertRaisesRegex(GENERATOR.ManifestError, "observation-only"):
            GENERATOR.validate_manifest(self.manifest)


if __name__ == "__main__":
    unittest.main()

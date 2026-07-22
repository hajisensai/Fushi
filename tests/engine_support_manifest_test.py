#!/usr/bin/env python3
"""P0 contract tests for the generated engine support matrix."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from types import ModuleType


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
        self.assertEqual(
            {
                "siglus",
                "kirikiri_z",
                "xaudio2_directsound",
                "renpy_ffmpeg",
                "unity_il2cpp",
            },
            set(self.engines),
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


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Validate engine-support.yaml and render its deterministic Markdown matrix.

The manifest intentionally uses YAML 1.2's JSON-compatible syntax. This keeps
the generator dependency-free while the .yaml file remains consumable by YAML
tooling. Do not add recognition signatures copied only from external databases:
every non-empty signature group must carry real-sample/runtime evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from galhook_evidence import validate_evidence

DEFAULT_SOURCE = ROOT / "engine-support.yaml"
ALLOWED_STATUSES = {
    "verified",
    "partial",
    "implemented_unverified",
    "unavailable",
}
SIGNATURE_FIELDS = (
    "executable_names",
    "pe_architectures",
    "directory_files_all",
    "pe_imports",
    "runtime_modules",
    "resource_extensions",
    "hashes",
)
REQUIRED_ENGINE_FIELDS = (
    "id",
    "display_name",
    "aliases",
    "family",
    "detection",
    "process_strategy",
    "text",
    "audio",
    "verified_games",
    "current_status",
    "known_limitations",
    "adapter_path",
    "fixture_paths",
    "test_paths",
)
STATUS_RANK = {
    "unavailable": 0,
    "implemented_unverified": 1,
    "partial": 2,
    "verified": 3,
}
# Existing claims predate the structured evidence contract. Keep these exact
# hashes only for backward compatibility; changed/new claims must link a
# release-eligible evidence document. Never refresh hashes to bypass evidence.
LEGACY_ENGINE_STATUSES = {
    "siglus": "verified",
    "reallive": "implemented_unverified",
    "kirikiri_z": "partial",
    "xaudio2_directsound": "verified",
    "renpy_ffmpeg": "implemented_unverified",
    "tyrano_nwjs": "partial",
    "bgi_ethornell": "implemented_unverified",
    "artemis_pfs": "partial",
    "catsystem2": "partial",
    "malie_libp": "partial",
    "qlie_filepack": "partial",
    "unity_il2cpp": "verified",
}
LEGACY_CAPABILITY_CLAIM_HASHES = {
    "siglus:audio:resource_audio": "7b2316ffcfa06be52c0c6248f293ad5bb2c4c22d4f81be881cd41e8c8b754eeb",
    "siglus:audio:directsound_pcm": "d4b53cdf9d022d3796267d8ac2f7a4b7dc6102e653d9b0f290d5b40e008c5e39",
    "siglus:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "kirikiri_z:audio:directsound_pcm": "93a3ae17bc12f8b3bfda2fca05dce8eda038ac4c24c5a465d9b456cd4aa85bfd",
    "kirikiri_z:audio:process_loopback": "803493d53592050c2169a148ffec2dda8933a1a2073b9ff81238c286fd236eea",
    "xaudio2_directsound:audio:xaudio2_source_voice_pcm": "eb054fe518b735eae6c3f4b0d606e9c5a8a907947f97af6452fd6ad1e2449f99",
    "xaudio2_directsound:audio:directsound_buffer_pcm": "7d3efc8d037d0ecd9026b84f89ef05744b20d0ab5675acdb3d1e652a7a5c87df",
    "renpy_ffmpeg:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "tyrano_nwjs:audio:tyrano_asar_voice_resource": "335410b4036d7acd473201f8e8df781e41e24229caede45fa5f334b6f6063c9b",
    "tyrano_nwjs:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "artemis_pfs:audio:artemis_pf8_voice_resource": "489ae075d110a01512037e6e9846569fbae352ac34767e2abb58bf95df784690",
    "artemis_pfs:audio:directsound_pcm": "74b4827e1e99823f20f2df1aecc5b3687a257438f366e55c77d3c3ab4b69095f",
    "artemis_pfs:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "catsystem2:audio:catsystem2_unencrypted_kif_voice_resource": "f92f831a9a4e85d9f3a699f3d35d9467e0fbdcae5e7a8881d33405dd3d41fcb9",
    "catsystem2:audio:directsound_pcm": "9b248c5ff2544381130989338bb4bc31f3828f4cf673b5a77f7bb54c9f74d450",
    "catsystem2:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "malie_libp:audio:malie_libp_cfi_voice_resource": "d421dc04a4d26d4a794bf266c4b776b723c55367cd91b7ac48d3adc0c1ede47f",
    "malie_libp:audio:directsound_pcm": "d728a4f98d6f934d2a510c4c61165c4902ad9c0b0460cf9f8a179747488b0c43",
    "malie_libp:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
    "qlie_filepack:audio:qlie_wuvorbis_per_source_pcm": "3428a1638a385e599eb41947a7735278b48fd13d648047c267e9437f4a9de217",
    "qlie_filepack:audio:directsound_pcm": "41e211507605fd8121ec6e5b3f15fe8825eff87d14c118967b0fd9e7ba83e6a9",
    "qlie_filepack:audio:process_loopback": "803493d53592050c2169a148ffec2dda8933a1a2073b9ff81238c286fd236eea",
    "unity_il2cpp:text:luna_pc_hooks": "061a1852221b66ccee322f94209199d390655a4290454789a58a150517219d26",
    "unity_il2cpp:text:unity_tmp_events": "91a5bde722d9ccb411d3c7ede2b8b39ad6520427e82eb39a71f6ebf5ea99a02f",
    "unity_il2cpp:audio:unity_audioclip_resource": "9eea0fa71a92f8dcb03a355190fcd43b9cbc407691baeb12ba764551fd9f94fa",
    "unity_il2cpp:audio:xaudio2_source_voice_pcm": "d5a4101e13fe1f93a1721be402fd9e1f0d3f7b9d14129279dac04ca23938a7fa",
    "unity_il2cpp:audio:process_loopback": "c47de17dc5977323136fd947e33eddfe08a316b268122083d14a114e2c9620ee",
}
LEGACY_VERIFIED_GAMES_PREFIX = {
    "siglus": (1, "bad79e9dd64ca9bbf77e61ae6a86f24d723c28eb93b876bdc201112518c1e47d"),
    "reallive": (0, "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"),
    "kirikiri_z": (2, "e0dfa4748ebdbaa09a8607c74332e5f2e3bd3838bbfeb99851e591c6d89e9382"),
    "xaudio2_directsound": (1, "966ee962efb7da1f1df11ef37a5f33546e9007b096e5526dd6b919a0d84f56cb"),
    "renpy_ffmpeg": (1, "042fdc2d15148d3cf59a7f58d1256ffa335c9afe221e63926f51cf8b8193a540"),
    "tyrano_nwjs": (1, "8ac425f7d8e73b3e79d79cfe2c2ec04d397861a1fac06590726c2dba40e83c89"),
    "bgi_ethornell": (0, "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"),
    "artemis_pfs": (1, "365d343225f191a042b2ac53a1fe7d5c32f74549f47283559fe87c1b0fe85929"),
    "catsystem2": (1, "0b684b6ad4e64b0b176c205c5cbb909fa321c8a837eb40f2df0216af1c8c1cbf"),
    "malie_libp": (1, "c966c0bb70fad0782773029ea60a746108f1ff8b18f4bd04c045f01fc1ce40bc"),
    "qlie_filepack": (1, "845cb384721c48998090baacd6cfcb689a0a3e8ab5f0f0b5bfcf926d3551d813"),
    "unity_il2cpp": (1, "a9c89a1ef1fa43b3c86ec78949ab68c16ce105d34905f856126a5af3ad641e32"),
}
LEGACY_ENGINE_CLAIM_FIELD_HASHES = {
    "siglus:family": "39c743afe6daf38098a11a28784d74489abc35162f3ca2f6bfa4007314bad6ef",
    "siglus:process_strategy": "0c68fe6218ec1102ddcf0b32285706906d356da6bd35391d42b06b2c71f7db5d",
    "siglus:text_contract": "0ad102a7de623f1729e0ac76d1b25c5a6382d82ad63a1fe9f41138b9a8b2ae8b",
    "siglus:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "reallive:family": "0bdd42e1a544ad2e465bfaa41975e19db7a5cfe4e6d0cb85c533669c35df8989",
    "reallive:process_strategy": "4fc92c2e65f135296409415cc6d4c3b3345f8aa047c0fdb000553312240bee12",
    "reallive:text_contract": "3399f985e01b4fe17e4a3895b39c283b0e251311b6080b1011906f6bf70a41f7",
    "reallive:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "kirikiri_z:family": "1fcc491b95b933927d10b8549982c70106d4063cdc52168c3bdd9cbc7d38bf19",
    "kirikiri_z:process_strategy": "c2a8b87daf999b73ba1fbbb458c39ba43d41b05a8ef6119e564d20b91fd7bd16",
    "kirikiri_z:text_contract": "2d013ca1890e48bf0199f4682d72e4a7cce6693c27077974a5b90a3d8b3ff61c",
    "kirikiri_z:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "xaudio2_directsound:family": "0deed1d613a51a937ddde6a0bf1d1d1a0ea84f45460ab0f72118a05f3483f43c",
    "xaudio2_directsound:process_strategy": "1d60e5058dab518274b6a9e831371eb011a8bc55bc302d010abd2b581c4c6389",
    "xaudio2_directsound:text_contract": "b9dec651b5c331559d60bbadd2a40c3dde87402c7d9989629fec19f8f225a3db",
    "xaudio2_directsound:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "renpy_ffmpeg:family": "e542b8f0841d94f1e7256a1bf10262663382ad506088d41fee72d8c974e1c3f2",
    "renpy_ffmpeg:process_strategy": "de51ab6c2fbf273961c2a39d659e10366e3ccff1ae5f627d814893abc8029be9",
    "renpy_ffmpeg:text_contract": "e52621a29388a8d243bf036a2a46bf98cfd0ccf558c9ab429b4f8ba542e628d5",
    "renpy_ffmpeg:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "tyrano_nwjs:family": "0b9af44e4f27d5c25773e6d00cc39dc9a241fa54201d7d3e735669651c12d323",
    "tyrano_nwjs:process_strategy": "81171eb4192f0c6099a1447fd9febfd978848d068aebf16c645be55252aaf72b",
    "tyrano_nwjs:text_contract": "4fed2fd4b35adad6c8b6a9d178040db111da8ab573b9e09cf29c4728a42339d4",
    "tyrano_nwjs:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "bgi_ethornell:family": "0c7679f339d0b9fd6f0d8bce1ed7f12f727df86b5ba1e30c3624d379cd93ea56",
    "bgi_ethornell:process_strategy": "41bbf34b8ab938844ec27c3a79ebdebc754de42b947a7f5376f2a7794f0efeef",
    "bgi_ethornell:text_contract": "6f70dd9a28ddfb2566f833d59bf65c6f1b44b996cc41176997b737fa7bc61309",
    "bgi_ethornell:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "artemis_pfs:family": "a88670c34a758fee2f3c2abdf411549133c660694018aefb5681a388b29770c0",
    "artemis_pfs:process_strategy": "b8a40ff1b39f7fe7d61b0e25379127ab4147a92e86051aa502f936f95df08094",
    "artemis_pfs:text_contract": "097282c24f1c1caff6f684569616122b50b57d8aa301207dbf208cde5ea81968",
    "artemis_pfs:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "catsystem2:family": "0a316b29dd3f2ec79f366c9c27e4964d2648c5be1a7ec5c5832f1b6ce785be59",
    "catsystem2:process_strategy": "944ce57be8da17fd14541bf188ac21914dee5e2a5a35b8293d7846d4cae44805",
    "catsystem2:text_contract": "b7f301e14e2d97e4e4213291263a172240e9212cdd11c8127b71254a9dc36877",
    "catsystem2:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "malie_libp:family": "2081cb25f5d58532a083ad95fbe550e3ab7913ca90a80fc8639059b649b2a9d4",
    "malie_libp:process_strategy": "3ff0bd419752085296fd43d0ff3ecbe1c25401d68ef229822f7acbf3a2b340e9",
    "malie_libp:text_contract": "0eaf6bc8ffa263e0de2cdcf65ad15142a5e8180a8a80659ad3c072fa509b2569",
    "malie_libp:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "qlie_filepack:family": "206e003828fb493a1c15755151aa43eb51e6f545c086b8e1d060e626441d586e",
    "qlie_filepack:process_strategy": "2fae5f74ae3de7eb07f027f219273589f1b87aa27d974041090f657465f2398d",
    "qlie_filepack:text_contract": "d22ac0bff7f543836a1b69104363aac238c7edadf50aca5bfaf57f7c8829fb04",
    "qlie_filepack:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "unity_il2cpp:family": "31a1d21bc4c74436b37844340fb1abd9f6b99b93cd3b5ee20bde0cf17c44c68a",
    "unity_il2cpp:process_strategy": "a1fedd087a0bb45ada684e428f4967938f10112ce2f715df2bc5d339529b4ad6",
    "unity_il2cpp:text_contract": "b71d40c7c86e6e936d30c6eb6207f19d1ed5bd54a0ecf74463fca426e110850d",
    "unity_il2cpp:audio_contract": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
}
LEGACY_LIMITATIONS_PREFIX = {
    "siglus": (3, "17455ce073881f0de8b794ae21b1dd4aa53a5206658bb06502dc813a83bee706"),
    "reallive": (3, "26213432808ed52356a649551eb93f04a65a6ff0a2a9a48da46d4138127ee349"),
    "kirikiri_z": (3, "ed8a339e38f2e54514c58f4917f555176e2fde076be5dbd9f40ae72ea25de115"),
    "xaudio2_directsound": (3, "b91eae69b94a94726c4719d4e7e3776bf9d04c33200a54cc77389695c7aa9f44"),
    "renpy_ffmpeg": (4, "7c3fb8feb52fadb034353bd980fc21de1c746e11806d92b87f8081ec98be6882"),
    "tyrano_nwjs": (3, "d3c61cc8330cb4236e38860ff4c710ab8186a81f557014b10c6eb13e153aa0a9"),
    "bgi_ethornell": (3, "5bdc14013a2445fa536df7804144f0e3aa0f3cfc3dcdb73efbc3817b10060704"),
    "artemis_pfs": (3, "0c0312f436e89709ff33de1ee70f29fd8e4e616a629e865c94231dd0135b7c8c"),
    "catsystem2": (3, "a17301396c6262267057addbb544f14c1d4f3d6d657edd0f4968a21e3e5ca641"),
    "malie_libp": (4, "4f05408bc11967c2955bc59e4dab6aeb8e7fa9ae4f3443e13924b49179ba2407"),
    "qlie_filepack": (5, "f9b3e48194780e35ddc878464f7f5185f48b41504c387cdbbdf62f50edf2140c"),
    "unity_il2cpp": (3, "1de6daa5058f3b2a37a5d28ed5b4b6b6686d47945f7e5caf10109c5f3ae4e8ff"),
}
AUDIO_PROOF_BOUNDARIES = {
    "artemis_pf8_voice_resource": "resource_observed",
    "bgi_arc20_voice_resource": "resource_observed",
    "catsystem2_unencrypted_kif_voice_resource": "resource_observed",
    "directsound_buffer_pcm": "pcm_observed",
    "directsound_pcm": "pcm_observed",
    "ffmpeg54_decoder_pcm": "pcm_observed",
    "ffmpeg_resource_event": "resource_observed",
    "kirikiri_decoder_pcm": "pcm_observed",
    "kirikiri_resource_stream": "resource_observed",
    "malie_libp_cfi_voice_resource": "resource_observed",
    "process_loopback": "loopback_observed",
    "qlie_wuvorbis_float_per_source_pcm": "pcm_observed",
    "qlie_wuvorbis_per_source_pcm": "pcm_observed",
    "resource_audio": "resource_observed",
    "tyrano_asar_voice_resource": "resource_observed",
    "unity_audioclip_resource": "resource_observed",
    "visual_arts_ovk_resource": "resource_observed",
    "xaudio2_or_directsound_pcm": "pcm_observed",
    "xaudio2_source_voice_pcm": "pcm_observed",
}
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ManifestError(ValueError):
    """Raised when the machine-readable support contract is invalid."""


def load_manifest(path: Path) -> dict[str, Any]:
    """Load the JSON-compatible YAML manifest."""

    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError("manifest root must be an object")
    return value


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ManifestError(message)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(value: Any) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _engine_claim_values(engine: dict[str, Any]) -> dict[str, Any]:
    return {
        "family": engine["family"],
        "process_strategy": engine["process_strategy"],
        "text_contract": {
            key: value
            for key, value in engine["text"].items()
            if key != "capabilities"
        },
        "audio_contract": {
            key: value
            for key, value in engine["audio"].items()
            if key != "priority"
        },
        "support_status": engine["current_status"],
        "known_limitations": engine["known_limitations"],
    }


def _validate_support_evidence(
    engine: dict[str, Any],
    capability_statuses: dict[str, str],
    capability_boundaries: dict[str, str],
    required_capability_refs: set[str],
    engine_claim_hashes: dict[str, str],
    required_engine_claims: set[str],
    verified_games: list[dict[str, Any]],
    required_game_hashes: set[str],
    source_root: Path,
) -> None:
    engine_id = engine["id"]
    records = engine.get("support_evidence")
    _require(
        isinstance(records, list) and records,
        f"{engine_id}.support_evidence must be a non-empty evidence-file list",
    )
    game_by_hash: dict[str, dict[str, Any]] = {}
    for game in verified_games:
        game_hash = _canonical_sha256(game)
        _require(
            game_hash not in game_by_hash,
            f"{engine_id}.verified_games contains duplicate records",
        )
        game_by_hash[game_hash] = game

    root = source_root.resolve()
    seen_files: set[str] = set()
    aggregate_refs: set[str] = set()
    aggregate_engine_claims: set[str] = set()
    game_ref_counts: dict[str, int] = {}
    current_status_evidence = 0
    for record_index, value in enumerate(records):
        record_prefix = f"{engine_id}.support_evidence[{record_index}]"
        _require(isinstance(value, dict), f"{record_prefix} must be an object")
        relative_value = value.get("file")
        _require(
            isinstance(relative_value, str) and relative_value,
            f"{record_prefix}.file is required",
        )
        _require(
            relative_value not in seen_files,
            f"{engine_id}.support_evidence contains duplicate files",
        )
        seen_files.add(relative_value)
        relative = Path(relative_value)
        _require(
            not relative.is_absolute()
            and ".." not in relative.parts
            and len(relative.parts) >= 2
            and relative.parts[0] == "evidence"
            and relative.suffix.lower() == ".json",
            f"{record_prefix}.file must be a relative evidence/*.json path",
        )
        evidence_path = (root / relative).resolve()
        try:
            evidence_path.relative_to(root)
        except ValueError as error:
            raise ManifestError(f"{record_prefix}.file escapes the manifest root") from error

        expected_sha = value.get("sha256")
        _require(
            isinstance(expected_sha, str)
            and SHA256.fullmatch(expected_sha) is not None,
            f"{record_prefix}.sha256 must be lowercase SHA-256",
        )
        try:
            actual_sha = _sha256(evidence_path)
        except OSError as error:
            raise ManifestError(f"{record_prefix}.file cannot be read: {error}") from error
        _require(
            actual_sha == expected_sha,
            f"{record_prefix}.sha256 mismatch: expected {expected_sha}, got {actual_sha}",
        )
        try:
            evidence_document = json.loads(evidence_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ManifestError(f"{record_prefix}.file is invalid: {error}") from error
        report = validate_evidence(evidence_document)
        _require(
            report["valid"] and report["release_eligible"],
            f"{record_prefix} is not release eligible: " + "; ".join(report["errors"]),
        )
        task = evidence_document.get("task", {})
        _require(
            task.get("engine_id") == engine_id,
            f"{record_prefix} task.engine_id mismatch",
        )
        task_status = task.get("support_status")
        _require(
            task_status in {"partial", "verified"}
            and STATUS_RANK[task_status]
            <= STATUS_RANK[engine["current_status"]],
            f"{record_prefix} task.support_status exceeds manifest status",
        )
        if task_status == engine["current_status"]:
            current_status_evidence += 1

        refs = value.get("capability_refs")
        _require(
            isinstance(refs, list) and refs,
            f"{record_prefix}.capability_refs must be a non-empty list",
        )
        _require(
            all(isinstance(ref, str) and ref for ref in refs),
            f"{record_prefix}.capability_refs must contain strings",
        )
        _require(
            len(refs) == len(set(refs)),
            f"{record_prefix}.capability_refs contains duplicates",
        )
        unknown_refs = set(refs) - set(capability_statuses)
        _require(
            not unknown_refs,
            f"{record_prefix}.capability_refs are unknown: "
            + ", ".join(sorted(unknown_refs)),
        )
        unsupported_refs = {
            ref
            for ref in refs
            if capability_statuses.get(ref) not in {"partial", "verified"}
        }
        _require(
            not unsupported_refs,
            f"{record_prefix}.capability_refs are not partial/verified: "
            + ", ".join(sorted(unsupported_refs)),
        )
        proved_rows = evidence_document["stages"]["release"]["proved_capabilities"]
        proved = {row["ref"]: row["proof_boundary"] for row in proved_rows}
        _require(
            set(refs) == set(proved),
            f"{record_prefix}.capability_refs must exactly match "
            "the hash-pinned proved_capabilities",
        )
        mismatched_boundaries = {
            ref
            for ref in refs
            if capability_boundaries.get(ref) != proved.get(ref)
        }
        _require(
            not mismatched_boundaries,
            f"{record_prefix} capability proof boundary mismatch: "
            + ", ".join(sorted(mismatched_boundaries)),
        )
        _require(
            any(
                capability_boundaries.get(ref)
                in {"resource_observed", "pcm_observed"}
                for ref in refs
            ),
            f"{record_prefix} must reference engine-native audio",
        )
        aggregate_refs.update(refs)

        engine_claim_refs = value.get("engine_claim_refs")
        _require(
            isinstance(engine_claim_refs, list)
            and all(
                isinstance(claim, str) and claim
                for claim in engine_claim_refs
            ),
            f"{record_prefix}.engine_claim_refs must be a string list",
        )
        _require(
            len(engine_claim_refs) == len(set(engine_claim_refs)),
            f"{record_prefix}.engine_claim_refs contains duplicates",
        )
        proved_claim_rows = evidence_document["stages"]["release"][
            "proved_engine_claims"
        ]
        proved_claims = {
            row["claim"]: row["value_sha256"] for row in proved_claim_rows
        }
        _require(
            set(engine_claim_refs) == set(proved_claims),
            f"{record_prefix}.engine_claim_refs must exactly match "
            "the hash-pinned proved_engine_claims",
        )
        unknown_claims = set(engine_claim_refs) - set(engine_claim_hashes)
        _require(
            not unknown_claims,
            f"{record_prefix}.engine_claim_refs are unknown: "
            + ", ".join(sorted(unknown_claims)),
        )
        claim_hash_mismatches = {
            claim
            for claim in engine_claim_refs
            if engine_claim_hashes.get(claim) != proved_claims.get(claim)
        }
        _require(
            not claim_hash_mismatches,
            f"{record_prefix} engine claim hash mismatch: "
            + ", ".join(sorted(claim_hash_mismatches)),
        )
        aggregate_engine_claims.update(engine_claim_refs)

        game_ref = value.get("verified_game_ref")
        if game_ref is not None:
            _require(
                isinstance(game_ref, str) and SHA256.fullmatch(game_ref) is not None,
                f"{record_prefix}.verified_game_ref must be a canonical SHA-256",
            )
            _require(
                game_ref in game_by_hash,
                f"{record_prefix}.verified_game_ref is not in verified_games",
            )
            game_ref_counts[game_ref] = game_ref_counts.get(game_ref, 0) + 1
            game = game_by_hash[game_ref]
            identity = evidence_document["identity"]
            process = identity["process"]
            executable = identity["artifacts"]["executable"]
            _require(
                game.get("name") == task.get("game_name"),
                f"{record_prefix} verified game name mismatch",
            )
            _require(
                game.get("engine_version") == task.get("game_version"),
                f"{record_prefix} verified game version mismatch",
            )
            _require(
                game.get("architecture") == process.get("architecture"),
                f"{record_prefix} verified game architecture mismatch",
            )
            _require(
                isinstance(game.get("executable_sha256"), str)
                and game["executable_sha256"].lower()
                == executable.get("sha256", "").lower(),
                f"{record_prefix} verified game executable SHA-256 mismatch",
            )
            started_at = process.get("started_at", "")
            _require(
                isinstance(game.get("verified_on"), str)
                and len(started_at) >= 10
                and game["verified_on"] == started_at[:10],
                f"{record_prefix} verified game date mismatch",
            )

    _require(
        required_capability_refs.issubset(aggregate_refs),
        f"{engine_id}.support_evidence missing promoted capabilities: "
        + ", ".join(sorted(required_capability_refs - aggregate_refs)),
    )
    _require(
        required_engine_claims.issubset(aggregate_engine_claims),
        f"{engine_id}.support_evidence missing changed engine claims: "
        + ", ".join(sorted(required_engine_claims - aggregate_engine_claims)),
    )
    missing_games = {
        game_hash
        for game_hash in required_game_hashes
        if game_ref_counts.get(game_hash) != 1
    }
    _require(
        not missing_games,
        f"{engine_id}.support_evidence must bind each new verified game exactly once: "
        + ", ".join(sorted(missing_games)),
    )
    _require(
        current_status_evidence > 0,
        f"{engine_id}.support_evidence needs evidence for current status "
        f"{engine['current_status']}",
    )


def validate_manifest(
    manifest: dict[str, Any], source_root: Path = ROOT
) -> None:
    """Validate the P0 schema and evidence guardrails."""

    _require(
        type(manifest.get("schema_version")) is int
        and manifest["schema_version"] == 1,
        "schema_version must be 1",
    )
    _require(isinstance(manifest.get("verified_at"), str), "verified_at is required")
    _require(
        isinstance(manifest.get("generated_document"), str),
        "generated_document is required",
    )
    engines = manifest.get("engines")
    _require(isinstance(engines, list) and engines, "engines must be a non-empty list")

    seen_ids: set[str] = set()
    for index, engine in enumerate(engines):
        prefix = f"engines[{index}]"
        _require(isinstance(engine, dict), f"{prefix} must be an object")
        for field in REQUIRED_ENGINE_FIELDS:
            _require(field in engine, f"{prefix}.{field} is required")

        engine_id = engine["id"]
        _require(isinstance(engine_id, str) and engine_id, f"{prefix}.id is invalid")
        _require(engine_id not in seen_ids, f"duplicate engine id: {engine_id}")
        seen_ids.add(engine_id)
        _require(
            engine["current_status"] in ALLOWED_STATUSES,
            f"{engine_id}.current_status is invalid",
        )

        detection = engine["detection"]
        _require(isinstance(detection, dict), f"{engine_id}.detection must be an object")
        for field in SIGNATURE_FIELDS:
            group = detection.get(field)
            _require(isinstance(group, dict), f"{engine_id}.detection.{field} is required")
            values = group.get("values")
            _require(isinstance(values, list), f"{engine_id}.detection.{field}.values must be a list")
            evidence = group.get("evidence")
            if values:
                _require(isinstance(evidence, dict), f"{engine_id}.{field} needs evidence")
                _require(
                    evidence.get("kind") in {"real_sample", "runtime_observation"},
                    f"{engine_id}.{field} evidence must come from a real sample/runtime observation",
                )
                _require(
                    isinstance(evidence.get("reference"), str) and evidence["reference"],
                    f"{engine_id}.{field} evidence reference is required",
                )
            else:
                _require(evidence is None, f"{engine_id}.{field} empty values must use null evidence")

        verified_games = engine["verified_games"]
        _require(
            isinstance(verified_games, list),
            f"{engine_id}.verified_games must be a list",
        )
        legacy_games = LEGACY_VERIFIED_GAMES_PREFIX.get(engine_id)
        if legacy_games is None:
            new_games = verified_games
        else:
            legacy_game_count, legacy_games_hash = legacy_games
            _require(
                len(verified_games) >= legacy_game_count
                and _canonical_sha256(verified_games[:legacy_game_count])
                == legacy_games_hash,
                f"{engine_id}.verified_games legacy prefix is immutable; append new evidence instead",
            )
            new_games = verified_games[legacy_game_count:]
        for game_index, game in enumerate(new_games):
            _require(
                isinstance(game, dict),
                f"{engine_id} new verified_games[{game_index}] must be an object",
            )
            for field in (
                "name",
                "architecture",
                "engine_version",
                "verified_on",
                "evidence",
                "executable_sha256",
            ):
                _require(
                    isinstance(game.get(field), str) and bool(game[field]),
                    f"{engine_id} new verified_games[{game_index}].{field} "
                    "must be a non-empty string",
                )
        required_game_hashes = {
            _canonical_sha256(game) for game in new_games
        }
        _require(
            len(required_game_hashes) == len(new_games),
            f"{engine_id}.verified_games contains duplicate new records",
        )
        games_changed = bool(new_games)
        limitations = engine["known_limitations"]
        _require(
            isinstance(limitations, list)
            and all(isinstance(item, str) and item for item in limitations),
            f"{engine_id}.known_limitations must be a list of strings",
        )
        legacy_limitations = LEGACY_LIMITATIONS_PREFIX.get(engine_id)
        limitations_changed = False
        if legacy_limitations is not None:
            legacy_count, legacy_prefix_hash = legacy_limitations
            limitations_changed = (
                len(limitations) < legacy_count
                or _canonical_sha256(limitations[:legacy_count])
                != legacy_prefix_hash
            )
            _require(
                not limitations_changed,
                f"{engine_id}.known_limitations legacy prefix is immutable; "
                "append conservative limitations instead",
            )

        capability_statuses: dict[str, str] = {}
        capability_boundaries: dict[str, str] = {}
        required_capability_refs: set[str] = set()

        audio = engine["audio"]
        _require(isinstance(audio, dict), f"{engine_id}.audio must be an object")
        priority = audio.get("priority")
        _require(isinstance(priority, list) and priority, f"{engine_id}.audio.priority is required")
        seen_audio: set[str] = set()
        for capability_index, capability in enumerate(priority):
            _require(
                isinstance(capability, dict),
                f"{engine_id} audio capability must be an object",
            )
            kind = capability.get("kind")
            _require(
                isinstance(kind, str) and kind,
                f"{engine_id} audio capability kind is required",
            )
            _require(kind not in seen_audio, f"{engine_id} duplicate audio capability: {kind}")
            seen_audio.add(kind)
            _require(
                capability.get("status") in ALLOWED_STATUSES,
                f"{engine_id} audio capability has invalid status",
            )
            ref = f"audio:{kind}"
            capability_statuses[ref] = capability["status"]
            proof_boundary = AUDIO_PROOF_BOUNDARIES.get(kind)
            if capability["status"] in {"partial", "verified"}:
                _require(
                    proof_boundary is not None,
                    f"{engine_id} audio capability {kind} needs a proof-boundary mapping",
                )
                capability_boundaries[ref] = proof_boundary
            legacy_key = f"{engine_id}:{ref}"
            if (
                capability["status"] in {"partial", "verified"}
                and _canonical_sha256({"index": capability_index, **capability})
                != LEGACY_CAPABILITY_CLAIM_HASHES.get(legacy_key)
            ):
                required_capability_refs.add(ref)

        text = engine["text"]
        _require(isinstance(text, dict), f"{engine_id}.text must be an object")
        seen_text: set[str] = set()
        text_capabilities = text.get("capabilities", [])
        _require(
            isinstance(text_capabilities, list),
            f"{engine_id}.text.capabilities must be a list",
        )
        for capability_index, capability in enumerate(text_capabilities):
            _require(
                isinstance(capability, dict),
                f"{engine_id} text capability must be an object",
            )
            kind = capability.get("kind")
            _require(
                isinstance(kind, str) and kind,
                f"{engine_id} text capability kind is required",
            )
            _require(kind not in seen_text, f"{engine_id} duplicate text capability: {kind}")
            seen_text.add(kind)
            _require(
                capability.get("status") in ALLOWED_STATUSES,
                f"{engine_id} text capability has invalid status",
            )
            ref = f"text:{kind}"
            capability_statuses[ref] = capability["status"]
            if capability["status"] in {"partial", "verified"}:
                capability_boundaries[ref] = "text_observed"
            legacy_key = f"{engine_id}:{ref}"
            if (
                capability["status"] in {"partial", "verified"}
                and _canonical_sha256({"index": capability_index, **capability})
                != LEGACY_CAPABILITY_CLAIM_HASHES.get(legacy_key)
            ):
                required_capability_refs.add(ref)

        legacy_status = LEGACY_ENGINE_STATUSES.get(
            engine_id, "implemented_unverified"
        )
        status_promoted = (
            STATUS_RANK[engine["current_status"]] > STATUS_RANK[legacy_status]
        )
        engine_claim_values = _engine_claim_values(engine)
        engine_claim_hashes = {
            claim: _canonical_sha256(value)
            for claim, value in engine_claim_values.items()
        }
        required_engine_claims: set[str] = set()
        for claim in ("family", "process_strategy", "text_contract", "audio_contract"):
            legacy_hash = LEGACY_ENGINE_CLAIM_FIELD_HASHES.get(
                f"{engine_id}:{claim}"
            )
            if (
                (legacy_hash is None and status_promoted)
                or (
                    legacy_hash is not None
                    and engine_claim_hashes[claim] != legacy_hash
                )
            ):
                required_engine_claims.add(claim)
        if status_promoted:
            required_engine_claims.add("support_status")
            if engine_id not in LEGACY_ENGINE_STATUSES:
                required_engine_claims.add("known_limitations")
        if (
            status_promoted
            or games_changed
            or required_capability_refs
            or required_engine_claims
            or "support_evidence" in engine
        ):
            _validate_support_evidence(
                engine,
                capability_statuses,
                capability_boundaries,
                required_capability_refs,
                engine_claim_hashes,
                required_engine_claims,
                verified_games,
                required_game_hashes,
                source_root,
            )


def _display_value(value: Any) -> str:
    if value is None:
        return "未记录"
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, dict):
        return ", ".join(f"{key}={_display_value(item)}" for key, item in value.items())
    return str(value)


def _join(values: list[Any], empty: str = "—") -> str:
    return "、".join(_display_value(value) for value in values) if values else empty


def _escape_table(value: Any) -> str:
    return _display_value(value).replace("|", "\\|").replace("\n", " ")


def _capability_summary(capabilities: list[dict[str, Any]]) -> str:
    return "；".join(
        f"{item['kind']} ({item['status']})" for item in capabilities
    ) or "—"


def render_manifest(manifest: dict[str, Any], source_root: Path = ROOT) -> str:
    """Render a stable human-readable support matrix."""

    validate_manifest(manifest, source_root)
    baseline = manifest["source_baseline"]
    lines = [
        "# Galgame 引擎支持矩阵",
        "",
        "> 此文件由 `engine-support.yaml` 通过 `tools/generate_engine_support.py` 自动生成，禁止手工编辑。",
        f"> 状态基线：{manifest['verified_at']}；来源：`{baseline['repository']}/{baseline['document']}`（{baseline['section']}）。",
        "> “已验证”只代表下方明确列出的真实样本、版本和能力，不外推到同家族的其它游戏。",
        "",
        "## 总览",
        "",
        "| ID | 引擎 / 后端 | 状态 | 文本 | 音频优先级 | 已验证样本 |",
        "|---|---|---|---|---|---|",
    ]
    for engine in manifest["engines"]:
        lines.append(
            "| "
            + " | ".join(
                (
                    f"`{_escape_table(engine['id'])}`",
                    _escape_table(engine["display_name"]),
                    f"`{_escape_table(engine['current_status'])}`",
                    _escape_table(_capability_summary(engine["text"]["capabilities"])),
                    _escape_table(_capability_summary(engine["audio"]["priority"])),
                    str(len(engine["verified_games"])),
                )
            )
            + " |"
        )

    lines.extend(["", "## 识别与能力明细", ""])
    for engine in manifest["engines"]:
        lines.extend(
            [
                f"### {engine['display_name']} (`{engine['id']}`)",
                "",
                f"- 状态：`{engine['current_status']}`",
                f"- 别名：{_join(engine['aliases'])}",
                f"- 家族：`{engine['family']['id']}`（{engine['family']['relation']}）",
                f"- 当前 adapter：`{engine['adapter_path']}`",
                "- 进程策略："
                f"launch=`{engine['process_strategy']['launch']}`，"
                f"attach=`{engine['process_strategy']['attach']}`，"
                f"follow-child=`{str(engine['process_strategy']['follow_child_processes']).lower()}`",
                "",
                "识别签名（所有非空项均带真实样本或运行时观察证据）：",
                "",
            ]
        )
        if engine.get("support_evidence"):
            lines.append("结构化支持证据：")
            lines.append("")
            for record in engine["support_evidence"]:
                game_ref = record.get("verified_game_ref", "—")
                lines.append(
                    f"- `{record['file']}` @ `{record['sha256']}`；"
                    f"capabilities：{_join(record['capability_refs'])}；"
                    f"engine claims：{_join(record['engine_claim_refs'])}；"
                    f"verified game ref：`{game_ref}`"
                )
            lines.append("")
        for field in SIGNATURE_FIELDS:
            group = engine["detection"][field]
            values = group["values"]
            if not values:
                continue
            evidence = group["evidence"]
            lines.append(
                f"- `{field}`：{_join(values)}；证据：{evidence['kind']} — {evidence['reference']}"
            )

        lines.extend(["", "文本能力：", ""])
        if engine["text"]["capabilities"]:
            for item in engine["text"]["capabilities"]:
                lines.append(
                    f"- `{item['kind']}`：`{item['status']}` — {item['verification']}"
                )
        else:
            lines.append("- 不适用；文本由具体引擎 profile / Luna 线程处理。")
        lines.append(f"- codepage：{engine['text']['codepage']}")
        lines.append(f"- 线程提示：{engine['text']['thread_selection_hint']}")

        lines.extend(["", "音频优先级：", ""])
        for order, item in enumerate(engine["audio"]["priority"], start=1):
            lines.append(
                f"{order}. `{item['kind']}` — `{item['status']}`；格式：{item['format']}；"
                f"clean voice：{_display_value(item['clean_voice'])}"
            )

        lines.extend(["", "真实样本证据：", ""])
        for game in engine["verified_games"]:
            lines.append(
                f"- **{game['name']}**（{game['architecture']}，{game['engine_version']}，"
                f"{game['verified_on']}）：{game['evidence']} "
                f"SHA-256：{_display_value(game['executable_sha256'])}。"
            )

        lines.extend(["", "已知限制：", ""])
        lines.extend(f"- {item}" for item in engine["known_limitations"])
        lines.extend(
            [
                "",
                f"Fixtures：{_join([f'`{path}`' for path in engine['fixture_paths']], '尚无（P5 补齐）')}",
                "",
                f"Tests：{_join([f'`{path}`' for path in engine['test_paths']])}",
                "",
            ]
        )

    lines.extend(
        [
            "## 状态定义",
            "",
        ]
    )
    for status, description in manifest["status_definitions"].items():
        lines.append(f"- `{status}`：{description}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the checked-in Markdown is missing or stale",
    )
    args = parser.parse_args()

    manifest = load_manifest(args.source)
    rendered = render_manifest(manifest, args.source.resolve().parent)
    output = args.output or ROOT / manifest["generated_document"]
    if args.check:
        try:
            existing = output.read_text(encoding="utf-8")
        except OSError as error:
            raise SystemExit(f"generated document missing: {error}") from error
        if existing != rendered:
            raise SystemExit(
                f"{output} is stale; run tools/generate_engine_support.py"
            )
        print(f"OK {args.source} -> {output}")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"WROTE {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

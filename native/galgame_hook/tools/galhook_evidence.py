#!/usr/bin/env python3
"""Evidence contract and diagnostic decoding for galgame hook work."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


STAGES = ("observed", "implemented", "offline", "runtime", "e2e", "release")
STAGE_RESULTS = {"not_run", "pass", "fail"}
BOUNDARIES = (
    "process_found",
    "helper_ready",
    "ipc_ready",
    "text_observed",
    "text_thread_selected",
    "resource_observed",
    "pcm_observed",
    "paired",
    "loopback_observed",
    "card_e2e",
)
BOUNDARY_RESULTS = {"not_run", "pass", "fail", "not_applicable"}
OPTIONAL_BOUNDARIES = {
    "resource_observed",
    "pcm_observed",
    "loopback_observed",
}
ARCHITECTURES = {"x86", "x64"}
E2E_AUDIO_LAYERS = {
    "resource_observed",
    "pcm_observed",
    "loopback_observed",
}
NATIVE_AUDIO_LAYERS = {"resource_observed", "pcm_observed"}
ENGINE_CLAIMS = {
    "family",
    "process_strategy",
    "text_contract",
    "audio_contract",
    "support_status",
    "known_limitations",
}
OFFLINE_GATES = (
    "engine_support_check",
    "luna_profile_check",
    "lunahook_vendor_check",
    "adapter_structure_tests",
    "evidence_contract_tests",
    "workflow_tests",
    "production_replay",
    "x64_build",
    "x64_ctest",
    "x86_build",
    "x86_ctest",
)
SUPPORT_STATUSES = {
    "implemented_unverified",
    "partial",
    "verified",
    "unavailable",
}
SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")
ENGINE_ID = re.compile(r"^[a-z][a-z0-9_]{1,47}$")
CAPABILITY_REF = re.compile(r"^(text|audio):[a-z][a-z0-9_]{1,63}$")
DIAG_CONSTANT = re.compile(
    r"constexpr\s+uint32_t\s+(kDiag[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)u?;"
)


def new_evidence(engine_id: str) -> dict[str, Any]:
    if not ENGINE_ID.fullmatch(engine_id):
        raise ValueError("engine id must match ^[a-z][a-z0-9_]{1,47}$")
    return {
        "schema_version": 1,
        "task": {
            "engine_id": engine_id,
            "game_name": "",
            "game_version": "",
            "original_failure_path": "",
            "support_status": "implemented_unverified",
        },
        "identity": {
            "original_launch": {
                "method": "",
                "launcher": "",
                "original_path_reproduced": False,
            },
            "process": {
                "pid": None,
                "parent_pid": None,
                "architecture": "",
                "started_at": "",
            },
            "artifacts": {
                "executable": {"path": "", "sha256": "", "architecture": ""},
                "target_module": {"path": "", "sha256": "", "architecture": ""},
                "injector": {"path": "", "sha256": "", "architecture": ""},
                "hook_dll": {"path": "", "sha256": "", "architecture": ""},
            },
        },
        "timeline": [],
        "first_failed_boundary": None,
        "boundaries": [
            {"id": boundary, "status": "not_run", "evidence": []}
            for boundary in BOUNDARIES
        ],
        "stages": {
            "observed": {"status": "not_run", "evidence": []},
            "implemented": {
                "status": "not_run",
                "change_refs": [],
                "guard_refs": [],
            },
            "offline": {
                "status": "not_run",
                "commands": [
                    {
                        "gate": gate,
                        "command": "",
                        "exit_code": None,
                        "evidence": "",
                    }
                    for gate in OFFLINE_GATES
                ],
                "architectures": [],
                "production_replay": False,
            },
            "runtime": {"status": "not_run", "session_id": "", "evidence": []},
            "e2e": {
                "status": "not_run",
                "session_id": "",
                "text_source": "",
                "audio_layer": "",
                "pairing_evidence": "",
                "screenshot_evidence": "",
                "card_evidence": "",
            },
            "release": {
                "status": "not_run",
                "manifest_ref": "",
                "generated_matrix_check": "",
                "proved_capabilities": [],
                "proved_engine_claims": [],
            },
        },
        "privacy": {
            "payloads_included": False,
            "notes": "Keep only redacted metadata, hashes, and authorized minimal evidence.",
        },
    }


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _mapping(value: Any, path: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{path} must be an object")
        return {}
    return value


def _list(value: Any, path: str, errors: list[str]) -> list[Any]:
    if not isinstance(value, list):
        errors.append(f"{path} must be an array")
        return []
    return value


def _string_list(
    value: Any, path: str, errors: list[str], *, required: bool = False
) -> list[str]:
    values = _list(value, path, errors)
    if required and not values:
        errors.append(f"{path} must be a non-empty array")
    for index, item in enumerate(values):
        if not _nonempty_string(item):
            errors.append(f"{path}[{index}] must be a non-empty string")
    return [item for item in values if isinstance(item, str) and item.strip()]


def _validate_boundaries(
    value: Any, errors: list[str]
) -> tuple[dict[str, str], str | None]:
    rows = _list(value, "boundaries", errors)
    if len(rows) != len(BOUNDARIES):
        errors.append(
            f"boundaries must contain exactly {len(BOUNDARIES)} ordered entries"
        )
    statuses: dict[str, str] = {}
    first_fail: str | None = None
    stopped = False
    for index, expected_id in enumerate(BOUNDARIES):
        if index >= len(rows):
            break
        row = _mapping(rows[index], f"boundaries[{index}]", errors)
        boundary_id = row.get("id")
        status = row.get("status")
        if boundary_id != expected_id:
            errors.append(
                f"boundaries[{index}].id must be {expected_id!r}, got {boundary_id!r}"
            )
        if status not in BOUNDARY_RESULTS:
            errors.append(
                f"boundaries[{index}].status must be one of {sorted(BOUNDARY_RESULTS)}"
            )
            continue
        statuses[expected_id] = status
        _string_list(
            row.get("evidence"),
            f"boundaries[{index}].evidence",
            errors,
            required=status in {"pass", "fail"},
        )
        if status == "not_applicable" and expected_id not in OPTIONAL_BOUNDARIES:
            errors.append(f"boundary {expected_id} cannot be not_applicable")
        if stopped and status != "not_run":
            errors.append(
                f"boundary {expected_id} must be not_run after the first unresolved boundary"
            )
        if status in {"fail", "not_run"}:
            if status == "fail" and first_fail is None:
                first_fail = expected_id
            stopped = True
    return statuses, first_fail


def _validate_identity(
    document: dict[str, Any], errors: list[str]
) -> tuple[int | None, dict[str, dict[int, int | float]]]:
    identity = _mapping(document.get("identity"), "identity", errors)
    launch = _mapping(identity.get("original_launch"), "identity.original_launch", errors)
    process = _mapping(identity.get("process"), "identity.process", errors)
    artifacts = _mapping(identity.get("artifacts"), "identity.artifacts", errors)
    for field in ("method", "launcher"):
        if not _nonempty_string(launch.get(field)):
            errors.append(f"identity.original_launch.{field} is required")
    if launch.get("original_path_reproduced") is not True:
        errors.append(
            "identity.original_launch.original_path_reproduced must be true"
        )
    pid = process.get("pid")
    parent_pid = process.get("parent_pid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        errors.append("identity.process.pid must be a positive integer")
    if not isinstance(parent_pid, int) or isinstance(parent_pid, bool) or parent_pid < 0:
        errors.append("identity.process.parent_pid must be a non-negative integer")
    if process.get("architecture") not in ARCHITECTURES:
        errors.append(
            f"identity.process.architecture must be one of {sorted(ARCHITECTURES)}"
        )
    if not _nonempty_string(process.get("started_at")):
        errors.append("identity.process.started_at is required")
    for role in ("executable", "target_module", "injector", "hook_dll"):
        artifact = _mapping(artifacts.get(role), f"identity.artifacts.{role}", errors)
        if not _nonempty_string(artifact.get("path")):
            errors.append(f"identity.artifacts.{role}.path is required")
        if not SHA256.fullmatch(str(artifact.get("sha256", ""))):
            errors.append(
                f"identity.artifacts.{role}.sha256 must be 64 hexadecimal characters"
            )
        if artifact.get("architecture") != process.get("architecture"):
            errors.append(
                f"identity.artifacts.{role}.architecture must equal "
                "identity.process.architecture"
            )
    expected_suffixes = {
        "executable": {".exe"},
        "target_module": {".exe", ".dll"},
        "injector": {".exe"},
        "hook_dll": {".dll"},
    }
    for role, suffixes in expected_suffixes.items():
        artifact = artifacts.get(role, {})
        path_value = artifact.get("path") if isinstance(artifact, dict) else None
        if _nonempty_string(path_value) and Path(path_value).suffix.lower() not in suffixes:
            errors.append(
                f"identity.artifacts.{role}.path must end with "
                + " or ".join(sorted(suffixes))
            )
    incompatible_pairs = (
        ("injector", "hook_dll"),
        ("injector", "executable"),
        ("injector", "target_module"),
        ("hook_dll", "executable"),
        ("hook_dll", "target_module"),
    )
    for left, right in incompatible_pairs:
        left_artifact = artifacts.get(left, {})
        right_artifact = artifacts.get(right, {})
        if not isinstance(left_artifact, dict) or not isinstance(right_artifact, dict):
            continue
        left_path = left_artifact.get("path")
        right_path = right_artifact.get("path")
        if (
            _nonempty_string(left_path)
            and _nonempty_string(right_path)
            and left_path.strip().lower() == right_path.strip().lower()
        ):
            errors.append(
                f"identity artifacts {left} and {right} must use different paths"
            )
        left_sha = left_artifact.get("sha256")
        right_sha = right_artifact.get("sha256")
        if (
            isinstance(left_sha, str)
            and isinstance(right_sha, str)
            and SHA256.fullmatch(left_sha) is not None
            and SHA256.fullmatch(right_sha) is not None
            and left_sha.lower() == right_sha.lower()
        ):
            errors.append(
                f"identity artifacts {left} and {right} must use different SHA-256"
            )
    timeline = _list(document.get("timeline"), "timeline", errors)
    events: dict[str, dict[int, int | float]] = {}
    previous_at_ms: int | float | None = None
    for index, item in enumerate(timeline):
        row = _mapping(item, f"timeline[{index}]", errors)
        event = row.get("event")
        if not _nonempty_string(event):
            errors.append(f"timeline[{index}].event is required")
        at_ms = row.get("at_ms")
        if (
            not isinstance(at_ms, (int, float))
            or isinstance(at_ms, bool)
            or at_ms < 0
        ):
            errors.append(f"timeline[{index}].at_ms must be a non-negative number")
        elif previous_at_ms is not None and at_ms < previous_at_ms:
            errors.append("timeline entries must be ordered by at_ms")
        else:
            previous_at_ms = at_ms
        row_pid = row.get("pid")
        if not isinstance(row_pid, int) or isinstance(row_pid, bool) or row_pid <= 0:
            errors.append(f"timeline[{index}].pid must be a positive integer")
        elif _nonempty_string(event):
            event_pids = events.setdefault(event, {})
            previous_event_time = event_pids.get(row_pid)
            if previous_event_time is None or at_ms < previous_event_time:
                event_pids[row_pid] = at_ms
        if not _nonempty_string(row.get("evidence")):
            errors.append(f"timeline[{index}].evidence is required")
    target_pid = pid if isinstance(pid, int) and not isinstance(pid, bool) else None
    if target_pid is not None and target_pid not in events.get("process_start", {}):
        errors.append("timeline must contain process_start for identity.process.pid")
    attach_pids = set().union(
        *(
            set(events.get(name, {}))
            for name in ("attach", "injection", "attach_or_injection")
        )
    )
    if target_pid is not None and target_pid not in attach_pids:
        errors.append("timeline must contain attach or injection for identity.process.pid")
    if target_pid is not None:
        process_start = events.get("process_start", {}).get(target_pid)
        if process_start is not None:
            for event_name, event_pids in events.items():
                event_time = event_pids.get(target_pid)
                if event_time is not None and event_time < process_start:
                    errors.append(
                        f"timeline event {event_name} cannot precede process_start"
                    )
        attach_times = [
            events.get(name, {}).get(target_pid)
            for name in ("attach", "injection", "attach_or_injection")
        ]
        present_attach_times = [time for time in attach_times if time is not None]
        attach_time = min(present_attach_times) if present_attach_times else None
        ordered_lifecycle = [
            ("process_start", process_start),
            ("attach_or_injection", attach_time),
            ("helper_loaded", events.get("helper_loaded", {}).get(target_pid)),
            ("hook_installed", events.get("hook_installed", {}).get(target_pid)),
            ("helper_ready", events.get("helper_ready", {}).get(target_pid)),
            ("ipc_ready", events.get("ipc_ready", {}).get(target_pid)),
        ]
        present_lifecycle = [
            (name, time) for name, time in ordered_lifecycle if time is not None
        ]
        for (left_name, left_time), (right_name, right_time) in zip(
            present_lifecycle, present_lifecycle[1:]
        ):
            if left_time > right_time:
                errors.append(
                    f"timeline requires {left_name} <= {right_name}"
                )
        paired_time = events.get("paired", {}).get(target_pid)
        if paired_time is not None:
            for event_name in ("first_text", "first_resource", "first_pcm", "first_loopback"):
                event_time = events.get(event_name, {}).get(target_pid)
                if event_time is not None and event_time > paired_time:
                    errors.append(
                        f"timeline requires {event_name} <= paired"
                    )
        e2e_order = [
            ("paired", paired_time),
            ("screenshot", events.get("screenshot", {}).get(target_pid)),
            ("card_written", events.get("card_written", {}).get(target_pid)),
        ]
        present_e2e = [(name, time) for name, time in e2e_order if time is not None]
        for (left_name, left_time), (right_name, right_time) in zip(
            present_e2e, present_e2e[1:]
        ):
            if left_time > right_time:
                errors.append(f"timeline requires {left_name} <= {right_name}")
    return target_pid, events


def _require_target_events(
    events: dict[str, dict[int, int | float]],
    target_pid: int | None,
    names: set[str],
    errors: list[str],
    *,
    stage: str,
) -> None:
    if target_pid is None:
        return
    for name in sorted(names):
        if target_pid not in events.get(name, {}):
            errors.append(
                f"{stage} pass requires timeline event {name} for identity.process.pid"
            )


def _stage_statuses(
    document: dict[str, Any], errors: list[str]
) -> tuple[dict[str, dict[str, Any]], str | None]:
    stages = _mapping(document.get("stages"), "stages", errors)
    rows: dict[str, dict[str, Any]] = {}
    highest: str | None = None
    prior_passed = True
    stopped = False
    for stage in STAGES:
        row = _mapping(stages.get(stage), f"stages.{stage}", errors)
        rows[stage] = row
        status = row.get("status")
        if status not in STAGE_RESULTS:
            errors.append(
                f"stages.{stage}.status must be one of {sorted(STAGE_RESULTS)}"
            )
            prior_passed = False
            continue
        if status == "pass":
            if not prior_passed or stopped:
                errors.append(f"stage {stage} cannot pass before every prior stage passes")
            else:
                highest = stage
        elif status == "fail":
            if not prior_passed or stopped:
                errors.append(f"stage {stage} cannot fail before every prior stage passes")
            stopped = True
            prior_passed = False
        else:
            stopped = True
            prior_passed = False
    return rows, highest


def validate_evidence(document: Any) -> dict[str, Any]:
    errors: list[str] = []
    if not isinstance(document, dict):
        return {
            "valid": False,
            "errors": ["root must be an object"],
            "highest_proven_stage": None,
            "first_failed_boundary": None,
            "release_eligible": False,
        }
    if type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        errors.append("schema_version must be 1")
    task = _mapping(document.get("task"), "task", errors)
    engine_id = task.get("engine_id")
    if not isinstance(engine_id, str) or not ENGINE_ID.fullmatch(engine_id):
        errors.append("task.engine_id must match ^[a-z][a-z0-9_]{1,47}$")
    support_status = task.get("support_status")
    if support_status not in SUPPORT_STATUSES:
        errors.append(
            f"task.support_status must be one of {sorted(SUPPORT_STATUSES)}"
        )
    privacy = _mapping(document.get("privacy"), "privacy", errors)
    if privacy.get("payloads_included") is not False:
        errors.append("privacy.payloads_included must be false")

    boundary_statuses, first_fail = _validate_boundaries(
        document.get("boundaries"), errors
    )
    declared_fail = document.get("first_failed_boundary")
    if declared_fail != first_fail:
        errors.append(
            "first_failed_boundary must equal the first boundary with status fail "
            f"({first_fail!r})"
        )
    stage_rows, highest = _stage_statuses(document, errors)
    target_pid: int | None = None
    timeline_events: dict[str, dict[int, int | float]] = {}

    if stage_rows.get("observed", {}).get("status") == "pass":
        target_pid, timeline_events = _validate_identity(document, errors)
        for field in ("game_name", "game_version", "original_failure_path"):
            if not _nonempty_string(task.get(field)):
                errors.append(f"task.{field} is required when observed passes")
        _string_list(
            stage_rows["observed"].get("evidence"),
            "stages.observed.evidence",
            errors,
            required=True,
        )

    if stage_rows.get("implemented", {}).get("status") == "pass":
        _string_list(
            stage_rows["implemented"].get("change_refs"),
            "stages.implemented.change_refs",
            errors,
            required=True,
        )
        _string_list(
            stage_rows["implemented"].get("guard_refs"),
            "stages.implemented.guard_refs",
            errors,
            required=True,
        )

    if stage_rows.get("offline", {}).get("status") == "pass":
        commands = _list(
            stage_rows["offline"].get("commands"), "stages.offline.commands", errors
        )
        seen_gates: set[str] = set()
        for index, command in enumerate(commands):
            row = _mapping(command, f"stages.offline.commands[{index}]", errors)
            gate = row.get("gate")
            if not _nonempty_string(gate):
                errors.append(f"stages.offline.commands[{index}].gate is required")
            elif gate not in OFFLINE_GATES:
                errors.append(
                    f"stages.offline.commands[{index}].gate is unknown: {gate}"
                )
            elif gate in seen_gates:
                errors.append(f"duplicate offline gate: {gate}")
            else:
                seen_gates.add(gate)
            if not _nonempty_string(row.get("command")):
                errors.append(f"stages.offline.commands[{index}].command is required")
            exit_code = row.get("exit_code")
            if (
                not isinstance(exit_code, int)
                or isinstance(exit_code, bool)
                or exit_code != 0
            ):
                errors.append(
                    f"stages.offline.commands[{index}].exit_code must be 0"
                )
            if not _nonempty_string(row.get("evidence")):
                errors.append(f"stages.offline.commands[{index}].evidence is required")
        missing_gates = set(OFFLINE_GATES) - seen_gates
        if missing_gates:
            errors.append(
                "stages.offline.commands is missing gates: "
                + ", ".join(sorted(missing_gates))
            )
        architecture_values = _string_list(
            stage_rows["offline"].get("architectures"),
            "stages.offline.architectures",
            errors,
        )
        architectures = set(architecture_values)
        if not {"x86", "x64"}.issubset(architectures):
            errors.append("stages.offline.architectures must include x86 and x64")
        if stage_rows["offline"].get("production_replay") is not True:
            errors.append("stages.offline.production_replay must be true")

    if stage_rows.get("runtime", {}).get("status") == "pass":
        for boundary in BOUNDARIES[:5]:
            if boundary_statuses.get(boundary) != "pass":
                errors.append(
                    f"runtime pass requires boundary {boundary} to pass"
                )
        if not any(
            boundary_statuses.get(boundary) == "pass"
            for boundary in (
                "resource_observed",
                "pcm_observed",
                "loopback_observed",
            )
        ):
            errors.append(
                "runtime pass requires resource, PCM, or loopback capture evidence"
            )
        _string_list(
            stage_rows["runtime"].get("evidence"),
            "stages.runtime.evidence",
            errors,
            required=True,
        )
        if not _nonempty_string(stage_rows["runtime"].get("session_id")):
            errors.append("stages.runtime.session_id is required")
        required_runtime_events = {
            "helper_loaded",
            "hook_installed",
            "helper_ready",
            "ipc_ready",
            "target_module_loaded",
            "first_text",
            "text_thread_selected",
        }
        if boundary_statuses.get("resource_observed") == "pass":
            required_runtime_events.add("first_resource")
        if boundary_statuses.get("pcm_observed") == "pass":
            required_runtime_events.add("first_pcm")
        if boundary_statuses.get("loopback_observed") == "pass":
            required_runtime_events.add("first_loopback")
        _require_target_events(
            timeline_events,
            target_pid,
            required_runtime_events,
            errors,
            stage="runtime",
        )

    if stage_rows.get("e2e", {}).get("status") == "pass":
        for field in (
            "session_id",
            "text_source",
            "audio_layer",
            "pairing_evidence",
            "screenshot_evidence",
            "card_evidence",
        ):
            if not _nonempty_string(stage_rows["e2e"].get(field)):
                errors.append(f"stages.e2e.{field} is required")
        if (
            stage_rows["e2e"].get("session_id")
            != stage_rows.get("runtime", {}).get("session_id")
        ):
            errors.append(
                "stages.e2e.session_id must equal stages.runtime.session_id"
            )
        for boundary in ("paired", "card_e2e"):
            if boundary_statuses.get(boundary) != "pass":
                errors.append(f"e2e pass requires boundary {boundary} to pass")
        audio_layer = stage_rows["e2e"].get("audio_layer")
        if audio_layer not in E2E_AUDIO_LAYERS:
            errors.append(
                f"stages.e2e.audio_layer must be one of {sorted(E2E_AUDIO_LAYERS)}"
            )
        elif boundary_statuses.get(audio_layer) != "pass":
            errors.append(
                f"stages.e2e.audio_layer {audio_layer} must reference a passing boundary"
            )
        _require_target_events(
            timeline_events,
            target_pid,
            {"paired", "screenshot", "card_written"},
            errors,
            stage="e2e",
        )

    e2e_audio_layer = stage_rows.get("e2e", {}).get("audio_layer")
    native_audio = (
        e2e_audio_layer in NATIVE_AUDIO_LAYERS
        and boundary_statuses.get(e2e_audio_layer) == "pass"
    )
    if stage_rows.get("release", {}).get("status") == "pass":
        if not native_audio:
            errors.append(
                "release requires engine resource or PCM evidence; loopback is fallback only"
            )
        for field in ("manifest_ref", "generated_matrix_check"):
            if not _nonempty_string(stage_rows["release"].get(field)):
                errors.append(f"stages.release.{field} is required")
        proved_rows = _list(
            stage_rows["release"].get("proved_capabilities"),
            "stages.release.proved_capabilities",
            errors,
        )
        if not proved_rows:
            errors.append("stages.release.proved_capabilities is required")
        proved_refs: set[str] = set()
        proved_native_audio = False
        for index, item in enumerate(proved_rows):
            row = _mapping(
                item, f"stages.release.proved_capabilities[{index}]", errors
            )
            ref = row.get("ref")
            proof_boundary = row.get("proof_boundary")
            if (
                not _nonempty_string(ref)
                or CAPABILITY_REF.fullmatch(ref) is None
            ):
                errors.append(
                    f"stages.release.proved_capabilities[{index}].ref is invalid"
                )
                continue
            if ref in proved_refs:
                errors.append(f"duplicate proved capability: {ref}")
            proved_refs.add(ref)
            if not _nonempty_string(row.get("evidence")):
                errors.append(
                    f"stages.release.proved_capabilities[{index}].evidence is required"
                )
            if ref.startswith("text:"):
                if proof_boundary != "text_observed":
                    errors.append(
                        f"proved text capability {ref} must use text_observed"
                    )
                if boundary_statuses.get("text_observed") != "pass":
                    errors.append(
                        f"proved text capability {ref} requires text_observed to pass"
                    )
            else:
                if proof_boundary not in E2E_AUDIO_LAYERS:
                    errors.append(
                        f"proved audio capability {ref} has invalid proof_boundary"
                    )
                elif proof_boundary != e2e_audio_layer:
                    errors.append(
                        f"proved audio capability {ref} must use the E2E audio layer "
                        f"{e2e_audio_layer}"
                    )
                if boundary_statuses.get(proof_boundary) != "pass":
                    errors.append(
                        f"proved audio capability {ref} requires {proof_boundary} to pass"
                    )
                if proof_boundary in NATIVE_AUDIO_LAYERS:
                    proved_native_audio = True
        if not proved_native_audio:
            errors.append(
                "release proved_capabilities must include engine-native audio used by E2E"
            )
        engine_claim_rows = _list(
            stage_rows["release"].get("proved_engine_claims"),
            "stages.release.proved_engine_claims",
            errors,
        )
        proved_engine_claims: set[str] = set()
        for index, item in enumerate(engine_claim_rows):
            row = _mapping(
                item, f"stages.release.proved_engine_claims[{index}]", errors
            )
            claim = row.get("claim")
            if claim not in ENGINE_CLAIMS:
                errors.append(
                    f"stages.release.proved_engine_claims[{index}].claim "
                    f"must be one of {sorted(ENGINE_CLAIMS)}"
                )
                continue
            if claim in proved_engine_claims:
                errors.append(f"duplicate proved engine claim: {claim}")
            proved_engine_claims.add(claim)
            value_sha = row.get("value_sha256")
            if not isinstance(value_sha, str) or SHA256.fullmatch(value_sha) is None:
                errors.append(
                    f"stages.release.proved_engine_claims[{index}].value_sha256 "
                    "must be SHA-256"
                )
            if not _nonempty_string(row.get("evidence")):
                errors.append(
                    f"stages.release.proved_engine_claims[{index}].evidence is required"
                )
        if support_status not in {"partial", "verified"}:
            errors.append(
                "release pass requires support_status partial or verified"
            )
    if support_status in {"partial", "verified"}:
        if stage_rows.get("e2e", {}).get("status") != "pass":
            errors.append(
                f"support_status {support_status} requires a passing e2e stage"
            )
        if stage_rows.get("release", {}).get("status") != "pass":
            errors.append(
                f"support_status {support_status} requires a passing release stage"
            )
        if not native_audio:
            errors.append(
                f"support_status {support_status} requires engine resource or PCM evidence"
            )

    return {
        "valid": not errors,
        "errors": errors,
        "highest_proven_stage": highest,
        "first_failed_boundary": first_fail,
        "release_eligible": (
            not errors
            and highest == "release"
            and native_audio
            and support_status in {"partial", "verified"}
        ),
    }


def load_diag_constants(header: Path) -> dict[str, list[tuple[str, int]]]:
    text = header.read_text(encoding="utf-8")
    anchors = {
        "hookdiag": "constexpr uint32_t kDiagStartupAudioHooksReady",
        "hookio": "constexpr uint32_t kDiagMalieArchiveHandleTracked",
        "lunadiag": "constexpr uint32_t kDiagKirikiriVoiceStreamHookReady",
    }
    offsets = {name: text.index(anchor) for name, anchor in anchors.items()}
    sections = {
        "hookdiag": text[offsets["hookdiag"] : offsets["hookio"]],
        "hookio": text[offsets["hookio"] : offsets["lunadiag"]],
        "lunadiag": text[offsets["lunadiag"] :],
    }
    result: dict[str, list[tuple[str, int]]] = {}
    for field, section in sections.items():
        result[field] = [
            (match.group(1), int(match.group(2), 0))
            for match in DIAG_CONSTANT.finditer(section)
        ]
        if not result[field]:
            raise ValueError(f"no diagnostic constants found for {field}")
    return result


def decode_diagnostics(
    constants: dict[str, list[tuple[str, int]]], values: dict[str, int]
) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for field, raw in values.items():
        if raw < 0 or raw > 0xFFFFFFFF:
            raise ValueError(f"{field} must fit uint32")
        known_mask = 0
        active: list[dict[str, str]] = []
        for name, mask in constants[field]:
            known_mask |= mask
            if raw & mask:
                active.append({"name": name, "mask": f"0x{mask:08x}"})
        output[field] = {
            "raw": f"0x{raw:08x}",
            "set": active,
            "unknown_bits": f"0x{raw & (~known_mask & 0xFFFFFFFF):08x}",
        }
    return output


def dump_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"

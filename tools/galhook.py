#!/usr/bin/env python3
"""Hibiki engine-adapter evidence/probe/new/replay workflow (stdlib only)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

from galhook_evidence import (
    STAGES,
    decode_diagnostics,
    dump_json,
    load_diag_constants,
    new_evidence,
    validate_evidence,
)

ROOT = Path(__file__).resolve().parents[1]
ENGINE_ID = re.compile(r"^[a-z][a-z0-9_]{1,47}$")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _rva_to_offset(rva: int, sections: list[tuple[int, int, int, int]]) -> int | None:
    for virtual, virtual_size, raw, raw_size in sections:
        if virtual <= rva < virtual + max(virtual_size, raw_size):
            return raw + (rva - virtual)
    return None


def inspect_pe(path: Path) -> dict[str, Any]:
    """Read architecture/import names without executing or copying the PE."""
    try:
        data = path.read_bytes()
        if data[:2] != b"MZ" or len(data) < 0x40:
            raise ValueError("not_mz")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe : pe + 4] != b"PE\0\0":
            raise ValueError("not_pe")
        machine, section_count, _, _, _, optional_size = struct.unpack_from(
            "<HHIIIH", data, pe + 4
        )
        optional = pe + 24
        magic = struct.unpack_from("<H", data, optional)[0]
        directories = optional + (96 if magic == 0x10B else 112)
        import_rva = struct.unpack_from("<I", data, directories + 8)[0]
        section_table = optional + optional_size
        sections: list[tuple[int, int, int, int]] = []
        for index in range(section_count):
            offset = section_table + index * 40
            virtual_size, virtual, raw_size, raw = struct.unpack_from(
                "<IIII", data, offset + 8
            )
            sections.append((virtual, virtual_size, raw, raw_size))
        imports: list[str] = []
        descriptor = _rva_to_offset(import_rva, sections) if import_rva else None
        while descriptor is not None and descriptor + 20 <= len(data):
            values = struct.unpack_from("<IIIII", data, descriptor)
            if not any(values):
                break
            name_offset = _rva_to_offset(values[3], sections)
            if name_offset is not None:
                end = data.find(b"\0", name_offset, name_offset + 260)
                if end > name_offset:
                    imports.append(data[name_offset:end].decode("ascii", "replace"))
            descriptor += 20
        architecture = {0x14C: "x86", 0x8664: "x64", 0xAA64: "arm64"}.get(
            machine, f"machine_0x{machine:04x}"
        )
        return {"status": "ok", "architecture": architecture, "imports": sorted(set(imports))}
    except (OSError, ValueError, struct.error) as error:
        return {"status": "unavailable", "reason": str(error), "imports": []}


def _runtime_snapshot(pid: int | None) -> dict[str, Any]:
    if not pid or os.name != "nt":
        return {"status": "not_requested", "process_tree": [], "modules": []}
    script = (
        "$p=Get-Process -Id %d -ErrorAction Stop;"
        "$children=Get-CimInstance Win32_Process | Where-Object {$_.ParentProcessId -eq %d} | "
        "Select-Object ProcessId,Name;"
        "$modules=@($p.Modules | ForEach-Object {$_.ModuleName});"
        "[pscustomobject]@{process=[pscustomobject]@{id=$p.Id;name=$p.ProcessName};"
        "children=@($children);modules=@($modules)} | ConvertTo-Json -Depth 4 -Compress"
    ) % (pid, pid)
    try:
        completed = subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        value = json.loads(completed.stdout)
        return {
            "status": "ok",
            "process_tree": [value["process"], *value.get("children", [])],
            "modules": sorted(set(value.get("modules", [])), key=str.lower),
        }
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, KeyError) as error:
        return {"status": "unavailable", "reason": str(error), "process_tree": [], "modules": []}


def _trace_summary(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {
            "status": "not_supplied",
            "luna_threads": [],
            "resource_read_events": [],
            "audio_formats": [],
        }
    trace = json.loads(path.read_text(encoding="utf-8"))
    threads: dict[tuple[Any, Any], dict[str, Any]] = {}
    resources: list[dict[str, Any]] = []
    formats: list[dict[str, Any]] = []
    for event in trace.get("events", []):
        kind = event.get("kind")
        if kind == "text":
            key = (event.get("thread"), event.get("hook_code"))
            threads[key] = {"thread": key[0], "hook_code": key[1]}
        elif kind == "resource_audio":
            resources.append({key: event.get(key) for key in ("timestamp_ms", "format", "size")})
        elif kind in {"pcm", "loopback"}:
            formats.append({key: event.get(key) for key in ("kind", "sample_rate", "channels", "bits")})
    return {
        "status": "summarized_without_text_or_audio_payloads",
        "luna_threads": list(threads.values()),
        "resource_read_events": resources,
        "audio_formats": formats,
    }


def command_probe(args: argparse.Namespace) -> int:
    executable = Path(args.executable).resolve()
    if not executable.is_file():
        raise SystemExit(f"executable not found: {executable}")
    game_root = executable.parent
    inventory: list[dict[str, Any]] = []
    truncated = False
    for index, path in enumerate(sorted(game_root.rglob("*"))):
        if index >= args.max_files:
            truncated = True
            break
        if path.is_file():
            inventory.append(
                {
                    "relative_path": path.relative_to(game_root).as_posix(),
                    "extension": path.suffix.lower(),
                    "size": path.stat().st_size,
                }
            )
    pe = inspect_pe(executable)
    runtime = _runtime_snapshot(args.pid)
    trace = _trace_summary(Path(args.trace).resolve() if args.trace else None)
    modules = {name.lower() for name in runtime.get("modules", [])}
    imports = {name.lower() for name in pe.get("imports", [])}
    report = {
        "schema_version": 1,
        "privacy": {
            "game_root": "<game-root>",
            "copyright_payloads_included": False,
            "copied_extensions": [],
            "notes": "Only metadata, hashes, and optional trace summaries are included.",
        },
        "target": {
            "executable_name": executable.name,
            "executable_sha256": _sha256(executable),
            "pe": pe,
        },
        "directory_inventory": inventory,
        "inventory_truncated": truncated,
        "runtime": runtime,
        "trace_summary": trace,
        "capabilities": {
            "luna_thread_catalog": trace["status"],
            "resource_audio": "observed" if trace["resource_read_events"] else "not_observed",
            "xaudio2": "observed" if any("xaudio2" in name for name in imports | modules) else "not_observed",
            "directsound": "observed" if "dsound.dll" in imports | modules else "not_observed",
            "ffmpeg": "observed" if any(name.startswith(("avcodec", "avformat")) for name in imports | modules) else "not_observed",
        },
    }
    output = Path(args.output or f"galhook-probe-{report['target']['executable_sha256'][:12]}.zip").resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as bundle:
        bundle.writestr("diagnostic.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        bundle.writestr(
            "README.txt",
            "Hibiki galhook diagnostic bundle. Contains metadata only; no executable, script, image, or audio payloads.\n",
        )
    print(output)
    return 0


def _class_name(engine_id: str) -> str:
    return "".join(part.capitalize() for part in engine_id.split("_"))


def _append_unique(path: Path, line: str) -> None:
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    if line not in current:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(current.rstrip() + "\n" + line + "\n", encoding="utf-8", newline="\n")


def command_new(args: argparse.Namespace) -> int:
    engine_id = args.engine_id
    if not ENGINE_ID.fullmatch(engine_id):
        raise SystemExit("engine id must match ^[a-z][a-z0-9_]{1,47}$")
    root = Path(args.root).resolve()
    profile = root / "profiles" / f"{engine_id}.json"
    adapter = root / "hook" / "adapters" / f"{engine_id}_adapter.inc"
    profile_header = root / "hook" / "adapters" / f"{engine_id}_profile.h"
    native_test = root / "tests" / f"{engine_id}_adapter_test.cpp"
    fixture = root / "tests" / "fixtures" / f"{engine_id}_replay.json"
    targets = (profile, adapter, profile_header, native_test, fixture)
    existing = [str(path) for path in targets if path.exists()]
    if existing:
        raise SystemExit("refusing to overwrite: " + ", ".join(existing))
    for path in targets:
        path.parent.mkdir(parents=True, exist_ok=True)
    class_name = _class_name(engine_id)
    profile.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": engine_id,
                "status": "implemented_unverified",
                "detection": {"executable_sha256": [], "module_sha256": []},
                "capabilities": {"text": False, "resource_audio": False, "pcm_audio": False},
                "evidence": [],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    profile_header.write_text(
        f'''#pragma once

namespace hibiki_voice_hook {{
inline bool Matches{class_name}Profile(const wchar_t*) {{
  // Add only signatures measured from a real sample; an empty profile never matches.
  return false;
}}
}}  // namespace hibiki_voice_hook
''',
        encoding="utf-8",
    )
    adapter.write_text(
        f'''// Generated adapter skeleton for {engine_id}; remains unverified until fixture + real-game evidence exist.
#include "{engine_id}_profile.h"

class {class_name}Adapter final : public hibiki_voice_hook::EngineAdapter {{
 public:
  const char* id() const override {{ return "{engine_id}"; }}
  bool probe() const override {{ return hibiki_voice_hook::Matches{class_name}Profile(nullptr); }}
  bool install() override {{ installed_ = false; return false; }}
  hibiki_voice_hook::AdapterCapability capabilities() const override {{
    return hibiki_voice_hook::AdapterCapability::kNone;
  }}
  void onModuleLoaded(const wchar_t* module_name) override {{
    if (hibiki_voice_hook::Matches{class_name}Profile(module_name)) install();
  }}
  void shutdown() override {{ installed_ = false; }}
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {{
    return {{id(), probe(), installed_, 0}};
  }}
 private:
  bool installed_ = false;
}};
''',
        encoding="utf-8",
    )
    native_test.write_text(
        f'''#include "../hook/adapters/{engine_id}_profile.h"
int main() {{ return hibiki_voice_hook::Matches{class_name}Profile(nullptr) ? 1 : 0; }}
''',
        encoding="utf-8",
    )
    fixture.write_text(
        json.dumps(
            {"schema_version": 1, "engine_id": engine_id, "status": "implemented_unverified", "events": [], "expected": {"cards": [], "session_clean": True}},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    generated = root / "hook" / "generated"
    _append_unique(generated / "profile_includes.inc", f'#include "../adapters/{engine_id}_profile.h"')
    _append_unique(generated / "adapter_includes.inc", f'#include "../adapters/{engine_id}_adapter.inc"')
    _append_unique(generated / "adapter_startup.inc", f"    {engine_id}_.install();")
    _append_unique(generated / "adapter_module.inc", f"        {engine_id}_.onModuleLoaded(entry.szModule);")
    _append_unique(generated / "adapter_shutdown.inc", f"    {engine_id}_.shutdown();")
    _append_unique(generated / "adapter_fields.inc", f"  {class_name}Adapter {engine_id}_;")
    _append_unique(
        root / "CMakeLists.txt",
        f'''add_executable(hibiki_{engine_id}_adapter_test "tests/{engine_id}_adapter_test.cpp")
target_include_directories(hibiki_{engine_id}_adapter_test PRIVATE "hook")
add_test(NAME hibiki_{engine_id}_adapter_test COMMAND hibiki_{engine_id}_adapter_test)''',
    )

    if args.hibiki_root:
        hibiki = Path(args.hibiki_root).resolve() / "hibiki"
        dart_fixture = hibiki / "test" / "fixtures" / "galhook" / f"{engine_id}_replay.json"
        dart_test = hibiki / "test" / "mining" / f"{engine_id}_pairing_test.dart"
        dart_fixture.parent.mkdir(parents=True, exist_ok=True)
        dart_test.parent.mkdir(parents=True, exist_ok=True)
        dart_fixture.write_text(fixture.read_text(encoding="utf-8"), encoding="utf-8")
        dart_test.write_text(
            f'''import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {{
  test('{engine_id} fixture stays explicitly unverified until evidence is added', () async {{
    final data = jsonDecode(await File('test/fixtures/galhook/{engine_id}_replay.json').readAsString()) as Map<String, dynamic>;
    expect(data['status'], 'implemented_unverified');
  }});
}}
''',
            encoding="utf-8",
        )
    if (root / "tests" / "adapter_structure_test.py").exists():
        subprocess.run([sys.executable, str(root / "tests" / "adapter_structure_test.py")], cwd=root, check=True)
    print(json.dumps({"engine_id": engine_id, "created": [str(path) for path in targets]}, indent=2))
    return 0


def replay_trace(trace: dict[str, Any]) -> dict[str, Any]:
    config = trace.get("config", {})
    selected = config.get("selected_thread")
    tolerance = int(config.get("pair_tolerance_ms", 500))
    late_wait = int(config.get("resource_late_wait_ms", 500))
    texts: list[dict[str, Any]] = []
    audio: list[dict[str, Any]] = []
    seen: dict[str, int] = {}
    duplicates = 0
    filtered = 0
    ended = False
    for event in trace.get("events", []):
        kind = event.get("kind")
        if kind == "text":
            if selected is not None and event.get("thread") != selected:
                filtered += 1
                continue
            text = str(event.get("text", ""))
            timestamp = int(event.get("timestamp_ms", 0))
            if text in seen and timestamp - seen[text] <= 1000:
                duplicates += 1
                continue
            seen[text] = timestamp
            texts.append(event)
        elif kind in {"resource_audio", "pcm", "loopback"}:
            audio.append(event)
        elif kind == "session_end":
            ended = True
    cards: list[dict[str, Any]] = []
    priority = {"resource_audio": 0, "pcm": 1, "loopback": 2}
    for text_event in texts:
        timestamp = int(text_event.get("timestamp_ms", 0))
        candidates = []
        for event in audio:
            delta = abs(int(event.get("timestamp_ms", 0)) - timestamp)
            available = int(event.get("available_at_ms", event.get("timestamp_ms", 0)))
            if delta <= tolerance and available <= timestamp + late_wait:
                candidates.append((priority[event["kind"]], delta, event))
        candidates.sort(key=lambda item: (item[0], item[1]))
        chosen = candidates[0][2] if candidates else None
        cards.append(
            {
                "text_id": text_event.get("id"),
                "audio_backend": chosen.get("kind") if chosen else None,
                "audio_id": chosen.get("id") if chosen else None,
            }
        )
    return {
        "cards": cards,
        "duplicate_text_events": duplicates,
        "thread_filtered_events": filtered,
        "session_clean": ended,
    }


def command_replay(args: argparse.Namespace) -> int:
    path = Path(args.trace).resolve()
    trace = json.loads(path.read_text(encoding="utf-8"))
    actual = replay_trace(trace)
    expected = trace.get("expected")
    if expected is not None and actual != expected:
        print(json.dumps({"expected": expected, "actual": actual}, indent=2), file=sys.stderr)
        return 2
    output = Path(args.output).resolve() if args.output else None
    rendered = json.dumps(actual, ensure_ascii=False, indent=2) + "\n"
    if output:
        output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


def command_evidence_init(args: argparse.Namespace) -> int:
    output = Path(
        args.output
        or ROOT / ".galhook-evidence" / f"{args.engine_id}-hook-evidence.json"
    ).resolve()
    if output.exists() and not args.force:
        raise SystemExit(f"refusing to overwrite: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(dump_json(new_evidence(args.engine_id)), encoding="utf-8")
    print(output)
    return 0


def command_verify_evidence(args: argparse.Namespace) -> int:
    path = Path(args.evidence_file).resolve()
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(dump_json({"valid": False, "errors": [str(error)]}), end="")
        return 2
    report = validate_evidence(document)
    report["evidence_file_sha256"] = _sha256(path)
    if isinstance(document, dict) and isinstance(document.get("task"), dict):
        report["engine_id"] = document["task"].get("engine_id")
        report["support_status"] = document["task"].get("support_status")
    required = args.require_stage
    if required is not None:
        highest = report["highest_proven_stage"]
        if highest is None or STAGES.index(highest) < STAGES.index(required):
            report["valid"] = False
            report["errors"].append(
                f"required stage {required} is not proven; highest is {highest!r}"
            )
    print(dump_json(report), end="")
    return 0 if report["valid"] else 2


def _uint32(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if parsed < 0 or parsed > 0xFFFFFFFF:
        raise argparse.ArgumentTypeError("value must fit uint32")
    return parsed


def command_explain_diag(args: argparse.Namespace) -> int:
    constants = load_diag_constants(Path(args.header).resolve())
    report = decode_diagnostics(
        constants,
        {
            "hookdiag": args.hookdiag,
            "hookio": args.hookio,
            "lunadiag": args.lunadiag,
        },
    )
    print(dump_json(report), end="")
    return 0


def _check_commands(root: Path, native: bool) -> list[list[str]]:
    powershell = shutil.which("pwsh") or shutil.which("powershell") or "pwsh"
    commands = [
        [sys.executable, str(root / "tools" / "generate_engine_support.py"), "--check"],
        [sys.executable, str(root / "tools" / "generate_luna_profiles.py"), "--check"],
        [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(root / "tools" / "sync_lunahook.ps1"),
        ],
        [sys.executable, str(root / "tests" / "engine_support_manifest_test.py")],
        [sys.executable, str(root / "tests" / "adapter_structure_test.py")],
        [sys.executable, str(root / "tests" / "evidence_contract_test.py")],
        [sys.executable, str(root / "tests" / "galhook_workflow_test.py")],
    ]
    if native:
        for architecture, generator_arch in (("x64", "x64"), ("x86", "Win32")):
            build = root / "build" / architecture
            commands.extend(
                [
                    [
                        "cmake",
                        "-S",
                        str(root),
                        "-B",
                        str(build),
                        "-A",
                        generator_arch,
                    ],
                    ["cmake", "--build", str(build), "--config", "Release"],
                    [
                        "ctest",
                        "--test-dir",
                        str(build),
                        "-C",
                        "Release",
                        "--output-on-failure",
                    ],
                ]
            )
    return commands


def command_check(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    commands = _check_commands(root, args.native)
    if args.dry_run:
        print(
            dump_json(
                {
                    "cwd": str(root),
                    "native": args.native,
                    "commands": [subprocess.list2cmdline(command) for command in commands],
                }
            ),
            end="",
        )
        return 0
    for command in commands:
        print(f"+ {subprocess.list2cmdline(command)}", flush=True)
        completed = subprocess.run(command, cwd=root, check=False)
        if completed.returncode != 0:
            return int(completed.returncode)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="galhook")
    sub = parser.add_subparsers(dest="command", required=True)
    probe = sub.add_parser("probe")
    probe.add_argument("executable")
    probe.add_argument("--pid", type=int)
    probe.add_argument("--trace")
    probe.add_argument("--output")
    probe.add_argument("--max-files", type=int, default=5000)
    probe.set_defaults(func=command_probe)
    new = sub.add_parser("new")
    new.add_argument("engine_id")
    new.add_argument("--root", default=str(ROOT))
    new.add_argument("--hibiki-root")
    new.set_defaults(func=command_new)
    replay = sub.add_parser("replay")
    replay.add_argument("trace")
    replay.add_argument("--output")
    replay.set_defaults(func=command_replay)
    evidence = sub.add_parser("evidence")
    evidence_sub = evidence.add_subparsers(dest="evidence_command", required=True)
    evidence_init = evidence_sub.add_parser("init")
    evidence_init.add_argument("engine_id")
    evidence_init.add_argument("--output")
    evidence_init.add_argument("--force", action="store_true")
    evidence_init.set_defaults(func=command_evidence_init)
    verify = sub.add_parser("verify-evidence")
    verify.add_argument("evidence_file")
    verify.add_argument("--require-stage", choices=STAGES)
    verify.set_defaults(func=command_verify_evidence)
    explain = sub.add_parser("explain-diag")
    explain.add_argument("--hookdiag", type=_uint32, default=0)
    explain.add_argument("--hookio", type=_uint32, default=0)
    explain.add_argument("--lunadiag", type=_uint32, default=0)
    explain.add_argument(
        "--header", default=str(ROOT / "include" / "voice_hook_ipc.h")
    )
    explain.set_defaults(func=command_explain_diag)
    check = sub.add_parser("check")
    check.add_argument("--root", default=str(ROOT))
    check.add_argument("--native", action="store_true")
    check.add_argument("--dry-run", action="store_true")
    check.set_defaults(func=command_check)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

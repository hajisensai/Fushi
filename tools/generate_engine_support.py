#!/usr/bin/env python3
"""Validate engine-support.yaml and render its deterministic Markdown matrix.

The manifest intentionally uses YAML 1.2's JSON-compatible syntax. This keeps
the generator dependency-free while the .yaml file remains consumable by YAML
tooling. Do not add recognition signatures copied only from external databases:
every non-empty signature group must carry real-sample/runtime evidence.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
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


def validate_manifest(manifest: dict[str, Any]) -> None:
    """Validate the P0 schema and evidence guardrails."""

    _require(manifest.get("schema_version") == 1, "schema_version must be 1")
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

        audio = engine["audio"]
        _require(isinstance(audio, dict), f"{engine_id}.audio must be an object")
        priority = audio.get("priority")
        _require(isinstance(priority, list) and priority, f"{engine_id}.audio.priority is required")
        for capability in priority:
            _require(
                capability.get("status") in ALLOWED_STATUSES,
                f"{engine_id} audio capability has invalid status",
            )

        text = engine["text"]
        _require(isinstance(text, dict), f"{engine_id}.text must be an object")
        for capability in text.get("capabilities", []):
            _require(
                capability.get("status") in ALLOWED_STATUSES,
                f"{engine_id} text capability has invalid status",
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


def render_manifest(manifest: dict[str, Any]) -> str:
    """Render a stable human-readable support matrix."""

    validate_manifest(manifest)
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
    rendered = render_manifest(manifest)
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

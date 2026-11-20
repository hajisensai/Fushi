"""Register subagent_wait_slice.mjs as a user-level PreToolUse hook (run by a person, once).

Copies the hook next to the other user-level hooks (~/.claude/hooks) so it does not depend on
any checkout or worktree staying around, then adds a `Bash|PowerShell` PreToolUse entry to
~/.claude/settings.json. Idempotent; the previous settings file is kept as a .bak copy.

    python -I tool/claude_hooks/install_subagent_wait_slice.py
"""

from __future__ import annotations

import json
import pathlib
import shutil
import sys

HOOK_NAME: str = "subagent_wait_slice.mjs"


def main() -> int:
    source = pathlib.Path(__file__).resolve().parent / HOOK_NAME
    claude_dir = pathlib.Path.home() / ".claude"
    settings_path = claude_dir / "settings.json"
    target = claude_dir / "hooks" / HOOK_NAME
    if not source.is_file():
        print(f"missing {source}")
        return 1
    if not settings_path.is_file():
        print(f"missing {settings_path}")
        return 1

    raw = settings_path.read_bytes()
    settings = json.loads(raw.decode("utf-8-sig"))
    command = f"node {target.as_posix()}"
    entries = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
    registered = any(
        HOOK_NAME in str(hook.get("command", ""))
        for entry in entries
        for hook in entry.get("hooks", [])
    )

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    print(f"copied hook -> {target}")
    if registered:
        print("already registered in settings.json; only the hook file was refreshed")
        return 0

    entries.append(
        {
            "matcher": "Bash|PowerShell",
            "hooks": [{"type": "command", "command": command, "timeout": 10}],
        }
    )
    data = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    backup = settings_path.with_name("settings.json.bak-subagent-wait-slice")
    backup.write_bytes(raw)
    settings_path.write_bytes(data)
    print(f"registered: {command}")
    print(f"backup: {backup}")
    print("new sessions pick it up; running sessions keep their old hook list")
    return 0


if __name__ == "__main__":
    sys.exit(main())

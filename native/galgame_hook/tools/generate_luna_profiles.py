#!/usr/bin/env python3
"""Generate the embedded Luna hook profile table from the checked-in TSV."""

from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "config" / "luna_hook_profiles.tsv"
OUTPUT = ROOT / "include" / "luna_hook_profiles.inc"


def render(text: str) -> str:
    if ")HLUNA\"" in text:
        raise ValueError("profile data contains the raw-string delimiter")
    return f'R"HLUNA({text})HLUNA"\n'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render(SOURCE.read_text(encoding="utf-8"))
    if args.check:
        return 0 if OUTPUT.read_text(encoding="utf-8") == expected else 1
    OUTPUT.write_text(expected, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

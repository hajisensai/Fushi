#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline generator: OpenCC simplified->traditional data -> opencc_st_data.{h,cpp}

One-shot vendoring tool. NOT part of the CMake build — the generated .h/.cpp are
checked into native/fushidicts/fushidicts_src/text_processor/ as ordinary sources.
Re-run only when bumping the upstream pin (OPENCC_COMMIT + the SHA-256 pins below).

Source data (BYVoid/OpenCC, Apache-2.0), fetched from the pinned commit and verified
against the pinned SHA-256 before use, so the output is byte-reproducible:
  * data/dictionary/STCharacters.txt  simplified -> traditional, ALL candidates
                                      (`发\t發 髮`, `干\t幹 乾 干 榦`, `后\t後 后`);
  * data/dictionary/TWVariants.txt    OpenCC traditional -> Taiwan form (`裏\t裡`);
  * data/dictionary/HKVariants.txt    OpenCC traditional -> Hong Kong form.

Every candidate is kept, not only the first one: the lookup engine expands a
simplified query into several traditional spellings and lets the dictionary decide
which one exists (头发 -> 頭發 / 頭髮, only 頭髮 is a word). A first-candidate-only
table turns 关系 into 關系 and 头发 into 頭發 and silently misses those words.

Per simplified key the candidate list is: the STCharacters candidates in upstream
order, then the Taiwan / Hong Kong form of each of them (deduplicated). A character
that only appears as a TW/HK variant key (污 -> 汙) gets itself first, then the
variant, so 污漬 still yields the standard 污漬 next to the Taiwan 汙漬. Keys whose
list would be just the key itself are dropped.

Usage (from the repo root; needs network to raw.githubusercontent.com):
  python tool/native_gen/gen_opencc_st.py           # regenerate in place
  python tool/native_gen/gen_opencc_st.py --check   # exit 1 if the checked-in files differ
"""
from __future__ import annotations

import hashlib
import sys
import urllib.request
from collections.abc import Iterator
from pathlib import Path

OPENCC_COMMIT = "9b16591a0d065f5e1121620733721436e83c206f"
SOURCES: dict[str, str] = {
    "STCharacters.txt": "a0ca1601c70648cf48b33c3c6210ccbecc5c7eead4b4c3daf76587ba2c03582b",
    "TWVariants.txt": "245b94eb5842957e735dd44b7e7d4ff469a3643126cc8fa511adda5281e9cb86",
    "HKVariants.txt": "e5cd4345303224587102f2c9e4d2b67d2b7e349c6ce9152e4a118f4656cf7302",
}
RAW_BASE = f"https://raw.githubusercontent.com/BYVoid/OpenCC/{OPENCC_COMMIT}/data/dictionary/"

# Fixed output location (derived from this file, never from the command line).
OUT_DIR = (
    Path(__file__).resolve().parents[2]
    / "native"
    / "fushidicts"
    / "fushidicts_src"
    / "text_processor"
)
HEADER_NAME = "opencc_st_data.h"
SOURCE_NAME = "opencc_st_data.cpp"


def fetch(name: str) -> str:
    """Download one pinned OpenCC dictionary file and verify its SHA-256."""
    with urllib.request.urlopen(RAW_BASE + name, timeout=60) as response:
        data: bytes = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SOURCES[name]:
        raise SystemExit(f"{name}: sha256 {digest} != pinned {SOURCES[name]}")
    return data.decode("utf-8")


def parse(text: str) -> dict[str, list[str]]:
    """Parse an OpenCC `key<TAB>v1 v2 ...` file (first occurrence of a key wins)."""
    table: dict[str, list[str]] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        key, _, values = line.partition("\t")
        table.setdefault(key, [v for v in values.split(" ") if v])
    return table


def single_codepoint(s: str) -> bool:
    return len(s) == 1


def push_candidate(out: list[str], ch: str) -> None:
    if single_codepoint(ch) and ch not in out:
        out.append(ch)


def variant_forms(ch: str, variant_maps: tuple[dict[str, list[str]], ...]) -> Iterator[str]:
    for variants in variant_maps:
        yield from variants.get(ch, [])


def candidates_for_simplified(
    values: list[str], variant_maps: tuple[dict[str, list[str]], ...]
) -> list[str]:
    out: list[str] = []
    for value in values:
        push_candidate(out, value)
    for value in tuple(out):  # snapshot: push_candidate grows `out`
        for v in variant_forms(value, variant_maps):
            push_candidate(out, v)
    return out


def candidates_for_variant_only(
    key: str, variant_maps: tuple[dict[str, list[str]], ...]
) -> list[str]:
    out = [key]
    for v in variant_forms(key, variant_maps):
        push_candidate(out, v)
    return out


def build_candidates(
    st: dict[str, list[str]],
    tw: dict[str, list[str]],
    hk: dict[str, list[str]],
) -> list[tuple[int, list[int]]]:
    """Simplified code point -> ordered traditional candidates (see module doc)."""
    variant_maps = (tw, hk)
    result = {
        key: candidates_for_simplified(values, variant_maps)
        for key, values in st.items()
        if single_codepoint(key)
    }
    for variants in variant_maps:
        for key in variants:
            if single_codepoint(key) and key not in result:
                result[key] = candidates_for_variant_only(key, variant_maps)

    pairs = [
        (ord(key), [ord(c) for c in out])
        for key, out in result.items()
        if out and out != [key]
    ]
    pairs.sort()
    return pairs


def render(pairs: list[tuple[int, list[int]]]) -> tuple[str, str]:
    """Render (header, source) text for the candidate table."""
    pool: list[int] = []
    entries: list[str] = []
    max_count = 0
    for key, cands in pairs:
        entries.append(f"    SimpToTrad{{0x{key:04X}, {len(pool)}, {len(cands)}}},")
        pool.extend(cands)
        max_count = max(max_count, len(cands))
    if len(pool) > 0xFFFF or max_count > 0xFF:
        raise SystemExit("candidate pool no longer fits the uint16/uint8 layout")

    head = [
        "// AUTO-GENERATED by tool/native_gen/gen_opencc_st.py — DO NOT EDIT.",
        f"// Source: BYVoid/OpenCC (Apache-2.0, commit {OPENCC_COMMIT})",
        "//   data/dictionary/STCharacters.txt + TWVariants.txt + HKVariants.txt.",
        "// Maps 简体 (simplified) -> every 繁體 (traditional) candidate, upstream order,",
        "// then the Taiwan / Hong Kong forms. LICENSE for the data: OPENCC_LICENSE.",
    ]
    header = "\n".join(
        head
        + [
            "#pragma once",
            "",
            "#include <array>",
            "#include <cstddef>",
            "#include <cstdint>",
            "",
            "namespace opencc_st {",
            "",
            "struct SimpToTrad {",
            "  char32_t simplified;",
            "  std::uint16_t first;  // index into kCandidates",
            "  std::uint8_t count;   // number of candidates, >= 1",
            "};",
            "",
            f"inline constexpr std::size_t kSimpToTradCount = {len(pairs)};",
            f"inline constexpr std::size_t kCandidateCount = {len(pool)};",
            f"inline constexpr std::size_t kMaxCandidatesPerChar = {max_count};",
            "",
            "// Sorted by simplified code point.",
            "extern const std::array<SimpToTrad, kSimpToTradCount> kSimpToTrad;",
            "extern const std::array<char32_t, kCandidateCount> kCandidates;",
            "",
            "}  // namespace opencc_st",
            "",
        ]
    )
    body = head + [
        '#include "opencc_st_data.h"',
        "",
        "namespace opencc_st {",
        "",
        "const std::array<SimpToTrad, kSimpToTradCount> kSimpToTrad = {",
        *entries,
        "};",
        "",
        "const std::array<char32_t, kCandidateCount> kCandidates = {",
    ]
    for i in range(0, len(pool), 8):
        body.append("    " + " ".join(f"0x{c:04X}," for c in pool[i : i + 8]))
    body += ["};", "", "}  // namespace opencc_st", ""]
    return header, "\n".join(body)


def main(argv: list[str]) -> int:
    check = argv[1:] == ["--check"]
    if argv[1:] and not check:
        print(__doc__)
        return 2
    st = parse(fetch("STCharacters.txt"))
    tw = parse(fetch("TWVariants.txt"))
    hk = parse(fetch("HKVariants.txt"))
    pairs = build_candidates(st, tw, hk)
    header, source = render(pairs)
    outputs = {HEADER_NAME: header, SOURCE_NAME: source}
    if check:
        stale = [
            name
            for name, text in outputs.items()
            if (OUT_DIR / name).read_bytes().replace(b"\r\n", b"\n") != text.encode("utf-8")
        ]
        if stale:
            print("stale generated files: " + ", ".join(stale))
            return 1
        print(f"up to date ({len(pairs)} keys)")
        return 0
    for name, text in outputs.items():
        with open(OUT_DIR / name, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print(f"wrote {len(pairs)} keys, {sum(len(c) for _, c in pairs)} candidates")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

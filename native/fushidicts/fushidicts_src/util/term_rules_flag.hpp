#pragma once

#include <cstdint>
#include <fstream>
#include <optional>
#include <string>
#include <string_view>

#include "fs_utf8.hpp"

namespace fushi::term_rules_flag {
// Optional sidecar next to blobs.bin answering one question about a term
// dictionary: does ANY of its term records carry a non-empty `rules` (part of
// speech) string?
//
// Why it matters: Lookup::filter_by_pos implements the Yomitan contract "an
// empty rules string means this term is never an inflected form", so every
// deinflected hit on an empty-rules term is dropped. That contract only holds
// for dictionaries whose converter actually emitted POS tags. A Yomitan-format
// dictionary converted without POS (e.g. OALDPE10: 0 of ~860k terms tagged)
// otherwise never surfaces `walk` for `walked` — the whole English inflection
// table is silently disabled for it (see en_inflection_lookup_test.cpp).
//
// "0" (absent) => the reader treats empty rules as the wildcard "*" (the same
// storage rule write_simple_dict uses for MDX/StarDict/DSL, whose terms have
// no POS either). "1" (present) => Yomitan semantics unchanged.
//
// File layout: `<0|1> <blobs.bin size in bytes>`. The size ties the flag to
// the exact blobs.bin it was computed from: a package overlay-restored on top
// of a differently-imported directory leaves stale sidecars behind (overlay
// extraction never deletes files), and a mismatched flag must not be trusted.
// A missing/invalid file means "unknown": the reader scans the records once
// and rewrites the file (best effort; a read-only volume just rescans next
// time).
inline constexpr std::string_view kFilename = "term_rules.flag";

inline std::optional<bool> read(const std::string& dict_dir, uint64_t blobs_size) {
  std::ifstream in(fushi::fs_path(dict_dir + "/" + std::string(kFilename)), std::ios::binary);
  if (!in) return std::nullopt;
  int flag = -1;
  uint64_t recorded_size = 0;
  in >> flag >> recorded_size;
  if (!in || (flag != 0 && flag != 1) || recorded_size != blobs_size) return std::nullopt;
  return flag == 1;
}

inline bool write(const std::string& dict_dir, bool present, uint64_t blobs_size) {
  std::ofstream out(fushi::fs_path(dict_dir + "/" + std::string(kFilename)), std::ios::binary | std::ios::trunc);
  if (!out) return false;
  out << (present ? '1' : '0') << ' ' << blobs_size << '\n';
  return static_cast<bool>(out);
}
}  // namespace fushi::term_rules_flag

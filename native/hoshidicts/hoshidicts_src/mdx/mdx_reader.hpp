#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct MdxEntry {
  std::string key;
  std::string definition;
};

struct MdxResult {
  std::string title;
  std::string encoding;
  int version_major = 0;
  int version_minor = 0;
  std::vector<MdxEntry> entries;
};

// One resource inside an .mdd container: `path` is the (normalized-later) file
// path key, `blob` holds the raw bytes verbatim (image/audio/css/font).
struct MddEntry {
  std::string path;
  std::string blob;
};

namespace mdx_reader {
MdxResult parse(const uint8_t* data, size_t size);
// Parse an .mdd (same container as .mdx, but records are binary files keyed by
// path). Records are returned byte-exact: no text transcoding, no trailing-NUL
// stripping, no @@@LINK resolution.
std::vector<MddEntry> parse_mdd(const uint8_t* data, size_t size);
}

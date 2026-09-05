#pragma once

#include <cstdint>
#include <functional>
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

// Everything parse() reports about a dictionary apart from its entries.
struct MdxMeta {
  std::string title;
  std::string encoding;
  int version_major = 0;
  int version_minor = 0;
};

// One resource inside an .mdd container: `path` is the (normalized-later) file
// path key, `blob` holds the raw bytes verbatim (image/audio/css/font).
struct MddEntry {
  std::string path;
  std::string blob;
};

namespace mdx_reader {
// Invoked once per entry, in key order, with ownership of both strings.
using EntrySink = std::function<void(std::string&& key, std::string&& definition)>;

// Streaming parse: hands every entry to `sink` instead of materialising the
// dictionary. Peak memory is the key table plus a single record block, so a
// 400 MB .mdx costs tens of megabytes rather than well over a gigabyte -- which
// is what got large dictionaries jetsam-killed mid-import on iOS.
//
// Ordinary entries arrive in key order; @@@LINK= redirects are resolved against
// their targets and arrive afterwards. Order is not otherwise meaningful -- the
// importer indexes entries by headword hash.
MdxMeta parse_streaming(const uint8_t* data, size_t size, const EntrySink& sink);

// Whole-dictionary convenience wrapper over parse_streaming. Holds every entry
// in memory; prefer parse_streaming for anything user-supplied.
MdxResult parse(const uint8_t* data, size_t size);
// Parse an .mdd (same container as .mdx, but records are binary files keyed by
// path). Records are returned byte-exact: no text transcoding, no trailing-NUL
// stripping, no @@@LINK resolution.
std::vector<MddEntry> parse_mdd(const uint8_t* data, size_t size);
}

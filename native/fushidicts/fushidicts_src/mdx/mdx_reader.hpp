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
  // Decoded key count -- the number of entries the sink will see, minus any the
  // reader has to skip. Comes from the parsed key table, not a header claim, so
  // it is safe to size buffers against.
  size_t entry_count = 0;
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

// Invoked once, after the header and key table are decoded but BEFORE any entry
// is emitted. Callers that must create the output dictionary up front -- so
// glossary blobs can stream straight to disk rather than piling up in RAM --
// need the title at that point.
using MetaSink = std::function<void(const MdxMeta&)>;

// Streaming parse: hands every entry to `sink` instead of materialising the
// dictionary. Peak memory is the key table plus a single record block, so a
// 400 MB .mdx costs tens of megabytes rather than well over a gigabyte -- which
// is what got large dictionaries jetsam-killed mid-import on iOS.
//
// Ordinary entries arrive in key order; @@@LINK= redirects are resolved against
// their targets and arrive afterwards. Order is not otherwise meaningful -- the
// importer indexes entries by headword hash.
MdxMeta parse_streaming(const uint8_t* data, size_t size, const EntrySink& sink, const MetaSink& on_meta = {});

// Whole-dictionary convenience wrapper over parse_streaming. Holds every entry
// in memory; prefer parse_streaming for anything user-supplied.
MdxResult parse(const uint8_t* data, size_t size);
// Invoked once per .mdd record with ownership of its path. `blob` points into
// the record block currently being decoded and is valid only for the call.
using MddSink = std::function<void(std::string&& path, const uint8_t* blob, size_t size)>;

// Streaming .mdd parse (same container as .mdx, but records are binary files
// keyed by path). Records are handed over byte-exact: no text transcoding, no
// trailing-NUL stripping, no @@@LINK resolution. Peak memory is the key table
// plus one record block, so a media companion of hundreds of MB no longer has
// to fit in RAM twice over (BUG-3234) -- the importer writes each record out
// as it arrives.
void parse_mdd_streaming(const uint8_t* data, size_t size, const MddSink& sink);

// Whole-container convenience wrapper over parse_mdd_streaming. Holds every
// record in memory; prefer the streaming form for anything user-supplied.
std::vector<MddEntry> parse_mdd(const uint8_t* data, size_t size);
}

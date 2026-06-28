#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "../memory/memory.hpp"

// Sizes are 64-bit to hold values resolved from a ZIP64 0x0001 extra field.
// Downstream (has_entry_payload / read / read_media / libdeflate) consumes them
// as size_t; on a 32-bit ABI that assumes individual entries stay <4GB, which
// holds for dictionary archives (they are forced-ZIP64 for layout, not size).
struct ZipEntry {
  std::string name;
  uint16_t compression_method;
  uint64_t compressed_size;    // ZIP64 may store true size via 0x0001 extra
  uint64_t uncompressed_size;  // ZIP64 may store true size via 0x0001 extra
  size_t data_offset;
};

// BUG-927: absolute upper bound (1 GiB) on a single entry's declared
// uncompressed_size. has_entry_payload() only bounds the *compressed* payload, so
// this is the sole guard stopping a forged/oversized ZIP64 uncompressed_size from
// driving result.resize() into a multi-GB allocation. Exposed (was an anonymous
// helper) so the boundary can be unit-tested without depending on the exact ratio
// libdeflate happens to emit. The previous ratio-based cap (uncompressed <=
// compressed * 1100) wrongly rejected legitimate high-compression yomitan banks.
constexpr uint64_t kMaxUncompressedEntryBytes = 1024ull * 1024ull * 1024ull;
bool zip_uncompressed_size_in_range(const ZipEntry& e);

struct Zip {
  memory::mapped_file file;
  std::vector<ZipEntry> entries;

  ~Zip();
  bool open(const std::string& path);
  int find(const std::string& name) const;
  std::string read(int index) const;

  struct MediaResult {
    std::string path;
    std::vector<char> blob;
  };

  std::optional<MediaResult> read_media(int index) const;

 private:
  bool parse_central_directory();
};

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

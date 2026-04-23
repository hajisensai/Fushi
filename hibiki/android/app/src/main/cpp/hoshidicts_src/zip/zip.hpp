#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "../memory/memory.hpp"

struct ZipEntry {
  std::string name;
  uint16_t compression_method;
  uint64_t compressed_size;
  uint64_t uncompressed_size;
  uint64_t data_offset;
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

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

namespace mdx_reader {
MdxResult parse(const uint8_t* data, size_t size);
}

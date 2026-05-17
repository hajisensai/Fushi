#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace memory {
struct mapped_file {
  uint8_t* data = nullptr;
  size_t size = 0;

  explicit operator bool() const { return data != nullptr; }
};

mapped_file map_rd(const std::string& path);
mapped_file map_rw(const std::string& path, size_t file_size);
void unmap(mapped_file mapping);
}

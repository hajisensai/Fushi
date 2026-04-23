#include "zip.hpp"

#include <libdeflate.h>

#include <cstdint>
#include <cstring>

#include "../memory/memory.hpp"

namespace {
template <typename T>
T read_at(const uint8_t* base, size_t offset) {
  T val;
  std::memcpy(&val, base + offset, sizeof(T));
  return val;
}
}

Zip::~Zip() {
  memory::unmap(file);
}

bool Zip::open(const std::string& path) {
  file = memory::map_rd(path);
  if (!file) {
    return false;
  }

  return parse_central_directory();
}

int Zip::find(const std::string& name) const {
  for (int i = 0; i < static_cast<int>(entries.size()); ++i) {
    if (entries[i].name == name) {
      return i;
    }
  }
  return -1;
}

std::string Zip::read(int index) const {
  const auto& e = entries[index];
  if (e.uncompressed_size == 0) {
    return "";
  }

  if (e.data_offset + e.compressed_size > file.size) {
    return "";
  }

  std::string result;
  result.resize(e.uncompressed_size);
  const auto* src = file.data + e.data_offset;

  if (e.compression_method == 0) {
    std::memcpy(result.data(), src, e.uncompressed_size);
  } else if (e.compression_method == 8) {
    thread_local auto* d = libdeflate_alloc_decompressor();
    if (libdeflate_deflate_decompress(d, src, e.compressed_size, result.data(), e.uncompressed_size, nullptr) !=
        LIBDEFLATE_SUCCESS) {
      return "";
    }
  } else {
    return "";
  }
  return result;
}

std::optional<Zip::MediaResult> Zip::read_media(int index) const {
  const auto& e = entries[index];
  MediaResult out;
  out.path = e.name;
  out.blob.resize(e.uncompressed_size);
  if (e.uncompressed_size == 0) {
    return out;
  }

  if (e.data_offset + e.compressed_size > file.size) {
    return std::nullopt;
  }

  const auto* src = file.data + e.data_offset;
  if (e.compression_method == 0) {
    std::memcpy(out.blob.data(), src, e.uncompressed_size);
  } else if (e.compression_method == 8) {
    thread_local auto* d = libdeflate_alloc_decompressor();
    if (libdeflate_deflate_decompress(d, src, e.compressed_size, out.blob.data(), e.uncompressed_size, nullptr) !=
        LIBDEFLATE_SUCCESS) {
      return std::nullopt;
    }
  } else {
    return std::nullopt;
  }
  return out;
}

// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
bool Zip::parse_central_directory() {
  const auto* base = file.data;
  if (file.size < 22) {
    return false;
  }

  size_t eocd = file.size - 22;
  while (eocd > 0 && read_at<uint32_t>(base, eocd) != 0x06054b50) {
    eocd--;
  }

  uint64_t total_entries = read_at<uint16_t>(base, eocd + 10);
  uint64_t cd_offset = read_at<uint32_t>(base, eocd + 16);

  if (eocd >= 20 && read_at<uint32_t>(base, eocd - 20) == 0x07064b50) {
    auto eocd64_offset = read_at<uint64_t>(base, eocd - 12);
    if (eocd64_offset + 56 <= file.size && read_at<uint32_t>(base, eocd64_offset) == 0x06064b50) {
      total_entries = read_at<uint64_t>(base, eocd64_offset + 32);
      cd_offset = read_at<uint64_t>(base, eocd64_offset + 48);
    }
  }

  entries.reserve(total_entries);
  size_t pos = cd_offset;

  for (uint64_t i = 0; i < total_entries; ++i) {
    if (pos + 46 > file.size) {
      return false;
    }
    if (read_at<uint32_t>(base, pos) != 0x02014b50) {
      return false;
    }

    ZipEntry e;
    e.compression_method = read_at<uint16_t>(base, pos + 10);
    e.compressed_size = read_at<uint32_t>(base, pos + 20);
    e.uncompressed_size = read_at<uint32_t>(base, pos + 24);

    auto name_len = read_at<uint16_t>(base, pos + 28);
    auto extra_len = read_at<uint16_t>(base, pos + 30);
    auto comment_len = read_at<uint16_t>(base, pos + 32);

    uint64_t lfh_offset = read_at<uint32_t>(base, pos + 42);
    e.name.assign(reinterpret_cast<const char*>(base + pos + 46), name_len);

    // Parse Zip64 extra field if sizes are 0xFFFFFFFF
    size_t extra_start = pos + 46 + name_len;
    size_t extra_end = extra_start + extra_len;
    if (extra_end <= file.size) {
      size_t epos = extra_start;
      while (epos + 4 <= extra_end) {
        uint16_t header_id = read_at<uint16_t>(base, epos);
        uint16_t data_size = read_at<uint16_t>(base, epos + 2);
        if (header_id == 0x0001 && epos + 4 + data_size <= extra_end) {
          size_t fpos = epos + 4;
          if (e.uncompressed_size == 0xFFFFFFFF && fpos + 8 <= epos + 4 + data_size) {
            e.uncompressed_size = read_at<uint64_t>(base, fpos);
            fpos += 8;
          }
          if (e.compressed_size == 0xFFFFFFFF && fpos + 8 <= epos + 4 + data_size) {
            e.compressed_size = read_at<uint64_t>(base, fpos);
            fpos += 8;
          }
          if (lfh_offset == 0xFFFFFFFF && fpos + 8 <= epos + 4 + data_size) {
            lfh_offset = read_at<uint64_t>(base, fpos);
          }
          break;
        }
        epos += 4 + data_size;
      }
    }

    if (lfh_offset + 30 > file.size) {
      return false;
    }
    auto lfh_name_len = read_at<uint16_t>(base, lfh_offset + 26);
    auto lfh_extra_len = read_at<uint16_t>(base, lfh_offset + 28);
    e.data_offset = lfh_offset + 30 + lfh_name_len + lfh_extra_len;

    entries.push_back(std::move(e));
    pos += 46 + name_len + extra_len + comment_len;
  }

  return true;
}

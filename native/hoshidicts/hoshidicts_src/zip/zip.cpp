#include "zip.hpp"

#include <libdeflate.h>

#include <cstdint>
#include <cstring>
#include <limits>

#include "../memory/memory.hpp"

namespace {
template <typename T>
T read_at(const uint8_t* base, size_t offset) {
  T val;
  std::memcpy(&val, base + offset, sizeof(T));
  return val;
}

bool in_bounds(size_t size, size_t offset, size_t length) {
  return offset <= size && length <= size - offset;
}

bool has_entry_payload(const memory::mapped_file& file, const ZipEntry& e) {
  const size_t payload_size = e.compression_method == 0
                                  ? e.uncompressed_size
                                  : e.compressed_size;
  return in_bounds(file.size, e.data_offset, payload_size);
}

// DEFLATE's worst-case expansion ratio is ~1032:1 (a maximally-redundant store
// of a fixed Huffman block). A real dictionary bank never approaches that; a
// declared uncompressed_size far beyond this bound versus the compressed
// payload is a malformed/forged header (e.g. a ZIP64 0x0001 extra injecting a
// multi-GB uncompressed size over a tiny compressed payload) -- honouring it
// would make result.resize() attempt a huge allocation (std::bad_alloc on the
// worker thread, or a worse outcome on a 32-bit ABI). has_entry_payload() only
// validates that the *compressed* payload fits the file and never constrains
// uncompressed_size, so this is the only guard against attacker-controlled
// expansion. Cap at a generous multiple of the compressed size, plus a small
// fixed floor so tiny entries with legitimate inflation still pass.
constexpr uint64_t kMaxDeflateExpansionRatio = 1100;
constexpr uint64_t kMinDeflateExpansionFloor = 64 * 1024;

bool uncompressed_size_in_range(const ZipEntry& e) {
  if (e.compression_method == 0) {
    return true;  // stored: uncompressed_size == compressed_size by definition
  }
  // Avoid overflow in compressed_size * ratio: cap compressed_size first.
  const uint64_t ratio_cap =
      e.compressed_size > std::numeric_limits<uint64_t>::max() / kMaxDeflateExpansionRatio
          ? std::numeric_limits<uint64_t>::max()
          : e.compressed_size * kMaxDeflateExpansionRatio;
  const uint64_t limit =
      ratio_cap < kMinDeflateExpansionFloor ? kMinDeflateExpansionFloor : ratio_cap;
  return e.uncompressed_size <= limit;
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
  if (index < 0 || static_cast<size_t>(index) >= entries.size()) {
    return "";
  }

  const auto& e = entries[index];
  if (e.uncompressed_size == 0) {
    return "";
  }
  if (!has_entry_payload(file, e)) {
    return "";
  }
  if (!uncompressed_size_in_range(e)) {
    return "";  // forged/oversized uncompressed_size -> structured error, no huge resize
  }

  std::string result;
  result.resize(e.uncompressed_size);
  const auto* src = file.data + e.data_offset;

  if (e.compression_method == 0) {
    std::memcpy(result.data(), src, e.uncompressed_size);
  } else if (e.compression_method == 8) {
    thread_local auto* d = libdeflate_alloc_decompressor();
    if (!d) {
      return "";  // allocation failed -> do not deref null decompressor (0xC0000005)
    }
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
  if (index < 0 || static_cast<size_t>(index) >= entries.size()) {
    return std::nullopt;
  }

  const auto& e = entries[index];
  MediaResult out;
  out.path = e.name;
  if (e.uncompressed_size == 0) {
    return out;  // empty blob; no resize needed
  }
  if (!has_entry_payload(file, e)) {
    return std::nullopt;
  }
  if (!uncompressed_size_in_range(e)) {
    return std::nullopt;  // forged/oversized uncompressed_size -> skip this media
  }
  out.blob.resize(e.uncompressed_size);

  const auto* src = file.data + e.data_offset;
  if (e.compression_method == 0) {
    std::memcpy(out.blob.data(), src, e.uncompressed_size);
  } else if (e.compression_method == 8) {
    thread_local auto* d = libdeflate_alloc_decompressor();
    if (!d) {
      return std::nullopt;  // allocation failed -> do not deref null decompressor
    }
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
  if (read_at<uint32_t>(base, eocd) != 0x06054b50) {
    return false;
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

  if (cd_offset > std::numeric_limits<size_t>::max()) {
    return false;
  }
  if (total_entries > file.size / 46) {
    return false;
  }

  entries.reserve(total_entries);
  size_t pos = cd_offset;

  for (uint64_t i = 0; i < total_entries; ++i) {
    if (!in_bounds(file.size, pos, 46)) {
      return false;
    }
    if (read_at<uint32_t>(base, pos) != 0x02014b50) {
      return false;
    }

    ZipEntry e;
    e.compression_method = read_at<uint16_t>(base, pos + 10);
    const uint32_t comp32 = read_at<uint32_t>(base, pos + 20);
    const uint32_t uncomp32 = read_at<uint32_t>(base, pos + 24);

    auto name_len = read_at<uint16_t>(base, pos + 28);
    auto extra_len = read_at<uint16_t>(base, pos + 30);
    auto comment_len = read_at<uint16_t>(base, pos + 32);

    const uint32_t lfh32 = read_at<uint32_t>(base, pos + 42);
    const size_t entry_size = 46 + static_cast<size_t>(name_len) + extra_len +
                              comment_len;
    if (!in_bounds(file.size, pos, entry_size)) {
      return false;
    }

    e.compressed_size = comp32;
    e.uncompressed_size = uncomp32;
    uint64_t lfh_offset = lfh32;

    // ZIP64: any field equal to 0xFFFFFFFF means the real 64-bit value lives in
    // the central-directory extra block under header id 0x0001. The block packs
    // ONLY the overflowed fields, in fixed order: uncompressed size, compressed
    // size, local-header offset. (APPNOTE 4.5.3)
    constexpr uint32_t kZip64Sentinel = std::numeric_limits<uint32_t>::max();
    if (comp32 == kZip64Sentinel || uncomp32 == kZip64Sentinel ||
        lfh32 == kZip64Sentinel) {
      const size_t extra_base = pos + 46 + name_len;
      size_t eo = 0;
      bool resolved = false;
      while (eo + 4 <= extra_len) {
        const uint16_t hid = read_at<uint16_t>(base, extra_base + eo);
        const uint16_t hsz = read_at<uint16_t>(base, extra_base + eo + 2);
        if (eo + 4 + hsz > extra_len) {
          break;
        }
        if (hid == 0x0001) {
          size_t fo = extra_base + eo + 4;
          size_t remaining = hsz;
          auto take64 = [&](uint64_t& out) -> bool {
            if (remaining < 8) return false;
            out = read_at<uint64_t>(base, fo);
            fo += 8;
            remaining -= 8;
            return true;
          };
          if (uncomp32 == kZip64Sentinel && !take64(e.uncompressed_size)) {
            return false;
          }
          if (comp32 == kZip64Sentinel && !take64(e.compressed_size)) {
            return false;
          }
          if (lfh32 == kZip64Sentinel && !take64(lfh_offset)) {
            return false;
          }
          resolved = true;
          break;
        }
        eo += 4 + hsz;
      }
      if (!resolved) {
        return false;  // sentinel present but no ZIP64 extra → malformed
      }
    }

    e.name.assign(reinterpret_cast<const char*>(base + pos + 46), name_len);

    // lfh_offset is 64-bit (it may carry a resolved ZIP64 value). Reject any
    // out-of-range offset here, BEFORE in_bounds() narrows it to size_t -- on a
    // 32-bit ABI (armeabi-v7a) that narrowing could otherwise wrap a >4GB
    // offset into a small in-bounds value. Do not remove this guard.
    if (lfh_offset > file.size) {
      return false;
    }
    if (!in_bounds(file.size, lfh_offset, 30)) {
      return false;
    }
    if (read_at<uint32_t>(base, lfh_offset) != 0x04034b50) {
      return false;
    }

    auto lfh_name_len = read_at<uint16_t>(base, lfh_offset + 26);
    auto lfh_extra_len = read_at<uint16_t>(base, lfh_offset + 28);
    e.data_offset = lfh_offset + 30 + lfh_name_len + lfh_extra_len;
    if (!in_bounds(file.size, lfh_offset,
                   30 + static_cast<size_t>(lfh_name_len) + lfh_extra_len)) {
      return false;
    }
    if (!has_entry_payload(file, e)) {
      return false;
    }

    entries.push_back(std::move(e));
    pos += entry_size;
  }

  return true;
}

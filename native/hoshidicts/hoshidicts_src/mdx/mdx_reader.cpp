#include "mdx_reader.hpp"

#include <libdeflate.h>

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <unordered_map>

#include <utf8.h>

namespace {

inline uint16_t be16(const uint8_t* p) { return (uint16_t(p[0]) << 8) | p[1]; }

inline uint32_t be32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

inline uint64_t be64(const uint8_t* p) { return (uint64_t(be32(p)) << 32) | be32(p + 4); }

inline uint32_t le32(const uint8_t* p) {
  return p[0] | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

std::string utf16le_to_utf8(const uint8_t* data, size_t byte_len) {
  std::u16string u16;
  for (size_t i = 0; i + 1 < byte_len; i += 2) {
    u16.push_back(uint16_t(data[i]) | (uint16_t(data[i + 1]) << 8));
  }
  std::string result;
  utf8::utf16to8(u16.begin(), u16.end(), std::back_inserter(result));
  return result;
}

std::vector<uint8_t> decompress_block(const uint8_t* block, size_t compressed_total, size_t decompressed_size) {
  if (compressed_total < 8) return {};

  uint32_t comp_type = le32(block);
  const uint8_t* comp_data = block + 8;
  size_t comp_data_size = compressed_total - 8;

  std::vector<uint8_t> result(decompressed_size);

  if (comp_type == 0) {
    if (comp_data_size < decompressed_size) return {};
    std::memcpy(result.data(), comp_data, decompressed_size);
  } else if (comp_type == 2) {
    auto* d = libdeflate_alloc_decompressor();
    if (!d) return {};
    auto ret = libdeflate_zlib_decompress(d, comp_data, comp_data_size, result.data(), decompressed_size, nullptr);
    libdeflate_free_decompressor(d);
    if (ret != LIBDEFLATE_SUCCESS) return {};
  } else {
    return {};
  }

  return result;
}

std::string get_attribute(const std::string& xml, const std::string& attr_name) {
  std::string search = attr_name + "=\"";
  auto pos = xml.find(search);
  if (pos == std::string::npos) {
    search = attr_name + "='";
    pos = xml.find(search);
    if (pos == std::string::npos) return "";
  }
  char quote = xml[pos + attr_name.size() + 1];
  pos += search.size();
  auto end = xml.find(quote, pos);
  if (end == std::string::npos) return "";
  return xml.substr(pos, end - pos);
}

struct KeyEntry {
  uint64_t record_offset;
  std::string headword;
};

struct BlockMeta {
  uint64_t num_entries;
  uint64_t compressed_size;
  uint64_t decompressed_size;
};

}  // namespace

MdxResult mdx_reader::parse(const uint8_t* data, size_t size) {
  MdxResult result;
  if (size < 8) throw std::runtime_error("mdx: file too small");

  size_t pos = 0;

  // --- Header ---
  uint32_t header_bytes_size = be32(data + pos);
  pos += 4;
  if (pos + header_bytes_size + 4 > size) throw std::runtime_error("mdx: header overflow");

  std::string header_text;
  if (header_bytes_size >= 2 && data[pos] == 0xFF && data[pos + 1] == 0xFE) {
    header_text = utf16le_to_utf8(data + pos + 2, header_bytes_size - 2);
  } else if (header_bytes_size >= 4 && (data[pos + 1] == 0x00)) {
    header_text = utf16le_to_utf8(data + pos, header_bytes_size);
  } else {
    header_text.assign(reinterpret_cast<const char*>(data + pos), header_bytes_size);
  }
  pos += header_bytes_size;
  pos += 4;  // adler32

  result.title = get_attribute(header_text, "Title");
  result.encoding = get_attribute(header_text, "Encoding");
  if (result.encoding.empty()) result.encoding = "utf-8";

  // Normalize encoding
  std::string enc_lower = result.encoding;
  std::transform(enc_lower.begin(), enc_lower.end(), enc_lower.begin(), ::tolower);

  std::string version_str = get_attribute(header_text, "GeneratedByEngineVersion");
  if (!version_str.empty()) {
    auto dot = version_str.find('.');
    if (dot != std::string::npos) {
      result.version_major = std::stoi(version_str.substr(0, dot));
      result.version_minor = std::stoi(version_str.substr(dot + 1));
    } else {
      result.version_major = std::stoi(version_str);
    }
  }

  bool is_v2 = result.version_major >= 2;
  bool is_utf16 = (enc_lower.find("utf-16") != std::string::npos || enc_lower.find("utf16") != std::string::npos);
  int null_term_bytes = is_utf16 ? 2 : 1;

  // --- Key Block Header ---
  uint64_t num_key_blocks, num_entries;
  uint64_t key_block_info_decomp_size = 0, key_block_info_size, key_blocks_size;

  if (is_v2) {
    if (pos + 44 > size) throw std::runtime_error("mdx: key block header overflow");
    num_key_blocks = be64(data + pos);
    pos += 8;
    num_entries = be64(data + pos);
    pos += 8;
    key_block_info_decomp_size = be64(data + pos);
    pos += 8;
    key_block_info_size = be64(data + pos);
    pos += 8;
    key_blocks_size = be64(data + pos);
    pos += 8;
    pos += 4;  // adler32
  } else {
    if (pos + 16 > size) throw std::runtime_error("mdx: key block header overflow");
    num_key_blocks = be32(data + pos);
    pos += 4;
    num_entries = be32(data + pos);
    pos += 4;
    key_block_info_size = be32(data + pos);
    pos += 4;
    key_block_info_decomp_size = key_block_info_size;
    key_blocks_size = be32(data + pos);
    pos += 4;
  }

  if (pos + key_block_info_size > size) throw std::runtime_error("mdx: key block info overflow");

  // Decompress key block info
  std::vector<uint8_t> key_block_info;
  if (is_v2 && key_block_info_size >= 8) {
    uint32_t comp_type = le32(data + pos);
    if (comp_type == 2 || comp_type == 1) {
      key_block_info = decompress_block(data + pos, key_block_info_size, key_block_info_decomp_size);
    } else {
      key_block_info.assign(data + pos, data + pos + key_block_info_size);
    }
  } else {
    key_block_info.assign(data + pos, data + pos + key_block_info_size);
  }
  pos += key_block_info_size;

  if (key_block_info.empty()) throw std::runtime_error("mdx: empty key block info");

  // Parse key block info
  std::vector<BlockMeta> key_block_metas;
  {
    size_t ipos = 0;
    for (uint64_t b = 0; b < num_key_blocks; b++) {
      BlockMeta meta{};
      if (is_v2) {
        if (ipos + 8 > key_block_info.size()) break;
        meta.num_entries = be64(key_block_info.data() + ipos);
        ipos += 8;
        // Skip first key
        if (ipos + 2 > key_block_info.size()) break;
        uint16_t first_len = be16(key_block_info.data() + ipos);
        ipos += 2;
        ipos += (is_utf16 ? first_len * 2 : first_len) + null_term_bytes;
        // Skip last key
        if (ipos + 2 > key_block_info.size()) break;
        uint16_t last_len = be16(key_block_info.data() + ipos);
        ipos += 2;
        ipos += (is_utf16 ? last_len * 2 : last_len) + null_term_bytes;
        if (ipos + 16 > key_block_info.size()) break;
        meta.compressed_size = be64(key_block_info.data() + ipos);
        ipos += 8;
        meta.decompressed_size = be64(key_block_info.data() + ipos);
        ipos += 8;
      } else {
        if (ipos + 4 > key_block_info.size()) break;
        meta.num_entries = be32(key_block_info.data() + ipos);
        ipos += 4;
        if (ipos + 1 > key_block_info.size()) break;
        uint8_t first_len = key_block_info[ipos];
        ipos += 1;
        ipos += (is_utf16 ? first_len * 2 : first_len) + null_term_bytes;
        if (ipos + 1 > key_block_info.size()) break;
        uint8_t last_len = key_block_info[ipos];
        ipos += 1;
        ipos += (is_utf16 ? last_len * 2 : last_len) + null_term_bytes;
        if (ipos + 8 > key_block_info.size()) break;
        meta.compressed_size = be32(key_block_info.data() + ipos);
        ipos += 4;
        meta.decompressed_size = be32(key_block_info.data() + ipos);
        ipos += 4;
      }
      key_block_metas.push_back(meta);
    }
  }

  // Parse key blocks
  std::vector<KeyEntry> keys;
  keys.reserve(num_entries);

  if (pos + key_blocks_size > size) throw std::runtime_error("mdx: key blocks overflow");

  for (const auto& meta : key_block_metas) {
    if (pos + meta.compressed_size > size) break;

    std::vector<uint8_t> block_data;
    if (meta.compressed_size != meta.decompressed_size && meta.compressed_size >= 8) {
      block_data = decompress_block(data + pos, meta.compressed_size, meta.decompressed_size);
    } else {
      // Uncompressed (or runt < 8B) block: copy decompressed_size bytes straight
      // from the source buffer. The pos+compressed_size guard above only bounds
      // compressed_size; a corrupt block whose decompressed_size exceeds the
      // available source bytes would read past data + size (OOB). Bound it.
      if (pos + meta.decompressed_size > size) break;
      block_data.assign(data + pos, data + pos + meta.decompressed_size);
    }
    pos += meta.compressed_size;

    if (block_data.empty()) continue;

    size_t bpos = 0;
    for (uint64_t e = 0; e < meta.num_entries; e++) {
      KeyEntry entry;
      if (is_v2) {
        if (bpos + 8 > block_data.size()) break;
        entry.record_offset = be64(block_data.data() + bpos);
        bpos += 8;
      } else {
        if (bpos + 4 > block_data.size()) break;
        entry.record_offset = be32(block_data.data() + bpos);
        bpos += 4;
      }

      if (is_utf16) {
        size_t start = bpos;
        while (bpos + 1 < block_data.size()) {
          uint16_t ch = block_data[bpos] | (uint16_t(block_data[bpos + 1]) << 8);
          if (ch == 0) {
            bpos += 2;
            break;
          }
          bpos += 2;
        }
        if (bpos > start + 2) {
          entry.headword = utf16le_to_utf8(block_data.data() + start, bpos - start - 2);
        }
      } else {
        const char* s = reinterpret_cast<const char*>(block_data.data() + bpos);
        size_t max_len = block_data.size() - bpos;
        size_t len = 0;
        while (len < max_len && s[len] != '\0') len++;
        entry.headword.assign(s, len);
        bpos += len + 1;
      }

      keys.push_back(std::move(entry));
    }
  }

  // --- Record Blocks ---
  uint64_t num_record_blocks, record_block_info_size, record_blocks_total_size;

  if (is_v2) {
    if (pos + 32 > size) throw std::runtime_error("mdx: record header overflow");
    num_record_blocks = be64(data + pos);
    pos += 8;
    pos += 8;  // num_entries (already known)
    record_block_info_size = be64(data + pos);
    pos += 8;
    record_blocks_total_size = be64(data + pos);
    pos += 8;
  } else {
    if (pos + 16 > size) throw std::runtime_error("mdx: record header overflow");
    num_record_blocks = be32(data + pos);
    pos += 4;
    pos += 4;
    record_block_info_size = be32(data + pos);
    pos += 4;
    record_blocks_total_size = be32(data + pos);
    pos += 4;
  }

  if (pos + record_block_info_size > size) throw std::runtime_error("mdx: record block info overflow");

  struct RecordBlockMeta {
    uint64_t compressed_size;
    uint64_t decompressed_size;
  };
  std::vector<RecordBlockMeta> record_metas;
  record_metas.reserve(num_record_blocks);

  for (uint64_t b = 0; b < num_record_blocks; b++) {
    RecordBlockMeta meta{};
    if (is_v2) {
      if (pos + 16 > size) break;
      meta.compressed_size = be64(data + pos);
      pos += 8;
      meta.decompressed_size = be64(data + pos);
      pos += 8;
    } else {
      if (pos + 8 > size) break;
      meta.compressed_size = be32(data + pos);
      pos += 4;
      meta.decompressed_size = be32(data + pos);
      pos += 4;
    }
    record_metas.push_back(meta);
  }

  // Decompress all record blocks
  std::vector<uint8_t> all_records;
  {
    uint64_t total = 0;
    for (const auto& m : record_metas) total += m.decompressed_size;
    all_records.reserve(total);
  }

  for (const auto& meta : record_metas) {
    if (pos + meta.compressed_size > size) break;

    if (meta.compressed_size != meta.decompressed_size && meta.compressed_size >= 8) {
      auto block = decompress_block(data + pos, meta.compressed_size, meta.decompressed_size);
      if (!block.empty()) {
        all_records.insert(all_records.end(), block.begin(), block.end());
      }
    } else {
      // Uncompressed (or runt < 8B) record block: same OOB hazard as the key
      // block path above -- the pos+compressed_size guard does not cover a
      // decompressed_size that runs past data + size. Bound the copy.
      if (pos + meta.decompressed_size > size) break;
      all_records.insert(all_records.end(), data + pos, data + pos + meta.decompressed_size);
    }
    pos += meta.compressed_size;
  }

  // Build entries
  result.entries.reserve(keys.size());
  for (size_t i = 0; i < keys.size(); i++) {
    uint64_t start = keys[i].record_offset;
    uint64_t end = (i + 1 < keys.size()) ? keys[i + 1].record_offset : all_records.size();

    if (start >= all_records.size() || end > all_records.size() || start >= end) continue;

    std::string definition;
    if (is_utf16) {
      definition = utf16le_to_utf8(all_records.data() + start, end - start);
    } else {
      definition.assign(reinterpret_cast<const char*>(all_records.data() + start), end - start);
    }

    while (!definition.empty() && definition.back() == '\0') definition.pop_back();

    result.entries.push_back({std::move(keys[i].headword), std::move(definition)});
  }

  // Resolve @@@LINK= redirects (follow chains up to 10 hops)
  std::unordered_map<std::string, size_t> key_map;
  key_map.reserve(result.entries.size());
  for (size_t i = 0; i < result.entries.size(); i++) {
    key_map.emplace(result.entries[i].key, i);
  }

  for (auto& entry : result.entries) {
    int depth = 0;
    while (entry.definition.starts_with("@@@LINK=") && depth < 10) {
      std::string target = entry.definition.substr(8);
      while (!target.empty() && (target.back() == '\r' || target.back() == '\n' || target.back() == ' ')) {
        target.pop_back();
      }
      auto it = key_map.find(target);
      if (it == key_map.end()) break;
      entry.definition = result.entries[it->second].definition;
      depth++;
    }
  }

  return result;
}

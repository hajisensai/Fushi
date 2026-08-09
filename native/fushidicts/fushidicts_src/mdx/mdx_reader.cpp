#include "mdx_reader.hpp"

#include <libdeflate.h>

#include <algorithm>
#include <array>
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

// --- MDX Encrypted="2" key-block-info obfuscation ---------------------------
// MDict scrambles the (already zlib-compressed) key-block-info section with a
// self-contained algorithm that needs no registration key: a RIPEMD-128 hash
// of the section's own adler32 bytes seeds a rolling XOR/nibble-swap cipher.
// Without undoing it, libdeflate sees garbage and the parse dies with
// "empty key block info". This is bit 1 of the header's `Encrypted` attribute;
// bit 0 (record encryption) genuinely needs a purchased key and is left alone.

inline uint32_t rol32(uint32_t x, unsigned s) { return (x << s) | (x >> (32 - s)); }

// RIPEMD-128 (16-byte digest). Follows the reference from
// homes.esat.kuleuven.be/~bosselae/ripemd/rmd128.txt.
std::array<uint8_t, 16> ripemd128(const uint8_t* msg, size_t len) {
  static const unsigned rr[64] = {
      0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 7,  4,  13, 1,  10, 6,
      15, 3,  12, 0,  9,  5,  2,  14, 11, 8,  3,  10, 14, 4,  9,  15, 8,  1,  2,  7,  0,  6,
      13, 11, 5,  12, 1,  9,  11, 10, 0,  8,  12, 4,  13, 3,  7,  15, 14, 5,  6,  2};
  static const unsigned rrp[64] = {
      5,  14, 7,  0,  9,  2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12, 6,  11, 3,  7,  0,  13,
      5,  10, 14, 15, 8,  12, 4,  9,  1,  2,  15, 5,  1,  3,  7,  14, 6,  9,  11, 8,  12, 2,
      10, 0,  4,  13, 8,  6,  4,  1,  3,  11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14};
  static const unsigned ss[64] = {
      11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,  7,  6,  8,  13, 11, 9,
      7,  15, 7,  12, 15, 9,  11, 7,  13, 12, 11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,
      5,  12, 7,  5,  11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12};
  static const unsigned ssp[64] = {
      8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,  9,  13, 15, 7,  12, 8,
      9,  11, 7,  7,  12, 7,  6,  15, 13, 11, 9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14,
      13, 13, 7,  5,  15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8};

  auto f = [](int j, uint32_t x, uint32_t y, uint32_t z) -> uint32_t {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | (~x & z);
    if (j < 48) return (x | ~y) ^ z;
    return (x & z) | (y & ~z);
  };
  auto K = [](int j) -> uint32_t {
    if (j < 16) return 0x00000000u;
    if (j < 32) return 0x5a827999u;
    if (j < 48) return 0x6ed9eba1u;
    return 0x8f1bbcdcu;
  };
  auto Kp = [](int j) -> uint32_t {
    if (j < 16) return 0x50a28be6u;
    if (j < 32) return 0x5c4dd124u;
    if (j < 48) return 0x6d703ef3u;
    return 0x00000000u;
  };

  // Pad: 0x80, then zeros to 56 mod 64, then 64-bit little-endian bit length.
  std::vector<uint8_t> buf(msg, msg + len);
  uint64_t bit_len = uint64_t(len) * 8;
  buf.push_back(0x80);
  while (buf.size() % 64 != 56) buf.push_back(0x00);
  for (int i = 0; i < 8; i++) buf.push_back(uint8_t((bit_len >> (8 * i)) & 0xff));

  uint32_t h0 = 0x67452301u, h1 = 0xefcdab89u, h2 = 0x98badcfeu, h3 = 0x10325476u;
  for (size_t chunk = 0; chunk < buf.size(); chunk += 64) {
    uint32_t X[16];
    for (int i = 0; i < 16; i++) X[i] = le32(buf.data() + chunk + i * 4);
    uint32_t A = h0, B = h1, C = h2, D = h3;
    uint32_t Ap = h0, Bp = h1, Cp = h2, Dp = h3;
    for (int j = 0; j < 64; j++) {
      uint32_t t = rol32(A + f(j, B, C, D) + X[rr[j]] + K(j), ss[j]);
      A = D;
      D = C;
      C = B;
      B = t;
      t = rol32(Ap + f(63 - j, Bp, Cp, Dp) + X[rrp[j]] + Kp(j), ssp[j]);
      Ap = Dp;
      Dp = Cp;
      Cp = Bp;
      Bp = t;
    }
    uint32_t t = h1 + C + Dp;
    h1 = h2 + D + Ap;
    h2 = h3 + A + Bp;
    h3 = h0 + B + Cp;
    h0 = t;
  }

  std::array<uint8_t, 16> out{};
  uint32_t hs[4] = {h0, h1, h2, h3};
  for (int i = 0; i < 4; i++)
    for (int b = 0; b < 4; b++) out[i * 4 + b] = uint8_t((hs[i] >> (8 * b)) & 0xff);
  return out;
}

// In-place undo of the MDX key-block-info cipher (rolling nibble-swap XOR).
void mdx_fast_decrypt(uint8_t* data, size_t len, const uint8_t* key, size_t key_len) {
  if (key_len == 0) return;
  uint8_t prev = 0x36;
  for (size_t i = 0; i < len; i++) {
    uint8_t b = data[i];
    uint8_t t = uint8_t((b >> 4) | (b << 4));
    t = uint8_t(t ^ prev ^ uint8_t(i & 0xff) ^ key[i % key_len]);
    prev = b;
    data[i] = t;
  }
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

namespace {

struct ContainerData {
  std::string title;
  std::string encoding;
  int version_major = 0;
  int version_minor = 0;
  bool is_utf16 = false;
  std::vector<KeyEntry> keys;
  std::vector<uint8_t> all_records;
};

// Parse the MDX/MDD container down to decoded keys + the concatenated raw record
// stream. Shared by parse() (text records) and parse_mdd() (binary records) --
// they differ only in how each record slice is interpreted afterwards.
ContainerData parse_container(const uint8_t* data, size_t size) {
  ContainerData result;
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

  // `Encrypted` is a bitfield: bit 1 (value 2) scrambles the key-block-info
  // section (undoable, no key needed); bit 0 (value 1) encrypts record blocks
  // and requires a purchased registration key we cannot supply. Older dicts
  // wrote "No"/"Yes"; treat "Yes" as bit 0.
  int encrypted = 0;
  {
    std::string enc = get_attribute(header_text, "Encrypted");
    if (enc == "Yes" || enc == "yes") {
      encrypted = 1;
    } else if (!enc.empty()) {
      try {
        encrypted = std::stoi(enc);
      } catch (...) {
        encrypted = 0;
      }
    }
  }

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

  // Decompress key block info. When Encrypted="2", the compressed payload
  // (everything after the 8-byte comp_type+adler32 prefix) is scrambled and
  // must be unscrambled before libdeflate can inflate it. The RIPEMD-128 key is
  // derived from the section's own adler32 bytes [4..8) plus the fixed 0x3695
  // little-endian salt.
  std::vector<uint8_t> key_block_info;
  std::vector<uint8_t> kbi_plain;  // holds the decrypted section if needed
  const uint8_t* kbi_ptr = data + pos;
  if ((encrypted & 2) && key_block_info_size >= 8) {
    kbi_plain.assign(data + pos, data + pos + key_block_info_size);
    uint8_t seed[8] = {kbi_plain[4], kbi_plain[5], kbi_plain[6], kbi_plain[7], 0x95, 0x36, 0x00, 0x00};
    auto key = ripemd128(seed, 8);
    mdx_fast_decrypt(kbi_plain.data() + 8, kbi_plain.size() - 8, key.data(), key.size());
    kbi_ptr = kbi_plain.data();
  }
  if (is_v2 && key_block_info_size >= 8) {
    uint32_t comp_type = le32(kbi_ptr);
    if (comp_type == 2 || comp_type == 1) {
      key_block_info = decompress_block(kbi_ptr, key_block_info_size, key_block_info_decomp_size);
    } else {
      key_block_info.assign(kbi_ptr, kbi_ptr + key_block_info_size);
    }
  } else {
    key_block_info.assign(kbi_ptr, kbi_ptr + key_block_info_size);
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

  result.is_utf16 = is_utf16;
  result.keys = std::move(keys);
  result.all_records = std::move(all_records);
  return result;
}

}  // namespace

MdxResult mdx_reader::parse(const uint8_t* data, size_t size) {
  ContainerData c = parse_container(data, size);

  MdxResult result;
  result.title = std::move(c.title);
  result.encoding = std::move(c.encoding);
  result.version_major = c.version_major;
  result.version_minor = c.version_minor;

  // Build entries: each record slice is a text (HTML) definition.
  result.entries.reserve(c.keys.size());
  for (size_t i = 0; i < c.keys.size(); i++) {
    uint64_t start = c.keys[i].record_offset;
    uint64_t end = (i + 1 < c.keys.size()) ? c.keys[i + 1].record_offset : c.all_records.size();

    if (start >= c.all_records.size() || end > c.all_records.size() || start >= end) continue;

    std::string definition;
    if (c.is_utf16) {
      definition = utf16le_to_utf8(c.all_records.data() + start, end - start);
    } else {
      definition.assign(reinterpret_cast<const char*>(c.all_records.data() + start), end - start);
    }

    while (!definition.empty() && definition.back() == '\0') definition.pop_back();

    result.entries.push_back({std::move(c.keys[i].headword), std::move(definition)});
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

std::vector<MddEntry> mdx_reader::parse_mdd(const uint8_t* data, size_t size) {
  ContainerData c = parse_container(data, size);

  // Each record slice is a raw binary file (image/audio/css/font); the key is
  // its path. Keep bytes verbatim -- no transcoding, no trailing-NUL stripping
  // (a PNG/JPEG legitimately ends in NUL bytes), no @@@LINK resolution.
  std::vector<MddEntry> out;
  out.reserve(c.keys.size());
  for (size_t i = 0; i < c.keys.size(); i++) {
    uint64_t start = c.keys[i].record_offset;
    uint64_t end = (i + 1 < c.keys.size()) ? c.keys[i + 1].record_offset : c.all_records.size();

    if (start >= c.all_records.size() || end > c.all_records.size() || start >= end) continue;

    out.push_back(MddEntry{std::move(c.keys[i].headword),
                           std::string(reinterpret_cast<const char*>(c.all_records.data() + start),
                                       static_cast<size_t>(end - start))});
  }
  return out;
}

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

// One record block: where its compressed bytes sit in the file, and where its
// decompressed bytes land in the conceptual concatenated stream that the key
// table's record_offset values index into.
struct RecordBlockMeta {
  uint64_t file_offset = 0;
  uint64_t compressed_size = 0;
  uint64_t decompressed_size = 0;
  uint64_t decompressed_base = 0;
};

// The container parsed down to its index: header metadata, the decoded key
// table, and the record block table. Record bytes are deliberately NOT
// decompressed here -- callers stream them one block at a time (stream_records)
// or pull individual records back (extract_records). Materialising the whole
// decompressed stream is what used to make a 400 MB dictionary need well over a
// gigabyte of heap and get the app jetsam-killed on iOS.
struct ContainerIndex {
  std::string title;
  std::string encoding;
  int version_major = 0;
  int version_minor = 0;
  bool is_utf16 = false;
  std::vector<KeyEntry> keys;
  std::vector<RecordBlockMeta> record_metas;
  uint64_t total_decompressed = 0;
};

// Parse the MDX/MDD container down to decoded keys + the record block table.
// Shared by parse() (text records) and parse_mdd() (binary records) -- they
// differ only in how each record slice is interpreted afterwards.
ContainerIndex parse_container_index(const uint8_t* data, size_t size) {
  ContainerIndex result;
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

  // MDD (`<Library_Data …>`) keys are file paths and are ALWAYS UTF-16LE; only
  // MDX (`<Dictionary …>`) text honours the Encoding attribute. Writers such as
  // MDTT emit `Encoding=""` in .mdd headers, and defaulting that to UTF-8 made
  // the key-block scan walk single-byte NULs through UTF-16 data: every key
  // offset drifted and the parse died later with "record block info overflow",
  // dropping the whole media companion (fonts, images, scripts) on the floor.
  // An .mdd that does declare an encoding keeps being taken at its word.
  const bool is_mdd = header_text.find("<Library_Data") != std::string::npos;
  result.encoding = get_attribute(header_text, "Encoding");
  if (result.encoding.empty()) result.encoding = is_mdd ? "utf-16" : "utf-8";

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

  // Locate each record block instead of decompressing it. `pos` now sits at the
  // first block's compressed bytes; walking the table assigns every block both
  // its file offset and its base in the decompressed stream, which is what lets
  // a block be inflated on its own later (in order, or by targeted lookup).
  //
  // A block whose compressed bytes run past EOF truncates the table here, which
  // is the same point the old eager loop stopped decompressing at.
  {
    uint64_t block_pos = pos;
    uint64_t running_base = 0;
    size_t usable = 0;
    for (auto& meta : record_metas) {
      if (block_pos + meta.compressed_size > size) break;
      meta.file_offset = block_pos;
      meta.decompressed_base = running_base;
      block_pos += meta.compressed_size;
      running_base += meta.decompressed_size;
      usable++;
    }
    record_metas.resize(usable);
    result.total_decompressed = running_base;
  }

  result.is_utf16 = is_utf16;
  result.keys = std::move(keys);
  result.record_metas = std::move(record_metas);
  return result;
}

// Inflate a single record block. Mirrors the old inline logic: a block whose
// compressed size equals its decompressed size (or is a runt < 8 B) is stored
// verbatim, and that raw copy is bounded against the source buffer exactly like
// the key-block path -- the file_offset+compressed_size check does not cover a
// corrupt decompressed_size that would read past data + size.
bool decompress_record_block(const uint8_t* data, size_t size, const RecordBlockMeta& meta,
                             std::vector<uint8_t>& out) {
  if (meta.file_offset + meta.compressed_size > size) return false;
  const uint8_t* src = data + meta.file_offset;

  if (meta.compressed_size != meta.decompressed_size && meta.compressed_size >= 8) {
    out = decompress_block(src, meta.compressed_size, meta.decompressed_size);
    return !out.empty();
  }
  if (meta.file_offset + meta.decompressed_size > size) return false;
  out.assign(src, src + meta.decompressed_size);
  return true;
}

// Byte span of the record belonging to key `i` within the decompressed stream.
uint64_t record_end_offset(const ContainerIndex& idx, size_t i) {
  return (i + 1 < idx.keys.size()) ? idx.keys[i + 1].record_offset : idx.total_decompressed;
}

// Visit every record in key order while holding at most one block -- plus any
// record straddling a block boundary -- in memory.
//
// A block that fails to inflate is skipped along with the entries living in it,
// rather than dropping its bytes while keeping its span: key offsets index the
// decompressed stream, so a silent hole would misalign every later entry and
// hand back garbage definitions for the rest of the dictionary.
void stream_records(const uint8_t* data, size_t size, ContainerIndex& idx,
                    const std::function<void(size_t key_index, const uint8_t* rec, size_t len)>& sink) {
  if (idx.keys.empty()) return;

  std::vector<uint8_t> window;  // covers [window_base, window_base + window.size())
  std::vector<uint8_t> block;
  uint64_t window_base = 0;
  size_t key_index = 0;

  for (const auto& meta : idx.record_metas) {
    if (key_index >= idx.keys.size()) break;

    if (!decompress_record_block(data, size, meta, block)) {
      const uint64_t block_end = meta.decompressed_base + meta.decompressed_size;
      while (key_index < idx.keys.size() && idx.keys[key_index].record_offset < block_end) key_index++;
      window.clear();
      window_base = block_end;
      continue;
    }

    // Resync rather than concatenating across a dropped block.
    if (window_base + window.size() != meta.decompressed_base) {
      window.clear();
      window_base = meta.decompressed_base;
    }
    window.insert(window.end(), block.begin(), block.end());
    const uint64_t window_end = window_base + window.size();

    while (key_index < idx.keys.size()) {
      const uint64_t start = idx.keys[key_index].record_offset;
      const uint64_t end = record_end_offset(idx, key_index);
      if (end > window_end) break;  // record continues into the next block
      if (start < window_base || start >= end) {
        key_index++;
        continue;
      }
      sink(key_index, window.data() + (start - window_base), static_cast<size_t>(end - start));
      key_index++;
    }

    // Release everything the remaining entries can no longer reach.
    const uint64_t keep_from = (key_index < idx.keys.size())
                                   ? std::max<uint64_t>(idx.keys[key_index].record_offset, window_base)
                                   : window_end;
    if (keep_from > window_base) {
      window.erase(window.begin(), window.begin() + static_cast<std::ptrdiff_t>(keep_from - window_base));
      window_base = keep_from;
    }
  }
}

// Pull back individual records named by key index, inflating only the blocks
// those records actually live in. Used to resolve @@@LINK= targets after the
// forward pass, so a redirect-heavy dictionary costs a handful of extra block
// inflations instead of a second full decompression.
void extract_records(const uint8_t* data, size_t size, const ContainerIndex& idx,
                     const std::vector<size_t>& wanted,
                     const std::function<void(size_t key_index, const uint8_t* rec, size_t len)>& sink) {
  if (idx.record_metas.empty()) return;

  // Last block whose decompressed_base is <= off.
  auto block_for = [&](uint64_t off) -> size_t {
    size_t lo = 0, hi = idx.record_metas.size();
    while (lo + 1 < hi) {
      size_t mid = lo + (hi - lo) / 2;
      if (idx.record_metas[mid].decompressed_base <= off) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  };

  std::vector<uint8_t> block;
  std::vector<uint8_t> joined;
  size_t cached = SIZE_MAX;

  for (size_t ki : wanted) {
    if (ki >= idx.keys.size()) continue;
    const uint64_t start = idx.keys[ki].record_offset;
    const uint64_t end = record_end_offset(idx, ki);
    if (start >= end || end > idx.total_decompressed) continue;

    const size_t first = block_for(start);
    const size_t last = block_for(end - 1);

    if (first == last) {
      if (cached != first) {
        if (!decompress_record_block(data, size, idx.record_metas[first], block)) {
          cached = SIZE_MAX;
          continue;
        }
        cached = first;
      }
      const uint64_t base = idx.record_metas[first].decompressed_base;
      if (start < base || end - base > block.size()) continue;
      sink(ki, block.data() + (start - base), static_cast<size_t>(end - start));
      continue;
    }

    // Straddles a boundary: stitch just the covered blocks for this one record.
    joined.clear();
    bool ok = true;
    for (size_t b = first; b <= last; b++) {
      std::vector<uint8_t> part;
      if (!decompress_record_block(data, size, idx.record_metas[b], part)) {
        ok = false;
        break;
      }
      joined.insert(joined.end(), part.begin(), part.end());
    }
    cached = SIZE_MAX;
    if (!ok) continue;
    const uint64_t base = idx.record_metas[first].decompressed_base;
    if (start < base || end - base > joined.size()) continue;
    sink(ki, joined.data() + (start - base), static_cast<size_t>(end - start));
  }
}

}  // namespace

namespace {

// Strip the trailing CR/LF/space MDict writers leave on a redirect target.
std::string link_target_of(const std::string& definition) {
  std::string target = definition.substr(8);
  while (!target.empty() && (target.back() == '\r' || target.back() == '\n' || target.back() == ' ')) {
    target.pop_back();
  }
  return target;
}

}  // namespace

MdxMeta mdx_reader::parse_streaming(const uint8_t* data, size_t size, const EntrySink& sink,
                                    const MetaSink& on_meta) {
  ContainerIndex idx = parse_container_index(data, size);

  MdxMeta meta;
  meta.title = idx.title;
  meta.encoding = idx.encoding;
  meta.version_major = idx.version_major;
  meta.version_minor = idx.version_minor;
  meta.entry_count = idx.keys.size();
  if (on_meta) on_meta(meta);

  // Text semantics for one record slice.
  const bool is_utf16 = idx.is_utf16;
  auto to_text = [is_utf16](const uint8_t* rec, size_t len) -> std::string {
    std::string s = is_utf16 ? utf16le_to_utf8(rec, len)
                             : std::string(reinterpret_cast<const char*>(rec), len);
    while (!s.empty() && s.back() == '\0') s.pop_back();
    return s;
  };

  // A @@@LINK= redirect names a headword that can sit anywhere in the file, so
  // it cannot be resolved during a single forward pass. Redirect bodies are a
  // few dozen bytes each, so park them and resolve afterwards by inflating only
  // the blocks their targets live in -- rather than keeping the whole
  // dictionary around just in case something points backwards.
  struct PendingLink {
    size_t key_index;
    std::string target;
  };
  std::vector<PendingLink> links;

  stream_records(data, size, idx, [&](size_t ki, const uint8_t* rec, size_t len) {
    std::string text = to_text(rec, len);
    if (text.starts_with("@@@LINK=")) {
      links.push_back({ki, link_target_of(text)});
      return;
    }
    sink(std::string(idx.keys[ki].headword), std::move(text));
  });

  if (links.empty()) return meta;

  // Redirects are resolved entirely at the INDEX level: chains are walked over
  // key indices and no definition text is ever retained. Holding target text
  // instead would reintroduce exactly the blow-up this rewrite exists to remove
  // -- a redirect-heavy dictionary can name millions of targets whose combined
  // HTML runs to gigabytes.
  constexpr size_t kNoKey = static_cast<size_t>(-1);

  // Only the headwords redirects actually name, not a table over every key.
  std::unordered_map<std::string_view, size_t> target_index;
  target_index.reserve(links.size());
  for (const auto& link : links) {
    target_index.emplace(std::string_view(link.target), kNoKey);
  }
  // One linear pass over the key table resolves them all. Duplicate headwords
  // keep the first, matching the old whole-table key_map.
  for (size_t i = 0; i < idx.keys.size(); i++) {
    auto it = target_index.find(std::string_view(idx.keys[i].headword));
    if (it != target_index.end() && it->second == kNoKey) it->second = i;
  }

  // Redirect key index -> the key index it points at.
  std::unordered_map<size_t, size_t> redirect_target;
  redirect_target.reserve(links.size());
  for (const auto& link : links) {
    auto it = target_index.find(std::string_view(link.target));
    redirect_target.emplace(link.key_index, it == target_index.end() ? kNoKey : it->second);
  }

  // Walk chains over indices (a target may itself be a redirect, and a chain may
  // point backwards), bounded by the same 10 hops the old resolution allowed.
  // Group the redirects by the record they ultimately need, carrying the link's
  // position so each one can be marked off once its text has been handed over.
  std::unordered_map<size_t, std::vector<size_t>> links_by_target;
  for (size_t pos = 0; pos < links.size(); pos++) {
    size_t target = redirect_target[links[pos].key_index];
    for (int hop = 0; hop < 10 && target != kNoKey; hop++) {
      auto next = redirect_target.find(target);
      if (next == redirect_target.end()) break;  // lands on a real entry
      target = next->second;
    }
    if (target == kNoKey || redirect_target.count(target)) continue;  // dangling or circular
    links_by_target[target].push_back(pos);
  }

  // Pull each needed record back once and emit its aliases on the spot, so the
  // text lives only for the duration of the callback. Sorted so the targeted
  // reader walks blocks forward and can reuse the one it just inflated.
  std::vector<size_t> targets;
  targets.reserve(links_by_target.size());
  for (const auto& [target, _] : links_by_target) targets.push_back(target);
  std::sort(targets.begin(), targets.end());

  // Aliases carry their target's bytes verbatim: byte-identical definitions are
  // what let the importer collapse them onto one glossary blob by hash
  // (BUG-1665), so this must stay a faithful copy, not a reference.
  std::vector<bool> resolved(links.size(), false);
  extract_records(data, size, idx, targets, [&](size_t ki, const uint8_t* rec, size_t len) {
    auto it = links_by_target.find(ki);
    if (it == links_by_target.end()) return;
    std::string definition = to_text(rec, len);
    for (size_t pos : it->second) {
      sink(std::string(idx.keys[links[pos].key_index].headword), std::string(definition));
      resolved[pos] = true;
    }
  });

  // A redirect whose target is dangling, circular or unreadable keeps its
  // "@@@LINK=" body -- import_mdx drops those, and parse() reports them exactly
  // as the old whole-table resolution left them.
  for (size_t pos = 0; pos < links.size(); pos++) {
    if (resolved[pos]) continue;
    sink(std::string(idx.keys[links[pos].key_index].headword), "@@@LINK=" + links[pos].target);
  }

  return meta;
}

MdxResult mdx_reader::parse(const uint8_t* data, size_t size) {
  MdxResult result;
  MdxMeta meta = parse_streaming(data, size, [&](std::string&& key, std::string&& definition) {
    result.entries.push_back({std::move(key), std::move(definition)});
  });
  result.title = std::move(meta.title);
  result.encoding = std::move(meta.encoding);
  result.version_major = meta.version_major;
  result.version_minor = meta.version_minor;
  return result;
}

std::vector<MddEntry> mdx_reader::parse_mdd(const uint8_t* data, size_t size) {
  ContainerIndex idx = parse_container_index(data, size);

  // Each record slice is a raw binary file (image/audio/css/font); the key is
  // its path. Keep bytes verbatim -- no transcoding, no trailing-NUL stripping
  // (a PNG/JPEG legitimately ends in NUL bytes), no @@@LINK resolution.
  std::vector<MddEntry> out;
  out.reserve(idx.keys.size());
  stream_records(data, size, idx, [&](size_t ki, const uint8_t* rec, size_t len) {
    out.push_back(MddEntry{std::move(idx.keys[ki].headword),
                           std::string(reinterpret_cast<const char*>(rec), len)});
  });
  return out;
}

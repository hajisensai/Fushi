// Shared builder for a minimal, valid, UNENCRYPTED MDX v2 file (UTF-8 records),
// used by tests that need a real .mdx on disk. Encrypted MDX fixtures live in
// mdx_encrypted_keyinfo_test.cpp (they additionally exercise the RIPEMD-128
// decrypt path). Container layout mirrors mdx_reader.cpp's parser.
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include <libdeflate.h>

namespace mdx_fixture {

inline void put_be16(std::vector<uint8_t>& v, uint16_t x) {
  v.push_back(uint8_t(x >> 8));
  v.push_back(uint8_t(x & 0xff));
}
inline void put_be32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 3; i >= 0; i--) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}
inline void put_be64(std::vector<uint8_t>& v, uint64_t x) {
  for (int i = 7; i >= 0; i--) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}
inline void put_le32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 0; i < 4; i++) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}

inline std::vector<uint8_t> zlib_compress(const std::vector<uint8_t>& in) {
  auto* c = libdeflate_alloc_compressor(6);
  size_t bound = libdeflate_zlib_compress_bound(c, in.size());
  std::vector<uint8_t> out(bound);
  size_t n = libdeflate_zlib_compress(c, in.data(), in.size(), out.data(), out.size());
  libdeflate_free_compressor(c);
  out.resize(n);
  return out;
}

// comp_type(le32=2) + 4-byte checksum placeholder + zlib(payload)
inline std::vector<uint8_t> make_zlib_block(const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> z = zlib_compress(payload);
  std::vector<uint8_t> block;
  put_le32(block, 2);            // zlib
  put_le32(block, 0xDEADBEEF);   // checksum (reader ignores)
  block.insert(block.end(), z.begin(), z.end());
  return block;
}

// Build a single-key-block, single-record-block UTF-8 MDX v2 file (Encrypted=0)
// from ordered (headword, definition) pairs. `title` becomes the <Title>.
inline std::vector<uint8_t> build_mdx_plain(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries) {
  // Record stream: definitions concatenated, each NUL-terminated.
  std::vector<uint8_t> records;
  std::vector<uint64_t> offsets;
  for (const auto& [k, d] : entries) {
    (void)k;
    offsets.push_back(records.size());
    records.insert(records.end(), d.begin(), d.end());
    records.push_back(0);
  }

  // Key block: (be64 record_offset + headword + NUL) per entry.
  std::vector<uint8_t> key_entries;
  for (size_t i = 0; i < entries.size(); i++) {
    put_be64(key_entries, offsets[i]);
    key_entries.insert(key_entries.end(), entries[i].first.begin(), entries[i].first.end());
    key_entries.push_back(0);
  }
  std::vector<uint8_t> key_block = make_zlib_block(key_entries);

  // Key block info (one block meta): plaintext then zlib (comp_type=2), no crypto.
  std::vector<uint8_t> kbi_plain;
  put_be64(kbi_plain, entries.size());  // num entries in this key block
  const std::string& first = entries.front().first;
  const std::string& last = entries.back().first;
  put_be16(kbi_plain, uint16_t(first.size()));
  kbi_plain.insert(kbi_plain.end(), first.begin(), first.end());
  kbi_plain.push_back(0);
  put_be16(kbi_plain, uint16_t(last.size()));
  kbi_plain.insert(kbi_plain.end(), last.begin(), last.end());
  kbi_plain.push_back(0);
  put_be64(kbi_plain, key_block.size());    // compressed size of the key block
  put_be64(kbi_plain, key_entries.size());  // decompressed size of the key block
  std::vector<uint8_t> kbi = make_zlib_block(kbi_plain);

  // Record block info + record block.
  std::vector<uint8_t> record_block = make_zlib_block(records);
  std::vector<uint8_t> record_block_info;
  put_be64(record_block_info, record_block.size());
  put_be64(record_block_info, records.size());

  std::vector<uint8_t> file;
  std::string header = "<Dictionary GeneratedByEngineVersion=\"2.0\" Encrypted=\"0\" "
                       "Encoding=\"UTF-8\" Title=\"" + title + "\"/>";
  put_be32(file, uint32_t(header.size()));
  file.insert(file.end(), header.begin(), header.end());
  put_be32(file, 0);  // header adler (ignored)

  put_be64(file, 1);                    // num key blocks
  put_be64(file, entries.size());       // num entries
  put_be64(file, kbi_plain.size());     // key_block_info_decomp_size
  put_be64(file, kbi.size());           // key_block_info_size
  put_be64(file, key_block.size());     // key_blocks_size
  put_be32(file, 0);                    // key block info adler (ignored)
  file.insert(file.end(), kbi.begin(), kbi.end());
  file.insert(file.end(), key_block.begin(), key_block.end());

  put_be64(file, 1);                       // num record blocks
  put_be64(file, entries.size());          // num entries (ignored)
  put_be64(file, record_block_info.size());
  put_be64(file, record_block.size());     // record_blocks_total_size
  file.insert(file.end(), record_block_info.begin(), record_block_info.end());
  file.insert(file.end(), record_block.begin(), record_block.end());
  return file;
}

}  // namespace mdx_fixture

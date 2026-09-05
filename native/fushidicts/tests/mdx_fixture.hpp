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

// Build a single-key-block, single-record-block UTF-8 MDX-family v2 container
// (Encrypted=0) from ordered (key, record) pairs. When `null_terminate` is true
// (MDX text records) each record is NUL-terminated; when false (MDD binary
// files) records are concatenated byte-exact. `title` becomes the <Title>.
// How the container describes itself, and how its keys are encoded. Real .mdd
// files written by MDTT and friends use the `<Library_Data …>` root with an
// EMPTY Encoding attribute and UTF-16LE keys; .mdx uses `<Dictionary …>` and
// honours Encoding. build_mdx_plain/build_mdd_plain keep the original
// UTF-8/`<Dictionary>` shape; build_mdd_utf16 produces the real .mdd shape.
struct ContainerShape {
  const char* root_element = "Dictionary";
  const char* encoding_attr = "UTF-8";
  bool utf16_keys = false;
};

// ASCII-only headwords widen to UTF-16LE by interleaving zero bytes, which is
// all the fixtures need (paths like "\\scripts\\x.js").
inline void append_key_bytes(std::vector<uint8_t>& out, const std::string& key, bool utf16) {
  for (char c : key) {
    out.push_back(static_cast<uint8_t>(c));
    if (utf16) out.push_back(0);
  }
}

inline void append_key_terminator(std::vector<uint8_t>& out, bool utf16) {
  out.push_back(0);
  if (utf16) out.push_back(0);
}

inline std::vector<uint8_t> build_container_shaped(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    bool null_terminate, const ContainerShape& shape) {
  std::vector<uint8_t> records;
  std::vector<uint64_t> offsets;
  for (const auto& [k, d] : entries) {
    (void)k;
    offsets.push_back(records.size());
    records.insert(records.end(), d.begin(), d.end());
    if (null_terminate) records.push_back(0);
  }

  std::vector<uint8_t> key_entries;
  for (size_t i = 0; i < entries.size(); i++) {
    put_be64(key_entries, offsets[i]);
    append_key_bytes(key_entries, entries[i].first, shape.utf16_keys);
    append_key_terminator(key_entries, shape.utf16_keys);
  }
  std::vector<uint8_t> key_block = make_zlib_block(key_entries);

  // first/last headword lengths are CHARACTER counts (the reader multiplies by
  // 2 for UTF-16), and the inline copies use the same width as the keys.
  std::vector<uint8_t> kbi_plain;
  put_be64(kbi_plain, entries.size());
  const std::string& first = entries.front().first;
  const std::string& last = entries.back().first;
  put_be16(kbi_plain, uint16_t(first.size()));
  append_key_bytes(kbi_plain, first, shape.utf16_keys);
  append_key_terminator(kbi_plain, shape.utf16_keys);
  put_be16(kbi_plain, uint16_t(last.size()));
  append_key_bytes(kbi_plain, last, shape.utf16_keys);
  append_key_terminator(kbi_plain, shape.utf16_keys);
  put_be64(kbi_plain, key_block.size());
  put_be64(kbi_plain, key_entries.size());
  std::vector<uint8_t> kbi = make_zlib_block(kbi_plain);

  std::vector<uint8_t> record_block = make_zlib_block(records);
  std::vector<uint8_t> record_block_info;
  put_be64(record_block_info, record_block.size());
  put_be64(record_block_info, records.size());

  std::vector<uint8_t> file;
  std::string header = std::string("<") + shape.root_element +
                       " GeneratedByEngineVersion=\"2.0\" Encrypted=\"0\" Encoding=\"" +
                       shape.encoding_attr + "\" Title=\"" + title + "\"/>";
  put_be32(file, uint32_t(header.size()));
  file.insert(file.end(), header.begin(), header.end());
  put_be32(file, 0);

  put_be64(file, 1);
  put_be64(file, entries.size());
  put_be64(file, kbi_plain.size());
  put_be64(file, kbi.size());
  put_be64(file, key_block.size());
  put_be32(file, 0);
  file.insert(file.end(), kbi.begin(), kbi.end());
  file.insert(file.end(), key_block.begin(), key_block.end());

  put_be64(file, 1);
  put_be64(file, entries.size());
  put_be64(file, record_block_info.size());
  put_be64(file, record_block.size());
  file.insert(file.end(), record_block_info.begin(), record_block_info.end());
  file.insert(file.end(), record_block.begin(), record_block.end());
  return file;
}

inline std::vector<uint8_t> build_container(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    bool null_terminate) {
  // Record stream: records concatenated (MDX: each NUL-terminated).
  std::vector<uint8_t> records;
  std::vector<uint64_t> offsets;
  for (const auto& [k, d] : entries) {
    (void)k;
    offsets.push_back(records.size());
    records.insert(records.end(), d.begin(), d.end());
    if (null_terminate) records.push_back(0);
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

// MDX whose record stream is split across several zlib blocks, with the split
// points given as byte offsets into the concatenated DECOMPRESSED stream. A
// split may fall in the middle of a record.
//
// Key offsets index that concatenated stream and are unaffected by where the
// splits land -- which is precisely the invariant the streaming reader leans on
// when it inflates one block at a time. Every other fixture here emits a single
// record block, so nothing else in the suite can exercise a record that
// straddles a block boundary, a window that must carry bytes forward, or a
// redirect whose target lives in a different block than the redirect itself.
struct RecordSplitOptions {
  // MDX text records are NUL-terminated; .mdd binary records are not.
  bool null_terminate = true;
  // Byte offsets into the concatenated decompressed stream where a new block starts.
  std::vector<size_t> split_offsets;
  // When non-empty, these values are written into the key table instead of the
  // real record positions -- for exercising a corrupt/hostile key table, whose
  // record_offset values are read straight out of the file with no validation.
  std::vector<uint64_t> record_offset_override;
};

inline std::vector<uint8_t> build_container_record_splits(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    const RecordSplitOptions& opts) {
  std::vector<uint8_t> records;
  std::vector<uint64_t> offsets;
  for (const auto& [k, d] : entries) {
    (void)k;
    offsets.push_back(records.size());
    records.insert(records.end(), d.begin(), d.end());
    if (opts.null_terminate) records.push_back(0);
  }
  if (!opts.record_offset_override.empty()) {
    offsets = opts.record_offset_override;
    offsets.resize(entries.size(), 0);
  }
  const std::vector<size_t>& split_offsets = opts.split_offsets;

  std::vector<uint8_t> key_entries;
  for (size_t i = 0; i < entries.size(); i++) {
    put_be64(key_entries, offsets[i]);
    key_entries.insert(key_entries.end(), entries[i].first.begin(), entries[i].first.end());
    key_entries.push_back(0);
  }
  std::vector<uint8_t> key_block = make_zlib_block(key_entries);

  std::vector<uint8_t> kbi_plain;
  put_be64(kbi_plain, entries.size());
  const std::string& first = entries.front().first;
  const std::string& last = entries.back().first;
  put_be16(kbi_plain, uint16_t(first.size()));
  kbi_plain.insert(kbi_plain.end(), first.begin(), first.end());
  kbi_plain.push_back(0);
  put_be16(kbi_plain, uint16_t(last.size()));
  kbi_plain.insert(kbi_plain.end(), last.begin(), last.end());
  kbi_plain.push_back(0);
  put_be64(kbi_plain, key_block.size());
  put_be64(kbi_plain, key_entries.size());
  std::vector<uint8_t> kbi = make_zlib_block(kbi_plain);

  // Cut the record stream at the requested offsets and zlib each piece.
  std::vector<size_t> bounds{0};
  for (size_t off : split_offsets) {
    if (off > 0 && off < records.size() && off > bounds.back()) bounds.push_back(off);
  }
  bounds.push_back(records.size());

  std::vector<std::vector<uint8_t>> record_blocks;
  std::vector<uint64_t> decompressed_sizes;
  for (size_t i = 0; i + 1 < bounds.size(); i++) {
    std::vector<uint8_t> chunk(records.begin() + static_cast<std::ptrdiff_t>(bounds[i]),
                               records.begin() + static_cast<std::ptrdiff_t>(bounds[i + 1]));
    decompressed_sizes.push_back(chunk.size());
    record_blocks.push_back(make_zlib_block(chunk));
  }

  std::vector<uint8_t> record_block_info;
  uint64_t record_blocks_total = 0;
  for (size_t i = 0; i < record_blocks.size(); i++) {
    put_be64(record_block_info, record_blocks[i].size());
    put_be64(record_block_info, decompressed_sizes[i]);
    record_blocks_total += record_blocks[i].size();
  }

  std::vector<uint8_t> file;
  std::string header = "<Dictionary GeneratedByEngineVersion=\"2.0\" Encrypted=\"0\" "
                       "Encoding=\"UTF-8\" Title=\"" + title + "\"/>";
  put_be32(file, uint32_t(header.size()));
  file.insert(file.end(), header.begin(), header.end());
  put_be32(file, 0);

  put_be64(file, 1);
  put_be64(file, entries.size());
  put_be64(file, kbi_plain.size());
  put_be64(file, kbi.size());
  put_be64(file, key_block.size());
  put_be32(file, 0);
  file.insert(file.end(), kbi.begin(), kbi.end());
  file.insert(file.end(), key_block.begin(), key_block.end());

  put_be64(file, record_blocks.size());
  put_be64(file, entries.size());
  put_be64(file, record_block_info.size());
  put_be64(file, record_blocks_total);
  file.insert(file.end(), record_block_info.begin(), record_block_info.end());
  for (const auto& block : record_blocks) {
    file.insert(file.end(), block.begin(), block.end());
  }
  return file;
}

inline std::vector<uint8_t> build_mdx_record_splits(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    const std::vector<size_t>& split_offsets) {
  RecordSplitOptions opts;
  opts.split_offsets = split_offsets;
  return build_container_record_splits(title, entries, opts);
}

// .mdd shape (binary records, no NUL terminator) split across several blocks.
inline std::vector<uint8_t> build_mdd_record_splits(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    const std::vector<size_t>& split_offsets) {
  RecordSplitOptions opts;
  opts.null_terminate = false;
  opts.split_offsets = split_offsets;
  return build_container_record_splits(title, entries, opts);
}

// Key table carrying caller-chosen record_offset values -- a corrupt container.
inline std::vector<uint8_t> build_mdx_bad_offsets(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries,
    const std::vector<uint64_t>& record_offsets, const std::vector<size_t>& split_offsets) {
  RecordSplitOptions opts;
  opts.split_offsets = split_offsets;
  opts.record_offset_override = record_offsets;
  return build_container_record_splits(title, entries, opts);
}

// MDX: text (HTML) records, NUL-terminated.
inline std::vector<uint8_t> build_mdx_plain(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries) {
  return build_container(title, entries, /*null_terminate=*/true);
}

// MDD: binary file records keyed by path, byte-exact (no terminator).
inline std::vector<uint8_t> build_mdd_plain(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries) {
  return build_container(title, entries, /*null_terminate=*/false);
}

// MDD as real writers emit it: `<Library_Data …>` root, EMPTY Encoding
// attribute, UTF-16LE keys. Defaulting that empty attribute to UTF-8 walks the
// key scan through the wrong byte width and the parse dies with
// "record block info overflow", dropping the whole media companion.
inline std::vector<uint8_t> build_mdd_utf16_library_data(
    const std::string& title, const std::vector<std::pair<std::string, std::string>>& entries) {
  ContainerShape shape;
  shape.root_element = "Library_Data";
  shape.encoding_attr = "";
  shape.utf16_keys = true;
  return build_container_shaped(title, entries, /*null_terminate=*/false, shape);
}

}  // namespace mdx_fixture

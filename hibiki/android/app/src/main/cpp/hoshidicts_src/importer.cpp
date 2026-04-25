#include "hoshidicts/importer.hpp"

#include <ankerl/unordered_dense.h>
#include <xxh3.h>
#include <zstd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <future>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "hash/hash.hpp"
#include "json/yomitan_parser.hpp"
#include "mdx/mdx_reader.hpp"
#include "memory/memory.hpp"
#include "zip/zip.hpp"

namespace {
struct Files {
  std::vector<int> term_banks;
  std::vector<int> meta_banks;
  std::vector<int> tag_banks;
  std::vector<int> media_files;
};

struct ProcessedFile {
  std::vector<char> data;
  std::vector<std::pair<uint64_t, uint64_t>> offsets;
  ankerl::unordered_dense::map<uint64_t, std::vector<char>> glossaries;
  std::vector<std::pair<uint64_t, uint64_t>> glossary_offsets;
  size_t count = 0;
};

void setup_stream_exceptions(std::ofstream& stream) { stream.exceptions(std::ios::failbit | std::ios::badbit); }

std::string_view basename(std::string_view path) {
  auto pos1 = path.rfind('/');
  auto pos2 = path.rfind('\\');
  auto pos = std::string_view::npos;
  if (pos1 != std::string_view::npos && pos2 != std::string_view::npos)
    pos = std::max(pos1, pos2);
  else if (pos1 != std::string_view::npos)
    pos = pos1;
  else
    pos = pos2;
  return pos == std::string_view::npos ? path : path.substr(pos + 1);
}

Files get_files(const Zip& zip) {
  Files files;
  for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/' || name.back() == '\\') {
      continue;
    }

    auto base = basename(name);
    if (base.starts_with("term_bank_")) {
      files.term_banks.push_back(i);
    } else if (base.starts_with("term_meta_bank_")) {
      files.meta_banks.push_back(i);
    } else if (base.starts_with("tag_bank_")) {
      files.tag_banks.push_back(i);
    } else if (!(base == "styles.css" || base == "index.json")) {
      files.media_files.push_back(i);
    }
  }
  return files;
}

template <typename T>
void write_val(std::vector<char>& out, T value) {
  const size_t old_size = out.size();
  out.resize(old_size + sizeof(T));
  std::memcpy(out.data() + old_size, &value, sizeof(T));
}

void write_str(std::vector<char>& out, std::string_view value) {
  if (value.empty()) {
    return;
  }
  const size_t old_size = out.size();
  out.resize(old_size + value.size());
  std::memcpy(out.data() + old_size, value.data(), value.size());
}

void write_bytes(std::vector<char>& out, const void* data, size_t n) {
  const size_t old_size = out.size();
  out.resize(old_size + n);
  std::memcpy(out.data() + old_size, data, n);
}

void radix_sort(std::vector<std::pair<uint64_t, uint64_t>>& offsets) {
  if (offsets.size() < 2) {
    return;
  }

  const size_t n = offsets.size();
  const size_t num_threads = std::max<size_t>(1, std::thread::hardware_concurrency());
  std::vector<std::pair<uint64_t, uint64_t>> temp(n);
  auto* src = &offsets;
  auto* dst = &temp;

  std::vector<std::array<size_t, 65536>> local_counts(num_threads);

  for (uint32_t shift = 0; shift < 64; shift += 16) {
    const size_t chunk = (n + num_threads - 1) / num_threads;
    std::vector<std::future<void>> futures;
    for (size_t t = 0; t < num_threads; t++) {
      const size_t begin = t * chunk;
      const size_t end = std::min(begin + chunk, n);
      if (begin >= n) {
        break;
      }

      local_counts[t].fill(0);
      futures.push_back(std::async(std::launch::async, [src, shift, begin, end, &local_counts, t]() {
        for (size_t i = begin; i < end; i++) {
          local_counts[t][((*src)[i].first >> shift) & 0xffff]++;
        }
      }));
    }
    for (auto& future : futures) {
      future.get();
    }

    std::array<size_t, 65536> global_count{};
    for (size_t t = 0; t < futures.size(); t++) {
      for (size_t bucket = 0; bucket < 65536; bucket++) {
        global_count[bucket] += local_counts[t][bucket];
      }
    }

    std::array<size_t, 65536> global_pos{};
    size_t total = 0;
    for (size_t bucket = 0; bucket < 65536; bucket++) {
      global_pos[bucket] = total;
      total += global_count[bucket];
    }

    std::vector<std::array<size_t, 65536>> thread_pos(futures.size());
    for (size_t bucket = 0; bucket < 65536; bucket++) {
      size_t pos = global_pos[bucket];
      for (size_t t = 0; t < futures.size(); t++) {
        thread_pos[t][bucket] = pos;
        pos += local_counts[t][bucket];
      }
    }

    std::vector<std::future<void>> scatter_futures;
    for (size_t t = 0; t < futures.size(); t++) {
      const size_t begin = t * chunk;
      const size_t end = std::min(begin + chunk, n);
      scatter_futures.push_back(std::async(std::launch::async, [src, dst, shift, begin, end, &thread_pos, t]() {
        for (size_t i = begin; i < end; i++) {
          const size_t bucket = ((*src)[i].first >> shift) & 0xffff;
          (*dst)[thread_pos[t][bucket]++] = (*src)[i];
        }
      }));
    }
    for (auto& future : scatter_futures) {
      future.get();
    }

    std::swap(src, dst);
  }
}

ProcessedFile process_term_bank(const std::string& content) {
  ProcessedFile processed;
  if (content.empty()) {
    return processed;
  }

  std::vector<Term> out;
  if (!yomitan_parser::parse_term_bank(content, out)) {
    return processed;
  }

  std::vector<char> compressed;
  ZSTD_CCtx* cctx = ZSTD_createCCtx();
  if (!cctx) {
    return processed;
  }

  for (auto& term : out) {
    const std::string_view glossary = term.glossary.str;
    uint64_t glossary_hash = XXH3_64bits(glossary.data(), glossary.size());
    auto it = processed.glossaries.find(glossary_hash);
    if (it == processed.glossaries.end()) {
      const size_t bound = ZSTD_compressBound(glossary.size());
      compressed.resize(bound);
      const size_t compressed_size =
          ZSTD_compressCCtx(cctx, compressed.data(), bound, glossary.data(), glossary.size(), 0);
      if (ZSTD_isError(compressed_size)) {
        ZSTD_freeCCtx(cctx);
        throw std::runtime_error("failed to compress glossary");
      }
      compressed.resize(compressed_size);
      processed.glossaries.emplace(glossary_hash, compressed);
    }

    uint64_t offset = processed.data.size();
    uint32_t blob_size = processed.glossaries[glossary_hash].size();
    std::string_view expr = term.expression;
    std::string_view reading = term.reading.empty() ? expr : term.reading;
    std::string_view definition_tags = term.definition_tags.value_or("");

    write_val<uint8_t>(processed.data, 0);
    write_val<uint16_t>(processed.data, expr.size());
    write_str(processed.data, expr);
    write_val<uint16_t>(processed.data, reading.size());
    write_str(processed.data, reading);

    uint64_t glossary_offset = processed.data.size();
    write_val<uint64_t>(processed.data, 0);
    write_val<uint32_t>(processed.data, blob_size);
    processed.glossary_offsets.emplace_back(glossary_hash, glossary_offset);

    write_val<uint8_t>(processed.data, definition_tags.size());
    write_str(processed.data, definition_tags);
    write_val<uint8_t>(processed.data, term.rules.size());
    write_str(processed.data, term.rules);
    write_val<uint8_t>(processed.data, term.term_tags.size());
    write_str(processed.data, term.term_tags);

    processed.offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
    if (reading != expr) {
      processed.offsets.emplace_back(XXH3_64bits(reading.data(), reading.size()), offset);
    }
    processed.count++;
  }
  ZSTD_freeCCtx(cctx);

  return processed;
}

ProcessedFile process_meta_bank(const std::string& content) {
  ProcessedFile processed;
  if (content.empty()) {
    return processed;
  }

  std::vector<Meta> out;
  if (!yomitan_parser::parse_meta_bank(content, out)) {
    return processed;
  }

  for (auto& meta : out) {
    uint64_t offset = processed.data.size();
    std::string_view expr = meta.expression;
    std::string_view mode = meta.mode;
    std::string_view data = meta.data.str;

    write_val<uint8_t>(processed.data, 1);
    write_val<uint16_t>(processed.data, expr.size());
    write_str(processed.data, expr);
    write_val<uint8_t>(processed.data, mode.size());
    write_str(processed.data, mode);
    write_val<uint32_t>(processed.data, data.size());
    write_str(processed.data, data);

    processed.offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
    processed.count++;
  }

  return processed;
}

void write_terms(std::ofstream& file, std::vector<std::pair<uint64_t, uint64_t>>& offsets, const Zip& zip,
                 const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram) {
  if (files.empty()) {
    return;
  }

  size_t max_threads =
      low_ram ? 2 : std::max<size_t>(4, static_cast<const unsigned long>(std::thread::hardware_concurrency()) + 4);
  std::deque<std::future<ProcessedFile>> threads;

  ankerl::unordered_dense::map<uint64_t, uint64_t> glossaries;
  auto write_processed = [&](ProcessedFile&& processed) {
    if (processed.data.empty()) {
      return;
    }

    std::vector<char> glossary_buf;
    for (auto& [hash, compressed] : processed.glossaries) {
      auto [it, inserted] = glossaries.try_emplace(hash, write_offset);
      if (inserted) {
        write_bytes(glossary_buf, compressed.data(), compressed.size());
        write_offset += compressed.size();
      }
    }
    if (!glossary_buf.empty()) {
      file.write(glossary_buf.data(), static_cast<std::streamsize>(glossary_buf.size()));
    }

    for (auto& [hash, pos] : processed.glossary_offsets) {
      uint64_t glossary_offset = glossaries[hash];
      std::memcpy(processed.data.data() + pos, &glossary_offset, sizeof(uint64_t));
    }

    file.write(processed.data.data(), static_cast<std::streamsize>(processed.data.size()));

    for (auto& [hash, offset] : processed.offsets) {
      offsets.emplace_back(hash, offset + write_offset);
    }

    write_offset += processed.data.size();
    result.term_count += processed.count;
  };

  for (int file_index : files) {
    threads.push_back(
        std::async(std::launch::async, [&zip, file_index]() { return process_term_bank(zip.read(file_index)); }));

    if (threads.size() == max_threads) {
      write_processed(threads.front().get());
      threads.pop_front();
    }
  }

  while (!threads.empty()) {
    write_processed(threads.front().get());
    threads.pop_front();
  }
}

void write_meta(std::ofstream& file, std::vector<std::pair<uint64_t, uint64_t>>& offsets, const Zip& zip,
                const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram) {
  if (files.empty()) {
    return;
  }

  size_t max_threads =
      low_ram ? 2 : std::max<size_t>(4, static_cast<const unsigned long>(std::thread::hardware_concurrency()) + 4);
  std::deque<std::future<ProcessedFile>> threads;
  auto write_processed = [&](ProcessedFile&& processed) {
    if (processed.data.empty()) {
      return;
    }
    file.write(processed.data.data(), static_cast<std::streamsize>(processed.data.size()));

    for (auto& [hash, offset] : processed.offsets) {
      offsets.emplace_back(hash, offset + write_offset);
    }

    write_offset += processed.data.size();
    result.meta_count += processed.count;
  };

  for (int file_index : files) {
    threads.push_back(
        std::async(std::launch::async, [&zip, file_index]() { return process_meta_bank(zip.read(file_index)); }));

    if (threads.size() == max_threads) {
      write_processed(threads.front().get());
      threads.pop_front();
    }
  }

  while (!threads.empty()) {
    write_processed(threads.front().get());
    threads.pop_front();
  }
}

std::vector<char> build_offset_index(std::vector<std::pair<uint64_t, uint64_t>>& offsets, uint64_t& write_offset,
                                     std::vector<std::pair<uint64_t, uint64_t>>& hash_entries) {
  std::vector<char> offset_buf;
  radix_sort(offsets);
  for (size_t i = 0; i < offsets.size();) {
    size_t j = i + 1;
    while (j < offsets.size() && offsets[j].first == offsets[i].first) {
      j++;
    }

    hash_entries.emplace_back(offsets[i].first, write_offset);

    auto count = static_cast<uint32_t>(j - i);
    write_val<uint32_t>(offset_buf, count);
    for (size_t k = i; k < j; ++k) {
      write_val<uint64_t>(offset_buf, offsets[k].second);
    }

    write_offset += sizeof(uint32_t) + count * sizeof(uint64_t);
    i = j;
  }
  return offset_buf;
}

size_t write_media(const std::string& path, const Zip& zip, const std::vector<int>& files, std::string_view zip_prefix = {}) {
  if (files.empty()) {
    return 0;
  }

  std::ofstream media(path + "/media.bin", std::ios::binary);
  std::ofstream media_idx(path + "/media.idx", std::ios::binary);
  setup_stream_exceptions(media);
  setup_stream_exceptions(media_idx);

  size_t media_count = 0;
  uint32_t write_pos = 0;
  std::vector<char> buf;
  std::vector<std::pair<std::string, uint32_t>> index_entries;
  for (int file_index : files) {
    auto media_file = zip.read_media(file_index);
    if (!media_file.has_value()) {
      continue;
    }

    auto& mp = media_file->path;
    if (!zip_prefix.empty() && mp.size() > zip_prefix.size() &&
        std::string_view(mp).substr(0, zip_prefix.size()) == zip_prefix) {
      mp.erase(0, zip_prefix.size());
    }

    uint32_t record_start = write_pos;
    buf.clear();
    write_val<uint16_t>(buf, media_file->path.size());
    write_str(buf, media_file->path);
    write_val<uint32_t>(buf, media_file->blob.size());
    write_bytes(buf, media_file->blob.data(), media_file->blob.size());
    media.write(buf.data(), static_cast<std::streamsize>(buf.size()));
    write_pos += buf.size();

    index_entries.emplace_back(std::move(media_file->path), record_start);
    media_count++;
  }

  std::ranges::sort(index_entries);
  std::vector<char> index_buf;
  write_val<uint32_t>(index_buf, index_entries.size());
  for (const auto& [name, offset] : index_entries) {
    write_val<uint64_t>(index_buf, offset);
  }

  media_idx.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
  return media_count;
}

int find_mdx_in_zip(const Zip& zip) {
  for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
    const auto& name = zip.entries[i].name;
    if (name.size() >= 4) {
      auto ext = name.substr(name.size() - 4);
      if (ext == ".mdx" || ext == ".MDX") return i;
    }
  }
  return -1;
}

void extract_css_from_zip(const Zip& zip, const std::string& output_path) {
  std::string combined_css;
  for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
    auto base = basename(zip.entries[i].name);
    if (base.size() >= 4 && base.substr(base.size() - 4) == ".css") {
      auto css = zip.read(i);
      if (!css.empty()) {
        combined_css += "/* " + std::string(base) + " */\n";
        combined_css += css;
        combined_css += "\n";
      }
    }
  }
  if (!combined_css.empty()) {
    std::ofstream f(output_path, std::ios::binary);
    setup_stream_exceptions(f);
    f.write(combined_css.data(), static_cast<std::streamsize>(combined_css.size()));
  }
}

ImportResult import_mdx(const Zip& zip, int mdx_idx, const std::string& output_dir, bool low_ram) {
  ImportResult result;

  std::string mdx_data = zip.read(mdx_idx);
  if (mdx_data.empty()) throw std::runtime_error("failed to read .mdx from zip");

  auto mdx = mdx_reader::parse(reinterpret_cast<const uint8_t*>(mdx_data.data()), mdx_data.size());
  if (mdx.entries.empty()) throw std::runtime_error("mdx: no entries found");

  result.title = mdx.title;
  if (result.title.empty()) {
    auto base = basename(zip.entries[mdx_idx].name);
    if (base.size() > 4) result.title = std::string(base.substr(0, base.size() - 4));
    else result.title = "MDict Dictionary";
  }

  std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;
  std::string path = dict_path.string();
  std::filesystem::create_directories(dict_path);

  // Write synthetic index.json
  Index index;
  index.title = result.title;
  index.format = 3;
  if (glz::write_file_json(index, path + "/index.json", std::string{})) {
    throw std::runtime_error("failed to write index.json");
  }

  // Extract CSS
  extract_css_from_zip(zip, path + "/styles.css");

  // Build blobs.bin from MDict entries
  std::ofstream blobs(path + "/blobs.bin", std::ios::binary);
  setup_stream_exceptions(blobs);
  std::vector<std::pair<uint64_t, uint64_t>> offsets;
  uint64_t write_offset = 0;

  ZSTD_CCtx* cctx = ZSTD_createCCtx();
  if (!cctx) throw std::runtime_error("failed to create zstd context");

  ankerl::unordered_dense::map<uint64_t, uint64_t> glossary_positions;
  ankerl::unordered_dense::map<uint64_t, std::vector<char>> glossary_blobs;
  std::vector<char> compressed;

  size_t batch_size = low_ram ? 5000 : 20000;
  std::vector<char> data_buf;
  std::vector<std::pair<uint64_t, uint64_t>> glossary_fixups;

  auto flush_batch = [&]() {
    if (data_buf.empty()) return;

    // Write pending glossaries
    std::vector<char> glossary_buf;
    for (auto& [hash, blob] : glossary_blobs) {
      auto [it, inserted] = glossary_positions.try_emplace(hash, write_offset);
      if (inserted) {
        glossary_buf.insert(glossary_buf.end(), blob.begin(), blob.end());
        write_offset += blob.size();
      }
    }
    if (!glossary_buf.empty()) {
      blobs.write(glossary_buf.data(), static_cast<std::streamsize>(glossary_buf.size()));
    }
    glossary_blobs.clear();

    // Fix up glossary offsets in data
    for (auto& [hash, pos] : glossary_fixups) {
      uint64_t real_offset = glossary_positions[hash];
      std::memcpy(data_buf.data() + pos, &real_offset, sizeof(uint64_t));
    }
    glossary_fixups.clear();

    blobs.write(data_buf.data(), static_cast<std::streamsize>(data_buf.size()));

    write_offset += data_buf.size();
    data_buf.clear();
  };

  for (size_t i = 0; i < mdx.entries.size(); i++) {
    auto& entry = mdx.entries[i];
    if (entry.key.empty() || entry.definition.empty()) continue;
    if (entry.definition.starts_with("@@@LINK=")) continue;

    // Compress glossary (the HTML definition)
    std::string_view def_view = entry.definition;
    uint64_t glossary_hash = XXH3_64bits(def_view.data(), def_view.size());

    if (glossary_blobs.find(glossary_hash) == glossary_blobs.end() &&
        glossary_positions.find(glossary_hash) == glossary_positions.end()) {
      size_t bound = ZSTD_compressBound(def_view.size());
      compressed.resize(bound);
      size_t compressed_size = ZSTD_compressCCtx(cctx, compressed.data(), bound, def_view.data(), def_view.size(), 0);
      if (ZSTD_isError(compressed_size)) continue;
      compressed.resize(compressed_size);
      glossary_blobs.emplace(glossary_hash, compressed);
    }

    uint32_t blob_size = 0;
    if (auto it = glossary_blobs.find(glossary_hash); it != glossary_blobs.end()) {
      blob_size = it->second.size();
    } else if (auto it2 = glossary_positions.find(glossary_hash); it2 != glossary_positions.end()) {
      // Already written, need to find compressed size — store in data with size 0 placeholder
      // Actually we need the size. Let's re-compress briefly or just store the size.
      // For simplicity, just re-compress.
      size_t bound = ZSTD_compressBound(def_view.size());
      compressed.resize(bound);
      size_t cs = ZSTD_compressCCtx(cctx, compressed.data(), bound, def_view.data(), def_view.size(), 0);
      blob_size = ZSTD_isError(cs) ? 0 : static_cast<uint32_t>(cs);
    }

    std::string_view expr = entry.key;
    std::string_view reading;  // MDict doesn't have separate reading

    uint64_t offset = data_buf.size();
    write_val<uint8_t>(data_buf, 0);  // type: term
    write_val<uint16_t>(data_buf, expr.size());
    write_str(data_buf, expr);
    write_val<uint16_t>(data_buf, 0);  // no reading

    uint64_t glossary_offset_pos = data_buf.size();
    write_val<uint64_t>(data_buf, 0);  // placeholder, will be fixed up
    write_val<uint32_t>(data_buf, blob_size);
    glossary_fixups.emplace_back(glossary_hash, glossary_offset_pos);

    write_val<uint8_t>(data_buf, 0);  // no definition_tags
    write_val<uint8_t>(data_buf, 0);  // no rules
    write_val<uint8_t>(data_buf, 0);  // no term_tags

    offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
    result.term_count++;

    if (result.term_count % batch_size == 0) {
      // Adjust offsets to account for write_offset
      for (size_t j = offsets.size() - batch_size; j < offsets.size(); j++) {
        offsets[j].second += write_offset;
      }
      flush_batch();
    }
  }

  // Flush remaining
  size_t remaining = result.term_count % batch_size;
  if (remaining == 0 && result.term_count > 0) remaining = batch_size;
  for (size_t j = offsets.size() - remaining; j < offsets.size(); j++) {
    offsets[j].second += write_offset;
  }
  flush_batch();

  ZSTD_freeCCtx(cctx);

  if (offsets.empty()) throw std::runtime_error("empty dictionary");

  std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
  auto offset_buf = build_offset_index(offsets, write_offset, hash_entries);
  std::vector<std::pair<uint64_t, uint64_t>>().swap(offsets);

  auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
    hash::linear table;
    table.build_to_file(hash_entries, path + "/hash.table");
  });

  blobs.write(offset_buf.data(), static_cast<std::streamsize>(offset_buf.size()));
  hash_thread.get();

  std::ofstream sui(path + "/.hoshidicts_1", std::ios::binary);
  result.success = true;
  return result;
}
}

ImportResult import_standalone_mdx(const std::string& mdx_path, const std::string& output_dir, bool low_ram) {
  ImportResult result;

  auto file = memory::map_rd(mdx_path);
  if (!file) throw std::runtime_error("failed to open .mdx file");

  try {
    auto mdx = mdx_reader::parse(file.data, file.size);
    memory::unmap(file);
    file = {};

    if (mdx.entries.empty()) throw std::runtime_error("mdx: no entries found");

    result.title = mdx.title;
    if (result.title.empty()) {
      auto base = basename(mdx_path);
      if (base.size() > 4)
        result.title = std::string(base.substr(0, base.size() - 4));
      else
        result.title = "MDict Dictionary";
    }

    std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;
    std::string path = dict_path.string();
    std::filesystem::create_directories(dict_path);

    Index index;
    index.title = result.title;
    index.format = 3;
    if (glz::write_file_json(index, path + "/index.json", std::string{})) {
      throw std::runtime_error("failed to write index.json");
    }

    // Reuse the same blobs-writing logic via a temporary Zip-less helper
    // For standalone .mdx, we construct a minimal MdxResult and pass to the
    // same writing code. We'll inline the blob writing here.
    std::ofstream blobs(path + "/blobs.bin", std::ios::binary);
    setup_stream_exceptions(blobs);
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    uint64_t write_offset = 0;

    ZSTD_CCtx* cctx = ZSTD_createCCtx();
    if (!cctx) throw std::runtime_error("failed to create zstd context");

    ankerl::unordered_dense::map<uint64_t, uint64_t> glossary_positions;
    ankerl::unordered_dense::map<uint64_t, std::vector<char>> glossary_blobs;
    std::vector<char> compressed;
    size_t batch_size = low_ram ? 5000 : 20000;
    std::vector<char> data_buf;
    std::vector<std::pair<uint64_t, uint64_t>> glossary_fixups;

    auto flush_batch = [&]() {
      if (data_buf.empty()) return;
      std::vector<char> glossary_buf;
      for (auto& [hash, blob] : glossary_blobs) {
        auto [it, inserted] = glossary_positions.try_emplace(hash, write_offset);
        if (inserted) {
          glossary_buf.insert(glossary_buf.end(), blob.begin(), blob.end());
          write_offset += blob.size();
        }
      }
      if (!glossary_buf.empty())
        blobs.write(glossary_buf.data(), static_cast<std::streamsize>(glossary_buf.size()));
      glossary_blobs.clear();
      for (auto& [hash, pos] : glossary_fixups) {
        uint64_t real_offset = glossary_positions[hash];
        std::memcpy(data_buf.data() + pos, &real_offset, sizeof(uint64_t));
      }
      glossary_fixups.clear();
      blobs.write(data_buf.data(), static_cast<std::streamsize>(data_buf.size()));
      write_offset += data_buf.size();
      data_buf.clear();
    };

    for (auto& entry : mdx.entries) {
      if (entry.key.empty() || entry.definition.empty()) continue;
      if (entry.definition.starts_with("@@@LINK=")) continue;

      std::string_view def_view = entry.definition;
      uint64_t glossary_hash = XXH3_64bits(def_view.data(), def_view.size());
      if (glossary_blobs.find(glossary_hash) == glossary_blobs.end() &&
          glossary_positions.find(glossary_hash) == glossary_positions.end()) {
        size_t bound = ZSTD_compressBound(def_view.size());
        compressed.resize(bound);
        size_t cs = ZSTD_compressCCtx(cctx, compressed.data(), bound, def_view.data(), def_view.size(), 0);
        if (ZSTD_isError(cs)) continue;
        compressed.resize(cs);
        glossary_blobs.emplace(glossary_hash, compressed);
      }

      uint32_t blob_size = 0;
      if (auto it = glossary_blobs.find(glossary_hash); it != glossary_blobs.end())
        blob_size = it->second.size();

      std::string_view expr = entry.key;
      uint64_t offset = data_buf.size();
      write_val<uint8_t>(data_buf, 0);
      write_val<uint16_t>(data_buf, expr.size());
      write_str(data_buf, expr);
      write_val<uint16_t>(data_buf, 0);
      uint64_t glossary_offset_pos = data_buf.size();
      write_val<uint64_t>(data_buf, 0);
      write_val<uint32_t>(data_buf, blob_size);
      glossary_fixups.emplace_back(glossary_hash, glossary_offset_pos);
      write_val<uint8_t>(data_buf, 0);
      write_val<uint8_t>(data_buf, 0);
      write_val<uint8_t>(data_buf, 0);
      offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
      result.term_count++;

      if (result.term_count % batch_size == 0) {
        for (size_t j = offsets.size() - batch_size; j < offsets.size(); j++)
          offsets[j].second += write_offset;
        flush_batch();
      }
    }

    size_t remaining = result.term_count % batch_size;
    if (remaining == 0 && result.term_count > 0) remaining = batch_size;
    for (size_t j = offsets.size() - remaining; j < offsets.size(); j++)
      offsets[j].second += write_offset;
    flush_batch();
    ZSTD_freeCCtx(cctx);

    if (offsets.empty()) throw std::runtime_error("empty dictionary");

    std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
    auto offset_buf = build_offset_index(offsets, write_offset, hash_entries);
    std::vector<std::pair<uint64_t, uint64_t>>().swap(offsets);
    auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
      hash::linear table;
      table.build_to_file(hash_entries, path + "/hash.table");
    });
    blobs.write(offset_buf.data(), static_cast<std::streamsize>(offset_buf.size()));
    hash_thread.get();

    std::ofstream sui(path + "/.hoshidicts_1", std::ios::binary);
    result.success = true;
  } catch (...) {
    memory::unmap(file);
    throw;
  }
  return result;
}

ImportResult dictionary_importer::import(const std::string& zip_path, const std::string& output_dir, bool low_ram) {
  ImportResult result;
  try {
    // Check if it's a standalone .mdx file
    if (zip_path.size() >= 4) {
      auto ext = zip_path.substr(zip_path.size() - 4);
      if (ext == ".mdx" || ext == ".MDX") {
        result = import_standalone_mdx(zip_path, output_dir, low_ram);
        if (!result.success && !result.title.empty()) {
          std::filesystem::remove_all(std::filesystem::path(output_dir) / result.title);
        }
        return result;
      }
    }

    Zip zip;
    if (!zip.open(zip_path)) {
      throw std::runtime_error("failed to open file");
    }

    int index_idx = zip.find("index.json");
    if (index_idx < 0) {
      for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
        if (basename(zip.entries[i].name) == "index.json") {
          index_idx = i;
          break;
        }
      }
    }
    if (index_idx < 0) {
      // Try MDict format
      int mdx_idx = find_mdx_in_zip(zip);
      if (mdx_idx >= 0) {
        result = import_mdx(zip, mdx_idx, output_dir, low_ram);
        return result;
      }
      std::string msg = "unsupported dictionary format (" +
                        std::to_string(zip.entries.size()) + " entries: [";
      for (size_t i = 0; i < zip.entries.size() && i < 20; i++) {
        if (i > 0) msg += ", ";
        msg += zip.entries[i].name;
      }
      msg += "])";
      throw std::runtime_error(msg);
    }
    std::string index_content = zip.read(index_idx);
    if (index_content.empty()) {
      throw std::runtime_error("could not read index.json");
    }

    Index index;
    if (!yomitan_parser::parse_index(index_content, index)) {
      throw std::runtime_error("failed to parse index.json");
    }

    result.title = index.title;

    std::string zip_prefix;
    {
      const auto& index_name = zip.entries[index_idx].name;
      auto slash = index_name.rfind('/');
      if (slash == std::string::npos) slash = index_name.rfind('\\');
      if (slash != std::string::npos) {
        zip_prefix = index_name.substr(0, slash + 1);
      }
    }

    std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;
    std::string path = dict_path.string();
    std::filesystem::create_directories(dict_path);

    if (glz::write_file_json(index, path + "/index.json", std::string{})) {
      throw std::runtime_error("failed to write index.json");
    }

    int styles_idx = zip.find("styles.css");
    if (styles_idx < 0) {
      for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
        if (basename(zip.entries[i].name) == "styles.css") {
          styles_idx = i;
          break;
        }
      }
    }
    if (styles_idx >= 0) {
      std::string styles = zip.read(styles_idx);
      if (!styles.empty()) {
        std::ofstream styles_file(path + "/styles.css", std::ios::binary);
        setup_stream_exceptions(styles_file);
        styles_file.write(styles.data(), static_cast<std::streamsize>(styles.size()));
      }
    }

    const Files files = get_files(zip);
    std::future<size_t> media_thread =
        std::async(std::launch::async, [&path, &zip, &files, &zip_prefix]() { return write_media(path, zip, files.media_files, zip_prefix); });

    std::ofstream blobs(path + "/blobs.bin", std::ios::binary);
    setup_stream_exceptions(blobs);
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    uint64_t write_offset = 0;
    write_terms(blobs, offsets, zip, files.term_banks, write_offset, result, low_ram);
    write_meta(blobs, offsets, zip, files.meta_banks, write_offset, result, low_ram);

    if (!files.term_banks.empty()) {
      result.detected_type = "term";
    } else if (!files.meta_banks.empty()) {
      std::string first_meta = zip.read(files.meta_banks[0]);
      std::vector<Meta> metas;
      if (yomitan_parser::parse_meta_bank(first_meta, metas) && !metas.empty()) {
        std::string_view mode = metas[0].mode;
        if (mode == "freq") {
          result.detected_type = "frequency";
        } else if (mode == "pitch") {
          result.detected_type = "pitch";
        }
      }
    }

    if (offsets.empty()) {
      throw std::runtime_error("empty dictionary");
    }

    std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
    auto offset_buf = build_offset_index(offsets, write_offset, hash_entries);
    std::vector<std::pair<uint64_t, uint64_t>>().swap(offsets);

    auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
      hash::linear table;
      table.build_to_file(hash_entries, path + "/hash.table");
    });

    blobs.write(offset_buf.data(), static_cast<std::streamsize>(offset_buf.size()));
    hash_thread.get();

    result.media_count = media_thread.get();

    std::ofstream sui(path + "/.hoshidicts_1", std::ios::binary);
    result.success = true;
  } catch (const std::exception& e) {
    result.success = false;
    result.errors.emplace_back(e.what());
  }

  if (!result.success && !result.title.empty()) {
    std::filesystem::remove_all(std::filesystem::path(output_dir) / result.title);
  }

  return result;
}

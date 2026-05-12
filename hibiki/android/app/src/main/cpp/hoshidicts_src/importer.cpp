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
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "hash/bloom.hpp"
#include "hash/hash.hpp"
#include "json/yomitan_parser.hpp"
#include "mdx/mdx_reader.hpp"
#include "stardict/stardict_reader.hpp"
#include "zip/zip.hpp"

#include <utf8.h>

namespace {
struct Files {
  std::vector<int> term_banks;
  std::vector<int> kanji_banks;
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

Files get_files(const Zip& zip) {
  Files files;
  for (int i = 0; i < static_cast<int>(zip.entries.size()); i++) {
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/') {
      continue;
    }

    if (name.starts_with("term_bank_")) {
      files.term_banks.push_back(i);
    } else if (name.starts_with("kanji_bank_")) {
      files.kanji_banks.push_back(i);
    } else if (name.starts_with("term_meta_bank_") || name.starts_with("kanji_meta_bank_")) {
      files.meta_banks.push_back(i);
    } else if (name.starts_with("tag_bank_")) {
      files.tag_banks.push_back(i);
    } else if (!(name == "styles.css" || name == "index.json")) {
      files.media_files.push_back(i);
    }
  }
  return files;
}

std::string detect_type(const Files& files, const Zip& zip) {
  if (!files.kanji_banks.empty()) {
    return "kanji";
  }
  if (!files.term_banks.empty()) {
    return "term";
  }
  if (!files.meta_banks.empty()) {
    std::string content = zip.read(files.meta_banks[0]);
    if (!content.empty()) {
      std::vector<Meta> metas;
      if (yomitan_parser::parse_meta_bank(content, metas) && !metas.empty()) {
        if (metas[0].mode == "freq") return "frequency";
        if (metas[0].mode == "pitch") return "pitch";
      }
    }
  }
  return "term";
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
  auto global_count = std::make_unique<std::array<size_t, 65536>>();
  auto global_pos = std::make_unique<std::array<size_t, 65536>>();

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

    global_count->fill(0);
    for (size_t t = 0; t < futures.size(); t++) {
      for (size_t bucket = 0; bucket < 65536; bucket++) {
        (*global_count)[bucket] += local_counts[t][bucket];
      }
    }

    global_pos->fill(0);
    size_t total = 0;
    for (size_t bucket = 0; bucket < 65536; bucket++) {
      (*global_pos)[bucket] = total;
      total += (*global_count)[bucket];
    }

    std::vector<std::array<size_t, 65536>> thread_pos(futures.size());
    for (size_t bucket = 0; bucket < 65536; bucket++) {
      size_t pos = (*global_pos)[bucket];
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

size_t write_media(const std::string& path, const Zip& zip, const std::vector<int>& files) {
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

ProcessedFile process_simple_entries(const std::vector<SimpleEntry>& entries) {
  ProcessedFile processed;
  if (entries.empty()) {
    return processed;
  }

  std::vector<char> compressed;
  ZSTD_CCtx* cctx = ZSTD_createCCtx();
  if (!cctx) {
    return processed;
  }

  for (const auto& entry : entries) {
    const std::string_view glossary = entry.definition;
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
    std::string_view expr = entry.headword;

    write_val<uint8_t>(processed.data, 0);
    write_val<uint16_t>(processed.data, expr.size());
    write_str(processed.data, expr);
    write_val<uint16_t>(processed.data, 0);  // reading_len = 0

    uint64_t glossary_offset = processed.data.size();
    write_val<uint64_t>(processed.data, 0);
    write_val<uint32_t>(processed.data, blob_size);
    processed.glossary_offsets.emplace_back(glossary_hash, glossary_offset);

    write_val<uint8_t>(processed.data, 0);  // def_tags_len = 0
    write_val<uint8_t>(processed.data, 0);  // rules_len = 0
    write_val<uint8_t>(processed.data, 0);  // term_tags_len = 0

    processed.offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
    processed.count++;
  }
  ZSTD_freeCCtx(cctx);

  return processed;
}

ImportResult import_mdx(const std::string& mdx_path, const std::string& output_dir) {
  std::ifstream file(mdx_path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    return {.success = false, .errors = {"failed to open MDX file"}};
  }

  auto size = file.tellg();
  file.seekg(0);
  std::vector<uint8_t> data(size);
  file.read(reinterpret_cast<char*>(data.data()), size);

  MdxResult mdx;
  try {
    mdx = mdx_reader::parse(data.data(), data.size());
  } catch (const std::exception& e) {
    return {.success = false, .errors = {std::string("MDX parse error: ") + e.what()}};
  }

  std::string title = mdx.title;
  if (title.empty()) {
    title = std::filesystem::path(mdx_path).stem().string();
  }

  std::vector<SimpleEntry> entries;
  entries.reserve(mdx.entries.size());
  for (auto& e : mdx.entries) {
    if (e.key.empty()) continue;
    // REVIEW FIX I5: Skip @@@LINK= redirect entries - these are cross-references
    // that point to other entries and should not be stored as definitions
    if (e.definition.starts_with("@@@LINK=")) continue;
    entries.push_back({std::move(e.key), std::move(e.definition)});
  }

  return dictionary_importer::write_simple_dict(title, entries, output_dir);
}

ImportResult import_mdx_from_zip(Zip& zip, const std::string& output_dir) {
  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.size() > 4 && name.substr(name.size() - 4) == ".mdx") {
      std::string temp_dir = output_dir + "/_mdx_temp";
      std::filesystem::create_directories(temp_dir);
      std::string temp_path = temp_dir + "/" + std::filesystem::path(name).filename().string();
      {
        std::string content = zip.read(static_cast<int>(i));
        std::ofstream out(temp_path, std::ios::binary);
        setup_stream_exceptions(out);
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
      }
      auto result = import_mdx(temp_path, output_dir);
      std::filesystem::remove_all(temp_dir);
      return result;
    }
  }
  return {.success = false, .errors = {"no .mdx file found in zip"}};
}

ImportResult import_stardict(const std::string& ifo_path, const std::string& output_dir) {
  StardictResult sd;
  try {
    sd = stardict_reader::parse(ifo_path);
  } catch (const std::exception& e) {
    return {.success = false, .errors = {std::string("StarDict parse error: ") + e.what()}};
  }

  std::vector<SimpleEntry> entries;
  entries.reserve(sd.entries.size());
  for (auto& e : sd.entries) {
    entries.push_back({std::move(e.word), std::move(e.definition)});
  }

  return dictionary_importer::write_simple_dict(sd.bookname, entries, output_dir);
}

ImportResult import_stardict_from_zip(Zip& zip, const std::string& output_dir) {
  std::string temp_dir = output_dir + "/_stardict_temp";
  std::filesystem::create_directories(temp_dir);
  std::string ifo_path;

  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/') continue;
    std::string filename = std::filesystem::path(name).filename().string();
    std::string ext = std::filesystem::path(filename).extension().string();
    if (ext == ".ifo" || ext == ".idx" || ext == ".dict" || filename.ends_with(".dict.dz")) {
      std::string out_path = temp_dir + "/" + filename;
      std::string content = zip.read(static_cast<int>(i));
      std::ofstream out(out_path, std::ios::binary);
      out.write(content.data(), static_cast<std::streamsize>(content.size()));
      if (ext == ".ifo") ifo_path = out_path;
    }
  }

  if (ifo_path.empty()) {
    std::filesystem::remove_all(temp_dir);
    return {.success = false, .errors = {"no .ifo file found in zip"}};
  }

  auto result = import_stardict(ifo_path, output_dir);
  std::filesystem::remove_all(temp_dir);
  return result;
}

std::string sanitize_title(const std::string& raw) {
  std::string title;
  title.reserve(raw.size());
  for (unsigned char c : raw) {
    if (c < 0x20) continue;
    if (c == '/' || c == '\\' || c == ':' || c == '*' ||
        c == '?' || c == '"' || c == '<' || c == '>' || c == '|') {
      title += '_';
    } else {
      title += static_cast<char>(c);
    }
  }
  while (!title.empty() && (title.back() == ' ' || title.back() == '.')) title.pop_back();
  if (title.empty()) title = "unnamed_dictionary";
  if (title.size() > 200) {
    size_t chars = utf8::distance(title.begin(), title.end());
    if (chars > 200) {
      auto it = title.begin();
      utf8::advance(it, 200, title.end());
      title.erase(it, title.end());
    }
  }
  return title;
}

std::string read_dsl_file_as_utf8(const std::string& dsl_path) {
  std::ifstream file(dsl_path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) return {};
  auto size = file.tellg();
  if (size < 2) return {};
  file.seekg(0);
  std::vector<uint8_t> raw(size);
  file.read(reinterpret_cast<char*>(raw.data()), size);

  // UTF-16 LE BOM: FF FE
  if (raw.size() >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) {
    std::u16string u16;
    for (size_t i = 2; i + 1 < raw.size(); i += 2) {
      u16.push_back(uint16_t(raw[i]) | (uint16_t(raw[i + 1]) << 8));
    }
    std::string result;
    utf8::utf16to8(u16.begin(), u16.end(), std::back_inserter(result));
    return result;
  }

  // UTF-8 BOM: EF BB BF — skip it
  size_t start = 0;
  if (raw.size() >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
    start = 3;
  }

  return std::string(reinterpret_cast<char*>(raw.data() + start), raw.size() - start);
}

ImportResult import_dsl(const std::string& dsl_path, const std::string& output_dir) {
  std::string content = read_dsl_file_as_utf8(dsl_path);
  if (content.empty()) {
    return {.success = false, .errors = {"failed to open or read DSL file"}};
  }

  std::string title;
  std::vector<SimpleEntry> entries;
  std::string current_headword;
  std::string current_definition;

  auto flush_entry = [&]() {
    if (!current_headword.empty() && !current_definition.empty()) {
      while (!current_definition.empty() &&
             (current_definition.back() == '\n' || current_definition.back() == '\r' ||
              current_definition.back() == ' ')) {
        current_definition.pop_back();
      }
      entries.push_back({current_headword, current_definition});
    }
    current_headword.clear();
    current_definition.clear();
  };

  std::istringstream stream(content);
  std::string line;

  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;

    if (line[0] == '#') {
      if (line.starts_with("#NAME")) {
        title = line.substr(5);
        while (!title.empty() && (title.front() == ' ' || title.front() == '\t' || title.front() == '"')) {
          title.erase(title.begin());
        }
        while (!title.empty() && (title.back() == ' ' || title.back() == '\t' || title.back() == '"')) {
          title.pop_back();
        }
      }
      continue;
    }

    if (line[0] == '\t' || line[0] == ' ') {
      size_t start = 0;
      while (start < line.size() && (line[start] == '\t' || line[start] == ' ')) start++;
      if (start < line.size()) {
        if (!current_definition.empty()) current_definition += '\n';
        current_definition += line.substr(start);
      }
    } else {
      flush_entry();
      current_headword = line;
    }
  }
  flush_entry();

  if (title.empty()) {
    title = std::filesystem::path(dsl_path).stem().string();
  }

  // Strip DSL markup: remove [tag] markers, handle \[ \] escapes, convert [m] to indent
  for (auto& e : entries) {
    std::string& def = e.definition;
    std::string cleaned;
    cleaned.reserve(def.size());
    size_t i = 0;
    while (i < def.size()) {
      if (def[i] == '\\' && i + 1 < def.size() && (def[i + 1] == '[' || def[i + 1] == ']')) {
        cleaned += def[i + 1];
        i += 2;
        continue;
      }
      if (def[i] == '[') {
        size_t end = def.find(']', i);
        if (end != std::string::npos) {
          i = end + 1;
          continue;
        }
      }
      cleaned += def[i];
      i++;
    }
    def = std::move(cleaned);
  }

  return dictionary_importer::write_simple_dict(title, entries, output_dir);
}

ImportResult import_yomitan(Zip& zip, const std::string& output_dir, bool low_ram) {
  ImportResult result;
  try {
    int index_idx = zip.find("index.json");
    if (index_idx < 0) {
      throw std::runtime_error("could not find index.json");
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

    std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;
    std::string path = dict_path.string();
    std::filesystem::create_directories(dict_path);

    if (glz::write_file_json(index, path + "/index.json", std::string{})) {
      throw std::runtime_error("failed to write index.json");
    }

    int styles_idx = zip.find("styles.css");
    if (styles_idx >= 0) {
      std::string styles = zip.read(styles_idx);
      if (!styles.empty()) {
        std::ofstream styles_file(path + "/styles.css", std::ios::binary);
        setup_stream_exceptions(styles_file);
        styles_file.write(styles.data(), static_cast<std::streamsize>(styles.size()));
      }
    }

    const Files files = get_files(zip);
    result.detected_type = detect_type(files, zip);
    std::future<size_t> media_thread =
        std::async(std::launch::async, [&path, &zip, &files]() { return write_media(path, zip, files.media_files); });

    std::ofstream blobs(path + "/blobs.bin", std::ios::binary);
    setup_stream_exceptions(blobs);
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    uint64_t write_offset = 0;
    write_terms(blobs, offsets, zip, files.term_banks, write_offset, result, low_ram);
    write_meta(blobs, offsets, zip, files.meta_banks, write_offset, result, low_ram);
    if (offsets.empty()) {
      throw std::runtime_error("empty dictionary");
    }

    std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
    auto offset_buf = build_offset_index(offsets, write_offset, hash_entries);
    std::vector<std::pair<uint64_t, uint64_t>>().swap(offsets);

    auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
      hash::linear table;
      table.build_to_file(hash_entries, path + "/hash.table");
      auto hashes = hash_entries | std::views::keys | std::ranges::to<std::vector>();
      hash::bloom::build_to_file(hashes, path + "/bloom.filter");
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

}  // end anonymous namespace

ImportResult dictionary_importer::write_simple_dict(const std::string& title, const std::vector<SimpleEntry>& entries,
                                                    const std::string& output_dir, const std::string& styles_css) {
  ImportResult result;
  try {
    result.title = sanitize_title(title);
    result.detected_type = "term";

    std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;
    std::string path = dict_path.string();
    std::filesystem::create_directories(dict_path);

    Index index;
    index.title = result.title;
    index.format = 3;
    if (glz::write_file_json(index, path + "/index.json", std::string{})) {
      throw std::runtime_error("failed to write index.json");
    }

    if (!styles_css.empty()) {
      std::ofstream styles_file(path + "/styles.css", std::ios::binary);
      setup_stream_exceptions(styles_file);
      styles_file.write(styles_css.data(), static_cast<std::streamsize>(styles_css.size()));
    }

    ProcessedFile processed = process_simple_entries(entries);
    if (processed.data.empty()) {
      throw std::runtime_error("empty dictionary");
    }

    ankerl::unordered_dense::map<uint64_t, uint64_t> glossaries;
    std::ofstream blobs(path + "/blobs.bin", std::ios::binary);
    setup_stream_exceptions(blobs);
    uint64_t write_offset = 0;

    // Write glossary blobs first
    std::vector<char> glossary_buf;
    for (auto& [hash, compressed] : processed.glossaries) {
      auto [it, inserted] = glossaries.try_emplace(hash, write_offset);
      if (inserted) {
        write_bytes(glossary_buf, compressed.data(), compressed.size());
        write_offset += compressed.size();
      }
    }
    if (!glossary_buf.empty()) {
      blobs.write(glossary_buf.data(), static_cast<std::streamsize>(glossary_buf.size()));
    }

    // Fix up glossary offsets in term data
    for (auto& [hash, pos] : processed.glossary_offsets) {
      uint64_t glossary_offset = glossaries[hash];
      std::memcpy(processed.data.data() + pos, &glossary_offset, sizeof(uint64_t));
    }

    // Adjust term offsets to account for glossary blob region
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    for (auto& [hash, offset] : processed.offsets) {
      offsets.emplace_back(hash, offset + write_offset);
    }

    blobs.write(processed.data.data(), static_cast<std::streamsize>(processed.data.size()));
    write_offset += processed.data.size();
    result.term_count = processed.count;

    if (offsets.empty()) {
      throw std::runtime_error("empty dictionary");
    }

    std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
    auto offset_buf = build_offset_index(offsets, write_offset, hash_entries);
    std::vector<std::pair<uint64_t, uint64_t>>().swap(offsets);

    auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
      hash::linear table;
      table.build_to_file(hash_entries, path + "/hash.table");
      auto hashes = hash_entries | std::views::keys | std::ranges::to<std::vector>();
      hash::bloom::build_to_file(hashes, path + "/bloom.filter");
    });

    blobs.write(offset_buf.data(), static_cast<std::streamsize>(offset_buf.size()));
    hash_thread.get();

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

ImportResult dictionary_importer::import(const std::string& file_path, const std::string& output_dir, bool low_ram) {
  std::string ext;
  {
    auto dot = file_path.rfind('.');
    if (dot != std::string::npos) {
      ext = file_path.substr(dot);
      std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    }
  }

  if (ext == ".mdx") return import_mdx(file_path, output_dir);
  if (ext == ".dsl") return import_dsl(file_path, output_dir);
  if (ext == ".ifo") return import_stardict(file_path, output_dir);

  Zip zip;
  if (!zip.open(file_path)) {
    return {.success = false, .errors = {"unsupported format or failed to open file"}};
  }

  if (zip.find("index.json") >= 0) {
    return import_yomitan(zip, output_dir, low_ram);
  }

  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.size() > 4 && name.substr(name.size() - 4) == ".mdx") {
      return import_mdx_from_zip(zip, output_dir);
    }
  }

  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.size() > 4 && name.substr(name.size() - 4) == ".ifo") {
      return import_stardict_from_zip(zip, output_dir);
    }
  }

  return {.success = false, .errors = {"unsupported dictionary format"}};
}

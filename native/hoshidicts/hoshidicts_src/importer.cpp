#include "hoshidicts/importer.hpp"
#include "hoshidicts/media_path.hpp"

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
#include <limits>
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
#include "util/fs_utf8.hpp"
#include "zip/zip.hpp"

#include "hoshidicts/platform.hpp"
#include <utf8.h>

namespace {

// Resource limits to prevent OOM from malicious or huge dictionaries.
static constexpr size_t kMaxEntriesPerBank = 1'000'000;
static constexpr size_t kMaxTotalEntries = 10'000'000;
static constexpr size_t kMaxDataBufferBytes = 1024 * 1024 * 1024;       // 1 GB
static constexpr size_t kMaxGlossarySizeBytes = 10 * 1024 * 1024;       // 10 MB uncompressed

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
  size_t freq_count = 0;
  size_t pitch_count = 0;
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
  // A mixed dictionary that ships both term_bank_*.json and kanji_bank_*.json
  // (e.g. a JA-JA 国語辞典 with an embedded kanji appendix) is fundamentally a
  // term dictionary: its 80k+ entries are looked up by word. Classifying it as
  // "kanji" sent the whole thing into the kanji bucket only, so word lookup
  // returned nothing. Term wins whenever a term_bank exists; only a pure
  // kanji_bank-only dictionary (KANJIDIC) stays "kanji". The mixed dictionary's
  // kanji_bank is still written to blobs.bin and surfaced by routing the
  // dictionary into BOTH buckets at the Dart layer (metadata['hasKanji']='true').
  if (!files.term_banks.empty()) {
    return "term";
  }
  if (!files.kanji_banks.empty()) {
    return "kanji";
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
    if (processed.data.size() > kMaxDataBufferBytes) {
      HOSHI_LOGW("term bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      HOSHI_LOGW("term bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
      break;
    }

    const std::string_view glossary = term.glossary.str;
    if (glossary.size() > kMaxGlossarySizeBytes) {
      HOSHI_LOGW("glossary too large (%zu bytes), skipping entry", glossary.size());
      continue;
    }

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
    uint32_t blob_size = static_cast<uint32_t>(processed.glossaries[glossary_hash].size());
    std::string_view expr = term.expression;
    std::string_view reading = term.reading.empty() ? expr : term.reading;
    std::string_view definition_tags = term.definition_tags.value_or("");

    if (expr.size() > std::numeric_limits<uint16_t>::max()) {
      HOSHI_LOGW("expression too long (%zu bytes), skipping entry", expr.size());
      continue;
    }
    if (reading.size() > std::numeric_limits<uint16_t>::max()) {
      HOSHI_LOGW("reading too long (%zu bytes), skipping entry", reading.size());
      continue;
    }
    if (definition_tags.size() > std::numeric_limits<uint8_t>::max() ||
        term.rules.size() > std::numeric_limits<uint8_t>::max() ||
        term.term_tags.size() > std::numeric_limits<uint8_t>::max()) {
      HOSHI_LOGW("tags/rules too long, skipping entry");
      continue;
    }

    write_val<uint8_t>(processed.data, 0);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(expr.size()));
    write_str(processed.data, expr);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(reading.size()));
    write_str(processed.data, reading);

    uint64_t glossary_offset = processed.data.size();
    write_val<uint64_t>(processed.data, 0);
    write_val<uint32_t>(processed.data, blob_size);
    processed.glossary_offsets.emplace_back(glossary_hash, glossary_offset);

    write_val<uint8_t>(processed.data, static_cast<uint8_t>(definition_tags.size()));
    write_str(processed.data, definition_tags);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(term.rules.size()));
    write_str(processed.data, term.rules);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(term.term_tags.size()));
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
    if (processed.data.size() > kMaxDataBufferBytes) {
      HOSHI_LOGW("meta bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      HOSHI_LOGW("meta bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
      break;
    }

    uint64_t offset = processed.data.size();
    std::string_view expr = meta.expression;
    std::string_view mode = meta.mode;
    std::string_view data = meta.data.str;

    write_val<uint8_t>(processed.data, 1);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(expr.size()));
    write_str(processed.data, expr);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(mode.size()));
    write_str(processed.data, mode);
    write_val<uint32_t>(processed.data, static_cast<uint32_t>(data.size()));
    write_str(processed.data, data);

    processed.offsets.emplace_back(XXH3_64bits(expr.data(), expr.size()), offset);
    processed.count++;
    if (mode == "freq") {
      processed.freq_count++;
    } else if (mode == "pitch") {
      processed.pitch_count++;
    }
  }

  return processed;
}

// ---------------------------------------------------------------------------
// S0 binary contract -- kanji record (type byte == 2).
//
// Kanji records live in the SAME blobs.bin and share the SAME hash.table /
// bloom.filter index as term (type 0) and meta (type 1) records. The hash key
// is xxh3(character). Layout (little-endian, mirrors the term layout so the
// existing build_offset_index / query plumbing is reused unchanged):
//
//   [u8  = 2]                       record type tag (term=0 / meta=1 / kanji=2)
//   [u16 char_len][char bytes]      single kanji, UTF-8
//   [u16 ony_len ][onyomi bytes]    onyomi (space-separated, as in Yomitan)
//   [u16 kun_len ][kunyomi bytes]   kunyomi (space-separated)
//   [u8  rad_len ][radical bytes]   radical from stats (may be empty)
//   [u16 strokes ]                  stroke count from stats (0 == unknown)
//   [u8  tags_len][tags bytes]      kanji tags (space-separated, may be empty)
//   [u64 meanings_offset][u32 meanings_blob_size]
//                                   meanings joined by newline, ZSTD-compressed,
//                                   pooled in the shared glossary blob region
//                                   (identical mechanism as term glossaries).
//
// meanings are joined with newline because Yomitan kanji meanings are
// single-line phrases; the reader splits them back on newline.
// ---------------------------------------------------------------------------

}  // end anonymous namespace (reopened below) -- glz::meta must be at global scope

// Stats{} is an open-ended object whose key names differ per dictionary. Pull
// the two fields the UI needs (radical, stroke count) by trying the common
// KANJIDIC-derived key names; missing keys are tolerated. Defined at global
// scope so its glz::meta specialization is not in an anonymous namespace.
struct KanjiStats {
  std::optional<std::string_view> radical;
  std::optional<std::string_view> rad;
  std::optional<std::string_view> kangxi_radical;
  std::optional<std::string_view> strokes;
  std::optional<std::string_view> stroke_count;
};

template <>
struct glz::meta<KanjiStats> {
  using T = KanjiStats;
  static constexpr auto value = object("radical", &T::radical, "rad", &T::rad, "kangxi_radical", &T::kangxi_radical,
                                       "strokes", &T::strokes, "stroke count", &T::stroke_count);
};

namespace {

// Parse the raw stats blob for radical (string) and stroke count (uint16).
void extract_kanji_stats(std::string_view stats_json, std::string_view& radical_out, uint16_t& strokes_out) {
  radical_out = {};
  strokes_out = 0;
  if (stats_json.empty()) {
    return;
  }
  KanjiStats stats;
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(stats, stats_json);
  if (error) {
    return;
  }
  if (stats.radical.has_value() && !stats.radical->empty()) {
    radical_out = *stats.radical;
  } else if (stats.rad.has_value() && !stats.rad->empty()) {
    radical_out = *stats.rad;
  } else if (stats.kangxi_radical.has_value() && !stats.kangxi_radical->empty()) {
    radical_out = *stats.kangxi_radical;
  }
  std::string_view strokes_str;
  if (stats.strokes.has_value()) {
    strokes_str = *stats.strokes;
  } else if (stats.stroke_count.has_value()) {
    strokes_str = *stats.stroke_count;
  }
  if (!strokes_str.empty()) {
    unsigned long parsed = 0;
    for (char c : strokes_str) {
      if (c < 0x30 || c > 0x39) {
        break;
      }
      parsed = parsed * 10 + static_cast<unsigned long>(c - 0x30);
      if (parsed > std::numeric_limits<uint16_t>::max()) {
        parsed = std::numeric_limits<uint16_t>::max();
        break;
      }
    }
    strokes_out = static_cast<uint16_t>(parsed);
  }
}

ProcessedFile process_kanji_bank(const std::string& content) {
  ProcessedFile processed;
  if (content.empty()) {
    return processed;
  }

  std::vector<Kanji> out;
  if (!yomitan_parser::parse_kanji_bank(content, out)) {
    return processed;
  }

  std::vector<char> compressed;
  ZSTD_CCtx* cctx = ZSTD_createCCtx();
  if (!cctx) {
    return processed;
  }

  for (auto& kanji : out) {
    if (processed.data.size() > kMaxDataBufferBytes) {
      HOSHI_LOGW("kanji bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      HOSHI_LOGW("kanji bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
      break;
    }

    std::string_view character = kanji.character;
    if (character.empty()) {
      continue;
    }
    if (character.size() > std::numeric_limits<uint16_t>::max() ||
        kanji.onyomi.size() > std::numeric_limits<uint16_t>::max() ||
        kanji.kunyomi.size() > std::numeric_limits<uint16_t>::max() ||
        kanji.tags.size() > std::numeric_limits<uint8_t>::max()) {
      HOSHI_LOGW("kanji field too long, skipping entry");
      continue;
    }

    std::string meanings_joined;
    for (size_t i = 0; i < kanji.meanings.size(); i++) {
      if (i) {
        meanings_joined.push_back(static_cast<char>(0x0a));
      }
      meanings_joined.append(kanji.meanings[i]);
    }
    if (meanings_joined.size() > kMaxGlossarySizeBytes) {
      HOSHI_LOGW("kanji meanings too large (%zu bytes), skipping entry", meanings_joined.size());
      continue;
    }

    uint64_t meanings_hash = XXH3_64bits(meanings_joined.data(), meanings_joined.size());
    auto it = processed.glossaries.find(meanings_hash);
    if (it == processed.glossaries.end()) {
      const size_t bound = ZSTD_compressBound(meanings_joined.size());
      compressed.resize(bound);
      const size_t compressed_size =
          ZSTD_compressCCtx(cctx, compressed.data(), bound, meanings_joined.data(), meanings_joined.size(), 0);
      if (ZSTD_isError(compressed_size)) {
        ZSTD_freeCCtx(cctx);
        throw std::runtime_error("failed to compress kanji meanings");
      }
      compressed.resize(compressed_size);
      processed.glossaries.emplace(meanings_hash, compressed);
    }

    std::string_view radical;
    uint16_t strokes = 0;
    extract_kanji_stats(kanji.stats.str, radical, strokes);
    if (radical.size() > std::numeric_limits<uint8_t>::max()) {
      radical = {};
    }

    uint64_t offset = processed.data.size();
    uint32_t blob_size = static_cast<uint32_t>(processed.glossaries[meanings_hash].size());

    write_val<uint8_t>(processed.data, 2);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(character.size()));
    write_str(processed.data, character);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(kanji.onyomi.size()));
    write_str(processed.data, kanji.onyomi);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(kanji.kunyomi.size()));
    write_str(processed.data, kanji.kunyomi);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(radical.size()));
    write_str(processed.data, radical);
    write_val<uint16_t>(processed.data, strokes);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(kanji.tags.size()));
    write_str(processed.data, kanji.tags);

    uint64_t meanings_offset_pos = processed.data.size();
    write_val<uint64_t>(processed.data, 0);
    write_val<uint32_t>(processed.data, blob_size);
    processed.glossary_offsets.emplace_back(meanings_hash, meanings_offset_pos);

    processed.offsets.emplace_back(XXH3_64bits(character.data(), character.size()), offset);
    processed.count++;
  }
  ZSTD_freeCCtx(cctx);

  return processed;
}

void write_kanji(std::ofstream& file, std::vector<std::pair<uint64_t, uint64_t>>& offsets, const Zip& zip,
                 const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram,
                 ankerl::unordered_dense::map<uint64_t, uint64_t>& glossaries) {
  if (files.empty()) {
    return;
  }

  size_t max_threads =
      low_ram ? 2 : std::max<size_t>(4, static_cast<const unsigned long>(std::thread::hardware_concurrency()) + 4);
  std::deque<std::future<ProcessedFile>> threads;

  bool limit_reached = false;
  auto write_processed = [&](ProcessedFile&& processed) {
    if (processed.data.empty() || limit_reached) {
      return;
    }
    if (result.kanji_count + processed.count > kMaxTotalEntries) {
      HOSHI_LOGW("total kanji entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
      limit_reached = true;
      return;
    }

    std::vector<char> meanings_buf;
    for (auto& [hash, compressed] : processed.glossaries) {
      auto [it, inserted] = glossaries.try_emplace(hash, write_offset);
      if (inserted) {
        write_bytes(meanings_buf, compressed.data(), compressed.size());
        write_offset += compressed.size();
      }
    }
    if (!meanings_buf.empty()) {
      file.write(meanings_buf.data(), static_cast<std::streamsize>(meanings_buf.size()));
    }

    for (auto& [hash, pos] : processed.glossary_offsets) {
      uint64_t meanings_offset = glossaries[hash];
      std::memcpy(processed.data.data() + pos, &meanings_offset, sizeof(uint64_t));
    }

    file.write(processed.data.data(), static_cast<std::streamsize>(processed.data.size()));

    for (auto& [hash, offset] : processed.offsets) {
      offsets.emplace_back(hash, offset + write_offset);
    }

    write_offset += processed.data.size();
    result.kanji_count += processed.count;
  };

  for (int file_index : files) {
    threads.push_back(
        std::async(std::launch::async, [&zip, file_index]() { return process_kanji_bank(zip.read(file_index)); }));

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

void write_terms(std::ofstream& file, std::vector<std::pair<uint64_t, uint64_t>>& offsets, const Zip& zip,
                 const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram) {
  if (files.empty()) {
    return;
  }

  size_t max_threads =
      low_ram ? 2 : std::max<size_t>(4, static_cast<const unsigned long>(std::thread::hardware_concurrency()) + 4);
  std::deque<std::future<ProcessedFile>> threads;

  bool limit_reached = false;
  ankerl::unordered_dense::map<uint64_t, uint64_t> glossaries;
  auto write_processed = [&](ProcessedFile&& processed) {
    if (processed.data.empty() || limit_reached) {
      return;
    }
    if (result.term_count + processed.count > kMaxTotalEntries) {
      HOSHI_LOGW("total term entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
      limit_reached = true;
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
  bool limit_reached = false;
  std::deque<std::future<ProcessedFile>> threads;
  auto write_processed = [&](ProcessedFile&& processed) {
    if (processed.data.empty() || limit_reached) {
      return;
    }
    if (result.meta_count + processed.count > kMaxTotalEntries) {
      HOSHI_LOGW("total meta entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
      limit_reached = true;
      return;
    }

    file.write(processed.data.data(), static_cast<std::streamsize>(processed.data.size()));

    for (auto& [hash, offset] : processed.offsets) {
      offsets.emplace_back(hash, offset + write_offset);
    }

    write_offset += processed.data.size();
    result.meta_count += processed.count;
    result.freq_count += processed.freq_count;
    result.pitch_count += processed.pitch_count;
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

  std::ofstream media(hoshi::fs_path(path + "/media.bin"), std::ios::binary);
  std::ofstream media_idx(hoshi::fs_path(path + "/media.idx"), std::ios::binary);
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
    media_file->path = hoshidicts::normalize_media_path(std::move(media_file->path));
    if (media_file->path.size() > std::numeric_limits<uint16_t>::max()) {
      HOSHI_LOGW("media path too long (%zu bytes), skipping", media_file->path.size());
      continue;
    }
    buf.clear();
    write_val<uint16_t>(buf, static_cast<uint16_t>(media_file->path.size()));
    write_str(buf, media_file->path);
    write_val<uint32_t>(buf, static_cast<uint32_t>(media_file->blob.size()));
    write_bytes(buf, media_file->blob.data(), media_file->blob.size());
    media.write(buf.data(), static_cast<std::streamsize>(buf.size()));
    write_pos += static_cast<uint32_t>(buf.size());

    index_entries.emplace_back(std::move(media_file->path), record_start);
    media_count++;
  }

  std::ranges::sort(index_entries);
  std::vector<char> index_buf;
  write_val<uint32_t>(index_buf, static_cast<uint32_t>(index_entries.size()));
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
    if (processed.data.size() > kMaxDataBufferBytes) {
      HOSHI_LOGW("simple entries data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      HOSHI_LOGW("simple entries count exceeded %zu, stopping", kMaxEntriesPerBank);
      break;
    }

    const std::string_view glossary = entry.definition;
    if (glossary.size() > kMaxGlossarySizeBytes) {
      HOSHI_LOGW("glossary too large (%zu bytes), skipping entry", glossary.size());
      continue;
    }

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
    uint32_t blob_size = static_cast<uint32_t>(processed.glossaries[glossary_hash].size());
    std::string_view expr = entry.headword;

    if (expr.size() > std::numeric_limits<uint16_t>::max()) {
      HOSHI_LOGW("expression too long (%zu bytes), skipping entry", expr.size());
      continue;
    }

    write_val<uint8_t>(processed.data, 0);
    write_val<uint16_t>(processed.data, static_cast<uint16_t>(expr.size()));
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
  std::ifstream file(hoshi::fs_path(mdx_path), std::ios::binary | std::ios::ate);
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
    title = hoshi::fs_to_utf8(hoshi::fs_path(mdx_path).stem());
  }

  std::vector<SimpleEntry> entries;
  entries.reserve(mdx.entries.size());
  for (auto& e : mdx.entries) {
    if (e.key.empty()) continue;
    // Unresolvable @@@LINK= (circular or dangling) — already attempted in mdx_reader
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
      std::filesystem::create_directories(hoshi::fs_path(temp_dir));
      std::string temp_path = temp_dir + "/" + hoshi::fs_to_utf8(hoshi::fs_path(name).filename());
      {
        std::string content = zip.read(static_cast<int>(i));
        std::ofstream out(hoshi::fs_path(temp_path), std::ios::binary);
        setup_stream_exceptions(out);
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
      }
      auto result = import_mdx(temp_path, output_dir);
      std::filesystem::remove_all(hoshi::fs_path(temp_dir));
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
  std::filesystem::create_directories(hoshi::fs_path(temp_dir));
  std::string ifo_path;

  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/') continue;
    std::string filename = hoshi::fs_to_utf8(hoshi::fs_path(name).filename());
    std::string ext = hoshi::fs_to_utf8(hoshi::fs_path(filename).extension());
    if (ext == ".ifo" || ext == ".idx" || ext == ".dict" || ext == ".syn" || filename.ends_with(".dict.dz")) {
      std::string out_path = temp_dir + "/" + filename;
      std::string content = zip.read(static_cast<int>(i));
      std::ofstream out(hoshi::fs_path(out_path), std::ios::binary);
      out.write(content.data(), static_cast<std::streamsize>(content.size()));
      if (ext == ".ifo") ifo_path = out_path;
    }
  }

  if (ifo_path.empty()) {
    std::filesystem::remove_all(hoshi::fs_path(temp_dir));
    return {.success = false, .errors = {"no .ifo file found in zip"}};
  }

  auto result = import_stardict(ifo_path, output_dir);
  std::filesystem::remove_all(hoshi::fs_path(temp_dir));
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
  std::ifstream file(hoshi::fs_path(dsl_path), std::ios::binary | std::ios::ate);
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
    title = hoshi::fs_to_utf8(hoshi::fs_path(dsl_path).stem());
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

    result.title = sanitize_title(std::string(index.title));

    std::filesystem::path dict_path = hoshi::fs_path(output_dir) / hoshi::fs_path(result.title);
    {
      auto canonical_parent = std::filesystem::weakly_canonical(hoshi::fs_path(output_dir));
      auto canonical_child = std::filesystem::weakly_canonical(dict_path);
      auto rel = std::filesystem::relative(canonical_child, canonical_parent);
      if (rel.empty() || *rel.begin() == "..") {
        throw std::runtime_error("path traversal detected in dictionary title");
      }
    }
    std::string path = hoshi::fs_to_utf8(dict_path);
    std::filesystem::create_directories(dict_path);

    {
      std::string index_buf;
      if (glz::write_json(index, index_buf)) {
        throw std::runtime_error("failed to write index.json");
      }
      std::ofstream index_out(hoshi::fs_path(path + "/index.json"), std::ios::binary);
      index_out.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
      if (!index_out.good()) {
        throw std::runtime_error("failed to write index.json");
      }
    }

    int styles_idx = zip.find("styles.css");
    if (styles_idx >= 0) {
      std::string styles = zip.read(styles_idx);
      if (!styles.empty()) {
        std::ofstream styles_file(hoshi::fs_path(path + "/styles.css"), std::ios::binary);
        setup_stream_exceptions(styles_file);
        styles_file.write(styles.data(), static_cast<std::streamsize>(styles.size()));
      }
    }

    const Files files = get_files(zip);
    result.detected_type = detect_type(files, zip);
    std::future<size_t> media_thread =
        std::async(std::launch::async, [&path, &zip, &files]() { return write_media(path, zip, files.media_files); });

    std::ofstream blobs(hoshi::fs_path(path + "/blobs.bin"), std::ios::binary);
    setup_stream_exceptions(blobs);
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    uint64_t write_offset = 0;
    write_terms(blobs, offsets, zip, files.term_banks, write_offset, result, low_ram);
    write_meta(blobs, offsets, zip, files.meta_banks, write_offset, result, low_ram);
    ankerl::unordered_dense::map<uint64_t, uint64_t> kanji_glossaries;
    write_kanji(blobs, offsets, zip, files.kanji_banks, write_offset, result, low_ram, kanji_glossaries);
    if (offsets.empty()) {
      // A kanji-only dictionary still produces offsets (one per character), so
      // the only way to reach here is a dictionary with no parseable entries of
      // any kind. Keep the guard; kanji entries now count toward it.
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

    std::ofstream sui(hoshi::fs_path(path + "/.hoshidicts_1"), std::ios::binary);
    result.success = true;
  } catch (const std::exception& e) {
    result.success = false;
    result.errors.emplace_back(e.what());
  }

  if (!result.success && !result.title.empty()) {
    std::filesystem::remove_all(hoshi::fs_path(output_dir) / hoshi::fs_path(result.title));
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

    std::filesystem::path dict_path = hoshi::fs_path(output_dir) / hoshi::fs_path(result.title);
    {
      auto canonical_parent = std::filesystem::weakly_canonical(hoshi::fs_path(output_dir));
      auto canonical_child = std::filesystem::weakly_canonical(dict_path);
      auto rel = std::filesystem::relative(canonical_child, canonical_parent);
      if (rel.empty() || *rel.begin() == "..") {
        throw std::runtime_error("path traversal detected in dictionary title");
      }
    }
    std::string path = hoshi::fs_to_utf8(dict_path);
    std::filesystem::create_directories(dict_path);

    Index index;
    index.title = result.title;
    index.format = 3;
    {
      std::string index_buf;
      if (glz::write_json(index, index_buf)) {
        throw std::runtime_error("failed to write index.json");
      }
      std::ofstream index_out(hoshi::fs_path(path + "/index.json"), std::ios::binary);
      index_out.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
      if (!index_out.good()) {
        throw std::runtime_error("failed to write index.json");
      }
    }

    if (!styles_css.empty()) {
      std::ofstream styles_file(hoshi::fs_path(path + "/styles.css"), std::ios::binary);
      setup_stream_exceptions(styles_file);
      styles_file.write(styles_css.data(), static_cast<std::streamsize>(styles_css.size()));
    }

    ProcessedFile processed = process_simple_entries(entries);
    if (processed.data.empty()) {
      throw std::runtime_error("empty dictionary");
    }

    ankerl::unordered_dense::map<uint64_t, uint64_t> glossaries;
    std::ofstream blobs(hoshi::fs_path(path + "/blobs.bin"), std::ios::binary);
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

    std::ofstream sui(hoshi::fs_path(path + "/.hoshidicts_1"), std::ios::binary);
    result.success = true;
  } catch (const std::exception& e) {
    result.success = false;
    result.errors.emplace_back(e.what());
  }

  if (!result.success && !result.title.empty()) {
    std::filesystem::remove_all(hoshi::fs_path(output_dir) / hoshi::fs_path(result.title));
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

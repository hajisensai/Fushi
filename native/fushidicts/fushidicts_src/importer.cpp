#include "fushidicts/importer.hpp"
#include "fushidicts/media_path.hpp"

#include <ankerl/unordered_dense.h>
#include <xxh3.h>
#define ZDICT_STATIC_LINKING_ONLY
#include <zdict.h>
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
#include <map>
#include <memory>
#include <optional>
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
#include "memory/memory.hpp"
#include "stardict/stardict_reader.hpp"
#include "util/fs_utf8.hpp"
#include "util/import_breadcrumb.hpp"
#include "zip/zip.hpp"

#include "fushidicts/platform.hpp"
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
    // Logical (dictionary-relative) name: a dictionary re-zipped with a wrapper
    // directory stores "MyDict/term_bank_1.json", and matching the raw name sent
    // every bank into media_files, leaving offsets empty -> "empty dictionary".
    const std::string_view name = zip.logical_name(i);
    if (name.empty() || name.back() == '/' || is_packaging_noise(name)) {
      continue;  // BUG-2053: "__MACOSX/..." / ".DS_Store" are not dictionary media
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
        // IPA transcription dicts (mode "ipa") share the pitch storage/query
        // path (query_pitch reads both pitch + ipa meta records), so a pure-IPA
        // dictionary must classify as "pitch" — otherwise it falls through to
        // "term" and is never registered as a pitch dict, leaving its data
        // unreachable. Upstream 918744d only widened the count branch and missed
        // this; Hibiki must widen detect_type too (TODO-687 block3).
        if (metas[0].mode == "pitch" || metas[0].mode == "ipa") return "pitch";
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

// 上游 8993838：导入时从第一个 term bank 采样（≤2MB、<8 样本放弃）、
// ZDICT_optimizeTrainFromBuffer_fastCover 训练 ≤110KB 的 zstd dictionary。
// 短 glossary 的压缩率显著受益（跨条目共享统计模型）。只训 term bank——
// meta/kanji 记录数少、收益低，且上游注明可能反噬查询性能。
std::vector<char> train_zstd_dict(const Zip& zip, const Files& files, bool low_ram) {
  if (files.term_banks.empty()) {
    return {};
  }

  const std::string content = zip.read(files.term_banks[0]);
  std::vector<Term> terms;
  if (!yomitan_parser::parse_term_bank(content, terms)) {
    return {};
  }

  size_t bank_bytes = 0;
  for (const auto& term : terms) {
    bank_bytes += term.glossary.str.size();
  }

  std::vector<char> samples;
  std::vector<size_t> sizes;
  constexpr size_t max_sample_bytes = 2L * 1024 * 1024;
  const size_t step = std::max<size_t>(1, bank_bytes / max_sample_bytes);
  for (size_t i = 0; i < terms.size() && samples.size() < max_sample_bytes; i += step) {
    write_str(samples, terms[i].glossary.str);
    sizes.push_back(terms[i].glossary.str.size());
  }

  if (sizes.size() < 8) {
    return {};
  }

  ZDICT_fastCover_params_t params = {};
  params.d = 8;
  params.steps = 4;
  params.splitPoint = 1.0;
  params.nbThreads = low_ram ? 1 : std::max<unsigned int>(1, std::thread::hardware_concurrency());

  std::vector<char> dict(static_cast<size_t>(110 * 1024));
  const size_t dict_size = ZDICT_optimizeTrainFromBuffer_fastCover(
      dict.data(), dict.size(), samples.data(), sizes.data(), static_cast<unsigned>(sizes.size()), &params);
  if (ZDICT_isError(dict_size)) {
    return {};
  }

  dict.resize(dict_size);
  return dict;
}

ProcessedFile process_term_bank(const std::string& content, const ZSTD_CDict* cdict) {
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
  // cdict 为空时 refCDict(nullptr) 即清除引用，退回普通压缩。
  ZSTD_CCtx_refCDict(cctx, cdict);

  for (auto& term : out) {
    if (processed.data.size() > kMaxDataBufferBytes) {
      FUSHI_LOGW("term bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      FUSHI_LOGW("term bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
      break;
    }

    const std::string_view glossary = term.glossary.str;
    if (glossary.size() > kMaxGlossarySizeBytes) {
      FUSHI_LOGW("glossary too large (%zu bytes), skipping entry", glossary.size());
      continue;
    }

    uint64_t glossary_hash = XXH3_64bits(glossary.data(), glossary.size());
    auto it = processed.glossaries.find(glossary_hash);
    if (it == processed.glossaries.end()) {
      const size_t bound = ZSTD_compressBound(glossary.size());
      compressed.resize(bound);
      const size_t compressed_size = ZSTD_compress2(cctx, compressed.data(), bound, glossary.data(), glossary.size());
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
      FUSHI_LOGW("expression too long (%zu bytes), skipping entry", expr.size());
      continue;
    }
    if (reading.size() > std::numeric_limits<uint16_t>::max()) {
      FUSHI_LOGW("reading too long (%zu bytes), skipping entry", reading.size());
      continue;
    }
    if (definition_tags.size() > std::numeric_limits<uint8_t>::max() ||
        term.rules.size() > std::numeric_limits<uint8_t>::max() ||
        term.term_tags.size() > std::numeric_limits<uint8_t>::max()) {
      FUSHI_LOGW("tags/rules too long, skipping entry");
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
    // v2 term 记录追加段（上游 909c854）：Yomitan score，排序信号（JMdict 系词典
    // 用它区分常用/罕用词形）。v1 读侧到 term_tags 结束，v2 读侧版本门控读取。
    write_val<int32_t>(processed.data, static_cast<int32_t>(term.score));

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
      FUSHI_LOGW("meta bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      FUSHI_LOGW("meta bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
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
    } else if (mode == "pitch" || mode == "ipa") {
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
//   -- v2 only (marker .fushidicts_2), appended after the meanings pair --
//   [u8 stat_count] then per stat:  [u8 key_len][key][u16 val_len][val]
//                                   full stats key/value pairs (JLPT, grade,
//                                   freq, ...) minus the radical/strokes keys
//                                   already extracted above (借鉴上游 64afa2f 的
//                                   stats 保留能力). v1 readers never touch this
//                                   region; v2 readers gate on the dict-level
//                                   format version, so v1 records stay readable.
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

// 收集 stats 里 radical/strokes 之外的全部键值对（值归一成字符串：带引号的经
// glaze 反转义，数字/布尔保留原 token）。std::map 使键有序稳定；展示排序本就由
// UI/tag 元数据决定，不依赖 bank 原始顺序。
std::vector<std::pair<std::string, std::string>> collect_kanji_stats(std::string_view stats_json) {
  std::vector<std::pair<std::string, std::string>> out;
  if (stats_json.empty()) {
    return out;
  }
  std::map<std::string, glz::raw_json_view> raw;
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(raw, stats_json);
  if (error) {
    return out;
  }
  for (auto& [key, val] : raw) {
    if (key == "radical" || key == "rad" || key == "kangxi_radical" || key == "strokes" || key == "stroke count") {
      continue;  // 已提取进专用字段，避免重复
    }
    if (key.empty() || key.size() > std::numeric_limits<uint8_t>::max()) {
      continue;
    }
    std::string value;
    std::string_view token = val.str;
    if (!token.empty() && token.front() == 0x22) {
      if (glz::read_json(value, token)) {
        continue;
      }
    } else {
      value.assign(token);
    }
    if (value.size() > std::numeric_limits<uint16_t>::max()) {
      continue;
    }
    out.emplace_back(key, std::move(value));
    if (out.size() >= std::numeric_limits<uint8_t>::max()) {
      break;
    }
  }
  return out;
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
      FUSHI_LOGW("kanji bank data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      break;
    }
    if (processed.count >= kMaxEntriesPerBank) {
      FUSHI_LOGW("kanji bank entry count exceeded %zu, stopping", kMaxEntriesPerBank);
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
      FUSHI_LOGW("kanji field too long, skipping entry");
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
      FUSHI_LOGW("kanji meanings too large (%zu bytes), skipping entry", meanings_joined.size());
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

    // v2 stats 追加段（见上方 S0 契约注释）。
    const auto stats_kv = collect_kanji_stats(kanji.stats.str);
    write_val<uint8_t>(processed.data, static_cast<uint8_t>(stats_kv.size()));
    for (const auto& [stat_key, stat_value] : stats_kv) {
      write_val<uint8_t>(processed.data, static_cast<uint8_t>(stat_key.size()));
      write_str(processed.data, stat_key);
      write_val<uint16_t>(processed.data, static_cast<uint16_t>(stat_value.size()));
      write_str(processed.data, stat_value);
    }

    processed.offsets.emplace_back(XXH3_64bits(character.data(), character.size()), offset);
    processed.count++;
  }
  ZSTD_freeCCtx(cctx);

  return processed;
}

void write_kanji(std::ofstream& file, std::vector<std::pair<uint64_t, uint64_t>>& offsets, const Zip& zip,
                 const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram,
                 ankerl::unordered_dense::map<uint64_t, uint64_t>& glossaries,
                 const std::string& breadcrumb_dir) {
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
      FUSHI_LOGW("total kanji entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
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

  int bank_seq = 0;
  for (int file_index : files) {
    // Main (serial) import thread: record the bank we are about to submit before
    // fanning out decompression to a worker. If a worker hard-crashes (SEH), the
    // last breadcrumb pins the crash to this bank +/- the concurrency window.
    fushi::import_breadcrumb::set(breadcrumb_dir,
                                  "yomitan: kanji_bank #" + std::to_string(bank_seq++) + " / " +
                                      zip.entries[file_index].name);
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
                 const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram,
                 const std::string& breadcrumb_dir, const ZSTD_CDict* cdict) {
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
      FUSHI_LOGW("total term entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
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

  int bank_seq = 0;
  for (int file_index : files) {
    fushi::import_breadcrumb::set(breadcrumb_dir,
                                  "yomitan: term_bank #" + std::to_string(bank_seq++) + " / " +
                                      zip.entries[file_index].name);
    threads.push_back(std::async(
        std::launch::async, [&zip, file_index, cdict]() { return process_term_bank(zip.read(file_index), cdict); }));

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
                const std::vector<int>& files, uint64_t& write_offset, ImportResult& result, bool low_ram,
                const std::string& breadcrumb_dir) {
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
      FUSHI_LOGW("total meta entries would exceed %zu, stopping import of further banks", kMaxTotalEntries);
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

  int bank_seq = 0;
  for (int file_index : files) {
    fushi::import_breadcrumb::set(breadcrumb_dir,
                                  "yomitan: meta_bank #" + std::to_string(bank_seq++) + " / " +
                                      zip.entries[file_index].name);
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

// Append one media record [u16 path_len][path][u32 blob_size][blob] to `media`,
// recording (normalized_path, record_offset) for the sorted index. Shared by the
// yomitan-zip writer and the .mdd writer so the on-disk media format stays
// byte-identical (the query side binary-searches media.idx by path). Returns
// false if the record was skipped (path too long).
// write_pos is u64 to match the on-disk u64 record offsets: multi-part MDD
// dictionaries (OALD ships ~3.7GB of mp3) sit right under the u32 cliff, and a
// u32 accumulator would wrap silently past 4GB -> garbage offsets in media.idx.
bool append_media_record(std::ofstream& media, uint64_t& write_pos,
                         std::vector<std::pair<std::string, uint64_t>>& index_entries,
                         std::string path, const void* blob, size_t blob_size) {
  path = fushidicts::normalize_media_path(std::move(path));
  if (path.size() > std::numeric_limits<uint16_t>::max()) {
    FUSHI_LOGW("media path too long (%zu bytes), skipping", path.size());
    return false;
  }
  uint64_t record_start = write_pos;
  std::vector<char> buf;
  write_val<uint16_t>(buf, static_cast<uint16_t>(path.size()));
  write_str(buf, path);
  write_val<uint32_t>(buf, static_cast<uint32_t>(blob_size));
  write_bytes(buf, blob, blob_size);
  media.write(buf.data(), static_cast<std::streamsize>(buf.size()));
  write_pos += buf.size();
  index_entries.emplace_back(std::move(path), record_start);
  return true;
}

// Finalize media.idx: [u32 count][u64 record_offset x count], sorted by path.
void write_media_idx(std::ofstream& media_idx,
                     std::vector<std::pair<std::string, uint64_t>>& index_entries) {
  std::ranges::sort(index_entries);
  std::vector<char> index_buf;
  write_val<uint32_t>(index_buf, static_cast<uint32_t>(index_entries.size()));
  for (const auto& [name, offset] : index_entries) {
    write_val<uint64_t>(index_buf, offset);
  }
  media_idx.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
}

size_t write_media(const std::string& path, const Zip& zip, const std::vector<int>& files,
                   const std::string& breadcrumb_dir) {
  if (files.empty()) {
    return 0;
  }

  std::ofstream media(fushi::fs_path(path + "/media.bin"), std::ios::binary);
  std::ofstream media_idx(fushi::fs_path(path + "/media.idx"), std::ios::binary);
  setup_stream_exceptions(media);
  setup_stream_exceptions(media_idx);

  size_t media_count = 0;
  uint64_t write_pos = 0;
  std::vector<std::pair<std::string, uint64_t>> index_entries;
  int media_seq = 0;
  for (int file_index : files) {
    // write_media runs on its own std::async thread (in parallel with the term/
    // meta/kanji loop), so this breadcrumb interleaves with theirs -- the stage
    // prefix still tells whether the last touched step was media decompression.
    fushi::import_breadcrumb::set(breadcrumb_dir,
                                  "yomitan: media #" + std::to_string(media_seq++) + " / " +
                                      zip.entries[file_index].name);
    auto media_file = zip.read_media(file_index);
    if (!media_file.has_value()) {
      continue;
    }
    if (append_media_record(media, write_pos, index_entries, std::move(media_file->path),
                            media_file->blob.data(), media_file->blob.size())) {
      media_count++;
    }
  }

  write_media_idx(media_idx, index_entries);
  return media_count;
}

// Import one or more .mdd files (MDX media companions) into an already-written
// dictionary directory, producing media.bin/media.idx that the query side +
// popup image:// scheme consume unchanged. All parts merge into ONE sorted
// index -- the query side binary-searches a single media.idx, so writing per
// file would truncate the previous part's store. Files are parsed one at a
// time so peak memory stays one part (BUG-1261: OALD's parts total ~3.7GB).
// Media failure never aborts the host dictionary; an unreadable/broken part is
// skipped and the rest still mount.
// A file that is not inside any .mdd but must still be reachable through the
// media store — e.g. the "NLT.js" / "oaldpex.js" sitting next to the .mdx that
// the entries reference with a bare <script src>. Serving those from the same
// store means the popup has ONE way to fetch a dictionary asset by name.
struct ExtraMediaFile {
  std::string path;   // media key, already dictionary-relative
  std::string bytes;
};

size_t import_mdd_into(const std::vector<std::string>& mdd_paths, const std::string& dict_dir,
                       const std::vector<ExtraMediaFile>& extra_files = {}) {
  std::ofstream mbin;
  std::ofstream midx;
  bool opened = false;
  size_t count = 0;
  uint64_t write_pos = 0;
  std::vector<std::pair<std::string, uint64_t>> index_entries;

  for (const auto& mdd_path : mdd_paths) {
    std::ifstream f(fushi::fs_path(mdd_path), std::ios::binary | std::ios::ate);
    if (!f) continue;
    auto n = f.tellg();
    if (n <= 0) continue;
    std::vector<uint8_t> data(static_cast<size_t>(n));
    f.seekg(0);
    f.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(n));

    std::vector<MddEntry> media;
    try {
      media = mdx_reader::parse_mdd(data.data(), data.size());
    } catch (const std::exception& e) {
      FUSHI_LOGW("mdd parse failed (%s), continuing without this part", e.what());
      continue;
    }
    if (media.empty()) continue;

    // Lazily create the store on the first non-empty part: zero usable parts
    // must leave no (empty) media.bin/media.idx behind, same as before.
    if (!opened) {
      mbin.open(fushi::fs_path(dict_dir + "/media.bin"), std::ios::binary);
      midx.open(fushi::fs_path(dict_dir + "/media.idx"), std::ios::binary);
      setup_stream_exceptions(mbin);
      setup_stream_exceptions(midx);
      opened = true;
    }
    for (auto& m : media) {
      if (append_media_record(mbin, write_pos, index_entries, std::move(m.path), m.blob.data(),
                              m.blob.size())) {
        count++;
      }
    }
  }

  // Loose siblings share the store, so a dictionary with no usable .mdd at all
  // still gets one created for them.
  for (const auto& e : extra_files) {
    if (e.path.empty() || e.bytes.empty()) continue;
    if (!opened) {
      mbin.open(fushi::fs_path(dict_dir + "/media.bin"), std::ios::binary);
      midx.open(fushi::fs_path(dict_dir + "/media.idx"), std::ios::binary);
      setup_stream_exceptions(mbin);
      setup_stream_exceptions(midx);
      opened = true;
    }
    if (append_media_record(mbin, write_pos, index_entries, std::string(e.path), e.bytes.data(),
                            e.bytes.size())) {
      count++;
    }
  }

  if (!opened) return 0;
  write_media_idx(midx, index_entries);
  return count;
}

// MDict convention: media lives in Foo.mdd plus numbered overflow parts
// Foo.1.mdd / Foo.2.mdd / ... (large dictionaries -- OALD splits ~3.7GB of
// pronunciation mp3 across three numbered parts). Parts are strictly
// sequential, so stop at the first gap. BUG-1261: only Foo.mdd was mounted,
// leaving every blob in the numbered parts (all OALD audio + example images)
// unreachable.
std::vector<std::string> collect_sibling_mdd_paths(const std::string& mdx_path) {
  std::vector<std::string> mdd_paths;
  auto mdd_path = fushi::fs_path(mdx_path);
  mdd_path.replace_extension(".mdd");
  if (std::filesystem::exists(mdd_path)) {
    mdd_paths.push_back(fushi::fs_to_utf8(mdd_path));
  }
  for (int part = 1;; ++part) {
    auto part_path = fushi::fs_path(mdx_path);
    part_path.replace_extension("." + std::to_string(part) + ".mdd");
    if (!std::filesystem::exists(part_path)) break;
    mdd_paths.push_back(fushi::fs_to_utf8(part_path));
  }
  return mdd_paths;
}

// Term records for a simple dictionary. The glossary blobs they point at are
// already on disk, so each record carries its final blob offset and only the
// per-term bytes are held in memory.
struct SimpleDictRecords {
  std::vector<char> data;
  std::vector<std::pair<uint64_t, uint64_t>> offsets;  // (headword hash, offset within data)
  uint64_t blob_region_size = 0;                       // bytes of glossary blobs written ahead of data
  size_t count = 0;
};

// A simple dictionary's output directory, opened before any entry is processed
// so glossary blobs can be streamed straight into blobs.bin.
struct SimpleDictSink {
  std::string title;  // sanitized
  std::string path;
  std::ofstream blobs;
};

// Incremental builder for the simple-dictionary (MDX / StarDict / DSL) record
// stream. The per-entry logic lives here exactly once so the whole-vector
// callers and the streaming MDX caller cannot drift apart on caps, glossary
// dedup or record layout.
//
// Feeding entries one at a time, straight through to disk, is what lets a large
// dictionary import at all: the 389 MB sample in BUG-2160 used to need the file
// buffer, the fully decompressed record stream, a copy of every entry, the whole
// compressed glossary table AND a second copy of that table staged for writing.
class SimpleEntryAccumulator {
 public:
  // `blobs` is the dictionary's blobs.bin, already open. Each newly-seen
  // glossary is compressed and written to it immediately; only its offset and
  // size are remembered (24 bytes), never the compressed bytes. That is what
  // makes peak memory scale with the entry COUNT rather than with the
  // dictionary's total text -- the 389 MB sample expands to 8.6 GB of HTML,
  // whose compressed form alone is 1.24 GB.
  explicit SimpleEntryAccumulator(std::ostream& blobs) : blobs_(blobs), cctx_(ZSTD_createCCtx()) {}
  ~SimpleEntryAccumulator() {
    if (cctx_) ZSTD_freeCCtx(cctx_);
  }
  SimpleEntryAccumulator(const SimpleEntryAccumulator&) = delete;
  SimpleEntryAccumulator& operator=(const SimpleEntryAccumulator&) = delete;

  // Size the record buffers up front when the entry count is known. Growing by
  // doubling instead costs a multi-million-entry dictionary both the overshoot
  // (up to 2x the bytes it needs) and a transient copy of the whole buffer at
  // every reallocation, right where memory is tightest.
  void reserve(size_t entries) {
    if (entries == 0 || entries > kMaxTotalEntries) return;
    records_.offsets.reserve(entries);
    records_.data.reserve(entries * kEstimatedRecordBytes);
  }

  // Returns false once a whole-dictionary cap is hit; the caller should stop
  // feeding, and anything fed afterwards is ignored. An entry rejected on its
  // own merits (oversized glossary or headword) is skipped but returns true.
  bool add(std::string_view headword, std::string_view glossary) {
    if (!cctx_ || stopped_) return false;

    if (records_.data.size() > kMaxDataBufferBytes) {
      FUSHI_LOGW("simple entries data buffer exceeded %zu bytes, stopping", kMaxDataBufferBytes);
      stopped_ = true;
      return false;
    }
    // BUG-1904：这里是 MDX / DSL 的**整本词典**条目流，不是 Yomitan 的单个
    // term_bank_N.json。kMaxEntriesPerBank 是给后者设计的——一本 Yomitan 词典摊成
    // 几十上百个 bank、每个几千条，100 万/bank 绰绰有余；而 MDX 整本词典就是这一
    // 个流，于是同一个常量在两种布局下语义完全不同。实测大辞林第四版声明
    // 1,086,308 条，被这里砍到正好 1,000,000（少 86,308），导入还报 success。
    // 整词典级别的 OOM 保护应当是 kMaxTotalEntries；数据量本身另有
    // kMaxDataBufferBytes（1 GB）与单条 kMaxGlossarySizeBytes 兜底，三道都还在。
    if (records_.count >= kMaxTotalEntries) {
      FUSHI_LOGW("simple entries count exceeded %zu, stopping", kMaxTotalEntries);
      stopped_ = true;
      return false;
    }

    if (glossary.size() > kMaxGlossarySizeBytes) {
      FUSHI_LOGW("glossary too large (%zu bytes), skipping entry", glossary.size());
      return true;
    }
    // Checked before the glossary is compressed: a rejected entry must not leave
    // an unreferenced blob behind in the dedup table.
    if (headword.size() > std::numeric_limits<uint16_t>::max()) {
      FUSHI_LOGW("expression too long (%zu bytes), skipping entry", headword.size());
      return true;
    }

    // Identical glossaries share one blob, which is what collapses @@@LINK=
    // aliases onto their lemma (BUG-1665). The dedup table now holds a
    // (offset, size) pair instead of the compressed bytes.
    uint64_t glossary_hash = XXH3_64bits(glossary.data(), glossary.size());
    auto it = blob_of_.find(glossary_hash);
    if (it == blob_of_.end()) {
      const size_t bound = ZSTD_compressBound(glossary.size());
      compressed_.resize(bound);
      const size_t compressed_size =
          ZSTD_compressCCtx(cctx_, compressed_.data(), bound, glossary.data(), glossary.size(), 0);
      if (ZSTD_isError(compressed_size)) {
        throw std::runtime_error("failed to compress glossary");
      }
      BlobRef ref{records_.blob_region_size, static_cast<uint32_t>(compressed_size)};
      blobs_.write(compressed_.data(), static_cast<std::streamsize>(compressed_size));
      records_.blob_region_size += compressed_size;
      it = blob_of_.emplace(glossary_hash, ref).first;
    }
    const BlobRef blob = it->second;

    uint64_t offset = records_.data.size();

    write_val<uint8_t>(records_.data, 0);
    write_val<uint16_t>(records_.data, static_cast<uint16_t>(headword.size()));
    write_str(records_.data, headword);
    write_val<uint16_t>(records_.data, 0);  // reading_len = 0

    // The blob is already on disk at a known offset, so the term record carries
    // the final value -- no placeholder and no whole-file patch-up pass.
    write_val<uint64_t>(records_.data, blob.offset);
    write_val<uint32_t>(records_.data, blob.size);

    write_val<uint8_t>(records_.data, 0);  // def_tags_len = 0
    // rules = "*": simple dicts have no per-term POS. The wildcard makes
    // filter_by_pos keep these terms for deinflected (inflected-form) lookups
    // instead of erasing them; see Deinflector::pos_to_conditions. Stored as a
    // normal variable-length rules string (reader consumes it by length).
    write_val<uint8_t>(records_.data, 1);  // rules_len = 1
    write_val<uint8_t>(records_.data, static_cast<uint8_t>('*'));
    write_val<uint8_t>(records_.data, 0);  // term_tags_len = 0

    records_.offsets.emplace_back(XXH3_64bits(headword.data(), headword.size()), offset);
    records_.count++;
    return true;
  }

  SimpleDictRecords finish() { return std::move(records_); }

 private:
  // Fixed part of a term record (21 B) plus room for a typical headword; only a
  // sizing hint, the buffer still grows if the estimate is low.
  static constexpr size_t kEstimatedRecordBytes = 40;

  struct BlobRef {
    uint64_t offset;
    uint32_t size;
  };

  std::ostream& blobs_;
  ankerl::unordered_dense::map<uint64_t, BlobRef> blob_of_;
  SimpleDictRecords records_;
  ZSTD_CCtx* cctx_ = nullptr;
  std::vector<char> compressed_;
  bool stopped_ = false;
};

// Declared here so import_mdx can drive the same two-phase write the
// vector-taking entry point uses. Both are defined next to write_simple_dict.
SimpleDictSink open_simple_dict(const std::string& title, const std::string& output_dir);
void finish_simple_dict(SimpleDictSink& sink, SimpleDictRecords&& records, const std::string& styles_css,
                        ImportResult& result);

// Read a whole file into a string. "" if absent/empty/unreadable.
std::string read_file_text(const std::filesystem::path& p) {
  std::ifstream in(p, std::ios::binary | std::ios::ate);
  if (!in) return "";
  auto n = in.tellg();
  if (n <= 0) return "";
  std::string text(static_cast<size_t>(n), '\0');
  in.seekg(0);
  in.read(text.data(), static_cast<std::streamsize>(n));
  return text;
}

// HTML tag/attribute names are case-insensitive, so the scan below must be too.
char ascii_lower(char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; }

size_t ci_find(std::string_view haystack, std::string_view needle, size_t from) {
  if (needle.empty() || haystack.size() < needle.size()) return std::string_view::npos;
  for (size_t i = from; i + needle.size() <= haystack.size(); i++) {
    size_t j = 0;
    while (j < needle.size() && ascii_lower(haystack[i + j]) == ascii_lower(needle[j])) j++;
    if (j == needle.size()) return i;
  }
  return std::string_view::npos;
}

bool ends_with_ci(std::string_view text, std::string_view suffix) {
  if (text.size() < suffix.size()) return false;
  const size_t off = text.size() - suffix.size();
  for (size_t i = 0; i < suffix.size(); i++) {
    if (ascii_lower(text[off + i]) != ascii_lower(suffix[i])) return false;
  }
  return true;
}

// Definitions to scan for <link>/<script> tags. The tags are per-entry
// boilerplate in MDict dictionaries, so this only has to be large enough to
// survive a few leading entries that are pure @@@LINK redirects or stubs.
constexpr size_t kCssScanEntryLimit = 50;

// A bare file name safe to resolve against the dictionary's own directory:
// no separators, no "..", no drive letter. Everything else is dropped rather
// than sanitised, so a crafted href can never escape that directory.
bool is_plain_file_name(std::string_view name) {
  if (name.empty() || name.size() > 255) return false;
  if (name == "." || name == "..") return false;
  return name.find_first_of("/\\:") == std::string_view::npos;
}

// Collect the sibling files an MDX's own definitions ask for: the href of every
// <link ...href="....css"...>, or the src of every <script ...src="....js"...>.
//
// MDict dictionaries carry these tags in every entry, and the file they name
// does NOT have to match the .mdx stem — "NLT（話し言葉）.mdx" ships its styles
// as "NLT.css". Reading the name the HTML actually asks for replaces guessing
// it from the stem.
//
// Only bare file names are returned (is_plain_file_name), so a reference into a
// subdirectory — "scripts/foo-jquery.js", which lives in the .mdd rather than
// next to the .mdx — is skipped here and served from the media store instead.
// Only the first entries are scanned: the tags are boilerplate repeated per
// entry, so a handful of definitions surfaces every referenced file in practice.
std::vector<std::string> extract_referenced_names(const std::vector<SimpleEntry>& entries, size_t scan_limit,
                                                  std::string_view tag_name, std::string_view attr,
                                                  std::string_view required_ext) {
  std::vector<std::string> names;
  const size_t limit = std::min(scan_limit, entries.size());

  for (size_t i = 0; i < limit; i++) {
    std::string_view html = entries[i].definition;
    for (size_t pos = 0; (pos = ci_find(html, tag_name, pos)) != std::string_view::npos;) {
      const size_t tag_end = html.find('>', pos);
      if (tag_end == std::string_view::npos) break;
      const std::string_view tag = html.substr(pos, tag_end - pos);
      pos = tag_end + 1;

      const size_t attr_pos = ci_find(tag, attr, 0);
      if (attr_pos == std::string_view::npos) continue;
      const size_t eq = tag.find('=', attr_pos + attr.size());
      if (eq == std::string_view::npos) continue;
      size_t vs = tag.find_first_not_of(" \t\r\n", eq + 1);
      if (vs == std::string_view::npos) continue;
      const char quote = tag[vs];
      if (quote != '"' && quote != '\'') continue;
      const size_t ve = tag.find(quote, vs + 1);
      if (ve == std::string_view::npos) continue;

      const std::string_view value = tag.substr(vs + 1, ve - vs - 1);
      if (!is_plain_file_name(value)) continue;
      if (!ends_with_ci(value, required_ext)) continue;

      std::string name(value);
      if (std::find(names.begin(), names.end(), name) == names.end()) {
        names.push_back(std::move(name));
      }
    }
  }

  return names;
}

std::vector<std::string> extract_linked_css_names(const std::vector<SimpleEntry>& entries, size_t scan_limit) {
  return extract_referenced_names(entries, scan_limit, "<link", "href", ".css");
}

std::vector<std::string> extract_linked_script_names(const std::vector<SimpleEntry>& entries, size_t scan_limit) {
  return extract_referenced_names(entries, scan_limit, "<script", "src", ".js");
}

// The stylesheet(s) to inline as the dictionary's styles.css.
//
// Preferred source is whatever the definitions <link> to, resolved inside the
// .mdx's own directory (that is where MDict keeps them, and it is the only
// directory consulted). The stem-named sibling (Foo.mdx -> Foo.css) stays as
// the fallback for dictionaries whose entries carry no <link> at all.
// Multiple stylesheets are concatenated in first-seen order, matching the
// cascade a browser would build from the same tags.
std::string read_sibling_css(const std::string& primary_path, const std::vector<SimpleEntry>& entries) {
  const auto dir = fushi::fs_path(primary_path).parent_path();

  std::string combined;
  for (const auto& name : extract_linked_css_names(entries, kCssScanEntryLimit)) {
    std::string css = read_file_text(dir / fushi::fs_path(name));
    if (css.empty()) continue;
    if (!combined.empty()) combined += "\n";
    combined += css;
  }
  if (!combined.empty()) return combined;

  auto css_path = fushi::fs_path(primary_path);
  css_path.replace_extension(".css");
  return read_file_text(css_path);
}

ImportResult import_mdx(const std::string& mdx_path, const std::string& output_dir) {
  // Mapped, not read: a 400 MB dictionary would otherwise open with a 400 MB
  // heap buffer that stays resident for the whole import. Mapped pages are clean
  // and file-backed, so the OS reclaims them under pressure instead of the
  // process being killed for holding them (iOS jetsam).
  memory::mapped_file mapped = memory::map_rd(mdx_path);
  if (!mapped) {
    return {.success = false, .errors = {"failed to open MDX file"}};
  }
  struct MappingGuard {
    memory::mapped_file file;
    ~MappingGuard() { memory::unmap(file); }
  } mapping_guard{mapped};

  // The <link>/<script> scans only look at the first kCssScanEntryLimit
  // definitions, so retain exactly that many as they stream past. That is the
  // only reason to hold on to any entry at all.
  std::vector<SimpleEntry> css_scan_sample;
  ImportResult result;
  result.detected_type = "term";
  std::string sanitized;

  try {
    // The dictionary directory is opened from the header, before any entry is
    // read, so glossary blobs can stream straight to disk while the records
    // arrive. Nothing here ever holds the whole dictionary.
    std::optional<SimpleDictSink> sink;
    std::optional<SimpleEntryAccumulator> accumulator;

    mdx_reader::parse_streaming(
        mapped.data, mapped.size,
        [&](std::string&& key, std::string&& definition) {
          if (key.empty()) return;
          // Unresolvable @@@LINK= (circular or dangling) — already attempted in mdx_reader
          if (definition.starts_with("@@@LINK=")) return;
          if (css_scan_sample.size() < kCssScanEntryLimit) {
            css_scan_sample.push_back({key, definition});
          }
          accumulator->add(key, definition);
        },
        [&](const MdxMeta& meta) {
          std::string title =
              meta.title.empty() ? fushi::fs_to_utf8(fushi::fs_path(mdx_path).stem()) : meta.title;
          sink.emplace(open_simple_dict(title, output_dir));
          sanitized = sink->title;
          result.title = sanitized;
          accumulator.emplace(sink->blobs);
          accumulator->reserve(meta.entry_count);
        });

    if (!accumulator) {
      throw std::runtime_error("MDX parse error: no dictionary header");
    }

    // MDX glossaries are HTML that <link> a stylesheet sitting next to the .mdx.
    // Inline it as the dict's styles.css so the popup's constructDictCss scopes
    // and injects it; otherwise the definitions render unstyled. The name comes
    // from the <link> tags themselves (it need not match the .mdx stem), falling
    // back to the stem-named sibling. Nothing found -> empty -> no styles.css.
    //
    // Inlining, rather than letting the rewritten <link> fetch it over
    // dictmedia://, is what keeps the rules scoped to this dictionary: these
    // sheets style bare tags (table/th/td), which unscoped would repaint every
    // other dictionary's tables in the shared popup document.
    std::string styles_css = read_sibling_css(mdx_path, css_scan_sample);

    finish_simple_dict(*sink, accumulator->finish(), styles_css, result);
    result.success = true;
  } catch (const std::exception& e) {
    result.success = false;
    result.errors.emplace_back(std::string("MDX parse error: ") + e.what());
  }

  if (!result.success && !sanitized.empty()) {
    std::filesystem::remove_all(fushi::fs_path(output_dir) / fushi::fs_path(sanitized));
  }

  // Auto-mount the media companions (Foo.mdx -> Foo.mdd + numbered overflow
  // parts Foo.N.mdd) into the same dict dir, so <img>/<link>/sound:// in the
  // glossaries resolve via the image:// media scheme.
  // Media is best-effort: a missing/broken .mdd never fails the dictionary.
  // The scripts the entries reference with a bare <script src="foo.js"> live
  // next to the .mdx, not inside the .mdd. Fold them into the same media store
  // so the popup fetches every dictionary asset — .mdd or loose sibling — by
  // one name through one channel.
  if (result.success) {
    const auto dir = fushi::fs_path(mdx_path).parent_path();
    std::vector<ExtraMediaFile> extra;
    for (const auto& name : extract_linked_script_names(css_scan_sample, kCssScanEntryLimit)) {
      std::string bytes = read_file_text(dir / fushi::fs_path(name));
      if (!bytes.empty()) extra.push_back({name, std::move(bytes)});
    }

    std::vector<std::string> mdd_paths = collect_sibling_mdd_paths(mdx_path);
    if (!mdd_paths.empty() || !extra.empty()) {
      import_mdd_into(mdd_paths, output_dir + "/" + result.title, extra);
    }
  }

  return result;
}

ImportResult import_mdx_from_zip(Zip& zip, const std::string& output_dir) {
  int mdx_index = -1;
  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.size() > 4 && name.substr(name.size() - 4) == ".mdx") {
      mdx_index = static_cast<int>(i);
      break;
    }
  }
  if (mdx_index < 0) {
    return {.success = false, .errors = {"no .mdx file found in zip"}};
  }

  std::string temp_dir = output_dir + "/_mdx_temp";
  std::filesystem::create_directories(fushi::fs_path(temp_dir));

  std::string mdx_filename = fushi::fs_to_utf8(fushi::fs_path(zip.entries[mdx_index].name).filename());
  std::string stem = fushi::fs_to_utf8(fushi::fs_path(mdx_filename).stem());
  std::string temp_path = temp_dir + "/" + mdx_filename;

  auto extract = [&](int idx, const std::string& out_name) {
    std::string content = zip.read(idx);
    std::ofstream out(fushi::fs_path(temp_dir + "/" + out_name), std::ios::binary);
    setup_stream_exceptions(out);
    out.write(content.data(), static_cast<std::streamsize>(content.size()));
  };

  // Extract the .mdx plus its sibling media (.mdd, incl. numbered overflow
  // parts Foo.N.mdd) / stylesheet (.css), flattened next to the .mdx so
  // import_mdx's sibling auto-mount (collect_sibling_mdd_paths) finds them.
  auto is_numbered_part_stem = [&stem](const std::string& fstem) {
    // "Foo.3" for stem "Foo": stem + '.' + at least one digit, digits only.
    if (fstem.size() < stem.size() + 2) return false;
    if (fstem.compare(0, stem.size(), stem) != 0 || fstem[stem.size()] != '.') return false;
    for (size_t k = stem.size() + 1; k < fstem.size(); ++k) {
      if (fstem[k] < '0' || fstem[k] > '9') return false;
    }
    return true;
  };
  extract(mdx_index, mdx_filename);
  for (size_t i = 0; i < zip.entries.size(); i++) {
    if (static_cast<int>(i) == mdx_index) continue;
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/') continue;
    std::string fn = fushi::fs_to_utf8(fushi::fs_path(name).filename());
    std::string ext = fushi::fs_to_utf8(fushi::fs_path(fn).extension());
    std::string fstem = fushi::fs_to_utf8(fushi::fs_path(fn).stem());
    // .css/.js are taken regardless of stem: a dictionary's stylesheet and
    // scripts are routinely named differently from its .mdx ("NLT（話し言葉）.mdx"
    // + "NLT.css" + "NLT.js"), and import_mdx resolves the ones its <link>/
    // <script> tags actually name. Extracting a file the entries never
    // reference costs one file in the temp dir and is otherwise inert.
    if ((ext == ".mdd" && (fstem == stem || is_numbered_part_stem(fstem))) || ext == ".css" ||
        ext == ".js") {
      extract(static_cast<int>(i), fstem + ext);
    }
  }

  auto result = import_mdx(temp_path, output_dir);
  std::filesystem::remove_all(fushi::fs_path(temp_dir));
  return result;
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
  std::filesystem::create_directories(fushi::fs_path(temp_dir));
  std::string ifo_path;

  for (size_t i = 0; i < zip.entries.size(); i++) {
    const auto& name = zip.entries[i].name;
    if (name.empty() || name.back() == '/') continue;
    std::string filename = fushi::fs_to_utf8(fushi::fs_path(name).filename());
    std::string ext = fushi::fs_to_utf8(fushi::fs_path(filename).extension());
    if (ext == ".ifo" || ext == ".idx" || ext == ".dict" || ext == ".syn" || filename.ends_with(".dict.dz")) {
      std::string out_path = temp_dir + "/" + filename;
      std::string content = zip.read(static_cast<int>(i));
      std::ofstream out(fushi::fs_path(out_path), std::ios::binary);
      out.write(content.data(), static_cast<std::streamsize>(content.size()));
      if (ext == ".ifo") ifo_path = out_path;
    }
  }

  if (ifo_path.empty()) {
    std::filesystem::remove_all(fushi::fs_path(temp_dir));
    return {.success = false, .errors = {"no .ifo file found in zip"}};
  }

  auto result = import_stardict(ifo_path, output_dir);
  std::filesystem::remove_all(fushi::fs_path(temp_dir));
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
  std::ifstream file(fushi::fs_path(dsl_path), std::ios::binary | std::ios::ate);
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
    title = fushi::fs_to_utf8(fushi::fs_path(dsl_path).stem());
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

ImportResult import_yomitan(Zip& zip, const std::string& output_dir, bool low_ram,
                            const std::string& breadcrumb_dir) {
  ImportResult result;
  fushi::import_breadcrumb::set(breadcrumb_dir, "yomitan: opened zip, reading index.json");
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

    std::filesystem::path dict_path = fushi::fs_path(output_dir) / fushi::fs_path(result.title);
    {
      auto canonical_parent = std::filesystem::weakly_canonical(fushi::fs_path(output_dir));
      auto canonical_child = std::filesystem::weakly_canonical(dict_path);
      auto rel = std::filesystem::relative(canonical_child, canonical_parent);
      if (rel.empty() || *rel.begin() == "..") {
        throw std::runtime_error("path traversal detected in dictionary title");
      }
    }
    std::string path = fushi::fs_to_utf8(dict_path);
    std::filesystem::create_directories(dict_path);

    {
      std::string index_buf;
      if (glz::write_json(index, index_buf)) {
        throw std::runtime_error("failed to write index.json");
      }
      std::ofstream index_out(fushi::fs_path(path + "/index.json"), std::ios::binary);
      index_out.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
      if (!index_out.good()) {
        throw std::runtime_error("failed to write index.json");
      }
    }

    int styles_idx = zip.find("styles.css");
    if (styles_idx >= 0) {
      std::string styles = zip.read(styles_idx);
      if (!styles.empty()) {
        std::ofstream styles_file(fushi::fs_path(path + "/styles.css"), std::ios::binary);
        setup_stream_exceptions(styles_file);
        styles_file.write(styles.data(), static_cast<std::streamsize>(styles.size()));
      }
    }

    const Files files = get_files(zip);
    result.detected_type = detect_type(files, zip);
    std::future<size_t> media_thread =
        std::async(std::launch::async, [&path, &zip, &files, &breadcrumb_dir]() {
          return write_media(path, zip, files.media_files, breadcrumb_dir);
        });

    // 上游 8993838：训练 zstd dictionary（可选，失败/样本不足即空）。训练成功则
    // 落盘 dict.zstd，term glossary 用 CDict 压缩；读侧凭 dict.zstd 是否存在决定
    // 是否挂 DDict（v2 marker 门控整个词典目录）。
    fushi::import_breadcrumb::set(breadcrumb_dir, "yomitan: training zstd dictionary");
    const std::vector<char> zstd_dict = train_zstd_dict(zip, files, low_ram);
    std::unique_ptr<ZSTD_CDict, decltype(&ZSTD_freeCDict)> cdict(nullptr, ZSTD_freeCDict);
    if (!zstd_dict.empty()) {
      cdict.reset(ZSTD_createCDict(zstd_dict.data(), zstd_dict.size(), 0));

      std::ofstream dict_file(fushi::fs_path(path + "/dict.zstd"), std::ios::binary);
      setup_stream_exceptions(dict_file);
      dict_file.write(zstd_dict.data(), static_cast<std::streamsize>(zstd_dict.size()));
    }

    std::ofstream blobs(fushi::fs_path(path + "/blobs.bin"), std::ios::binary);
    setup_stream_exceptions(blobs);
    std::vector<std::pair<uint64_t, uint64_t>> offsets;
    uint64_t write_offset = 0;
    write_terms(blobs, offsets, zip, files.term_banks, write_offset, result, low_ram, breadcrumb_dir, cdict.get());
    write_meta(blobs, offsets, zip, files.meta_banks, write_offset, result, low_ram, breadcrumb_dir);
    ankerl::unordered_dense::map<uint64_t, uint64_t> kanji_glossaries;
    write_kanji(blobs, offsets, zip, files.kanji_banks, write_offset, result, low_ram, kanji_glossaries, breadcrumb_dir);
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

    // v2 = 本批引入的格式阶梯（fork 首个版本升级）：kanji 记录带 stats 追加段 +
    // term glossary 可能使用 dict.zstd 训练字典。旧引擎认不出 v2 marker 会整目录
    // 不加载（降级后新导入词典不可见，不毁数据、重导可救）；v1 存量照读不变。
    std::ofstream sui(fushi::fs_path(path + "/.fushidicts_2"), std::ios::binary);
    result.success = true;
  } catch (const std::exception& e) {
    result.success = false;
    result.errors.emplace_back(e.what());
  }

  if (!result.success && !result.title.empty()) {
    std::filesystem::remove_all(fushi::fs_path(output_dir) / fushi::fs_path(result.title));
  }

  // Clean return (success or caught failure): drop the breadcrumb so the next
  // launch does not misreport this completed import as a crash.
  fushi::import_breadcrumb::clear(breadcrumb_dir);
  return result;
}

}  // end anonymous namespace

ImportResult dictionary_importer::write_simple_dict(const std::string& title, const std::vector<SimpleEntry>& entries,
                                                    const std::string& output_dir, const std::string& styles_css) {
  ImportResult result;
  result.detected_type = "term";
  std::string sanitized;
  try {
    SimpleDictSink sink = open_simple_dict(title, output_dir);
    sanitized = sink.title;
    result.title = sanitized;

    SimpleEntryAccumulator accumulator(sink.blobs);
    for (const auto& entry : entries) {
      if (!accumulator.add(entry.headword, entry.definition)) break;
    }
    finish_simple_dict(sink, accumulator.finish(), styles_css, result);
    result.success = true;
  } catch (const std::exception& e) {
    // The import runs on its own pthread; an escaped exception would terminate
    // the process rather than fail the import.
    result.success = false;
    result.errors.emplace_back(e.what());
  }

  if (!result.success && !sanitized.empty()) {
    std::filesystem::remove_all(fushi::fs_path(output_dir) / fushi::fs_path(sanitized));
  }
  return result;
}

namespace {

// Phase 1 of writing a simple dictionary: validate the title, create the
// directory and index.json, and open blobs.bin. This happens BEFORE entries are
// processed so the accumulator can stream glossary blobs straight into the file.
SimpleDictSink open_simple_dict(const std::string& title, const std::string& output_dir) {
  SimpleDictSink sink;
  sink.title = sanitize_title(title);

  std::filesystem::path dict_path = fushi::fs_path(output_dir) / fushi::fs_path(sink.title);
  {
    auto canonical_parent = std::filesystem::weakly_canonical(fushi::fs_path(output_dir));
    auto canonical_child = std::filesystem::weakly_canonical(dict_path);
    auto rel = std::filesystem::relative(canonical_child, canonical_parent);
    if (rel.empty() || *rel.begin() == "..") {
      throw std::runtime_error("path traversal detected in dictionary title");
    }
  }
  sink.path = fushi::fs_to_utf8(dict_path);
  std::filesystem::create_directories(dict_path);

  Index index;
  index.title = sink.title;
  index.format = 3;
  {
    std::string index_buf;
    if (glz::write_json(index, index_buf)) {
      throw std::runtime_error("failed to write index.json");
    }
    std::ofstream index_out(fushi::fs_path(sink.path + "/index.json"), std::ios::binary);
    index_out.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
    if (!index_out.good()) {
      throw std::runtime_error("failed to write index.json");
    }
  }

  sink.blobs.open(fushi::fs_path(sink.path + "/blobs.bin"), std::ios::binary);
  setup_stream_exceptions(sink.blobs);
  return sink;
}

// Phase 2: the glossary blob region is already in blobs.bin, so append the term
// records after it, then build the offset index, hash table and bloom filter.
// Writes the optional stylesheet and the format marker.
void finish_simple_dict(SimpleDictSink& sink, SimpleDictRecords&& records_in, const std::string& styles_css,
                        ImportResult& result) {
  SimpleDictRecords records = std::move(records_in);
  if (records.data.empty()) {
    throw std::runtime_error("empty dictionary");
  }

  if (!styles_css.empty()) {
    std::ofstream styles_file(fushi::fs_path(sink.path + "/styles.css"), std::ios::binary);
    setup_stream_exceptions(styles_file);
    styles_file.write(styles_css.data(), static_cast<std::streamsize>(styles_css.size()));
  }

  // Term records sit after the blob region, so their offsets shift by its size.
  // Shifted in place: a second vector here would be another 16 bytes per entry
  // alive at the peak, which on a multi-million-entry dictionary is real money.
  for (auto& [hash, offset] : records.offsets) {
    (void)hash;
    offset += records.blob_region_size;
  }

  sink.blobs.write(records.data.data(), static_cast<std::streamsize>(records.data.size()));
  uint64_t write_offset = records.blob_region_size + records.data.size();
  result.term_count = records.count;
  std::vector<char>().swap(records.data);

  if (records.offsets.empty()) {
    throw std::runtime_error("empty dictionary");
  }

  std::vector<std::pair<uint64_t, uint64_t>> hash_entries;
  auto offset_buf = build_offset_index(records.offsets, write_offset, hash_entries);
  std::vector<std::pair<uint64_t, uint64_t>>().swap(records.offsets);

  const std::string& path = sink.path;
  auto hash_thread = std::async(std::launch::async, [&hash_entries, &path]() {
    hash::linear table;
    table.build_to_file(hash_entries, path + "/hash.table");
    auto hashes = hash_entries | std::views::keys | std::ranges::to<std::vector>();
    hash::bloom::build_to_file(hashes, path + "/bloom.filter");
  });

  sink.blobs.write(offset_buf.data(), static_cast<std::streamsize>(offset_buf.size()));
  hash_thread.get();

  std::ofstream sui(fushi::fs_path(path + "/.fushidicts_1"), std::ios::binary);
}

}  // namespace

ImportResult dictionary_importer::import(const std::string& file_path, const std::string& output_dir, bool low_ram,
                                        const std::string& breadcrumb_dir) {
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
    return import_yomitan(zip, output_dir, low_ram, breadcrumb_dir);
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

#include "hoshidicts/query.hpp"
#include "hoshidicts/media_path.hpp"

#include <ankerl/unordered_dense.h>
#include <zstd.h>

#include "hoshidicts/platform.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <ranges>
#include <string>
#include <string_view>
#include <vector>

#include "hash/hash.hpp"
#include "json/yomitan_parser.hpp"
#include "memory/memory.hpp"
#include "util/fs_utf8.hpp"

namespace {

struct BlobReader {
  const uint8_t* ptr;
  const uint8_t* end;

  BlobReader(const uint8_t* data, size_t size) : ptr(data), end(data + size) {}

  template <typename T>
  [[nodiscard]] T read() {
    if (ptr + sizeof(T) > end) {
      ptr = end;
      return T{};
    }
    T val;
    std::memcpy(&val, ptr, sizeof(T));
    ptr += sizeof(T);
    return val;
  }

  [[nodiscard]] std::string_view read_str(uint32_t len) {
    if (ptr + len > end || ptr + len < ptr) {
      ptr = end;
      return {};
    }
    std::string_view result(reinterpret_cast<const char*>(ptr), len);
    ptr += len;
    return result;
  }

  [[nodiscard]] bool has(size_t n) const { return ptr + n <= end; }
};

}

struct DictionaryQuery::DictionaryData {
  hash::linear table;
  hash::bloom bloom;
  memory::mapped_file blobs;
  memory::mapped_file hash_table;
  memory::mapped_file bloom_filter;
  memory::mapped_file media;
  memory::mapped_file media_index;

  ~DictionaryData() {
    memory::unmap(blobs);
    memory::unmap(hash_table);
    memory::unmap(bloom_filter);
    memory::unmap(media);
    memory::unmap(media_index);
  }
};

DictionaryQuery::DictionaryQuery() = default;
DictionaryQuery::~DictionaryQuery() = default;

DictionaryQuery::DictionaryQuery(DictionaryQuery&&) noexcept = default;
DictionaryQuery& DictionaryQuery::operator=(DictionaryQuery&&) noexcept = default;

DictionaryQuery::Dictionary::Dictionary() = default;
DictionaryQuery::Dictionary::~Dictionary() = default;

DictionaryQuery::Dictionary::Dictionary(Dictionary&&) noexcept = default;
DictionaryQuery::Dictionary& DictionaryQuery::Dictionary::operator=(Dictionary&&) noexcept = default;

void DictionaryQuery::add_dict(const std::string& path, DictionaryType type) {
  if (!std::filesystem::is_regular_file(hoshi::fs_path(path + "/.hoshidicts_1"))) {
    return;
  }

  Dictionary dict;
  {
    std::ifstream index_in(hoshi::fs_path(path + "/index.json"), std::ios::binary);
    if (!index_in) {
      return;
    }
    std::string index_buf((std::istreambuf_iterator<char>(index_in)), {});
    Index index;
    if (glz::read_json(index, index_buf)) {
      return;
    }
    // Index::title is a std::string_view into index_buf (glaze parses strings
    // zero-copy). It MUST be copied into the owned dict.name *before* index_buf
    // leaves this scope. Reading index.title after the buffer was freed was a
    // use-after-free: the recycled heap chunk had its leading bytes overwritten
    // by an allocator free-list pointer, so dict.name became
    // "<garbage prefix> + <tail of title>" — rendered as U+FFFD (garbled
    // dictionary labels in the popup). Keep the copy inside the buffer's scope.
    dict.name = index.title.empty()
                    ? hoshi::fs_to_utf8(hoshi::fs_path(path).stem())
                    : std::string(index.title);
  }
  if (std::filesystem::exists(hoshi::fs_path(path + "/styles.css"))) {
    std::ifstream f(hoshi::fs_path(path + "/styles.css"));
    dict.styles = std::string(std::istreambuf_iterator<char>(f), {});
  }

  dict.data = std::make_unique<DictionaryData>();

  dict.data->hash_table = memory::map_rd(path + "/hash.table");
  if (!dict.data->hash_table) {
    return;
  }
  dict.data->table.load(dict.data->hash_table.data);

  dict.data->bloom_filter = memory::map_rd(path + "/bloom.filter");
  if (!dict.data->bloom_filter) {
    hash::bloom::build_to_file(dict.data->table.populated(), path + "/bloom.filter");
    dict.data->bloom_filter = memory::map_rd(path + "/bloom.filter");
  }
  dict.data->bloom.load(dict.data->bloom_filter.data);
  dict.data->table.set_bloom(&dict.data->bloom);

  dict.data->blobs = memory::map_rd(path + "/blobs.bin");
  if (!dict.data->blobs) {
    return;
  }

  dict.data->media = memory::map_rd(path + "/media.bin");
  if (dict.data->media) {
    dict.data->media_index = memory::map_rd(path + "/media.idx");
  }

  switch (type) {
    case TERM:
      term_dicts_.push_back(std::move(dict));
      break;
    case FREQ:
      freq_dicts_.push_back(std::move(dict));
      break;
    case PITCH:
      pitch_dicts_.push_back(std::move(dict));
      break;
    case KANJI:
      kanji_dicts_.push_back(std::move(dict));
      break;
  }
}

void DictionaryQuery::add_term_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::TERM); }

void DictionaryQuery::add_freq_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::FREQ); }

void DictionaryQuery::add_pitch_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::PITCH);
}

void DictionaryQuery::add_kanji_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::KANJI);
}

std::vector<TermResult> DictionaryQuery::query(const std::string& expression) const {
  auto results = query_raw(expression);
  for (auto& term : results) {
    materialize(term);
  }
  return results;
}

std::vector<TermResult> DictionaryQuery::query_raw(const std::string& expression) const {
  std::map<std::pair<std::string_view, std::string_view>, TermResult> term_map;
  for (const auto& [name, styles, data] : term_dicts_) {
    uint64_t offset_addr = data->table(expression);
    if (offset_addr == 0) {
      continue;
    }
    if (offset_addr + sizeof(uint32_t) > data->blobs.size) {
      continue;
    }
    BlobReader idx(data->blobs.data + offset_addr, data->blobs.size - offset_addr);

    auto count = idx.read<uint32_t>();
    for (uint32_t i = 0; i < count; i++) {
      if (!idx.has(sizeof(uint64_t))) {
        break;
      }
      auto offset = idx.read<uint64_t>();
      if (offset + 1 > data->blobs.size) {
        continue;
      }
      BlobReader blob(data->blobs.data + offset, data->blobs.size - offset);

      auto type = blob.read<uint8_t>();
      if (type != 0) {
        continue;
      }

      auto expr_len = blob.read<uint16_t>();
      std::string_view expr = blob.read_str(expr_len);

      auto reading_len = blob.read<uint16_t>();
      std::string_view reading = blob.read_str(reading_len);

      if (expr != expression && reading != expression) {
        continue;
      }

      auto glossary_offset = blob.read<uint64_t>();
      auto glossary_size = blob.read<uint32_t>();

      auto def_tags_size = blob.read<uint8_t>();
      std::string_view definition_tags = blob.read_str(def_tags_size);

      auto rules_size = blob.read<uint8_t>();
      std::string_view rules = blob.read_str(rules_size);

      auto term_tag_size = blob.read<uint8_t>();
      std::string_view term_tags = blob.read_str(term_tag_size);

      GlossaryEntry entry;
      entry.dict_name = name;
      entry.definition_tags = definition_tags;
      entry.term_tags = term_tags;
      entry.compressed_data = data->blobs.data + glossary_offset;
      entry.compressed_size = glossary_size;

      auto [it, inserted] = term_map.try_emplace({expr, reading});
      if (inserted) {
        it->second = {.expression = std::string(expr),
                      .reading = std::string(reading),
                      .rules = std::string(rules),
                      .glossaries = {},
                      .frequencies = {}};
      } else {
        if (!rules.empty()) {
          if (!it->second.rules.empty()) {
            it->second.rules += " ";
          }
          it->second.rules += rules;
        }
      }
      it->second.glossaries.push_back(std::move(entry));
    }
  }

  auto results = term_map | std::views::values | std::views::as_rvalue | std::ranges::to<std::vector>();
  query_freq(results);
  query_pitch(results);

  return results;
}

std::vector<KanjiResult> DictionaryQuery::query_kanji(const std::string& character) const {
  std::vector<KanjiResult> results;
  for (const auto& [name, styles, data] : kanji_dicts_) {
    uint64_t offset_addr = data->table(character);
    if (offset_addr == 0) {
      continue;
    }
    if (offset_addr + sizeof(uint32_t) > data->blobs.size) {
      continue;
    }
    BlobReader idx(data->blobs.data + offset_addr, data->blobs.size - offset_addr);

    auto count = idx.read<uint32_t>();
    for (uint32_t i = 0; i < count; i++) {
      if (!idx.has(sizeof(uint64_t))) {
        break;
      }
      auto offset = idx.read<uint64_t>();
      if (offset + 1 > data->blobs.size) {
        continue;
      }
      BlobReader blob(data->blobs.data + offset, data->blobs.size - offset);

      auto type = blob.read<uint8_t>();
      if (type != 2) {
        continue;
      }

      auto char_len = blob.read<uint16_t>();
      std::string_view ch = blob.read_str(char_len);
      if (ch != character) {
        continue;
      }

      auto ony_len = blob.read<uint16_t>();
      std::string_view onyomi = blob.read_str(ony_len);
      auto kun_len = blob.read<uint16_t>();
      std::string_view kunyomi = blob.read_str(kun_len);
      auto rad_len = blob.read<uint8_t>();
      std::string_view radical = blob.read_str(rad_len);
      auto strokes = blob.read<uint16_t>();
      auto tags_len = blob.read<uint8_t>();
      (void)blob.read_str(tags_len);  // tags: reserved (consume to keep cursor aligned)

      auto meanings_offset = blob.read<uint64_t>();
      auto meanings_size = blob.read<uint32_t>();

      KanjiResult result;
      result.character = std::string(ch);
      result.onyomi = std::string(onyomi);
      result.kunyomi = std::string(kunyomi);
      result.radical = std::string(radical);
      result.strokes = static_cast<int>(strokes);
      result.dict_name = name;

      if (meanings_size > 0 && meanings_offset < data->blobs.size) {
        std::string joined = decompress_glossary(data->blobs.data + meanings_offset, meanings_size);
        size_t start = 0;
        while (start <= joined.size()) {
          size_t nl = joined.find('\n', start);
          if (nl == std::string::npos) {
            if (start < joined.size()) {
              result.meanings.emplace_back(joined.substr(start));
            }
            break;
          }
          result.meanings.emplace_back(joined.substr(start, nl - start));
          start = nl + 1;
        }
      }

      results.push_back(std::move(result));
    }
  }
  return results;
}

void DictionaryQuery::query_freq(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    for (const auto& [name, styles, data] : freq_dicts_) {
      uint64_t offset_addr = data->table(term.expression);
      if (offset_addr == 0) {
        continue;
      }
      if (offset_addr + sizeof(uint32_t) > data->blobs.size) {
        continue;
      }
      BlobReader idx(data->blobs.data + offset_addr, data->blobs.size - offset_addr);
      auto count = idx.read<uint32_t>();

      std::vector<Frequency> frequencies;
      for (uint32_t i = 0; i < count; i++) {
        if (!idx.has(sizeof(uint64_t))) {
          break;
        }
        auto offset = idx.read<uint64_t>();
        if (offset + 1 > data->blobs.size) {
          continue;
        }
        BlobReader blob(data->blobs.data + offset, data->blobs.size - offset);

        auto type = blob.read<uint8_t>();
        if (type != 1) {
          continue;
        }

        auto expr_len = blob.read<uint16_t>();
        std::string_view expr = blob.read_str(expr_len);
        if (expr != term.expression) {
          continue;
        }

        auto mode_len = blob.read<uint8_t>();
        std::string_view mode = blob.read_str(mode_len);
        if (mode != "freq") {
          continue;
        }

        auto freq_data_size = blob.read<uint32_t>();
        std::string_view freq_data = blob.read_str(freq_data_size);

        ParsedFrequency parsed;
        if (yomitan_parser::parse_frequency(freq_data, parsed)) {
          if (!parsed.reading.empty() && parsed.reading != term.reading) {
            continue;
          }
          frequencies.emplace_back(
              Frequency{.value = parsed.value, .display_value = std::string(parsed.display_value)});
        }
      }
      if (!frequencies.empty()) {
        term.frequencies.emplace_back(FrequencyEntry{.dict_name = name, .frequencies = std::move(frequencies)});
      }
    }
  }
}

void DictionaryQuery::query_pitch(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    for (const auto& [name, styles, data] : pitch_dicts_) {
      uint64_t offset_addr = data->table(term.expression);
      if (offset_addr == 0) {
        continue;
      }
      if (offset_addr + sizeof(uint32_t) > data->blobs.size) {
        continue;
      }
      BlobReader idx(data->blobs.data + offset_addr, data->blobs.size - offset_addr);
      auto count = idx.read<uint32_t>();

      std::vector<int> pitch_positions;
      std::vector<std::string> transcriptions;
      for (uint32_t i = 0; i < count; i++) {
        if (!idx.has(sizeof(uint64_t))) {
          break;
        }
        auto offset = idx.read<uint64_t>();
        if (offset + 1 > data->blobs.size) {
          continue;
        }
        BlobReader blob(data->blobs.data + offset, data->blobs.size - offset);

        auto type = blob.read<uint8_t>();
        if (type != 1) {
          continue;
        }

        auto expr_len = blob.read<uint16_t>();
        std::string_view expr = blob.read_str(expr_len);
        if (expr != term.expression) {
          continue;
        }

        auto mode_len = blob.read<uint8_t>();
        std::string_view mode = blob.read_str(mode_len);

        // Both pitch-accent ("pitch") and IPA transcription ("ipa") meta records
        // share this PITCH dict bucket / storage layout (upstream 918744d). The
        // data blob differs only in how the JSON is shaped; parse with the
        // matching parser and accumulate into the right vector. Anything else is
        // skipped.
        ParsedPitch parsed;
        if (mode == "pitch") {
          auto pitch_data_size = blob.read<uint32_t>();
          std::string_view pitch_data = blob.read_str(pitch_data_size);
          if (yomitan_parser::parse_pitch(pitch_data, parsed)) {
            if (!parsed.reading.empty() && parsed.reading != term.reading) {
              continue;
            }
            pitch_positions.insert(pitch_positions.end(), parsed.pitches.begin(), parsed.pitches.end());
          }
        } else if (mode == "ipa") {
          auto transcriptions_data_size = blob.read<uint32_t>();
          std::string_view transcriptions_data = blob.read_str(transcriptions_data_size);
          if (yomitan_parser::parse_ipa(transcriptions_data, parsed)) {
            if (!parsed.reading.empty() && parsed.reading != term.reading) {
              continue;
            }
            for (std::string_view transcription : parsed.transcriptions) {
              transcriptions.emplace_back(transcription);
            }
          }
        }
      }
      if (!pitch_positions.empty() || !transcriptions.empty()) {
        term.pitches.emplace_back(PitchEntry{
            .dict_name = name,
            .pitch_positions = std::move(pitch_positions),
            .transcriptions = std::move(transcriptions),
        });
      }
    }
  }
}

std::string DictionaryQuery::decompress_glossary(const void* data, size_t size) {
  if (!data || size == 0) {
    return "";
  }

  unsigned long long decompressed_size = ZSTD_getFrameContentSize(data, size);
  if (decompressed_size == ZSTD_CONTENTSIZE_ERROR || decompressed_size == ZSTD_CONTENTSIZE_UNKNOWN) {
    return "";
  }

  static constexpr size_t kMaxGlossarySize = 64 * 1024 * 1024;  // 64 MB
  if (decompressed_size > kMaxGlossarySize) {
    HOSHI_LOGW("glossary decompressed size %llu exceeds limit",
               static_cast<unsigned long long>(decompressed_size));
    return "";
  }

  std::string result;
  result.resize(decompressed_size);

  size_t actual_size = ZSTD_decompress(result.data(), result.size(), data, size);
  if (ZSTD_isError(actual_size)) {
    return "";
  }

  result.resize(actual_size);
  return result;
}

void DictionaryQuery::materialize(TermResult& term) const {
  for (auto& g : term.glossaries) {
    g.glossary = decompress_glossary(g.compressed_data, g.compressed_size);
  }
}

std::vector<char> DictionaryQuery::get_media_file(const std::string& dict_name, const std::string& media_path) const {
  auto view = get_media_file_view(dict_name, media_path);
  if (view.data == nullptr || view.size == 0) {
    return {};
  }
  return {view.data, view.data + view.size};
}

MediaFileView DictionaryQuery::get_media_file_view(const std::string& dict_name, const std::string& media_path) const {
  const std::string normalized_media_path = hoshidicts::normalize_media_path(media_path);
  for (const auto& [name, styles, data] : term_dicts_) {
    if (name != dict_name) {
      continue;
    }

    if (!data->media || !data->media_index) {
      return {};
    }

    BlobReader idx_hdr(data->media_index.data, data->media_index.size);
    auto count = idx_hdr.read<uint32_t>();

    const size_t idx_entry_end = sizeof(uint32_t) + static_cast<size_t>(count) * sizeof(uint64_t);
    if (idx_entry_end > data->media_index.size) {
      return {};
    }

    auto find_by_indexed_path = [&](std::string_view requested_path) -> MediaFileView {
      size_t left = 0;
      size_t right = count;
      while (left < right) {
        const size_t mid = left + (right - left) / 2;
        uint64_t record_offset;
        std::memcpy(&record_offset, data->media_index.data + sizeof(uint32_t) + mid * sizeof(uint64_t), sizeof(uint64_t));

        if (record_offset >= data->media.size) {
          return {};
        }
        BlobReader rec(data->media.data + record_offset, data->media.size - record_offset);
        auto path_size = rec.read<uint16_t>();
        std::string_view indexed_path = rec.read_str(path_size);
        if (indexed_path < requested_path) {
          left = mid + 1;
        } else if (indexed_path > requested_path) {
          right = mid;
        } else {
          auto blob_size = rec.read<uint32_t>();
          if (!rec.has(blob_size)) {
            return {};
          }
          const char* blob_data = reinterpret_cast<const char*>(rec.ptr);
          return {.data = blob_data, .size = blob_size};
        }
      }
      return {};
    };

    MediaFileView view = find_by_indexed_path(normalized_media_path);
    if (view.data != nullptr) {
      return view;
    }

    std::string legacy_media_path = normalized_media_path;
    std::ranges::replace(legacy_media_path, '/', '\\');
    if (legacy_media_path != normalized_media_path) {
      view = find_by_indexed_path(legacy_media_path);
      if (view.data != nullptr) {
        return view;
      }
    }
    return {};
  }
  return {};
}

std::vector<DictionaryStyle> DictionaryQuery::get_styles() const {
  return term_dicts_ | std::views::filter([](const auto& d) { return !d.styles.empty(); }) |
         std::views::transform([](const auto& d) { return DictionaryStyle{d.name, d.styles}; }) |
         std::ranges::to<std::vector>();
}

std::vector<std::string> DictionaryQuery::get_freq_dict_order() const {
  return freq_dicts_ | std::views::transform([](const auto& d) { return d.name; }) | std::ranges::to<std::vector>();
}

// ── dictionary content probe (TODO-622) ─────────────────────────────
// Walk hash.table buckets -> offset-index -> record type byte. The on-disk
// format is stable and identical to what query()/query_kanji() consume:
//   hash.table : [u32 capacity][ slot{u64 hash, u64 offset} x capacity ]
//                empty slot == hash 0; offset points into the offset-index
//                region of blobs.bin.
//   offset-idx : [u32 count][u64 record_offset x count]
//   record     : first byte = type (0=term, 1=meta, 2=kanji)
// All little-endian (write_val/BlobReader use memcpy). We cannot sequentially
// scan the record region (no boundary metadata, glossary blobs interleaved),
// so we must go through the hash table. bloom.filter is not needed here.
int probe_dict_content(const std::string& dir) {
  memory::mapped_file hash_table = memory::map_rd(dir + "/hash.table");
  if (!hash_table || hash_table.size < sizeof(uint32_t)) {
    memory::unmap(hash_table);
    return 0;
  }
  memory::mapped_file blobs = memory::map_rd(dir + "/blobs.bin");
  if (!blobs) {
    memory::unmap(hash_table);
    return 0;
  }

  int mask = 0;
  uint32_t capacity = 0;
  std::memcpy(&capacity, hash_table.data, sizeof(uint32_t));

  // Bound the slot array to what the file actually holds.
  const size_t slot_size = sizeof(uint64_t) * 2;  // {hash, offset}
  const size_t max_slots = (hash_table.size - sizeof(uint32_t)) / slot_size;
  if (capacity > max_slots) {
    capacity = static_cast<uint32_t>(max_slots);
  }
  const uint8_t* slots = hash_table.data + sizeof(uint32_t);

  for (uint32_t i = 0; i < capacity && mask != 0x3; i++) {
    const uint8_t* slot = slots + static_cast<size_t>(i) * slot_size;
    uint64_t slot_hash = 0;
    uint64_t bucket = 0;
    std::memcpy(&slot_hash, slot, sizeof(uint64_t));
    if (slot_hash == 0) {
      continue;  // empty slot
    }
    std::memcpy(&bucket, slot + sizeof(uint64_t), sizeof(uint64_t));

    if (bucket + sizeof(uint32_t) > blobs.size) {
      continue;
    }
    BlobReader idx(blobs.data + bucket, blobs.size - bucket);
    uint32_t count = idx.read<uint32_t>();
    for (uint32_t k = 0; k < count && mask != 0x3; k++) {
      if (!idx.has(sizeof(uint64_t))) {
        break;
      }
      uint64_t rec = idx.read<uint64_t>();
      if (rec + 1 > blobs.size) {
        continue;
      }
      uint8_t type = blobs.data[rec];
      if (type == 0) {
        mask |= 0x1;  // has term
      } else if (type == 2) {
        mask |= 0x2;  // has kanji
      }
    }
  }

  memory::unmap(blobs);
  memory::unmap(hash_table);
  return mask;
}

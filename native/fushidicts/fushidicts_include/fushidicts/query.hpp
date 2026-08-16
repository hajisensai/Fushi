#pragma once

#include <memory>
#include <string>
#include <utility>
#include <vector>

#if defined(__clang__) && defined(__APPLE__)
#define SWIFT_IMPORT_UNSAFE __attribute__((swift_attr("import_unsafe")))
#else
#define SWIFT_IMPORT_UNSAFE
#endif

struct Frequency {
  int value;
  std::string display_value;
};

struct DictionaryStyle {
  std::string dict_name;
  std::string styles;
};

struct MediaFileView {
  const char* data;
  size_t size;
};

struct ZSTD_DDict_s;

struct GlossaryEntry {
  std::string dict_name;
  std::string glossary;
  std::string definition_tags;
  std::string term_tags;
  const uint8_t* compressed_data = nullptr;
  uint32_t compressed_size = 0;
  // v2 词典的 term glossary 用训练字典压缩（上游 8993838）；v1 恒为 nullptr，
  // usingDDict(nullptr) 等价普通解压。
  const ZSTD_DDict_s* zstd_dict = nullptr;
};

struct FrequencyEntry {
  std::string dict_name;
  std::vector<Frequency> frequencies;
};

struct PitchEntry {
  std::string dict_name;
  std::vector<int> pitch_positions;
  std::vector<std::string> transcriptions;
};

struct TermResult {
  std::string expression;
  std::string reading;
  std::string rules;
  std::vector<GlossaryEntry> glossaries;
  std::vector<FrequencyEntry> frequencies;
  std::vector<PitchEntry> pitches;
};

struct KanjiResult {
  std::string character;
  std::string onyomi;
  std::string kunyomi;
  std::string radical;
  int strokes = 0;
  std::vector<std::string> meanings;
  // v2 词典的完整 stats 键值对（JLPT/grade/freq 等，bank 原始顺序，radical/strokes
  // 以外的条目；借鉴上游 64afa2f 的 stats 保留能力）。v1 存量记录恒为空。
  std::vector<std::pair<std::string, std::string>> stats;
  std::string dict_name;
};

// Probe a written dictionary directory's blobs.bin/hash.table to discover which
// record types it actually contains, independent of its declared classification.
// Returns a bitmask: bit0 (0x1) = has term records (type byte 0),
// bit1 (0x2) = has kanji records (type byte 2). Returns 0 on any read failure.
// Single source of truth for re-classifying a mixed dictionary that detect_type
// may have mislabeled, and for self-healing already-imported dictionaries.
int probe_dict_content(const std::string& dir);

class DictionaryQuery {
 public:
  DictionaryQuery();
  ~DictionaryQuery();

  DictionaryQuery(const DictionaryQuery&) = delete;
  DictionaryQuery& operator=(const DictionaryQuery&) = delete;

  DictionaryQuery(DictionaryQuery&&) noexcept;
  DictionaryQuery& operator=(DictionaryQuery&&) noexcept;

  void add_term_dict(const std::string& path);
  void add_freq_dict(const std::string& path);
  void add_pitch_dict(const std::string& path);
  void add_kanji_dict(const std::string& path);

  void query_freq(std::vector<TermResult>& terms) const;
  void query_pitch(std::vector<TermResult>& terms) const;

  std::vector<TermResult> query(const std::string& expression) const;
  std::vector<KanjiResult> query_kanji(const std::string& character) const;

  std::vector<char> get_media_file(const std::string& dict_name, const std::string& media_path) const;
  SWIFT_IMPORT_UNSAFE
  MediaFileView get_media_file_view(const std::string& dict_name, const std::string& media_path) const;
  std::vector<DictionaryStyle> get_styles() const;
  std::vector<std::string> get_freq_dict_order() const;

 private:
  friend class Lookup;

  // BUG-1304: query_raw() returns terms WITHOUT frequency/pitch enrichment.
  // Lookup::lookup() calls it once per (scan candidate x text variant x
  // deinflection) -- ~69 times per user lookup, measured, not the ~1600 the
  // first draft of BUG-1304 extrapolated from the loop bounds -- and enriching
  // inside it meant every intermediate term hit every frequency and pitch
  // dictionary (each with its own JSON parse), only for most of that work to be
  // thrown away by the dedup + partial_sort + resize that follow.
  // The enrichment now happens once, on the surviving set, in lookup.cpp.
  //
  // Measured magnitude (Release, 7 term dicts x 150k entries, 3 freq dicts,
  // 2 pitch dicts, max_results=200): enrichment count 9.4 -> 3.2 per lookup
  // (2.94x), end-to-end 0.182 ms -> 0.173 ms per lookup (~5-9%). This is a real
  // but SMALL win -- do not cite it as a cause of seconds-scale lookup latency.
  // The public query_freq/query_pitch keep enriching a whole vector so
  // query() -- the single-expression entry point -- is unchanged.
  std::vector<TermResult> query_raw(const std::string& expression) const;
  void enrich_freq(TermResult& term) const;
  void enrich_pitch(TermResult& term) const;
  void materialize(TermResult& term) const;

  struct DictionaryData;
  struct Dictionary {
    Dictionary();
    ~Dictionary();

    Dictionary(const Dictionary&) = delete;
    Dictionary& operator=(const Dictionary&) = delete;

    Dictionary(Dictionary&&) noexcept;
    Dictionary& operator=(Dictionary&&) noexcept;

    std::string name;
    std::string styles;
    std::unique_ptr<DictionaryData> data;
  };
  enum DictionaryType : uint8_t { TERM, FREQ, PITCH, KANJI };

  void add_dict(const std::string& path, DictionaryType);

  static std::string decompress_glossary(const void* data, size_t size, const ZSTD_DDict_s* dict);
  std::vector<Dictionary> term_dicts_;
  std::vector<Dictionary> freq_dicts_;
  std::vector<Dictionary> pitch_dicts_;
  std::vector<Dictionary> kanji_dicts_;
};

#pragma once

#include <memory>
#include <string>
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

struct GlossaryEntry {
  std::string dict_name;
  std::string glossary;
  std::string definition_tags;
  std::string term_tags;
  const uint8_t* compressed_data = nullptr;
  uint32_t compressed_size = 0;
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
  std::vector<TermResult> query_raw(const std::string& expression) const;
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

  static std::string decompress_glossary(const void* data, size_t size);
  std::vector<Dictionary> term_dicts_;
  std::vector<Dictionary> freq_dicts_;
  std::vector<Dictionary> pitch_dicts_;
  std::vector<Dictionary> kanji_dicts_;
};

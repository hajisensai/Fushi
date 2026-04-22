#pragma once

#include <memory>
#include <string>
#include <vector>

struct Frequency {
  int value;
  std::string display_value;
};

struct DictionaryStyle {
  std::string dict_name;
  std::string styles;
};

struct GlossaryEntry {
  std::string dict_name;
  std::string glossary;
  std::string definition_tags;
  std::string term_tags;
};

struct FrequencyEntry {
  std::string dict_name;
  std::vector<Frequency> frequencies;
};

struct PitchEntry {
  std::string dict_name;
  std::vector<int> pitch_positions;
};

struct TermResult {
  std::string expression;
  std::string reading;
  std::string rules;
  std::vector<GlossaryEntry> glossaries;
  std::vector<FrequencyEntry> frequencies;
  std::vector<PitchEntry> pitches;
};

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

  void query_freq(std::vector<TermResult>& terms) const;
  void query_pitch(std::vector<TermResult>& terms) const;

  std::vector<TermResult> query(const std::string& expression) const;

  std::vector<char> get_media_file(const std::string& dict_name, const std::string& media_path) const;
  std::vector<DictionaryStyle> get_styles() const;
  std::vector<std::string> get_freq_dict_order() const;

 private:
  struct DictionaryData;
  struct Dictionary {
    std::string name;
    std::string styles;
    std::unique_ptr<DictionaryData> data;
  };
  enum DictionaryType : uint8_t { TERM, FREQ, PITCH };

  void add_dict(const std::string& path, DictionaryType);

  static std::string decompress_glossary(const void* data, size_t size);
  std::vector<Dictionary> term_dicts_;
  std::vector<Dictionary> freq_dicts_;
  std::vector<Dictionary> pitch_dicts_;
};

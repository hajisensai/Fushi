#pragma once

#include <string>
#include <vector>

struct ImportResult {
  bool success = false;
  std::string title;
  size_t term_count = 0;
  size_t meta_count = 0;
  size_t kanji_count = 0;
  size_t freq_count = 0;
  size_t pitch_count = 0;
  size_t media_count = 0;
  std::string detected_type = "term";
  // Any term record carries a non-empty `rules` (part-of-speech) string.
  // Persisted next to blobs.bin as term_rules.flag (util/term_rules_flag.hpp);
  // false means the reader treats empty rules as the "*" wildcard.
  bool term_rules_present = false;
  std::vector<std::string> errors;
};

struct SimpleEntry {
  std::string headword;
  std::string definition;
};

namespace dictionary_importer {
ImportResult import(const std::string& zip_path, const std::string& output_dir, bool low_ram = false,
                    const std::string& breadcrumb_dir = "");
ImportResult write_simple_dict(const std::string& title, const std::vector<SimpleEntry>& entries,
                               const std::string& output_dir, const std::string& styles_css = "");
};

#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct StardictEntry {
  std::string word;
  std::string definition;
};

struct StardictResult {
  std::string bookname;
  std::vector<StardictEntry> entries;
};

namespace stardict_reader {
StardictResult parse(const std::string& ifo_path);
StardictResult parse_from_data(const std::string& bookname,
                               const uint8_t* idx_data, size_t idx_size,
                               const uint8_t* dict_data, size_t dict_size,
                               const std::string& sametypesequence = "");
}

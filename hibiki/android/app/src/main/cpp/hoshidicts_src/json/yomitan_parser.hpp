#pragma once
#include <cstdint>
#include <glaze/glaze.hpp>
#include <cstdint>
#include <string_view>
#include <vector>

struct Index {
  std::string_view title;
  int format = 3;
  std::string_view revision;
  bool isUpdatable;
  std::string_view indexUrl;
  std::string_view downloadUrl;
};

struct Term {
  std::string_view expression;
  std::string_view reading;
  std::optional<std::string_view> definition_tags;
  std::string_view rules;
  int score = 0;
  glz::raw_json_view glossary;
  int64_t sequence = 0;
  std::string_view term_tags;
};

struct Meta {
  std::string_view expression;
  std::string_view mode;
  glz::raw_json_view data;
};

struct Tag {
  std::string_view name;
  std::string_view category;
  int order = 0;
  std::string_view notes;
  int score = 0;
};

struct ParsedFrequency {
  std::string_view reading;
  int value;
  std::string display_value;
};

struct ParsedPitch {
  std::string_view reading;
  std::vector<int> pitches;
};

namespace yomitan_parser {
bool parse_index(std::string_view content, Index& out);
bool parse_term_bank(std::string_view content, std::vector<Term>& out);
bool parse_meta_bank(std::string_view content, std::vector<Meta>& out);
bool parse_tag_bank(std::string_view content, std::vector<Tag>& out);
bool parse_frequency(std::string_view content, ParsedFrequency& out);
bool parse_pitch(std::string_view content, ParsedPitch& out);
};

#include "yomitan_parser.hpp"

#include <string_view>
#include <variant>

template <>
struct glz::meta<Index> {
  using T = Index;
  static constexpr auto value =
      object("title", glz::raw_string<&T::title>, "revision", glz::raw_string<&T::revision>, "format", &T::format,
             "isUpdatable", &T::isUpdatable, "indexUrl", glz::raw_string<&T::indexUrl>, "downloadUrl",
             glz::raw_string<&T::downloadUrl>);
};

template <>
struct glz::meta<Term> {
  using T = Term;
  static constexpr auto value =
      array(glz::raw_string<&T::expression>, glz::raw_string<&T::reading>, glz::raw_string<&T::definition_tags>,
            glz::raw_string<&T::rules>, &T::score, &T::glossary, &T::sequence, glz::raw_string<&T::term_tags>);
};

template <>
struct glz::meta<Meta> {
  using T = Meta;
  static constexpr auto value = array(glz::raw_string<&T::expression>, glz::raw_string<&T::mode>, &T::data);
};

template <>
struct glz::meta<Tag> {
  using T = Tag;
  static constexpr auto value =
      array(glz::raw_string<&T::name>, glz::raw_string<&T::category>, &T::order, glz::raw_string<&T::notes>, &T::score);
};

namespace internal {
struct FrequencyValue {
  int value;
  std::string display_value;
};

struct RawFrequencyFlat {
  std::optional<std::string_view> reading;
  int value;
  std::optional<std::string> display_value;
};

struct RawFrequency {
  std::optional<std::string_view> reading;
  std::variant<int, FrequencyValue> frequency;
};

struct PitchesArray {
  int position = 0;
};

struct RawPitch {
  std::string_view reading;
  std::vector<PitchesArray> pitches;
};
};

template <>
struct glz::meta<internal::RawFrequencyFlat> {
  using T = internal::RawFrequencyFlat;
  static constexpr auto value = object("reading", &T::reading, "value", &T::value, "displayValue", &T::display_value);
};

template <>
struct glz::meta<internal::FrequencyValue> {
  using T = internal::FrequencyValue;
  static constexpr auto value = object("value", &T::value, "displayValue", &T::display_value);
};

template <>
struct glz::meta<internal::RawFrequency> {
  using T = internal::RawFrequency;
  static constexpr auto value = object("reading", &T::reading, "frequency", &T::frequency);
};

template <>
struct glz::meta<internal::PitchesArray> {
  using T = internal::PitchesArray;
  static constexpr auto value = object("position", &T::position);
};

template <>
struct glz::meta<internal::RawPitch> {
  using T = internal::RawPitch;
  static constexpr auto value = object("reading", glz::raw_string<&T::reading>, "pitches", &T::pitches);
};

bool yomitan_parser::parse_index(std::string_view content, Index& out) {
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(out, content);
  return !error;
}

bool yomitan_parser::parse_term_bank(std::string_view content, std::vector<Term>& out) {
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(out, content);
  return !error;
}

bool yomitan_parser::parse_meta_bank(std::string_view content, std::vector<Meta>& out) {
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(out, content);
  return !error;
}

bool yomitan_parser::parse_tag_bank(std::string_view content, std::vector<Tag>& out) {
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(out, content);
  return !error;
}

bool yomitan_parser::parse_frequency(std::string_view content, ParsedFrequency& out) {
  internal::RawFrequencyFlat parsed_flat;
  auto error =
      glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = true}>(parsed_flat, content);
  if (!error) {
    out.reading = parsed_flat.reading.value_or("");
    out.value = parsed_flat.value;
    out.display_value = parsed_flat.display_value.value_or(std::to_string(parsed_flat.value));
    return true;
  }

  int val;
  error = glz::read_json(val, content);
  if (!error) {
    out.value = val;
    out.display_value = std::to_string(val);
    out.reading = "";
    return true;
  }

  internal::RawFrequency parsed;
  error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading.value_or("");
  if (std::holds_alternative<int>(parsed.frequency)) {
    int freq = std::get<int>(parsed.frequency);
    out.value = freq;
    out.display_value = std::to_string(freq);
  } else {
    auto& freq = std::get<internal::FrequencyValue>(parsed.frequency);
    out.value = freq.value;
    out.display_value = freq.display_value.empty() ? std::to_string(freq.value) : freq.display_value;
  }
  return true;
}

template <>
struct glz::meta<Kanji> {
  using T = Kanji;
  static constexpr auto value =
      array(glz::raw_string<&T::character>, glz::raw_string<&T::onyomi>, glz::raw_string<&T::kunyomi>,
            glz::raw_string<&T::tags>, &T::meanings, &T::stats);
};

bool yomitan_parser::parse_kanji_bank(std::string_view content, std::vector<Kanji>& out) {
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(out, content);
  return !error;
}

static void html_escape(std::string& out, std::string_view s) {
  for (char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out += c;
    }
  }
}

static void json_escape(std::string& out, std::string_view s) {
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
}

std::vector<Term> yomitan_parser::kanji_to_terms(const std::vector<Kanji>& kanji, std::vector<std::string>& storage) {
  std::vector<Term> terms;
  terms.reserve(kanji.size());
  storage.reserve(kanji.size() * 2);

  for (const auto& k : kanji) {
    if (k.character.empty()) continue;

    std::string html;
    html += "<div class=\"kanji-entry\">";
    if (!k.onyomi.empty()) {
      html += "<div class=\"kanji-readings\"><span class=\"kanji-label\">音</span> ";
      html_escape(html, k.onyomi);
      html += "</div>";
    }
    if (!k.kunyomi.empty()) {
      html += "<div class=\"kanji-readings\"><span class=\"kanji-label\">訓</span> ";
      html_escape(html, k.kunyomi);
      html += "</div>";
    }
    if (!k.meanings.empty()) {
      html += "<ol class=\"kanji-meanings\">";
      for (const auto& m : k.meanings) {
        html += "<li>";
        html_escape(html, m);
        html += "</li>";
      }
      html += "</ol>";
    }
    html += "</div>";

    std::string glossary_json = "[\"";
    json_escape(glossary_json, html);
    glossary_json += "\"]";

    storage.push_back(std::move(glossary_json));

    std::string reading;
    if (!k.onyomi.empty() && !k.kunyomi.empty()) {
      reading = std::string(k.onyomi) + " " + std::string(k.kunyomi);
    } else if (!k.onyomi.empty()) {
      reading = std::string(k.onyomi);
    } else {
      reading = std::string(k.kunyomi);
    }
    storage.push_back(std::move(reading));

    Term t;
    t.expression = k.character;
    t.reading = storage[storage.size() - 1];
    t.glossary = glz::raw_json_view{storage[storage.size() - 2]};
    terms.push_back(t);
  }

  return terms;
}

bool yomitan_parser::parse_pitch(std::string_view content, ParsedPitch& out) {
  internal::RawPitch parsed;
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading;
  out.pitches =
      parsed.pitches | std::views::transform(&internal::PitchesArray::position) | std::ranges::to<std::vector>();
  return true;
}
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
struct glz::meta<Kanji> {
  using T = Kanji;
  // [character, onyomi, kunyomi, tags, meanings[], stats{}]
  static constexpr auto value = array(glz::raw_string<&T::character>, glz::raw_string<&T::onyomi>,
                                      glz::raw_string<&T::kunyomi>, glz::raw_string<&T::tags>, &T::meanings, &T::stats);
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
  std::optional<std::string> display_value;
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

// 上游 79c55c2（parser 先行部分）：position 可以是数字或 pattern 字符串
//（"heiban" 等）。此前 int 独取会让含 pattern 条目的整条 meta 记录解析失败、
// 数字条目一起陪葬。nasal/devoice 键靠 error_on_unknown_keys=false 天然容忍；
// 结构化收集（连同 pattern 出 FFI/UI）留待二期。
struct PitchesArray {
  std::variant<int, std::string> position;
};

struct RawPitch {
  std::string_view reading;
  std::vector<PitchesArray> pitches;
};

struct TranscriptionsArray {
  std::string_view ipa;
};

struct RawIPA {
  std::string_view reading;
  std::vector<TranscriptionsArray> transcriptions;
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

template <>
struct glz::meta<internal::TranscriptionsArray> {
  using T = internal::TranscriptionsArray;
  static constexpr auto value = object("ipa", glz::raw_string<&T::ipa>);
};

template <>
struct glz::meta<internal::RawIPA> {
  using T = internal::RawIPA;
  static constexpr auto value =
      object("reading", glz::raw_string<&T::reading>, "transcriptions", &T::transcriptions);
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

bool yomitan_parser::parse_kanji_bank(std::string_view content, std::vector<Kanji>& out) {
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
  // 上游 01630e8：嵌套 object 变体与 flat 路径同样收紧——缺 frequency 键的畸形
  // 条目从「静默解析成 0」变为拒绝；displayValue 显式空串也如实保留。
  error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = true}>(parsed, content);
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
    out.display_value = freq.display_value.value_or(std::to_string(freq.value));
  }
  return true;
}

bool yomitan_parser::parse_pitch(std::string_view content, ParsedPitch& out) {
  internal::RawPitch parsed;
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = true}>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading;
  for (const auto& pitch : parsed.pitches) {
    if (std::holds_alternative<int>(pitch.position)) {
      out.pitches.push_back(std::get<int>(pitch.position));
    }
    // pattern 字符串位暂无消费方，跳过该条而非整条拒绝（二期扩 ABI 时再结构化）。
  }
  return true;
}

bool yomitan_parser::parse_ipa(std::string_view content, ParsedPitch& out) {
  internal::RawIPA parsed;
  auto error = glz::read<glz::opts{.error_on_unknown_keys = false, .error_on_missing_keys = false}>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading;
  out.transcriptions = parsed.transcriptions | std::views::transform(&internal::TranscriptionsArray::ipa) |
                       std::ranges::to<std::vector>();
  return true;
}
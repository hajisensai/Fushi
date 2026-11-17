#pragma once

#include <array>
#include <string>
#include <string_view>
#include <utility>

// 语言标签归一：变形表的 `language`（en / ja / kat …）与词典的语言（BCP-47：`en-US`、
// `ja-JP`、`zh-Hant`，偶见 ISO 639-2/3 的三字母码）要能互相比较，统一取**主语言子标签**
// 的小写两字母形。没有两字母码的语言（grc / sga）保持原样。空串 / 全空白 = 未标注。
//
// 只在装载时调用（Deinflector::load_transforms_json / DictionaryQuery::add_term_dict），
// 查词路径上比较的是归一后的结果。
namespace fushi {

inline std::string primary_language_tag(std::string_view tag) {
  constexpr std::string_view kSpace = " \t\n\v\f\r";
  const std::size_t begin = tag.find_first_not_of(kSpace);
  if (begin == std::string_view::npos) return {};
  tag.remove_prefix(begin);
  const std::size_t end = tag.find_first_of("-_ \t\n\v\f\r");
  if (end != std::string_view::npos) tag = tag.substr(0, end);

  std::string primary(tag);
  for (char& c : primary) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }

  // ISO 639-2/3 三字母码 → 639-1。只列随包变形表覆盖的语言和中文（中文没有变形表，
  // 但两种写法要归成同一个「已标注语言」）。
  static constexpr std::array<std::pair<std::string_view, std::string_view>, 24> kAliases = {{
      {"jpn", "ja"}, {"eng", "en"}, {"kor", "ko"}, {"deu", "de"}, {"ger", "de"}, {"fra", "fr"},
      {"fre", "fr"}, {"spa", "es"}, {"lat", "la"}, {"ell", "el"}, {"gre", "el"}, {"ara", "ar"},
      {"kat", "ka"}, {"geo", "ka"}, {"sqi", "sq"}, {"alb", "sq"}, {"eus", "eu"}, {"baq", "eu"},
      {"epo", "eo"}, {"gle", "ga"}, {"tgl", "tl"}, {"yid", "yi"}, {"zho", "zh"}, {"chi", "zh"},
  }};
  for (const auto& [from, to] : kAliases) {
    if (primary == from) return std::string(to);
  }
  return primary;
}

}  // namespace fushi

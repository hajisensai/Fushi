#include "text_processor.hpp"

#include <utf8.h>
#include <utf8proc.h>

#include <cstdint>
#include <functional>
#include <map>
#include <ranges>
#include <string>
#include <unordered_map>
#include <utility>

namespace {
struct TextProcessor {
  std::vector<int> options;
  std::function<std::u32string(const std::u32string&, int)> process;
};

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L21
constexpr uint32_t KATAKANA_SMALL_KA = 0x30f5;
constexpr uint32_t KATAKANA_SMALL_KE = 0x30f6;
constexpr uint32_t KANA_PROLONGED_SOUND_MARK = 0x30fc;

constexpr uint32_t HIRAGANA_CONVERSION_RANGE_START = 0x3041;
constexpr uint32_t HIRAGANA_CONVERSION_RANGE_END = 0x3096;

constexpr uint32_t KATAKANA_CONVERSION_RANGE_START = 0x30a1;
constexpr uint32_t KATAKANA_CONVERSION_RANGE_END = 0x30f6;

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L121
const std::unordered_map<char32_t, std::u32string> VOWEL_TO_KANA{
    {U'a', U"ぁあかがさざただなはばぱまゃやらゎわヵァアカガサザタダナハバパマャヤラヮワヵヷ"},
    {U'i', U"ぃいきぎしじちぢにひびぴみりゐィイキギシジチヂニヒビピミリヰヸ"},
    {U'u', U"ぅうくぐすずっつづぬふぶぷむゅゆるゥウクグスズッツヅヌフブプムュユルヴ"},
    {U'e', U"ぇえけげせぜてでねへべぺめれゑヶェエケゲセゼテデネヘベペメレヱヶヹ"},
    {U'o', U"ぉおこごそぞとどのほぼぽもょよろをォオコゴソゾトドノホボポモョヨロヲヺ"}};

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L131
std::unordered_map<char32_t, char32_t> build_kana_to_vowel_map() {
  std::unordered_map<char32_t, char32_t> map;
  for (const auto& [vowel, kana_string] : VOWEL_TO_KANA) {
    for (char32_t c : kana_string) {
      map.try_emplace(c, vowel);
    }
  }
  return map;
}

char32_t kana_to_vowel(char32_t kana) {
  static const auto KANA_TO_VOWEL = build_kana_to_vowel_map();
  auto it = KANA_TO_VOWEL.find(kana);
  if (it != KANA_TO_VOWEL.end()) {
    return it->second;
  }
  return 0;
}

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L155
char32_t get_prolonged_hiragana(char32_t prev) {
  switch (kana_to_vowel(prev)) {
    case U'a':
      return U'あ';
    case U'i':
      return U'い';
    case U'u':
      return U'う';
    case U'e':
      return U'え';
    case U'o':
      return U'う';
    default:
      return 0;
  }
}

bool is_in_range(uint32_t c, uint32_t range_start, uint32_t range_end) { return c >= range_start && c <= range_end; }

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L472
std::u32string hiragana_to_katakana(const std::u32string& text) {
  std::u32string result;
  const uint32_t offset = (KATAKANA_CONVERSION_RANGE_START - HIRAGANA_CONVERSION_RANGE_START);
  for (char32_t c : text) {
    if (is_in_range(c, HIRAGANA_CONVERSION_RANGE_START, HIRAGANA_CONVERSION_RANGE_END)) {
      c = static_cast<char32_t>(c + offset);
    }
    result += c;
  }
  return result;
}

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L441
std::u32string katakana_to_hiragana(const std::u32string& text) {
  std::u32string result;
  const uint32_t offset = (HIRAGANA_CONVERSION_RANGE_START - KATAKANA_CONVERSION_RANGE_START);
  for (char32_t c : text) {
    switch (c) {
      case KATAKANA_SMALL_KA:
      case KATAKANA_SMALL_KE:
        break;
      case KANA_PROLONGED_SOUND_MARK:
        if (result.length() > 0) {
          const auto prolonged = get_prolonged_hiragana(result.at(result.length() - 1));
          if (prolonged != 0) {
            c = prolonged;
          }
        }
        break;
      default:
        if (is_in_range(c, KATAKANA_CONVERSION_RANGE_START, KATAKANA_CONVERSION_RANGE_END)) {
          c = static_cast<char32_t>(c + offset);
        }
        break;
    }
    result += c;
  }
  return result;
}

// Unicode 范围小写（码点驱动，无语言门控）。覆盖 18 张 Yomitan 变换表里高频、
// 规则性强的双大小写脚本：ASCII / Latin-1 Supplement / 希腊 / 西里尔。其余脚本字符
// 天然落到 else 保持原样。土耳其 i/İ、立陶宛等特殊 casing 规则不在覆盖内（见计划风险节）。
std::u32string to_lowercase(const std::u32string& text) {
  std::u32string result;
  result.reserve(text.size());
  for (char32_t c : text) {
    if (c >= 0x0041 && c <= 0x005A) {  // ASCII A–Z
      c = static_cast<char32_t>(c + 0x20);
    } else if ((c >= 0x00C0 && c <= 0x00D6) ||  // Latin-1 À–Ö
               (c >= 0x00D8 && c <= 0x00DE)) {   // Latin-1 Ø–Þ
      c = static_cast<char32_t>(c + 0x20);
    } else if ((c >= 0x0391 && c <= 0x03A1) ||  // 希腊 Α–Ρ
               (c >= 0x03A3 && c <= 0x03AB)) {   // 希腊 Σ–Ϋ（跳过未分配的 0x03A2）
      c = static_cast<char32_t>(c + 0x20);
    } else if (c >= 0x0410 && c <= 0x042F) {  // 西里尔 А–Я
      c = static_cast<char32_t>(c + 0x20);
    } else if (c >= 0x0400 && c <= 0x040F) {  // 西里尔 Ѐ–Џ
      c = static_cast<char32_t>(c + 0x50);
    }
    result += c;
  }
  return result;
}

// P2：删除组合记号 / 阿拉伯 harakat·tatweel / 希伯来点。纯删除，对非目标脚本是 no-op。
bool is_combining_to_strip(char32_t c) {
  return (c >= 0x0300 && c <= 0x036F) ||  // 组合变音符
         (c >= 0x064B && c <= 0x065F) ||  // 阿拉伯 harakat 等
         (c == 0x0670) ||                 // 阿拉伯上标 alef
         (c == 0x0640) ||                 // 阿拉伯 tatweel（连接符）
         (c >= 0x0591 && c <= 0x05BD) ||  // 希伯来 cantillation/points
         (c == 0x05BF) || (c == 0x05C1) || (c == 0x05C2) || (c == 0x05C4) ||
         (c == 0x05C5) || (c == 0x05C7);  // 希伯来余项点
}

std::u32string strip_combining(const std::u32string& text) {
  std::u32string result;
  result.reserve(text.size());
  for (char32_t c : text) {
    if (!is_combining_to_strip(c)) {
      result += c;
    }
  }
  return result;
}

// P3：预合成拉丁变音字母 → ASCII 基字母（curated，覆盖 Latin-1 Supplement）。
// 处理“预合成”文本（实际文本主流）；P2 处理“已分解”文本。两者互补、互不依赖。
// 不折叠 ß/Æ/Œ 等会改变长度的连字，保留原样。Latin Extended-A 暂未覆盖（见计划风险节）。
char32_t precomposed_base(char32_t c) {
  switch (c) {
    case 0x00C0: case 0x00C1: case 0x00C2: case 0x00C3: case 0x00C4: case 0x00C5: return U'A';
    case 0x00C7: return U'C';
    case 0x00C8: case 0x00C9: case 0x00CA: case 0x00CB: return U'E';
    case 0x00CC: case 0x00CD: case 0x00CE: case 0x00CF: return U'I';
    case 0x00D1: return U'N';
    case 0x00D2: case 0x00D3: case 0x00D4: case 0x00D5: case 0x00D6: case 0x00D8: return U'O';
    case 0x00D9: case 0x00DA: case 0x00DB: case 0x00DC: return U'U';
    case 0x00DD: return U'Y';
    case 0x00E0: case 0x00E1: case 0x00E2: case 0x00E3: case 0x00E4: case 0x00E5: return U'a';
    case 0x00E7: return U'c';
    case 0x00E8: case 0x00E9: case 0x00EA: case 0x00EB: return U'e';
    case 0x00EC: case 0x00ED: case 0x00EE: case 0x00EF: return U'i';
    case 0x00F1: return U'n';
    case 0x00F2: case 0x00F3: case 0x00F4: case 0x00F5: case 0x00F6: case 0x00F8: return U'o';
    case 0x00F9: case 0x00FA: case 0x00FB: case 0x00FC: return U'u';
    case 0x00FD: case 0x00FF: return U'y';
    default: return c;
  }
}

std::u32string strip_precomposed(const std::u32string& text) {
  std::u32string result;
  result.reserve(text.size());
  for (char32_t c : text) {
    result += precomposed_base(c);
  }
  return result;
}

// P2 + P3 作为两个独立 {0,1} 处理器，靠 process() 的变体扇出自然组合
// （既分解、又预合成的词会得到各自变体）。
std::vector<TextProcessor> get_diacritic_removal_processors() {
  return {
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? strip_combining(text) : text;
       }},
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? strip_precomposed(text) : text;
       }},
  };
}

std::vector<TextProcessor> get_english_processors() {
  return {
      // lowercase
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         if (opt == 1) {
           return to_lowercase(text);
         }
         return text;
       }},
  };
}

// NFKC 兼容分解 + 正则合成（utf8proc）：折叠全角拉丁/数字、合字、上下标等
// 兼容字符到规范形（全角 Ａ -> 半角 A）。失败时回退原文。
std::u32string nfkc(const std::u32string& text) {
  std::string utf8 = utf8::utf32to8(text);
  utf8proc_uint8_t* out = utf8proc_NFKC(reinterpret_cast<const utf8proc_uint8_t*>(utf8.c_str()));
  if (!out) {
    return text;
  }
  std::string result(reinterpret_cast<char*>(out));
  utf8proc_free(out);
  return utf8::utf8to32(result);
}

// https://github.com/yomidevs/yomitan/blob/3440451aecb23a43f308857969c890a55ce34a91/ext/js/language/ja/japanese.js#L489
// ASCII 字母数字 -> 全角等价（纯码点位移，无依赖）。与 NFKC 互补，覆盖词典里
// 以全角字母数字收录的条目。
std::u32string alphanumeric_to_fullwidth(const std::u32string& text) {
  std::u32string result;
  for (char32_t c : text) {
    if (is_in_range(c, U'0', U'9')) {
      c = static_cast<char32_t>(c + (0xff10 - 0x30));
    } else if (is_in_range(c, U'A', U'Z')) {
      c = static_cast<char32_t>(c + (0xff21 - 0x41));
    } else if (is_in_range(c, U'a', U'z')) {
      c = static_cast<char32_t>(c + (0xff41 - 0x61));
    }
    result += c;
  }
  return result;
}

// TODO: implement rest of preprocessors
std::vector<TextProcessor> get_japanese_processors() {
  return {
      // https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese-text-preprocessors.js#L66
      {.options = {0, 1, 2},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
             switch (opt) {
               case 1:
                 return katakana_to_hiragana(text);
               case 2:
                 return hiragana_to_katakana(text);
               default:
                 return text;
             }
           }},
      // NFKC 在 english 的 to_lowercase 之前跑（japanese 链先于 english 链）：
      // 全角 Ａ 先经 NFKC 折成半角 A，再被 to_lowercase 小写成 a。顺序关键。
      {.options = {0, 1},
       .process = [](const std::u32string& text, int opt) -> std::u32string { return opt == 1 ? nfkc(text) : text; }},
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? alphanumeric_to_fullwidth(text) : text;
       }}};
}
}

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/translator.js#L564
std::vector<TextVariant> text_processor::process(const std::string& src) {
  std::u32string text = utf8::utf8to32(src);
  std::map<std::u32string, int> variants = {{text, 0}};

  auto all_processors = get_japanese_processors();
  auto en_processors = get_english_processors();
  all_processors.insert(all_processors.end(), en_processors.begin(), en_processors.end());
  auto dia_processors = get_diacritic_removal_processors();
  all_processors.insert(all_processors.end(), dia_processors.begin(), dia_processors.end());

  for (const auto& processor : all_processors) {
    std::map<std::u32string, int> next;

    for (const auto& [variant, steps] : variants) {
      for (int option : processor.options) {
        auto processed = processor.process(variant, option);
        int new_steps = (processed == variant) ? steps : steps + 1;

        auto [it, inserted] = next.try_emplace(processed, new_steps);
        if (!inserted && new_steps < it->second) {
          it->second = new_steps;
        }
      }
    }
    variants = std::move(next);
  }

  return variants |
         std::views::transform([](const auto& v) { return TextVariant{utf8::utf32to8(v.first), v.second}; }) |
         std::ranges::to<std::vector>();
}

#include "text_processor.hpp"

#include <utf8.h>
#include <utf8proc.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

#include "kanji_standardization_data.h"

namespace {
struct TextProcessor {
  std::vector<int> options;
  std::function<std::u32string(const std::u32string&, int)> process;
};

// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L21
constexpr uint32_t KATAKANA_SMALL_KA = 0x30f5;
constexpr uint32_t KATAKANA_SMALL_KE = 0x30f6;
constexpr uint32_t KANA_PROLONGED_SOUND_MARK = 0x30fc;
constexpr uint32_t HIRAGANA_SMALL_TSU = 0x3063;
constexpr uint32_t KATAKANA_SMALL_TSU = 0x30c3;

constexpr uint32_t HIRAGANA_CONVERSION_RANGE_START = 0x3041;
constexpr uint32_t HIRAGANA_CONVERSION_RANGE_END = 0x3096;

constexpr uint32_t KATAKANA_CONVERSION_RANGE_START = 0x30a1;
constexpr uint32_t KATAKANA_CONVERSION_RANGE_END = 0x30f6;

// 上游 9dc93b6：迭代符展开
constexpr char32_t KANJI_ITERATION_MARK = 0x3005;
constexpr char32_t HIRAGANA_ITERATION_MARK = 0x309d;
constexpr char32_t HIRAGANA_VOICED_ITERATION_MARK = 0x309e;
constexpr char32_t KATAKANA_ITERATION_MARK = 0x30fd;
constexpr char32_t KATAKANA_VOICED_ITERATION_MARK = 0x30fe;
constexpr char32_t DAKUTEN = 0x3099;

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

bool is_emphatic(char32_t c) {
  return c == HIRAGANA_SMALL_TSU || c == KATAKANA_SMALL_TSU || c == KANA_PROLONGED_SOUND_MARK;
}

// 上游 aaf75c9：折叠连续强调符（っっ→っ/ーー→ー）。首尾强调符保留。
// https://github.com/yomidevs/yomitan/blob/81d17d877fb18c62ba826210bf6db2b7f4d4deed/ext/js/language/ja/japanese.js#L776
// 上游的 full_collapse 模式（把单个っ/ッ/ー整个删掉）故意不移植：它会把含促音/长音的
// 正常词吞字（ヒットで→ひとで 命中「海星」、きって→きて），且吞字变体消耗的源文本更长、
// 在最长匹配优先排序下必然压过原形精确匹配；Yomitan 侧该模式也是默认关闭的用户选项（BUG-1777）。
std::u32string collapse_emphatic_sequences(const std::u32string& text) {
  ptrdiff_t left = 0;
  while (left < static_cast<ptrdiff_t>(text.size()) && is_emphatic(text[left])) {
    ++left;
  }
  ptrdiff_t right = static_cast<ptrdiff_t>(text.size()) - 1;
  while (right >= 0 && is_emphatic(text[right])) {
    --right;
  }
  if (left > right) {
    return text;
  }

  std::u32string leading_emphatics = text.substr(0, left);
  std::u32string trailing_emphatics = text.substr(right + 1);
  std::u32string middle;
  auto current_collapsed_code_point = static_cast<char32_t>(-1);

  for (ptrdiff_t i = left; i <= right; ++i) {
    char32_t c = text[i];
    if (is_emphatic(c)) {
      if (current_collapsed_code_point != c) {
        current_collapsed_code_point = c;
        middle += c;
      }
    } else {
      current_collapsed_code_point = static_cast<char32_t>(-1);
      middle += c;
    }
  }

  return leading_emphatics + middle + trailing_emphatics;
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

// BUG-2056：撇号有多个码点写法，词形还原规则与词典条目却只认一种。
// 真实 EPUB 的英文缩合形/所有格几乎一律用排版撇号 U+2019（don’t / John’s），而
// assets/transforms/en.json 的五条撇号规则（'s / s' / 'd / in' / "don't "）与绝大
// 多数英文词典的条目键都是 ASCII U+0027。NFKC 帮不上忙——U+2019 没有兼容分解
// （utf8proc_NFKC("’") 仍是 "’"）。所以哪怕扫描层把 don’t 整词送了进来，还原与查
// 表两级仍会全部落空，最终命中的还是修复前那条 "don"。
//
// 折成**一个规范码点**并双向各出一路变体（option 0 保留原文，既有命中一条不丢）：
//   option 1: 所有撇号 -> ASCII '    查询 don’t 命中 ASCII 条目 / ASCII 还原规则
//   option 2: 所有撇号 -> U+2019 ’   查询 don't 命中以排版撇号建键的词典
// 覆盖「文本写法 x 词典写法」四格全部，且无撇号文本 processed == variant，变体集
// 原地折叠、零额外查询。
constexpr char32_t APOSTROPHE_ASCII = U'\'';
constexpr char32_t APOSTROPHE_RIGHT_SINGLE = 0x2019;

bool is_apostrophe_like(char32_t c) {
  return c == APOSTROPHE_ASCII ||     // '  U+0027
         c == 0x2018 ||               // ‘  左单引号（OCR 常把 ’ 认成它）
         c == APOSTROPHE_RIGHT_SINGLE ||  // ’  U+2019
         c == 0x02BC;                 // ʼ  MODIFIER LETTER APOSTROPHE
}

std::u32string normalize_apostrophes(const std::u32string& text, char32_t to) {
  std::u32string result;
  result.reserve(text.size());
  for (char32_t c : text) {
    result += is_apostrophe_like(c) ? to : c;
  }
  return result;
}

std::vector<TextProcessor> get_english_processors() {
  return {
      // BUG-2056：撇号写法归一（见上）。放在 lowercase 之前或之后都一样——两个处理器
      // 互不依赖，变体扇出会把两种组合都算出来。
      {.options = {0, 1, 2},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
             switch (opt) {
               case 1:
                 return normalize_apostrophes(text, APOSTROPHE_ASCII);
               case 2:
                 return normalize_apostrophes(text, APOSTROPHE_RIGHT_SINGLE);
               default:
                 return text;
             }
           }},
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

// 上游 e7dfdea：异体字（異体字）-> 親字 标准化（来源 yomidevs/kanji-processor，MIT）。
// 上游用 C++23 #embed 嵌 full_list.json + 运行时 glaze 解析建 map；这里换成离线预生成
// 的 char32_t->char32_t 表（kanji_standardization_data.{h,cpp}），运行时零 JSON 解析，
// 且不依赖 MSVC/AppleClang 未必支持的 #embed。逐码点替换：命中变体则换親字，否则原样。
std::u32string standardize_kanji(const std::u32string& text) {
  static const auto map = [] {
    std::unordered_map<char32_t, char32_t> m;
    m.reserve(kanji_standardization::kVariantToParentCount);
    for (std::size_t i = 0; i < kanji_standardization::kVariantToParentCount; ++i) {
      const auto& entry = kanji_standardization::kVariantToParent[i];
      m[entry.variant] = entry.parent;
    }
    return m;
  }();

  std::u32string result;
  result.reserve(text.size());
  for (char32_t c : text) {
    auto it = map.find(c);
    result += it != map.end() ? it->second : c;
  }
  return result;
}

// 上游 9dc93b6：浊音迭代符（ゞ/ヾ）把前一假名 + 结合浊点经 NFC 合成浊音假名（こゞ→こご）。
char32_t add_dakuten(char32_t kana) {
  std::u32string pair = {kana, DAKUTEN};
  std::string utf8 = utf8::utf32to8(pair);
  utf8proc_uint8_t* out = utf8proc_NFC(reinterpret_cast<const utf8proc_uint8_t*>(utf8.c_str()));
  if (!out) {
    return kana;
  }
  std::u32string composed = utf8::utf8to32(std::string(reinterpret_cast<char*>(out)));
  utf8proc_free(out);
  return composed.size() == 1 ? composed.front() : kana;
}

char32_t expand_mark(char32_t prev, char32_t mark) {
  switch (mark) {
    case KANJI_ITERATION_MARK:
    case HIRAGANA_ITERATION_MARK:
    case KATAKANA_ITERATION_MARK:
      return prev;
    case HIRAGANA_VOICED_ITERATION_MARK:
    case KATAKANA_VOICED_ITERATION_MARK:
      return add_dakuten(prev);
    default:
      return 0;
  }
}

// 上游 9dc93b6：迭代符展开（佐々木→佐佐木、こゝ→ここ）。
std::u32string expand_iteration_marks(const std::u32string& text) {
  std::u32string result;
  for (size_t i = 0; i < text.size(); ++i) {
    result += text[i];
    if (i + 1 < text.size()) {
      char32_t expanded = expand_mark(text[i], text[i + 1]);
      if (expanded != 0) {
        result += expanded;
        ++i;
      }
    }
  }
  return result;
}

// 上游 ee0384b：全角数字 → 汉字数字（２→二）。ASCII 数字靠链中更早的
// alphanumeric_to_fullwidth 先转全角，变体扇出组合后同样命中（2月→２月→二月）。
constexpr std::u32string_view KANJI_NUMBERS = U"〇一二三四五六七八九";
std::u32string numbers_to_kanji(const std::u32string& text) {
  std::u32string result;
  for (char32_t c : text) {
    if (is_in_range(c, 0xff10, 0xff19)) {
      result += KANJI_NUMBERS[c - 0xff10];
    } else {
      result += c;
    }
  }
  return result;
}

// TODO: implement rest of preprocessors
std::vector<TextProcessor> get_japanese_processors() {
  return {
      // 上游 1cb9b4b：NFKC 提到链首——半角片假名（ﾒｶﾞﾈ）须先归一成全宽才能被
      // 假名转换识别。仍满足「NFKC 在 english 的 to_lowercase 之前」（japanese 链先于
      // english 链）：全角 Ａ 先折成半角 A，再被 to_lowercase 小写成 a。
      {.options = {0, 1},
       .process = [](const std::u32string& text, int opt) -> std::u32string { return opt == 1 ? nfkc(text) : text; }},
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
      // 上游 aaf75c9：强调折叠在假名转换后、宽度处理前（对齐上游链序）。
      // full_collapse 模式故意不挂链（见 collapse_emphatic_sequences 注释，BUG-1777）。
      {.options = {0, 1},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
             return opt == 1 ? collapse_emphatic_sequences(text) : text;
           }},
      {.options = {0, 1},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? alphanumeric_to_fullwidth(text) : text;
       }},
      // 上游 e7dfdea：异体字标准化处理器（独立于 NFKC，顺序无关）。
      {.options = {0, 1},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? standardize_kanji(text) : text;
       }},
      // 上游 9dc93b6 / ee0384b：迭代符展开与全角数字转汉字，按上游链序收尾。
      {.options = {0, 1},
       .process =
           [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? expand_iteration_marks(text) : text;
       }},
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? numbers_to_kanji(text) : text;
       }}};
}
}  // namespace

// ─────────────────────────── 谚文拆字 / 合字 ───────────────────────────
//
// 韩语的 transform 表（assets/transforms/ko.json，导自 Yomitan 的
// korean-transforms.js）**整表用 Hangul 兼容字母书写**：`부드러운 → 부드럽다`
// 那条 ㅂ 不规则写成 `{"fromSuffix":"ㅇㅜㄴ","toSuffix":"ㅂㄷㅏ"}`。实测 2682 条
// rule 里 2681 条含兼容字母。而 Deinflector 是**字节级精确查表**
// （deinflector.cpp 的 suffix_transforms_.find），预合成音节串 "부드러운"
// （U+BD80 U+B4DC U+B7EC U+C6B4）里永远不存在 "ㅇㅜㄴ" 那三个码点，于是韩语
// 450 条 transform 一条都点不着火（BUG-2148）。
//
// 上游靠一对处理器把两边编码对齐：`disassembleHangul` 预处理拆字去匹配规则，
// `reassembleHangul` 后处理拼回音节去查词典索引。这里补的就是这一对。
//
// 拆到**简单字母**——复合元音 ㅘ 拆成 ㅗㅏ、复合终声 ㄺ 拆成 ㄹㄱ。这不是选择而是
// 实测：ko.json 的字符表里 ㅘㅙㅚㅝㅞㅟㅢ 与 ㄳㄵㄶㄺㄻㄼㄽㄾㄿㅀㅄ **一个都没有**，
// 表就是按拆到底写的。
namespace {
// 初声 19 个（L 索引 0..18）→ 兼容字母。
constexpr char32_t kLeadCompat[19] = {U'ㄱ', U'ㄲ', U'ㄴ', U'ㄷ', U'ㄸ', U'ㄹ', U'ㅁ',
                                      U'ㅂ', U'ㅃ', U'ㅅ', U'ㅆ', U'ㅇ', U'ㅈ', U'ㅉ',
                                      U'ㅊ', U'ㅋ', U'ㅌ', U'ㅍ', U'ㅎ'};
// 中声 21 个在兼容字母区连续排列，直接算：U+314F + V。
constexpr char32_t kVowelBase = 0x314F;
constexpr char32_t kVowelLast = 0x3163;
// 终声 28 个（T 索引 0 = 无终声）→ 兼容字母。
constexpr char32_t kTailCompat[28] = {0,    U'ㄱ', U'ㄲ', U'ㄳ', U'ㄴ', U'ㄵ', U'ㄶ',
                                      U'ㄷ', U'ㄹ', U'ㄺ', U'ㄻ', U'ㄼ', U'ㄽ', U'ㄾ',
                                      U'ㄿ', U'ㅀ', U'ㅁ', U'ㅂ', U'ㅄ', U'ㅅ', U'ㅆ',
                                      U'ㅇ', U'ㅈ', U'ㅊ', U'ㅋ', U'ㅌ', U'ㅍ', U'ㅎ'};

constexpr char32_t kSyllableFirst = 0xAC00;
constexpr char32_t kSyllableLast = 0xD7A3;
constexpr int kVowelCount = 21;
constexpr int kTailCount = 28;

// 复合字母 ↔ 组成它的两个简单字母。元音与终声共用一张表：两侧值域不相交
// （元音在 U+314F..U+3163，终声簇在 U+3133..U+3144），合成时再按位置校验。
struct JamoPair {
  char32_t complex_jamo;
  char32_t first;
  char32_t second;
};
constexpr JamoPair kComplexJamo[] = {
    {U'ㄳ', U'ㄱ', U'ㅅ'}, {U'ㄵ', U'ㄴ', U'ㅈ'}, {U'ㄶ', U'ㄴ', U'ㅎ'}, {U'ㄺ', U'ㄹ', U'ㄱ'},
    {U'ㄻ', U'ㄹ', U'ㅁ'}, {U'ㄼ', U'ㄹ', U'ㅂ'}, {U'ㄽ', U'ㄹ', U'ㅅ'}, {U'ㄾ', U'ㄹ', U'ㅌ'},
    {U'ㄿ', U'ㄹ', U'ㅍ'}, {U'ㅀ', U'ㄹ', U'ㅎ'}, {U'ㅄ', U'ㅂ', U'ㅅ'}, {U'ㅘ', U'ㅗ', U'ㅏ'},
    {U'ㅙ', U'ㅗ', U'ㅐ'}, {U'ㅚ', U'ㅗ', U'ㅣ'}, {U'ㅝ', U'ㅜ', U'ㅓ'}, {U'ㅞ', U'ㅜ', U'ㅔ'},
    {U'ㅟ', U'ㅜ', U'ㅣ'}, {U'ㅢ', U'ㅡ', U'ㅣ'},
};

bool is_compat_vowel(char32_t c) { return c >= kVowelBase && c <= kVowelLast; }

// 把复合字母摊成组成字母；简单字母原样追加。
void append_decomposed(std::u32string& out, char32_t jamo) {
  for (const auto& pair : kComplexJamo) {
    if (pair.complex_jamo == jamo) {
      out += pair.first;
      out += pair.second;
      return;
    }
  }
  out += jamo;
}

// 两个简单字母能否合成一个复合字母；不能则返回 0。
char32_t compose_pair(char32_t first, char32_t second) {
  for (const auto& pair : kComplexJamo) {
    if (pair.first == first && pair.second == second) return pair.complex_jamo;
  }
  return 0;
}

// 兼容字母 → 初声索引，非初声返回 -1。
int lead_index(char32_t c) {
  for (int i = 0; i < 19; i++) {
    if (kLeadCompat[i] == c) return i;
  }
  return -1;
}

// 兼容字母 → 终声索引，非终声返回 0（= 无终声）。
int tail_index(char32_t c) {
  for (int i = 1; i < kTailCount; i++) {
    if (kTailCompat[i] == c) return i;
  }
  return 0;
}
}  // namespace

std::u32string text_processor::disassemble_hangul(const std::u32string& text) {
  // 早退：串里既没有预合成音节也没有兼容字母时原样返回。这个处理器挂在**所有语言**
  // 共用的处理器链上（process() 无语言路由），日/英查询的每个变体都会过一遍它，
  // 而下面的 append_decomposed 对每个字符都要线性扫一遍复合字母表——不早退等于
  // 给非韩语查询白加一份开销。
  bool has_hangul = false;
  for (char32_t c : text) {
    if ((c >= kSyllableFirst && c <= kSyllableLast) || (c >= 0x3130 && c <= 0x318F)) {
      has_hangul = true;
      break;
    }
  }
  if (!has_hangul) return text;

  std::u32string out;
  // 单音节最大展开是 5，不是 3：`곿` = ㄱ + (ㅘ→ㅗㅏ) + (ㄳ→ㄱㅅ)。11172 个音节里
  // 1463 个展开成 5、5054 个展开成 4，按 3 倍预留则绝大多数韩语串都要 realloc。
  out.reserve(text.size() * 5);
  for (char32_t c : text) {
    if (c >= kSyllableFirst && c <= kSyllableLast) {
      const int s = static_cast<int>(c - kSyllableFirst);
      const int lead = s / (kVowelCount * kTailCount);
      const int vowel = (s % (kVowelCount * kTailCount)) / kTailCount;
      const int tail = s % kTailCount;
      append_decomposed(out, kLeadCompat[lead]);
      append_decomposed(out, kVowelBase + static_cast<char32_t>(vowel));
      if (tail != 0) append_decomposed(out, kTailCompat[tail]);
    } else {
      // 已经是兼容字母的复合形（用户直接输入、或词典里就这么写）也拆开，
      // 这样拆字后的串与 ko.json 的书写法完全同域。
      append_decomposed(out, c);
    }
  }
  return out;
}

std::u32string text_processor::reassemble_hangul(const std::u32string& text) {
  std::u32string out;
  out.reserve(text.size());
  const size_t n = text.size();
  size_t i = 0;
  while (i < n) {
    const int lead = lead_index(text[i]);
    if (lead < 0 || i + 1 >= n) {
      out += text[i++];
      continue;
    }
    // 中声：优先按两个简单元音合成复合元音（ㅗ+ㅏ → ㅘ）。
    char32_t vowel = text[i + 1];
    size_t vowel_len = 1;
    if (i + 2 < n) {
      const char32_t merged = compose_pair(text[i + 1], text[i + 2]);
      if (merged != 0 && is_compat_vowel(merged)) {
        vowel = merged;
        vowel_len = 2;
      }
    }
    if (!is_compat_vowel(vowel)) {
      out += text[i++];
      continue;
    }
    size_t j = i + 1 + vowel_len;
    // 终声：**只有后面不跟元音时才收**——这正是「ㅂ 是上一个音节的终声还是下一个
    // 音节的初声」的唯一判据。`ㅂㅜㄷㅡㄹㅓㅂㄷㅏ` 里第二个 ㅂ 后面是 ㄷ 不是元音，
    // 收进 러 得到 럽；`ㅎㅏㄱㅗ` 里 ㄱ 后面是 ㅗ，不收，另起一个音节 고。
    int tail = 0;
    size_t tail_len = 0;
    if (j < n) {
      if (j + 1 < n) {
        const char32_t merged = compose_pair(text[j], text[j + 1]);
        const int merged_tail = merged != 0 ? tail_index(merged) : 0;
        if (merged_tail != 0 && (j + 2 >= n || !is_compat_vowel(text[j + 2]))) {
          tail = merged_tail;
          tail_len = 2;
        }
      }
      if (tail_len == 0) {
        const int single = tail_index(text[j]);
        if (single != 0 && (j + 1 >= n || !is_compat_vowel(text[j + 1]))) {
          tail = single;
          tail_len = 1;
        }
      }
    }
    const int vowel_idx = static_cast<int>(vowel - kVowelBase);
    out += kSyllableFirst +
           static_cast<char32_t>((lead * kVowelCount + vowel_idx) * kTailCount + tail);
    i = j + tail_len;
  }
  return out;
}

std::string text_processor::reassemble_hangul_utf8(const std::string& text) {
  // U+3130..U+318F（兼容字母）在 UTF-8 里恒为 E3 84/85/86 xx。扫到这个两字节前缀
  // 才值得做编码转换；扫不到就一定没有可合成的字母，原样返回。判据是**超集**
  // （E3 84.. 还覆盖 U+3000..U+31BF 的别的字符），误判只是多做一次恒等转换，
  // 不会漏掉真正需要合成的串。
  bool maybe_jamo = false;
  for (size_t i = 0; i + 1 < text.size(); i++) {
    const auto b0 = static_cast<unsigned char>(text[i]);
    const auto b1 = static_cast<unsigned char>(text[i + 1]);
    if (b0 == 0xE3 && (b1 == 0x84 || b1 == 0x85 || b1 == 0x86)) {
      maybe_jamo = true;
      break;
    }
  }
  if (!maybe_jamo) return text;
  return utf8::utf32to8(reassemble_hangul(utf8::utf8to32(text)));
}

namespace {
std::vector<TextProcessor> get_korean_processors() {
  return {
      // 拆字（BUG-2148）。对不含谚文的文本是恒等变换，变体表按结果去重，
      // 所以日/英查询不会因为它多出任何一个变体。
      {.options = {0, 1}, .process = [](const std::u32string& text, int opt) -> std::u32string {
         return opt == 1 ? text_processor::disassemble_hangul(text) : text;
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
  // 韩语拆字**必须挂在链尾**，这是一条隐式但要命的顺序不变式：链首附近的 nfkc
  // （get_japanese_processors 里那条）会把兼容字母兼容分解再规范合成回预合成音节，
  // NFKC("ㅂㅜㄷㅡ") == "부드"。把 get_korean_processors 前移到 nfkc 之前，拆字会被
  // 静默撤销、BUG-2148 原样复发，且端到端测试之外的任何单测都照绿。
  // 守卫见 korean_hangul_lookup_test 的「链序」一组。
  //
  // 反向也靠这个顺序：NFD 形式的韩语（U+1100 组合字母块，macOS 文件名/字幕常见）
  // disassemble_hangul 的早退范围认不出，靠链首 nfkc 先归一成预合成音节，韩语处理器
  // 在链尾正好接住。
  auto ko_processors = get_korean_processors();
  all_processors.insert(all_processors.end(), ko_processors.begin(), ko_processors.end());

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

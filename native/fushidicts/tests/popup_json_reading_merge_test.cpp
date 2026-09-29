// BUG-2753：build_popup_json 的词头分组必须与 Dart 侧 lookupHeadwordKey /
// soleExplicitReadings（packages/fushi_dictionary/lib/src/language/language.dart）
// 同一口径。Android 系统划词弹窗（PopupDictActivity → nativeLookupJson）走的是
// 这一份 C++ 实现。
//
//   * MDX/StarDict/DSL 读音恒空：同表记只有一个显式读音 → 空读音行并入该卡，
//     卡片读音取显式读音（即使空读音行先到）。
//   * 同表记有多个显式读音 → 不猜，空读音行自成一组。
//   * BUG-791：假名词的空读音视同表记，与显式读音 = 表记的行合卡。
//
// Dart 侧对应用例见 fushi/test/pages/dictionary_popup_empty_reading_group_test.dart。
//
// Usage: popup_json_reading_merge_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/popup_json.hpp"

static int g_fail = 0;

static int count(const std::string& haystack, const std::string& needle) {
  int n = 0;
  for (size_t pos = haystack.find(needle); pos != std::string::npos;
       pos = haystack.find(needle, pos + needle.size())) {
    ++n;
  }
  return n;
}

static void expect_count(const char* name, const std::string& json,
                         const std::string& needle, int want) {
  const int got = count(json, needle);
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: want %d x %s, got %d\n  in: %s\n", name,
                 want, needle.c_str(), got, json.c_str());
    ++g_fail;
  }
}

static LookupResult make(const std::string& expression,
                         const std::string& reading, const std::string& dict) {
  LookupResult r;
  r.matched = expression;
  r.deinflected = expression;
  r.preprocessor_steps = 0;
  r.term.expression = expression;
  r.term.reading = reading;
  r.term.rules = "";
  GlossaryEntry g;
  g.dict_name = dict;
  g.glossary = "[\"x\"]";
  g.definition_tags = "";
  g.term_tags = "";
  r.term.glossaries.push_back(g);
  return r;
}

int main() {
  const std::string torimodosu =
      "\xe5\x8f\x96\xe3\x82\x8a\xe6\x88\xbb\xe3\x81\x99";  // 取り戻す
  const std::string reading =
      "\xe3\x81\xa8\xe3\x82\x8a\xe3\x82\x82\xe3\x81\xa9\xe3\x81\x99";  // とりもどす

  // ① Yomitan 显式读音 + 两本 MDX 空读音 → 一张卡，读音 とりもどす。
  {
    const std::string json = build_popup_json(
        {make(torimodosu, reading, "JMdict"), make(torimodosu, "", "MDX-A"),
         make(torimodosu, "", "MDX-B")},
        100);
    expect_count("merge-cards", json, "\"expression\":", 1);
    expect_count("merge-reading", json, "\"reading\":\"" + reading + "\"", 1);
    expect_count("merge-glossaries", json, "\"dictionary\":\"MDX-", 2);
  }

  // ② MDX 行先到：卡片读音仍是补全后的显式读音，不是空串。
  {
    const std::string json = build_popup_json(
        {make(torimodosu, "", "MDX-A"), make(torimodosu, reading, "JMdict")},
        100);
    expect_count("mdx-first-cards", json, "\"expression\":", 1);
    expect_count("mdx-first-reading", json,
                 "\"reading\":\"" + reading + "\"", 1);
  }

  // ③ 多读音（辛い＝つらい／からい）+ 空读音 → 三组，空读音不被塞进任一组。
  {
    const std::string karai_expr = "\xe8\xbe\x9b\xe3\x81\x84";  // 辛い
    const std::string json = build_popup_json(
        {make(karai_expr, "\xe3\x81\xa4\xe3\x82\x89\xe3\x81\x84", "A"),
         make(karai_expr, "\xe3\x81\x8b\xe3\x82\x89\xe3\x81\x84", "B"),
         make(karai_expr, "", "C")},
        100);
    expect_count("ambiguous-cards", json, "\"expression\":", 3);
    expect_count("ambiguous-empty", json, "\"reading\":\"\"", 1);
  }

  // ④ BUG-791：假名词显式读音 = 表记 + 空读音 → 一张卡。
  {
    const std::string soredake =
        "\xe3\x81\x9d\xe3\x82\x8c\xe3\x81\xa0\xe3\x81\x91";  // それだけ
    const std::string json = build_popup_json(
        {make(soredake, soredake, "A"), make(soredake, "", "B")}, 100);
    expect_count("kana-cards", json, "\"expression\":", 1);
  }

  if (g_fail != 0) {
    std::fprintf(stderr, "popup_json_reading_merge_test: %d failure(s)\n",
                 g_fail);
    return 1;
  }
  std::printf("popup_json_reading_merge_test: PASS\n");
  return 0;
}

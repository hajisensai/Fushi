// build_popup_json(results, PopupJsonOptions)：app 内弹窗 / 浏览器扩展 / 无头服务端的
// 弹窗 JSON 语义。这些定点用例从 Dart 侧迁来——弹窗 JSON 以前由 Dart
// `buildPopupJsonFromLookup` 生成，现在只有这一份原生实现：
//   * BUG-1472 预算按词头计：fushi/test/models/lookup_term_budget_counts_headwords_test.dart、
//     fushi/test/pages/dictionary_popup_webview_test.dart（maximumTerms 两条）
//   * 隐藏词典在源头剔除、不占预算：fushi/test/models/lookup_hidden_dictionary_entries_test.dart、
//     fushi/test/pages/popup_hidden_dictionary_filter_test.dart
//   * 词典顺序按整卡稳定排序（BUG-2579）：fushi/test/models/dictionary_order_render_contract_test.dart
//   * 变形标签译成界面语言（BUG-2038）：只在显示路径翻译
//   * 回落标签 `matched → deinflected` 三分支：dictionary_popup_webview_test.dart
// 旧 Dart 实现对伪随机输入的逐字节向量见 popup_json_vectors_test.cpp；空读音并卡见
// popup_json_reading_merge_test.cpp。
//
// Usage: popup_json_options_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/popup_json.hpp"

namespace {

int g_fail = 0;

int count(const std::string& haystack, const std::string& needle) {
  int n = 0;
  for (size_t pos = haystack.find(needle); pos != std::string::npos; pos = haystack.find(needle, pos + needle.size())) {
    ++n;
  }
  return n;
}

void expect_count(const char* name, const std::string& json, const std::string& needle, int want) {
  const int got = count(json, needle);
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: want %d x %s, got %d\n  in: %s\n", name, want, needle.c_str(), got, json.c_str());
    ++g_fail;
  }
}

void expect_eq(const char* name, const std::string& got, const std::string& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s:\n  want: %s\n  got:  %s\n", name, want.c_str(), got.c_str());
    ++g_fail;
  }
}

// 第 [nth] 次出现的 needle 的位置（不存在返回 npos）。
size_t find_nth(const std::string& s, const std::string& needle, int nth) {
  size_t pos = s.find(needle);
  for (int i = 1; i < nth && pos != std::string::npos; i++) pos = s.find(needle, pos + 1);
  return pos;
}

void expect_order(const char* name, const std::string& json, const std::vector<std::string>& in_order) {
  size_t last = 0;
  for (const std::string& needle : in_order) {
    const size_t at = json.find(needle, last);
    if (at == std::string::npos) {
      std::fprintf(stderr, "FAIL %s: %s not found in order\n  in: %s\n", name, needle.c_str(), json.c_str());
      ++g_fail;
      return;
    }
    last = at + needle.size();
  }
}

LookupResult row(const std::string& expression, const std::string& reading, const std::vector<std::string>& dicts,
                 const std::string& matched = "", const std::string& deinflected = "",
                 std::vector<TransformGroup> trace = {}) {
  LookupResult r;
  r.matched = matched.empty() ? expression : matched;
  r.deinflected = deinflected.empty() && matched.empty() ? expression : deinflected;
  r.trace = std::move(trace);
  r.preprocessor_steps = 0;
  r.term.expression = expression;
  r.term.reading = reading;
  for (const std::string& dict : dicts) {
    GlossaryEntry g;
    g.dict_name = dict;
    g.glossary = "[\"" + dict + ":" + expression + "\"]";
    r.term.glossaries.push_back(g);
  }
  return r;
}

PopupJsonOptions opts(int max_terms) {
  PopupJsonOptions o;
  o.max_terms = max_terms;
  return o;
}

const std::string kEien = "\xe6\xb0\xb8\xe9\x81\xa0";                        // 永遠
const std::string kEiEn = "\xe3\x81\x88\xe3\x81\x84\xe3\x81\x88\xe3\x82\x93";  // えいえん
const std::string kTowa = "\xe3\x81\xa8\xe3\x82\x8f";                        // とわ
const std::string kTokoshie = "\xe3\x81\xa8\xe3\x81\x93\xe3\x81\x97\xe3\x81\x88";  // とこしえ
const std::string kTaberu = "\xe9\xa3\x9f\xe3\x81\xb9\xe3\x82\x8b";            // 食べる
const std::string kTabeta = "\xe9\xa3\x9f\xe3\x81\xb9\xe3\x81\x9f";            // 食べた
const std::string kArrow = " \xe2\x86\x92 ";                                   // →

}  // namespace

int main() {
  // ---- BUG-1472：预算按词头计，不按注释行计 ----------------------------------
  {
    // 永遠/えいえん 一个词头带 12 条注释，とわ / とこしえ 各一条：上限 10 也必须出全三个读音。
    std::vector<std::string> many;
    for (int i = 0; i < 12; i++) many.push_back("G" + std::to_string(i));
    const std::vector<LookupResult> eien = {row(kEien, kEiEn, many), row(kEien, kTowa, {"Daijirin"}),
                                            row(kEien, kTokoshie, {"Daijirin"})};
    const std::string json = build_popup_json(eien, opts(10));
    expect_count("1472-three-readings", json, "\"expression\":", 3);
    expect_count("1472-all-glossaries", json, "\"dictionary\":\"G", 12);
    expect_count("1472-cap-truncates-headwords", build_popup_json(eien, opts(2)), "\"expression\":", 2);
  }
  {
    // 同一词头（食べる/たべる）两行共 3 条注释：上限 2 只出一张卡，注释一条不少。
    const std::vector<LookupResult> taberu = {row(kTaberu, "x", {"JMdict", "Daijisen"}),
                                              row(kTaberu, "x", {"Kenkyusha"})};
    const std::string json = build_popup_json(taberu, opts(2));
    expect_count("1472-one-card", json, "\"expression\":", 1);
    expect_count("1472-no-halving", json, "\"dictionary\":", 3);
    // 旧 JNI 口径（注释行预算）原样保留：同一输入只剩 2 条注释。
    expect_count("legacy-glossary-budget", build_popup_json(taberu, 2), "\"dictionary\":", 2);
    // 第二个词头在上限 1 时被截掉。
    const std::vector<LookupResult> two = {row(kTaberu, "x", {"JMdict"}), row("Kuberu", "y", {"Daijirin"})};
    expect_count("1472-cap-1", build_popup_json(two, opts(1)), "\"expression\":", 1);
  }
  expect_eq("empty", build_popup_json({}, opts(100)), "[]");

  // ---- BUG-1307：引擎上限 = 词头预算后输出逐字节不变 ---------------------------
  // 迁自 fushi/test/models/dict_engine_max_results_alignment_test.dart：200 条结果与截到
  // max_terms 条（引擎 partial_sort + resize 之后）拼出的弹窗 JSON 必须相同。
  {
    std::vector<LookupResult> full;
    for (int i = 0; i < 200; i++) full.push_back(row("W" + std::to_string(i), "r" + std::to_string(i), {"A", "B"}));
    for (int max_terms : {1, 3, 10, 25}) {
      const std::vector<LookupResult> capped(full.begin(), full.begin() + max_terms);
      expect_eq(("1307-cap-" + std::to_string(max_terms)).c_str(), build_popup_json(capped, opts(max_terms)),
                build_popup_json(full, opts(max_terms)));
    }
  }

  // ---- 隐藏词典：源头剔除，不建卡、不占预算 -----------------------------------
  {
    PopupJsonOptions o = opts(10);
    o.hidden = {"Hidden"};
    expect_eq("hidden-only", build_popup_json({row(kEien, kEiEn, {"Hidden"})}, o), "[]");

    PopupJsonOptions one = opts(1);
    one.hidden = {"Hidden"};
    const std::string json =
        build_popup_json({row(kEien, kEiEn, {"Hidden"}), row(kEien, kTowa, {"Daijirin", "Hidden"})}, one);
    expect_count("hidden-no-budget-card", json, "\"expression\":", 1);
    expect_count("hidden-no-budget-reading", json, "\"reading\":\"" + kTowa + "\"", 1);
    expect_count("hidden-glossary-dropped", json, "\"dictionary\":\"Hidden\"", 0);
    expect_count("hidden-visible-kept", json, "\"dictionary\":\"Daijirin\"", 1);
  }
  {
    // 隐藏词典的频率 / 音调只随可见释义合并：只有隐藏释义的行不贡献频率。
    LookupResult hidden_row = row(kEien, kEiEn, {"Hidden"});
    FrequencyEntry f;
    f.dict_name = "JPDB";
    f.frequencies.push_back(Frequency{7, "7"});
    hidden_row.term.frequencies.push_back(f);
    PopupJsonOptions o = opts(10);
    o.hidden = {"Hidden"};
    const std::string json = build_popup_json({row(kEien, kEiEn, {"Visible"}), hidden_row}, o);
    expect_count("hidden-row-no-freq", json, "\"JPDB\"", 0);
  }

  // ---- BUG-2579：词典顺序按整张卡稳定排序 -------------------------------------
  {
    PopupJsonOptions o = opts(10);
    o.dictionary_order = {"OALDPE", "wty-en-en"};
    const std::string json = build_popup_json({row("sorry", "", {"wty-en-en", "OALDPE"})}, o);
    expect_order("order-managed", json, {"\"dictionary\":\"OALDPE\"", "\"dictionary\":\"wty-en-en\""});
  }
  {
    // しんどい：Yomitan 行（明鏡 + 大辞林）在前、第二词头 しんど 夹中间、MDX 空读音行在后。
    const std::string shindoi = "\xe3\x81\x97\xe3\x82\x93\xe3\x81\xa9\xe3\x81\x84";
    const std::string shindo = "\xe3\x81\x97\xe3\x82\x93\xe3\x81\xa9";
    PopupJsonOptions o = opts(10);
    o.dictionary_order = {"Meikyo", "MDX", "Daijirin"};
    const std::string json = build_popup_json(
        {row(shindoi, shindoi, {"Meikyo", "Daijirin"}), row(shindo, shindo, {"Daijirin"}), row(shindoi, "", {"MDX"})},
        o);
    expect_count("2579-cards", json, "\"expression\":", 2);
    expect_order("2579-order", json,
                 {"\"expression\":\"" + shindoi + "\"", "\"dictionary\":\"Meikyo\"", "\"dictionary\":\"MDX\"",
                  "\"dictionary\":\"Daijirin\"", "\"expression\":\"" + shindo + "\""});
    // 不在顺序表里的词典排最后，同词典多条保持原相对顺序。
    PopupJsonOptions partial = opts(10);
    partial.dictionary_order = {"B"};
    const std::string stable = build_popup_json({row("w", "", {"A", "C", "B", "A"})}, partial);
    if (find_nth(stable, "\"dictionary\":\"B\"", 1) > find_nth(stable, "\"dictionary\":\"A\"", 1)) {
      std::fprintf(stderr, "FAIL unknown-last: B must lead\n  in: %s\n", stable.c_str());
      ++g_fail;
    }
    expect_order("stable-rest", stable,
                 {"\"dictionary\":\"B\"", "\"dictionary\":\"A\"", "\"dictionary\":\"C\"", "\"dictionary\":\"A\""});
  }

  // ---- 回落标签 matched → deinflected 三分支 ----------------------------------
  {
    expect_count("fallback-one", build_popup_json({row(kTaberu, "t", {"J"}, kTabeta, kTaberu)}, opts(100)),
                 "{\"name\":\"" + kTabeta + kArrow + kTaberu + "\",\"description\":\"\"}", 1);
    expect_count("fallback-none-same", build_popup_json({row(kTaberu, "t", {"J"}, kTaberu, kTaberu)}, opts(100)),
                 "\"deinflectionTrace\":[]", 1);
    LookupResult empty_deinflected = row(kTaberu, "t", {"J"}, kTabeta, "x");
    empty_deinflected.deinflected.clear();
    expect_count("fallback-none-empty", build_popup_json({empty_deinflected}, opts(100)), "\"deinflectionTrace\":[]",
                 1);
  }

  // ---- BUG-2038：变形标签按界面语言翻译（只在显示路径） ------------------------
  {
    const std::vector<LookupResult> results = {
        row(kTaberu, "t", {"J"}, kTabeta, kTaberu, {TransformGroup{"-ta", "past"}, TransformGroup{"-te", "te"}})};
    PopupTranslations zh = {{"-ta", "TA_ZH"}, {"past", "PAST_ZH"}};
    PopupJsonOptions o = opts(100);
    o.translations = &zh;
    // 显示顺序 = 接续顺序（trace 反转）；表里有的翻，没有的原样。
    expect_count("2038-translated", build_popup_json(results, o),
                 "\"deinflectionTrace\":[{\"name\":\"-te\",\"description\":\"te\"},"
                 "{\"name\":\"TA_ZH\",\"description\":\"PAST_ZH\"}]",
                 1);
    expect_count("2038-untranslated", build_popup_json(results, opts(100)),
                 "{\"name\":\"-ta\",\"description\":\"past\"}", 1);
    // 回落标签整串作键查表。
    PopupTranslations fallback_zh = {{kTabeta + kArrow + kTaberu, "FALLBACK_ZH"}};
    PopupJsonOptions fo = opts(100);
    fo.translations = &fallback_zh;
    expect_count("2038-fallback", build_popup_json({row(kTaberu, "t", {"J"}, kTabeta, kTaberu)}, fo),
                 "{\"name\":\"FALLBACK_ZH\",\"description\":\"\"}", 1);
  }

  // ---- 空读音分组（BUG-791 / BUG-2753）：popup_json_reading_merge_test 之外的三条 ----
  // 迁自 fushi/test/pages/dictionary_popup_empty_reading_group_test.dart。
  {
    const std::string soredake = "\xe3\x81\x9d\xe3\x82\x8c\xe3\x81\xa0\xe3\x81\x91";  // それだけ
    expect_count("791-two-empty-one-card",
                 build_popup_json({row(soredake, "", {"A"}), row(soredake, "", {"B"})}, opts(100)),
                 "\"expression\":", 1);
    const std::string torimodosu = "\xe5\x8f\x96\xe3\x82\x8a\xe6\x88\xbb\xe3\x81\x99";  // 取り戻す
    const std::string torimodosu_alt = "\xe5\x8f\x96\xe6\x88\xbb\xe3\x81\x99";         // 取戻す
    const std::string reading = "\xe3\x81\xa8\xe3\x82\x8a\xe3\x82\x82\xe3\x81\xa9\xe3\x81\x99";  // とりもどす
    const std::string only_empty =
        build_popup_json({row(torimodosu, "", {"A"}), row(torimodosu, "", {"B"})}, opts(100));
    expect_count("2753-only-empty-cards", only_empty, "\"expression\":", 1);
    expect_count("2753-only-empty-reading", only_empty, "\"reading\":\"\"", 1);
    const std::string no_spill =
        build_popup_json({row(torimodosu_alt, reading, {"A"}), row(torimodosu, "", {"B"})}, opts(100));
    expect_count("2753-no-spill-cards", no_spill, "\"expression\":", 2);
    expect_count("2753-no-spill-reading", no_spill,
                 "\"expression\":\"" + torimodosu + "\",\"reading\":\"\"", 1);
  }

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("popup_json_options_test: PASS\n");
  return 0;
}

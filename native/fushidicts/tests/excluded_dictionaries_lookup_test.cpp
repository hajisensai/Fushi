// LookupOptions::excluded_dictionaries：按请求排除词典（服务端常驻全部词典、每次查词按
// 客户端 profile 的启用集合切换）。语义 = 「这次查词当作没装这本词典」。
//
// 本测试钉：
//   1) 被排除词典的释义不出现：只有它收录的词头整条消失；与其它词典共有的词头只剩
//      未排除词典的释义；
//   2) 不占结果名额：排除发生在 partial_sort + resize(max_results) 之前——被排除词典
//      的更长匹配本会排第一，max_results=1 时返回的仍是未排除词典的结果；
//   3) 被排除的频率 / 音调词典不进 term.frequencies / term.pitches，也不影响比较器：
//      排序与「根本没装它」的宿主逐条一致（同时它排在注册顺序第一位，没排除时确实
//      会决定顺序——反证这条断言不是恒真）；
//   4) 空选项 / 排除一个不存在的词典名：结果与默认选项逐字段一致；
//   5) 跨词典合并的 score（取 max）不带入被排除词典的值——排除在查库层整本跳过，
//      不是事后摘 glossary。
//
// Usage: excluded_dictionaries_lookup_test (no args) -> exit 0 PASS, non-zero FAIL.
#include <algorithm>
#include <format>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "import_fixture.hpp"

namespace {

struct Failures {
  int count = 0;
  void fail(std::string_view msg) {
    std::cerr << std::format("FAIL: {}\n", msg);
    ++count;
  }
  void expect(bool ok, std::string_view msg) {
    if (!ok) fail(msg);
  }
};

constexpr const char* kTermKept = "ExclTermKept";
constexpr const char* kTermExcluded = "ExclTermGone";
constexpr const char* kFreqExcluded = "ExclFreqGone";
constexpr const char* kFreqKept = "ExclFreqKept";

std::string index_json(const char* title) {
  return std::format(R"({{"title":"{}","format":3,"revision":"test"}})", title);
}

// 词条行：[expression, reading, defTags, rules, score, [glossary], sequence, termTags]
std::string term_row(const std::string& expression, const std::string& reading, const std::string& gloss,
                     int score = 0) {
  return std::format(R"(["{}","{}","","",{},["{}"],0,""])", expression, reading, score, gloss);
}

std::string freq_row(const std::string& expression, const std::string& reading, int value) {
  return std::format(R"(["{}","freq",{{"reading":"{}","frequency":{}}}])", expression, reading, value);
}

std::string pitch_row(const std::string& expression, const std::string& reading, int position) {
  return std::format(R"(["{}","pitch",{{"reading":"{}","pitches":[{{"position":{}}}]}}])", expression, reading,
                     position);
}

std::string import_dict(Failures& f, const char* title, const std::string& bank_name, const std::string& bank) {
  std::string error;
  const std::string dir = fushi_test::import_fixture_dict(
      std::string("excl_") + title, {{"index.json", index_json(title)}, {bank_name, bank}},
      fushi_test::temp_dir() + "/fushi_excl_" + title, error);
  if (dir.empty()) f.fail(std::string(title) + ": " + error);
  return dir;
}

bool has_dict_glossary(const LookupResult& r, std::string_view dict) {
  return std::ranges::any_of(r.term.glossaries, [dict](const GlossaryEntry& g) { return g.dict_name == dict; });
}

const LookupResult* find_result(const std::vector<LookupResult>& rs, std::string_view expression,
                                std::string_view reading) {
  const auto it = std::ranges::find_if(rs, [&](const LookupResult& r) {
    return r.term.expression == expression && r.term.reading == reading;
  });
  return it == rs.end() ? nullptr : std::to_address(it);
}

// 结果的可比摘要：词头、匹配、glossary 所属词典与正文、频率 / 音调条目。
std::string digest(const std::vector<LookupResult>& rs) {
  std::string out;
  for (const LookupResult& r : rs) {
    out += std::format("[{}/{} m={} d={}", r.term.expression, r.term.reading, r.matched, r.deinflected);
    for (const GlossaryEntry& g : r.term.glossaries) out += std::format(" g:{}={}", g.dict_name, g.glossary);
    for (const FrequencyEntry& fe : r.term.frequencies) {
      out += " f:" + fe.dict_name;
      for (const Frequency& v : fe.frequencies) out += "=" + std::to_string(v.value);
    }
    for (const PitchEntry& pe : r.term.pitches) {
      out += " p:" + pe.dict_name;
      for (const Pitch& p : pe.pitches) out += "=" + std::to_string(p.position);
    }
    out += "]";
  }
  return out;
}

LookupOptions excluding(std::vector<std::string> names) {
  LookupOptions options;
  options.excluded_dictionaries = std::move(names);
  return options;
}

// 1) + 2) + 4)：两本术语词典，被排除那本有更长的匹配（猫舌）和独有词头。
void check_glossaries_and_slots(Failures& f) {
  const std::string kept = import_dict(
      f, kTermKept, "term_bank_1.json", "[" + term_row("猫", "ねこ", "cat (kept)") + "]");
  const std::string gone = import_dict(
      f, kTermExcluded, "term_bank_1.json",
      "[" + term_row("猫", "ねこ", "cat (gone)") + "," + term_row("猫舌", "ねこじた", "cat tongue (gone)") + "]");
  if (kept.empty() || gone.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(gone);  // 注册顺序在前：不能靠注册顺序把它挤出去
  q.add_term_dict(kept);
  Deinflector d;
  Lookup lookup(q, d);

  // 反证：不排除时，被排除词典的更长匹配排第一，max_results=1 时只剩它。
  const auto baseline_top1 = lookup.lookup("猫舌", 1, 16);
  f.expect(baseline_top1.size() == 1 && baseline_top1.front().term.expression == "猫舌",
           "baseline: the longer 猫舌 match must rank first (otherwise the slot check below proves nothing)");

  const LookupOptions exclude_gone = excluding({kTermExcluded});
  const auto top1 = lookup.lookup("猫舌", 1, 16, exclude_gone);
  f.expect(top1.size() == 1, "excluded: max_results=1 must still return one result from the kept dictionary");
  if (!top1.empty()) {
    f.expect(top1.front().term.expression == "猫" && top1.front().term.reading == "ねこ",
             "excluded: the kept 猫/ねこ must take the only slot");
    f.expect(has_dict_glossary(top1.front(), kTermKept), "excluded: kept dictionary glossary missing");
    f.expect(!has_dict_glossary(top1.front(), kTermExcluded), "excluded: excluded dictionary glossary leaked");
    f.expect(top1.front().term.glossaries.size() == 1, "excluded: only the kept glossary may remain");
  }

  const auto wide = lookup.lookup("猫舌", 16, 16, exclude_gone);
  f.expect(find_result(wide, "猫舌", "ねこじた") == nullptr,
           "excluded: a headword only the excluded dictionary has must disappear");
  for (const LookupResult& r : wide) {
    f.expect(!has_dict_glossary(r, kTermExcluded), "excluded: no result may carry an excluded glossary");
  }

  // 与「只装了未排除词典」的宿主逐字段一致。
  DictionaryQuery q_kept_only;
  q_kept_only.add_term_dict(kept);
  Lookup lookup_kept_only(q_kept_only, d);
  f.expect(digest(wide) == digest(lookup_kept_only.lookup("猫舌", 16, 16)),
           "excluded lookup must equal a host that never loaded the excluded dictionary");

  // 4) 空选项 / 不存在的词典名：与默认选项逐字段一致。
  const std::string def = digest(lookup.lookup("猫舌", 16, 16));
  f.expect(!def.empty(), "default lookup returned nothing");
  f.expect(digest(lookup.lookup("猫舌", 16, 16, excluding({}))) == def, "empty exclusion changed the result");
  f.expect(digest(lookup.lookup("猫舌", 16, 16, excluding({"NoSuchDictionary", ""}))) == def,
           "excluding an unknown name changed the result");
  f.expect(digest(lookup.lookup("猫舌", 1, 16, excluding({}))) == digest(baseline_top1),
           "empty exclusion changed the truncated result");
}

// 3) 频率 / 音调：被排除的频率词典注册在前，不排除时它决定顺序。
void check_frequency_and_pitch(Failures& f) {
  const std::string terms = import_dict(
      f, "ExclFreqTerms", "term_bank_1.json",
      "[" + term_row("猫", "ねこ", "cat-neko") + "," + term_row("猫", "びょう", "cat-byou") + "]");
  const std::string freq_gone =
      import_dict(f, kFreqExcluded, "term_meta_bank_1.json",
                  "[" + freq_row("猫", "びょう", 1) + "," + freq_row("猫", "ねこ", 1000) + "," +
                      pitch_row("猫", "ねこ", 3) + "]");
  const std::string freq_kept =
      import_dict(f, kFreqKept, "term_meta_bank_1.json",
                  "[" + freq_row("猫", "ねこ", 10) + "," + freq_row("猫", "びょう", 500) + "," +
                      pitch_row("猫", "ねこ", 1) + "]");
  if (terms.empty() || freq_gone.empty() || freq_kept.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(terms);
  q.add_freq_dict(freq_gone);
  q.add_freq_dict(freq_kept);
  q.add_pitch_dict(freq_gone);
  q.add_pitch_dict(freq_kept);
  Deinflector d;
  Lookup lookup(q, d);

  // 反证：不排除时第一本频率词典（被排除的那本）决定顺序 → びょう 在前。
  const auto baseline = lookup.lookup("猫", 16, 16);
  f.expect(baseline.size() == 2 && baseline.front().term.reading == "びょう",
           "baseline: the first registered frequency dictionary must rank びょう first");

  const auto excluded = lookup.lookup("猫", 16, 16, excluding({kFreqExcluded}));
  f.expect(excluded.size() == 2 && excluded.front().term.reading == "ねこ",
           "excluded frequency dictionary must not influence the ranking");
  for (const LookupResult& r : excluded) {
    for (const FrequencyEntry& fe : r.term.frequencies) {
      f.expect(fe.dict_name != kFreqExcluded, "excluded frequency dictionary leaked into term.frequencies");
    }
    for (const PitchEntry& pe : r.term.pitches) {
      f.expect(pe.dict_name != kFreqExcluded, "excluded pitch dictionary leaked into term.pitches");
    }
  }
  if (const LookupResult* neko = find_result(excluded, "猫", "ねこ")) {
    f.expect(neko->term.frequencies.size() == 1 && neko->term.frequencies.front().dict_name == kFreqKept,
             "ねこ must keep exactly the kept frequency entry");
    f.expect(neko->term.pitches.size() == 1 && neko->term.pitches.front().dict_name == kFreqKept,
             "ねこ must keep exactly the kept pitch entry");
  } else {
    f.fail("excluded: 猫/ねこ missing");
  }

  // 截断后同样成立：max_results=1 留下的是没装被排除词典时的第一名。
  const auto top1 = lookup.lookup("猫", 1, 16, excluding({kFreqExcluded}));
  f.expect(top1.size() == 1 && top1.front().term.reading == "ねこ",
           "excluded frequency dictionary must not decide which result survives truncation");

  // 与「没装被排除频率 / 音调词典」的宿主逐字段一致（含 frequencies / pitches）。
  DictionaryQuery q_kept_only;
  q_kept_only.add_term_dict(terms);
  q_kept_only.add_freq_dict(freq_kept);
  q_kept_only.add_pitch_dict(freq_kept);
  Lookup lookup_kept_only(q_kept_only, d);
  f.expect(digest(excluded) == digest(lookup_kept_only.lookup("猫", 16, 16)),
           "excluded frequency lookup must equal a host that never loaded that dictionary");

  // 显式指定的排序词典被排除 = 找不到，静默不按它排（与上游同一语义）。
  LookupOptions explicit_gone = excluding({kFreqExcluded});
  explicit_gone.frequency_dictionary = kFreqExcluded;
  explicit_gone.frequency_order = LookupFrequencyOrder::Ascending;
  LookupOptions explicit_unknown;
  explicit_unknown.frequency_dictionary = "NoSuchDictionary";
  explicit_unknown.frequency_order = LookupFrequencyOrder::Ascending;
  f.expect(digest(lookup_kept_only.lookup("猫", 16, 16, explicit_unknown)) ==
               digest(lookup.lookup("猫", 16, 16, explicit_gone)),
           "an excluded explicit frequency dictionary must behave like an unknown one");

  // 空选项：逐字段与默认一致（含频率 / 音调）。
  f.expect(digest(lookup.lookup("猫", 16, 16, excluding({}))) == digest(baseline),
           "empty exclusion changed the frequency-ranked result");
}

// 同 (expression, reading) 跨词典合并时 score 取 max、rules 拼接：排除必须发生在查库层
//（整本跳过），否则被排除词典的 score 仍留在合并后的 TermResult 上左右排序。
void check_merged_score(Failures& f) {
  const std::string kept = import_dict(
      f, "ExclScoreKept", "term_bank_1.json",
      "[" + term_row("犬", "いぬ", "dog-inu") + "," + term_row("犬", "けん", "dog-ken") + "]");
  const std::string gone =
      import_dict(f, "ExclScoreGone", "term_bank_1.json", "[" + term_row("犬", "けん", "dog-ken (gone)", 100) + "]");
  if (kept.empty() || gone.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(kept);
  q.add_term_dict(gone);
  Deinflector d;
  Lookup lookup(q, d);
  DictionaryQuery q_kept_only;
  q_kept_only.add_term_dict(kept);
  Lookup lookup_kept_only(q_kept_only, d);

  const std::string kept_only = digest(lookup_kept_only.lookup("犬", 16, 16));
  const auto baseline = lookup.lookup("犬", 16, 16);
  f.expect(!baseline.empty() && baseline.front().term.reading == "けん",
           "baseline: the excluded dictionary's score must lift けん to the top (otherwise this case proves nothing)");
  f.expect(digest(lookup.lookup("犬", 16, 16, excluding({"ExclScoreGone"}))) == kept_only,
           "excluded dictionary's merged score must not influence the ranking");
}

}  // namespace

int main() {
  Failures f;
  check_glossaries_and_slots(f);
  check_frequency_and_pitch(f);
  check_merged_score(f);
  if (f.count == 0) {
    std::cout << "excluded_dictionaries_lookup_test: PASS\n";
    return 0;
  }
  std::cerr << std::format("excluded_dictionaries_lookup_test: {} failure(s)\n", f.count);
  return 1;
}

// BUG-3261：汉字 + 假名混写的惯用句查不到。
//
// 词典索引只有完整表记（棚に上げる）与完整读音（たなにあげる）两种键。真实文本常把
// 惯用句的一部分写成假名——「棚にあげる」「目をつけた」「子供がなく」——两种键都对不上，
// 修复前只剩「棚」「目」「子供」这种单字命中。修复在 lookup.cpp：混写串按各汉字段的
// 读音拼出候选完整读音查读音索引，再用 mixed_orthography::matches_mixed_orthography
// 逐字核对。
//
// 本测试用真 ja.json + 带词性的 Yomitan 词典跑真实 Lookup：正向覆盖还原形（て / た）、
// 片假名写法、整段汉字词换写（子供がないた → 子供が泣く）；反向覆盖「查询里的汉字不在
// 词头里」（日が ≠ 僻）、一段汉字拆半换写（足がいた ≠ 足掻く、水を ≠ 水脈）、读音对不上
// （棚にあがる ≠ 棚に上げる）；表记精确命中仍排第一。
//
// Usage: ja_mixed_orthography_lookup_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::ostringstream buf;
  buf << in.rdbuf();
  return buf.str();
}

std::string dump(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.term.expression + " <- " + r.matched;
    for (const TransformGroup& g : r.trace) s += " /" + g.name;
    s += "] ";
  }
  return s.empty() ? "(none)" : s;
}

// 首条结果（用户看到的卡片 + 高亮长度）必须是 [expression]、原文匹配 [matched]。
void expect_top(Lookup& lk, const std::string& query, const std::string& matched, const std::string& expression,
                const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16, 16);
  if (results.empty()) {
    fail(std::string(what) + ": lookup(\"" + query + "\") returned nothing");
    return;
  }
  const LookupResult& top = results.front();
  if (top.matched != matched || top.term.expression != expression) {
    fail(std::string(what) + ": lookup(\"" + query + "\") top should be [" + expression + " <- " + matched +
         "]; got " + dump(results));
  }
}

// 结果里不得出现词头 [expression]。
void expect_absent(Lookup& lk, const std::string& query, const std::string& expression, const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16, 16);
  for (const LookupResult& r : results) {
    if (r.term.expression == expression) {
      fail(std::string(what) + ": lookup(\"" + query + "\") must not return " + expression + "; got " +
           dump(results));
      return;
    }
  }
}

std::string row(const std::string& expr, const std::string& reading, const std::string& rules,
                const std::string& glossary_json) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"" + rules + "\",0," + glossary_json + ",0,\"\"]";
}

std::string gloss(const std::string& text) { return "[\"" + text + "\"]"; }

std::string import_dict(const char* label, const std::string& title, const std::vector<std::string>& rows,
                        const std::string& out_dir) {
  std::string bank = "[";
  for (size_t i = 0; i < rows.size(); i++) {
    if (i) bank += ",";
    bank += rows[i];
  }
  bank += "]";
  std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"1\"}"},
      {"term_bank_1.json", bank},
  };
  ImportResult r = dictionary_importer::import(fushi_test::write_zip(label, files), out_dir);
  if (!r.success) {
    fail(std::string("import ") + label + " failed: " + (r.errors.empty() ? "(no error)" : r.errors.front()));
    return {};
  }
  return out_dir + "/" + r.title;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <ja.json>\n", argv[0]);
    return 2;
  }
  const std::string ja_json = read_file(argv[1]);
  if (ja_json.empty()) {
    fail("cannot read ja.json");
    return 1;
  }

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_ja_mixed_orthography_out";
  std::filesystem::remove_all(out_dir);

  const std::string dict = import_dict("ja_mixed_main", "JaMixedMain",
                                       {
                                           row("棚", "たな", "n", gloss("shelf")),
                                           row("棚に上げる", "たなにあげる", "v1", gloss("to shelve")),
                                           row("上げる", "あげる", "v1", gloss("to raise")),
                                           row("目", "め", "n", gloss("eye")),
                                           row("目を付ける", "めをつける", "v1", gloss("to have one's eye on")),
                                           row("子供", "こども", "n", gloss("child")),
                                           row("子供が泣く", "こどもがなく", "v5", gloss("child cries")),
                                           row("足", "あし", "n", gloss("foot")),
                                           row("足掻く", "あがく", "v5", gloss("to struggle")),
                                           row("水", "みず", "n", gloss("water")),
                                           row("水脈", "みを", "n", gloss("waterway")),
                                           row("日", "ひ", "n", gloss("day")),
                                           row("僻", "ひが", "n", gloss("bias")),
                                       },
                                       out_dir);
  if (dict.empty()) return 1;

  DictionaryQuery query;
  query.add_term_dict(dict);
  Deinflector deinflector;
  deinflector.load_transforms_json(ja_json);
  Lookup lk(query, deinflector);

  // 正向：原形、还原形、汉字段内部分写成假名。
  expect_top(lk, "棚にあげる", "棚にあげる", "棚に上げる", "mixed dictionary form");
  expect_top(lk, "棚にあげて、", "棚にあげて", "棚に上げる", "mixed te-form");
  expect_top(lk, "目をつけた", "目をつけた", "目を付ける", "mixed ta-form");
  // 汉字词整段写成假名：子供がなく → 子供が泣く（泣 整段换写）。
  expect_top(lk, "子供がないた", "子供がないた", "子供が泣く", "whole kanji run spelled in kana");
  // 片假名写法与平假名读音等价。
  expect_top(lk, "棚にアゲる", "棚にアゲる", "棚に上げる", "katakana spelling");
  // 表记精确命中不受影响，仍排第一。
  expect_top(lk, "棚に上げる", "棚に上げる", "棚に上げる", "exact spelling");

  // 反向：查询里的汉字必须原样在词头里。
  expect_absent(lk, "日が", "僻", "query kanji absent from headword");
  // 反向：一段连续汉字不能拆半写成假名——半段换写的假名几乎总是助词。
  expect_absent(lk, "足がいた", "足掻く", "half of a kanji run spelled in kana");
  expect_absent(lk, "水を", "水脈", "half of a kanji run spelled in kana (particle)");
  // 反向：假名与读音对不上。
  expect_absent(lk, "棚にあがる", "棚に上げる", "kana not matching reading");

  if (g_fail == 0) std::printf("PASS ja_mixed_orthography_lookup_test\n");
  return g_fail == 0 ? 0 : 1;
}

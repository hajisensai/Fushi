// 2026-11 上游功能同步（hoshidicts 30ad52f / 3f0c2d9 / ad0be91 / e2a007f / 8e89a5d）的端到端守卫。
//
// 用真 ja.json + 带词性的 Yomitan 词典跑真实 Lookup：
//   D  片假名中点：カルミナ・ブラーナ 命中只收不带点写法的词条；串首 / 串尾的点不删；
//      变形不得跨过点（き・た 不经 きた → くる 还原成 来る）。
//   K  片假名词边界：结尾落在片假名词中间时只认原文（はテスト 不在「はテ」命中 果て）；
//      「平假名 + 片假名词」收尾时变形要么整段改写片假名（行きマス → 行く），要么不动它
//      （食べルナ 不经 るな → る 只改写一截）。
//   T  くって（嬉しくって → 嬉しい）。
//   H  歴史的仮名遣い（思ふ / 言はない / 来やう / 待ってゐる / 会ひたい）。
//   Y  -やしない / -やしません。
//   W  本地差异：歴史的仮名遣い规则（ja.json 里带 requiresPartOfSpeech）只对自带词性的词条
//      成立。无词性（通配）词典里的 宇宙〔うちう〕/ 乱右〔らんう〕 不得把「うちへ / ランへ」
//      误配成历史假名活用；现代活用在通配词典上照常还原；标记沿还原链传递。
//
// Usage: ja_upstream_sync_lookup_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
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

bool trace_has(const LookupResult& r, const std::string& group) {
  for (const TransformGroup& g : r.trace) {
    if (g.name == group) return true;
  }
  return false;
}

// 首条结果必须是 [expression]、原文匹配 [matched]；[group] 非空时变形链必须含该组。
void expect_top(Lookup& lk, const std::string& query, const std::string& matched, const std::string& expression,
                const std::string& group, const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16, 16);
  if (results.empty()) {
    fail(std::string(what) + ": lookup(\"" + query + "\") returned nothing");
    return;
  }
  const LookupResult& top = results.front();
  if (top.matched != matched || top.term.expression != expression || (!group.empty() && !trace_has(top, group))) {
    fail(std::string(what) + ": lookup(\"" + query + "\") top should be [" + expression + " <- " + matched +
         (group.empty() ? "" : " /" + group) + "]; got " + dump(results));
  }
}

// 结果里不得出现 (expression, matched) 这一条。
void expect_absent(Lookup& lk, const std::string& query, const std::string& matched, const std::string& expression,
                   const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16, 16);
  for (const LookupResult& r : results) {
    if (r.term.expression == expression && r.matched == matched) {
      fail(std::string(what) + ": lookup(\"" + query + "\") must not contain [" + expression + " <- " + matched +
           "]; got " + dump(results));
      return;
    }
  }
}

// 结果里必须有 (expression, matched) 这一条。
void expect_present(Lookup& lk, const std::string& query, const std::string& matched, const std::string& expression,
                    const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16, 16);
  for (const LookupResult& r : results) {
    if (r.term.expression == expression && r.matched == matched) return;
  }
  fail(std::string(what) + ": lookup(\"" + query + "\") must contain [" + expression + " <- " + matched + "]; got " +
       dump(results));
}

std::string row(const std::string& expr, const std::string& reading, const std::string& rules,
                const std::string& text) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"" + rules + "\",0,[\"" + text + "\"],0,\"\"]";
}

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

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_ja_upstream_sync_out";
  std::filesystem::remove_all(out_dir);

  const std::string dict = import_dict(
      "ja_upstream_sync", "JaUpstreamSync",
      {
          row("カルミナブラーナ", "", "n", "Carmina Burana"),
          row("カルミナ", "", "n", "carmina"),
          row("テスト", "", "n", "test"),
          row("見る", "みる", "v1", "see"),
          row("見", "み", "n", "look"),
          row("は", "", "prt", "topic particle"),
          row("果て", "はて", "n", "end"),
          row("行く", "いく", "v5", "go"),
          row("食べる", "たべる", "v1", "eat"),
          row("嬉しい", "うれしい", "adj-i", "glad"),
          row("思う", "おもう", "v5", "think"),
          row("言う", "いう", "v5", "say"),
          row("会う", "あう", "v5", "meet"),
          row("来る", "くる", "vk", "come"),
          row("待つ", "まつ", "v5", "wait"),
          row("分かる", "わかる", "v5", "understand"),
          // 与通配词典同一词条、但自带的词性是名词：歴史仮名规则要的是 v5，不成立。
          row("乱右", "らんう", "n", "rare word"),
      },
      out_dir);
  // 无词性词典：整本没有 rules → 读侧当通配 "*"（MDX / StarDict / 不带词性的 Yomitan 词典同理）。
  const std::string wildcard_dict = import_dict("ja_upstream_sync_wildcard", "JaUpstreamSyncWildcard",
                                                {
                                                    row("うち", "", "", "inside"),
                                                    row("宇宙", "うちう", "", "universe (historical reading)"),
                                                    row("ラン", "", "", "run"),
                                                    row("乱右", "らんう", "", "rare word"),
                                                    row("歌う", "うたう", "", "sing"),
                                                    row("走る", "はしる", "", "run"),
                                                    // 同一词条另一本词典带词性（v5）：两本的
                                                    // rules 并成 "v5 *"。
                                                    row("言う", "いう", "", "say"),
                                                    row("待つ", "まつ", "", "wait"),
                                                },
                                                out_dir);
  if (g_fail) return 1;

  Deinflector d;
  d.load_transforms_json(ja_json);
  DictionaryQuery q;
  q.add_term_dict(dict);
  q.add_term_dict(wildcard_dict);
  Lookup lk(q, d);

  // ---- D 片假名中点 -----------------------------------------------------------
  expect_top(lk, "カルミナ・ブラーナを聴いた", "カルミナ・ブラーナ", "カルミナブラーナ", "", "D1 middle dot stripped");
  // 串尾的点不删：前缀「カルミナ・」不会以 カルミナ 的身份多吞一个点。
  expect_absent(lk, "カルミナ・", "カルミナ・", "カルミナ", "D2 trailing dot kept");
  // 串首的点不删：从点上开始的查询不会把点算进 カルミナ 的匹配。
  expect_absent(lk, "・カルミナ", "・カルミナ", "カルミナ", "D3 leading dot kept");
  // 变形不跨过点：「き・た」删点成「きた」后不得经「きた → くる」（改写 2 个码点，越过
  // 了点）还原成 来る；不带点的「きた」照常还原。只改写点右边的部分不受限（行・った →
  // 行った → 行く 只改写「った」）。
  expect_absent(lk, "き・た", "き・た", "来る", "D4 no deinflection across a stripped dot");
  expect_present(lk, "きた", "きた", "来る", "D5 きた without dot still deinflects");
  expect_present(lk, "行・った", "行・った", "行く", "D6 rewrite right of the dot allowed");

  // ---- K 片假名词边界 -----------------------------------------------------------
  expect_top(lk, "はテスト", "は", "は", "", "K1 はテスト does not stop inside テスト");
  expect_absent(lk, "はテスト", "はテ", "果て", "K2 果て must not match はテ");
  expect_top(lk, "行きマス", "行きマス", "行く", "-ます", "K3 stylized katakana ending rewritten whole");
  expect_absent(lk, "食べルナ", "食べルナ", "食べる", "K4 partial rewrite of katakana tail rejected");

  // ---- T くって ----------------------------------------------------------------
  expect_top(lk, "嬉しくって泣いた", "嬉しくって", "嬉しい", "-て", "T1 嬉しくって");

  // ---- H 歴史的仮名遣い ----------------------------------------------------------
  expect_top(lk, "思ふ", "思ふ", "思う", "-ふ", "H1 思ふ");
  expect_top(lk, "言はない", "言はない", "言う", "negative", "H2 言はない");
  expect_top(lk, "来やう", "来やう", "来る", "volitional", "H3 来やう");
  expect_top(lk, "待ってゐる", "待ってゐる", "待つ", "-いる", "H4 待ってゐる");
  expect_top(lk, "会ひたい", "会ひたい", "会う", "-たい", "H5 会ひたい");

  // ---- Y -やしない / -やしません ------------------------------------------------
  expect_top(lk, "分かりやしない", "分かりやしない", "分かる", "-やしない", "Y1 分かりやしない");
  expect_top(lk, "食べやしません", "食べやしません", "食べる", "-やしません", "Y2 食べやしません");
  expect_top(lk, "来やしない", "来やしない", "来る", "-やしない", "Y3 来やしない");

  // ---- W 歴史的仮名遣い规则要求词条自带词性 ------------------------------------
  expect_top(lk, "うちへ帰る", "うち", "うち", "", "W1 うちへ is not historical うちう");
  expect_absent(lk, "うちへ帰る", "うちへ", "宇宙", "W2 宇宙 must not match うちへ");
  expect_top(lk, "ランへ行ってみた", "ラン", "ラン", "", "W3 ランへ is not historical らんう");
  // W4 也覆盖「自带词性不匹配（名词）时，并进来的通配不能替它放行」：乱右两本都有，rules 是 "n *"。
  expect_absent(lk, "ランへ行ってみた", "ランへ", "乱右", "W4 乱右 must not match ランへ");
  // 通配词典上歴史仮名不还原，现代活用照常（通配让步本身不变）。
  expect_absent(lk, "歌はう", "歌はう", "歌う", "W5 historical rule rejected on wildcard dict");
  expect_present(lk, "歌った", "歌った", "歌う", "W6 modern rule still accepted on wildcard dict");
  // 标记沿链传递：てゐる → て（带标记）→ 走る（现代 -て 规则）仍要求词性。
  expect_absent(lk, "走ってゐる", "走ってゐる", "走る", "W7 marker propagates through the chain");
  expect_present(lk, "走っている", "走っている", "走る", "W8 modern chain on wildcard dict");
  // 同一词条既在带词性词典（v5）又在通配词典里：rules 是两本并起来的 "v5 *"，自带的
  // 真词性匹配就成立，不因为另一本给了通配而整条丢掉（H2 / H4 的词条正是这种）。
  expect_top(lk, "言はない", "言はない", "言う", "negative", "W9 own POS wins over a merged wildcard");
  expect_top(lk, "待ってゐる", "待ってゐる", "待つ", "-いる", "W10 chained, own POS + merged wildcard");

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("PASS ja_upstream_sync_lookup_test\n");
  return 0;
}

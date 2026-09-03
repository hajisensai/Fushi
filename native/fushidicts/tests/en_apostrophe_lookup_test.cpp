// BUG-2056 端到端闭环：英文正文里点 don’t / John’s，查得到词条。
//
// 扫描层（scan/word_scan.cpp + 四份 selection.js）修好之后，喂进引擎的查询串终于
// 是整词 "don’t"（U+2019）而不是被截断的 "don"。但那只是**半条链**：
//   · fushi/assets/transforms/en.json 的五条撇号规则全是 ASCII U+0027
//     （'s / s' / 'd / in' / "don't "），U+2019 在整份文件里出现 0 次；
//   · 绝大多数英文词典的条目键同样是 ASCII；
//   · NFKC 救不了——U+2019 没有兼容分解，utf8proc_NFKC("’") 仍然是 "’"。
// 所以在补上 text_processor 的撇号归一之前，"don’t" 走完还原+查表两级仍然全落空，
// 用户看到的结果和修复前一模一样。
//
// 本测试跑的是 app 真正调用的那条路径 Lookup::lookup()（scan_candidates ->
// text_processor::process -> Deinflector::deinflect -> query_raw），词典是真的
// write_simple_dict 产物（MDX/StarDict/DSL 的存储形态），词形还原表是**仓库里那份
// 真的 en.json**（路径由 CMake 经 argv[1] 传入，不依赖运行时 cwd）。
//
// 四格全覆盖（文本写法 x 词典条目写法）：
//   1) 排版撇号文本 -> ASCII 条目：      lookup("don’t")  命中 don't
//   2) 排版撇号文本 -> ASCII 还原规则：  lookup("John’s") 经 possessive 命中 john
//   3) ASCII 文本   -> 排版撇号条目：    lookup("y'all")  命中 y’all
//   4) U+02BC 文本  -> ASCII 条目：      lookup("canʼt")  命中 can't
// 外加一条负向：en.json 必须仍然是纯 ASCII 撇号——否则本测试的前提（归一发生在
// 引擎侧、而不是靠给每条规则再抄一份 U+2019 版）已经不成立，得重写这份测试。
//
// Red/green：删掉 text_processor 的撇号归一处理器，1/2/3/4 全红。
//
// Usage: en_apostrophe_lookup_test <path/to/fushi/assets/transforms/en.json>
#include <cstdio>
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

// U+2019 ’ 排版撇号（真实 EPUB 的主流写法）; U+02BC ʼ modifier letter apostrophe.
const std::string RSQUO = "\xE2\x80\x99";
const std::string MODAP = "\xCA\xBC";

std::string dump(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.term.expression + " <- " + r.matched + "] ";
  }
  return s.empty() ? "(none)" : s;
}

bool has_expression(const std::vector<LookupResult>& results, const std::string& want) {
  for (const LookupResult& r : results) {
    if (r.term.expression == want) return true;
  }
  return false;
}

void expect_hit(Lookup& lk, const std::string& query, const std::string& want_expression,
                const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16);
  if (!has_expression(results, want_expression)) {
    fail(std::string(what) + ": lookup(\"" + query + "\") did not surface \"" + want_expression +
         "\"; got " + dump(results));
  }
}

// 更严的一档：命中必须来自**整个**查询串，而不是 scan_candidates 顺手生成的短前缀。
// 没有这一档，"John’s -> john" 是恒真的——撇号前的 "John" 本来就是一条候选前缀，
// 归一处理器删掉照样绿（实测：M-A1 变异下 case 2 存活）。
void expect_hit_whole(Lookup& lk, const std::string& query, const std::string& want_expression,
                      const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 16);
  for (const LookupResult& r : results) {
    if (r.term.expression == want_expression && r.matched == query) return;
  }
  fail(std::string(what) + ": lookup(\"" + query + "\") did not surface \"" + want_expression +
       "\" matched on the WHOLE query (a short-prefix hit does not count); got " + dump(results));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <en.json path>\n", argv[0]);
    return 2;
  }

  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "FAIL: cannot open transforms json '%s'\n", argv[1]);
    return 1;
  }
  std::ostringstream buf;
  buf << in.rdbuf();
  const std::string en_json = buf.str();
  if (en_json.empty()) {
    fail("en.json is empty");
    return 1;
  }

  // 前提钉子：en.json 的撇号规则是 ASCII 的，且整份文件没有 U+2019。归一只能发生
  // 在引擎侧；哪天有人往 en.json 里加了 U+2019 版规则，这条会红，提醒重审本测试。
  if (en_json.find("\"'s\"") == std::string::npos) {
    fail("en.json no longer carries the ASCII possessive rule \"'s\"");
  }
  if (en_json.find(RSQUO) != std::string::npos) {
    fail("en.json now contains U+2019; the engine-side apostrophe folding premise changed");
  }

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_en_apostrophe_out";
  std::vector<SimpleEntry> entries = {
      {"don't", "auxiliary: do not"},
      {"john", "a given name"},
      {"can't", "auxiliary: cannot"},
      {"y" + RSQUO + "all", "you all (entry keyed with a typographic apostrophe)"},
  };
  ImportResult r = dictionary_importer::write_simple_dict("EnApostropheDict", entries, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
    return 1;
  }

  DictionaryQuery q;
  q.add_term_dict(out_dir + "/" + r.title);
  Deinflector d;
  d.load_transforms_json(en_json);
  Lookup lk(q, d);

  // 0) 前提：ASCII 查询串本来就能命中 ASCII 条目（如果这条红，说明装置本身坏了，
  //    下面四条的红说明不了撇号的问题）。
  expect_hit(lk, "don't", "don't", "harness sanity (ascii -> ascii)");

  // 1) 排版撇号文本 -> ASCII 条目。这就是用户在 EPUB 里点 don’t 的那一下。
  expect_hit(lk, "don" + RSQUO + "t", "don't", "case 1 (typographic text -> ascii entry)");

  // 2) 排版撇号文本 -> ASCII 还原规则：John’s 经 en.json possessive('s -> "") 落到 john。
  //    必须用 whole 档：撇号前的 "John" 本身就是一条扫描候选前缀，用宽松档这条恒真。
  expect_hit_whole(lk, "John" + RSQUO + "s", "john",
                   "case 2 (typographic possessive -> en.json rule)");

  // 3) ASCII 文本 -> 排版撇号条目（反向那一格：只归一一侧就漏这格）。
  expect_hit(lk, "y'all", "y" + RSQUO + "all", "case 3 (ascii text -> typographic entry)");

  // 4) U+02BC（乌克兰语/OCR 常见）同样折进来。
  expect_hit(lk, "can" + MODAP + "t", "can't", "case 4 (U+02BC text -> ascii entry)");

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}

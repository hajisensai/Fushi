// BUG-2853：Yomitan「词典自带变形」重定向记录必须被跟随。
//
// LDOCE5++ 这类英语 Yomitan 词典把短语写成两条记录：
//   ["instead of", ..., [["instead of somebody/something", ["Redirected from instead of"]]], ...]
//   ["instead of somebody/something", ..., [{structured-content 释义}], ...]
// 前者的 glossary 项是 `[formOf, [rule...]]`（Yomitan schema 的 deinflection 形态），没有
// 任何可显示的释义。引擎此前把它当普通词条返回：匹配长度是 "instead of"（正文高亮到
// 这里），弹窗却把这条 glossary 当重定向滤空，用户只看到 "instead"。
//
// 本测试跑 app 真正调用的 Lookup::lookup()，词典是真 importer 导入的 Yomitan zip，
// 变形表是仓库里那份真 en.json（经 argv[1] 传入）。
//
// Red/green：把 lookup.cpp 的 merge_terms 里摘重定向 / 记目标那段删掉，R1–R5 全红。
//
// Usage: yomitan_redirect_lookup_test <path/to/fushi/assets/transforms/en.json>
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
  std::ifstream f(path, std::ios::binary);
  if (!f) return {};
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

std::string dump(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.term.expression + " <- " + r.matched + " (";
    for (const auto& t : r.trace) s += t.name + ";";
    s += ")] ";
  }
  return s.empty() ? "(none)" : s;
}

const LookupResult* find_expr(const std::vector<LookupResult>& results, const std::string& expr) {
  for (const LookupResult& r : results) {
    if (r.term.expression == expr) return &r;
  }
  return nullptr;
}

// Yomitan term bank v3 行：[expr, reading, def_tags, rules, score, [glossary], sequence, term_tags]
std::string definition_row(const std::string& expr) {
  return "[\"" + expr + "\",\"\",\"\",\"\",0,[\"definition of " + expr + "\"],0,\"\"]";
}

std::string redirect_row(const std::string& expr, const std::string& target) {
  return "[\"" + expr + "\",\"\",\"\",\"\",0,[[\"" + target + "\",[\"Redirected from " + expr + "\"]]],0,\"\"]";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <en.json>\n", argv[0]);
    return 2;
  }
  const std::string en_json = read_file(argv[1]);
  if (en_json.empty()) {
    fail("cannot read en.json");
    return 1;
  }

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_yomitan_redirect_out";
  std::filesystem::remove_all(out_dir);

  // 全部 rules 留空 = LDOCE5++ 的真实形态（整本无词性，term_rules.flag 为 0，空 rules 当通配），
  // 否则 R4 的动词头还原会被 filter_by_pos 挡在重定向记录之前。
  const std::vector<std::string> rows = {
      definition_row("instead"),
      definition_row("instead of somebody/something"),
      redirect_row("instead of", "instead of somebody/something"),
      definition_row("in"),
      definition_row("in (actual) fact"),
      redirect_row("in fact", "in (actual) fact"),
      definition_row("brush"),
      definition_row("brush somebody/something off"),
      redirect_row("brush off", "brush somebody/something off"),
      // 重定向到不存在的词头：摘掉后什么都不剩，不能留下空卡。
      redirect_row("dangling phrase", "no such headword"),
      // 释义与自指重定向标签混排（OALDPE10 形态，BUG-2566）：不是纯重定向，原样保留。
      "[\"give up\",\"\",\"\",\"\",0,[[\"give up\",[\"Redirected from give up\"]],\"to stop trying\"],0,\"\"]",
  };
  std::string bank = "[";
  for (size_t i = 0; i < rows.size(); i++) {
    if (i) bank += ",";
    bank += rows[i];
  }
  bank += "]";
  const std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"RedirectDict\",\"format\":3,\"revision\":\"1\"}"},
      {"term_bank_1.json", bank},
  };
  ImportResult imported = dictionary_importer::import(fushi_test::write_zip("yomitan_redirect", files), out_dir);
  if (!imported.success) {
    fail("import failed: " + (imported.errors.empty() ? std::string("(no error)") : imported.errors.front()));
    return 1;
  }

  Deinflector d;
  d.load_transforms_json(en_json);
  DictionaryQuery q;
  q.add_term_dict(out_dir + "/" + imported.title);
  Lookup lk(q, d);

  // R1：点 instead，查询串带着后文 —— 第一条必须是重定向目标，匹配长度覆盖整个短语。
  {
    auto results = lk.lookup("instead of people in sharp", 16);
    if (results.empty() || results.front().term.expression != "instead of somebody/something" ||
        results.front().matched != "instead of") {
      fail("R1 instead of -> instead of somebody/something first, matched \"instead of\"; got " + dump(results));
    } else if (results.front().trace.empty() || results.front().trace.back().name != "Redirected from instead of") {
      fail("R1 redirect rule must be carried in the trace; got " + dump(results));
    }
    if (find_expr(results, "instead of") != nullptr) {
      fail("R1 the redirect-only record itself must not surface as a result; got " + dump(results));
    }
    if (find_expr(results, "instead") == nullptr) {
      fail("R1 the shorter single-word hit must still be offered; got " + dump(results));
    }
  }

  // R2：被标点截住的短语。
  {
    auto results = lk.lookup("in fact, magic", 16);
    if (results.empty() || results.front().term.expression != "in (actual) fact" ||
        results.front().matched != "in fact") {
      fail("R2 in fact -> in (actual) fact first; got " + dump(results));
    }
  }

  // R3：短语动词，未变形。
  {
    auto results = lk.lookup("brush off the dust", 16);
    if (results.empty() || results.front().term.expression != "brush somebody/something off") {
      fail("R3 brush off -> brush somebody/something off first; got " + dump(results));
    }
  }

  // R4：短语动词变形（BUG-2549 的动词头还原）之后再跟随重定向，变形链两段都在。
  {
    auto results = lk.lookup("brushed off the dust", 16);
    const LookupResult* hit = find_expr(results, "brush somebody/something off");
    if (hit == nullptr || hit->matched != "brushed off") {
      fail("R4 brushed off -> brush somebody/something off (matched \"brushed off\"); got " + dump(results));
    } else if (hit->trace.size() < 2 || hit->trace.front().name != "past" ||
               hit->trace.back().name != "Redirected from brush off") {
      fail("R4 trace must be [past, ..., Redirected from brush off]; got " + dump(results));
    }
  }

  // R5：首字母大写（句首）照样跟随。
  {
    auto results = lk.lookup("Instead of people", 16);
    if (results.empty() || results.front().term.expression != "instead of somebody/something") {
      fail("R5 capitalised Instead of -> instead of somebody/something; got " + dump(results));
    }
  }

  // R6：悬空重定向不出空卡。
  {
    auto results = lk.lookup("dangling phrase here", 16);
    if (find_expr(results, "dangling phrase") != nullptr) {
      fail("R6 a dangling redirect-only record must be dropped; got " + dump(results));
    }
  }

  // R7：释义 + 自指标签混排的记录不是纯重定向，原样保留。
  {
    auto results = lk.lookup("give up now", 16);
    const LookupResult* hit = find_expr(results, "give up");
    if (hit == nullptr || hit->term.glossaries.size() != 1 || hit->trace.size() != 0) {
      fail("R7 mixed self-redirect + definition record must stay as-is; got " + dump(results));
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("yomitan_redirect_lookup_test: all passed\n");
  return 0;
}

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
// redirect_glossary.flag（util/redirect_glossary.hpp）：词典确认无纯重定向时查询期跳过
// 逐条检测。S1–S7 钉住导入端写 sidecar、缺失 / 陈旧时照旧检测、迁移扫描回填，以及
// 「sidecar 确实被读」的反向证据（伪造 0 后重定向记录原样浮上来）。R1–R7 在每种
// sidecar 状态下都必须原样成立。
//
// BUG-5272：Jitendex 的重定向词条（「⟶ 目标词」链接卡 + formOf，或只有链接卡）同样
// 跟随到目标词条（J1–J4）；判据放宽后旧版 sidecar 失效重扫（S8），只有链接卡的词典
// 导入端 / 迁移扫描同样打标（S9）。
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

// Jitendex 重定向词条的链接卡（真词典里 怖気つく 那条的形态，ruby 简化成纯文本）。
std::string jitendex_card(const std::string& query_encoded, const std::string& label) {
  return R"J({"type":"structured-content","content":{"tag":"div","lang":"ja","data":{"content":"redirect-glossary"},"content":["⟶",{"tag":"a","href":"?query=)J" +
         query_encoded + R"J(&wildcards=off","content":[")J" + label + R"J("]}]}})J";
}

// Jitendex 重定向行：读音空、score 为负（真词典 -101～-105）。
std::string jitendex_row(const std::string& expr, const std::string& glossary_items) {
  return "[\"" + expr + "\",\"\",\"\",\"\",-105,[" + glossary_items + "],-2007480,\"\"]";
}

// R1–R7：一份词典装载状态下的全部断言。[label] 标明装载时 sidecar 的状态，
// 同一组断言在「导入写好的 sidecar」「sidecar 缺失（查询期逐条检测）」「迁移扫描
// 回填的 sidecar」「陈旧 sidecar」四种状态下都必须成立——跳过检测只能是加速，
// 不能改变结果。
void run_redirect_checks(const Lookup& lk, const std::string& label) {
  // R1：点 instead，查询串带着后文 —— 第一条必须是重定向目标，匹配长度覆盖整个短语。
  {
    auto results = lk.lookup("instead of people in sharp", 16);
    if (results.empty() || results.front().term.expression != "instead of somebody/something" ||
        results.front().matched != "instead of") {
      fail(label + " R1 instead of -> instead of somebody/something first, matched \"instead of\"; got " + dump(results));
    } else if (results.front().trace.empty() || results.front().trace.back().name != "Redirected from instead of") {
      fail(label + " R1 redirect rule must be carried in the trace; got " + dump(results));
    }
    if (find_expr(results, "instead of") != nullptr) {
      fail(label + " R1 the redirect-only record itself must not surface as a result; got " + dump(results));
    }
    if (find_expr(results, "instead") == nullptr) {
      fail(label + " R1 the shorter single-word hit must still be offered; got " + dump(results));
    }
  }

  // R2：被标点截住的短语。
  {
    auto results = lk.lookup("in fact, magic", 16);
    if (results.empty() || results.front().term.expression != "in (actual) fact" ||
        results.front().matched != "in fact") {
      fail(label + " R2 in fact -> in (actual) fact first; got " + dump(results));
    }
  }

  // R3：短语动词，未变形。
  {
    auto results = lk.lookup("brush off the dust", 16);
    if (results.empty() || results.front().term.expression != "brush somebody/something off") {
      fail(label + " R3 brush off -> brush somebody/something off first; got " + dump(results));
    }
  }

  // R4：短语动词变形（BUG-2549 的动词头还原）之后再跟随重定向，变形链两段都在。
  {
    auto results = lk.lookup("brushed off the dust", 16);
    const LookupResult* hit = find_expr(results, "brush somebody/something off");
    if (hit == nullptr || hit->matched != "brushed off") {
      fail(label + " R4 brushed off -> brush somebody/something off (matched \"brushed off\"); got " + dump(results));
    } else if (hit->trace.size() < 2 || hit->trace.front().name != "past" ||
               hit->trace.back().name != "Redirected from brush off") {
      fail(label + " R4 trace must be [past, ..., Redirected from brush off]; got " + dump(results));
    }
  }

  // R5：首字母大写（句首）照样跟随。
  {
    auto results = lk.lookup("Instead of people", 16);
    if (results.empty() || results.front().term.expression != "instead of somebody/something") {
      fail(label + " R5 capitalised Instead of -> instead of somebody/something; got " + dump(results));
    }
  }

  // R6：悬空重定向不出空卡。
  {
    auto results = lk.lookup("dangling phrase here", 16);
    if (find_expr(results, "dangling phrase") != nullptr) {
      fail(label + " R6 a dangling redirect-only record must be dropped; got " + dump(results));
    }
  }

  // R7：释义 + 自指标签混排的记录不是纯重定向，原样保留。
  {
    auto results = lk.lookup("give up now", 16);
    const LookupResult* hit = find_expr(results, "give up");
    if (hit == nullptr || hit->term.glossaries.size() != 1 || hit->trace.size() != 0) {
      fail(label + " R7 mixed self-redirect + definition record must stay as-is; got " + dump(results));
    }
  }

  // J1：Jitendex 重定向（链接卡 + formOf）：直接出目标词条，匹配长度是原词，rule 进变形链；
  // 重定向词条本身（只剩「⟶ 怖気づく」的卡）不出。
  {
    auto results = lk.lookup("怖気つくな", 16);
    const LookupResult* hit = find_expr(results, "怖気づく");
    if (hit == nullptr || results.front().term.expression != "怖気づく" || hit->matched != "怖気つく") {
      fail(label + " J1 怖気つく -> 怖気づく first, matched 怖気つく; got " + dump(results));
    } else if (hit->trace.size() != 1 || hit->trace.back().name != "redirected from 怖気つく") {
      fail(label + " J1 the Jitendex formOf rule must be the trace (followed once); got " + dump(results));
    }
    if (find_expr(results, "怖気つく") != nullptr) {
      fail(label + " J1 the Jitendex redirect card must not surface as a result; got " + dump(results));
    }
  }

  // J2：只有链接卡、没有 formOf 项：目标取 href 的 query（百分号解码），不带 rule。
  {
    auto results = lk.lookup("アホんだらめ", 16);
    const LookupResult* hit = find_expr(results, "阿呆陀羅");
    if (hit == nullptr || hit->matched != "アホんだら" || !hit->trace.empty()) {
      fail(label + " J2 link-only card アホんだら -> 阿呆陀羅 (matched アホんだら, empty trace); got " + dump(results));
    }
    if (find_expr(results, "アホんだら") != nullptr) {
      fail(label + " J2 the link-only redirect card must not surface; got " + dump(results));
    }
  }

  // J3：formOf 在前、链接卡在后的顺序同样认；同一目标只跟一次。
  {
    auto results = lk.lookup("怖じけづく", 16);
    const LookupResult* hit = find_expr(results, "怖気づく");
    if (hit == nullptr || hit->matched != "怖じけづく" || hit->trace.size() != 1 ||
        hit->trace.front().name != "redirected from 怖じけづく") {
      fail(label + " J3 formOf-first order 怖じけづく -> 怖気づく with exactly its one rule; got " + dump(results));
    }
  }

  // J4：链接卡混着真释义的记录不是纯重定向，原样保留、不跟随。
  {
    auto results = lk.lookup("怖じ気", 16);
    const LookupResult* hit = find_expr(results, "怖じ気");
    if (hit == nullptr || hit->term.glossaries.size() != 1 || !hit->trace.empty()) {
      fail(label + " J4 a Jitendex card mixed with a definition must stay as-is; got " + dump(results));
    }
    if (find_expr(results, "怖気づく") != nullptr) {
      fail(label + " J4 a non-pure record must not be followed; got " + dump(results));
    }
  }
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
      // Jitendex（BUG-5272）。%E6%80%96%E6%B0%97%E3%81%A5%E3%81%8F = 怖気づく，
      // %E9%98%BF%E5%91%86%E9%99%80%E7%BE%85 = 阿呆陀羅。
      definition_row("怖気づく"),
      definition_row("阿呆陀羅"),
      jitendex_row("怖気つく", jitendex_card("%E6%80%96%E6%B0%97%E3%81%A5%E3%81%8F", "怖気づく") +
                                   ",[\"怖気づく\",[\"redirected from 怖気つく\"]]"),
      jitendex_row("アホんだら", jitendex_card("%E9%98%BF%E5%91%86%E9%99%80%E7%BE%85", "阿呆陀羅")),
      jitendex_row("怖じけづく", "[\"怖気づく\",[\"redirected from 怖じけづく\"]]," +
                                     jitendex_card("%E6%80%96%E6%B0%97%E3%81%A5%E3%81%8F", "怖気づく")),
      jitendex_row("怖じ気",
                   jitendex_card("%E6%80%96%E6%B0%97%E3%81%A5%E3%81%8F", "怖気づく") + ",\"fear; nervousness\""),
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
  const std::string dict_dir = out_dir + "/" + imported.title;
  const std::string flag_path = dict_dir + "/redirect_glossary.flag";
  const auto blobs_size = std::filesystem::file_size(dict_dir + "/blobs.bin");
  auto check_with_fresh_query = [&](const std::string& label) {
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    Lookup lk(q, d);
    run_redirect_checks(lk, label);
  };

  // S1：导入端在写 marker 之前写好 redirect_glossary.flag = 1（本词典有纯重定向）。
  if (!imported.redirect_glossary_present) fail("S1 ImportResult.redirect_glossary_present must be true");
  if (read_file(flag_path) != "1 " + std::to_string(blobs_size) + " 2\n") {
    fail("S1 redirect_glossary.flag must be \"1 <blobs size> 2\"; got \"" + read_file(flag_path) + "\"");
  }
  check_with_fresh_query("[S1 sidecar=1]");

  // S2：存量词典没有 sidecar —— 读侧照旧逐条检测，结果不变。
  std::filesystem::remove(flag_path);
  check_with_fresh_query("[S2 no sidecar]");

  // S3：迁移扫描（fushidicts_ensure_redirect_flag 的实现）认出重定向并回填 sidecar。
  if (ensure_redirect_glossary_flag(dict_dir) != 1) fail("S3 ensure_redirect_glossary_flag must report 1");
  if (read_file(flag_path) != "1 " + std::to_string(blobs_size) + " 2\n") {
    fail("S3 migration must rewrite redirect_glossary.flag as 1; got \"" + read_file(flag_path) + "\"");
  }
  check_with_fresh_query("[S3 migrated sidecar=1]");

  // S4：sidecar 的大小钉不上（覆盖式恢复留下的陈旧文件）就不采信，照旧检测。
  {
    std::ofstream(flag_path, std::ios::binary | std::ios::trunc) << "0 " << (blobs_size + 1) << " 2\n";
    check_with_fresh_query("[S4 stale sidecar]");
  }

  // S5：读侧确实按 sidecar 跳过检测——伪造一份「0」，纯重定向记录就原样浮上来。这条
  // 是反向证据：如果 sidecar 根本没被读，S1/S3 的绿就什么也证明不了。
  {
    std::ofstream(flag_path, std::ios::binary | std::ios::trunc) << "0 " << blobs_size << " 2\n";
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    Lookup lk(q, d);
    auto results = lk.lookup("instead of people in sharp", 16);
    if (find_expr(results, "instead of") == nullptr) {
      fail("S5 a forged redirect-free sidecar must disable detection (proves the flag is consulted); got " +
           dump(results));
    }
    std::filesystem::remove(flag_path);
    if (ensure_redirect_glossary_flag(dict_dir) != 1) fail("S5 re-scan after removing the forged sidecar must report 1");
  }

  // S6：没有任何纯重定向的 Yomitan 词典：导入写 0，迁移扫描同样得出 0。
  {
    const std::string plain_out = fushi_test::temp_dir() + "/fushi_yomitan_redirect_plain_out";
    std::filesystem::remove_all(plain_out);
    const std::string plain_bank = "[" + definition_row("instead") + "," +
                                   "[\"give up\",\"\",\"\",\"\",0,[[\"give up\",[\"Redirected from give up\"]],"
                                   "\"to stop trying\"],0,\"\"]]";
    const std::vector<fushi_test::ZipFile> plain_files = {
        {"index.json", "{\"title\":\"PlainDict\",\"format\":3,\"revision\":\"1\"}"},
        {"term_bank_1.json", plain_bank},
    };
    ImportResult plain = dictionary_importer::import(fushi_test::write_zip("yomitan_redirect_plain", plain_files),
                                                     plain_out);
    if (!plain.success) {
      fail("S6 plain import failed");
    } else {
      const std::string plain_dir = plain_out + "/" + plain.title;
      const auto plain_size = std::filesystem::file_size(plain_dir + "/blobs.bin");
      if (plain.redirect_glossary_present) fail("S6 plain dict must report redirect_glossary_present=false");
      if (read_file(plain_dir + "/redirect_glossary.flag") != "0 " + std::to_string(plain_size) + " 2\n") {
        fail("S6 plain dict sidecar must be \"0 <size>\"");
      }
      std::filesystem::remove(plain_dir + "/redirect_glossary.flag");
      if (ensure_redirect_glossary_flag(plain_dir) != 0) fail("S6 migration scan of the plain dict must report 0");
      DictionaryQuery q;
      q.add_term_dict(plain_dir);
      Lookup lk(q, d);
      auto results = lk.lookup("give up now", 16);
      const LookupResult* hit = find_expr(results, "give up");
      if (hit == nullptr || hit->term.glossaries.size() != 1 || !hit->term.glossaries.front().dict_redirect_free) {
        fail("S6 redirect-free dict: give up stays as-is and its glossary is marked dict_redirect_free; got " +
             dump(results));
      }
    }
  }

  // S7：MDX / StarDict / DSL 的存储形态同样写 sidecar（0）。
  {
    const std::string simple_out = fushi_test::temp_dir() + "/fushi_yomitan_redirect_simple_out";
    std::filesystem::remove_all(simple_out);
    ImportResult simple = dictionary_importer::write_simple_dict(
        "RedirectSimpleDict", {{"alpha", "<b>alpha</b> definition"}, {"beta", "beta definition"}}, simple_out);
    if (!simple.success) {
      fail("S7 write_simple_dict failed");
    } else {
      const std::string simple_dir = simple_out + "/" + simple.title;
      const auto simple_size = std::filesystem::file_size(simple_dir + "/blobs.bin");
      if (read_file(simple_dir + "/redirect_glossary.flag") != "0 " + std::to_string(simple_size) + " 2\n") {
        fail("S7 simple dict sidecar must be \"0 <size>\"");
      }
    }
  }

  // S8：判据放宽前（v1，没有第三列）写的 sidecar 不采信。存量 Jitendex 的旧 sidecar 是
  // 「0」——采信它就永远认不出 Jitendex 重定向。读侧照旧逐条检测（R / J 全部照样成立），
  // 迁移扫描按新判据重写成带版本的「1」。
  {
    std::ofstream(flag_path, std::ios::binary | std::ios::trunc) << "0 " << blobs_size << "\n";
    check_with_fresh_query("[S8 v1 sidecar]");
    if (ensure_redirect_glossary_flag(dict_dir) != 1) fail("S8 a v1 sidecar must be rescanned and report 1");
    if (read_file(flag_path) != "1 " + std::to_string(blobs_size) + " 2\n") {
      fail("S8 migration must rewrite the v1 sidecar as \"1 <size> 2\"; got \"" + read_file(flag_path) + "\"");
    }
  }

  // S9：只有 Jitendex 链接卡（没有 Yomitan formOf 项）的词典，导入端与迁移扫描同样认作含重定向。
  {
    const std::string jit_out = fushi_test::temp_dir() + "/fushi_yomitan_redirect_jitendex_out";
    std::filesystem::remove_all(jit_out);
    const std::string jit_bank =
        "[" + definition_row("阿呆陀羅") + "," +
        jitendex_row("アホんだら", jitendex_card("%E9%98%BF%E5%91%86%E9%99%80%E7%BE%85", "阿呆陀羅")) + "]";
    const std::vector<fushi_test::ZipFile> jit_files = {
        {"index.json", "{\"title\":\"JitendexLike\",\"format\":3,\"revision\":\"1\"}"},
        {"term_bank_1.json", jit_bank},
    };
    ImportResult jit =
        dictionary_importer::import(fushi_test::write_zip("yomitan_redirect_jitendex", jit_files), jit_out);
    if (!jit.success) {
      fail("S9 Jitendex-like import failed");
    } else {
      const std::string jit_dir = jit_out + "/" + jit.title;
      if (!jit.redirect_glossary_present) fail("S9 a link-card-only dict must report redirect_glossary_present=true");
      std::filesystem::remove(jit_dir + "/redirect_glossary.flag");
      if (ensure_redirect_glossary_flag(jit_dir) != 1) fail("S9 migration scan of a link-card-only dict must report 1");
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("yomitan_redirect_lookup_test: all passed\n");
  return 0;
}

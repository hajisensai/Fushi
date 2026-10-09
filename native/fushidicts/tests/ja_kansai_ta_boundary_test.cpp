// BUG-3212：关西方言变形「うた → った」跨词吞掉「ため / たび」的「た」。
//
// 「誓ってもらうためには」从「も」查词，旧行为最长匹配落在「もらうた」，经
// kansai-ben -た 还原成 もらう，高亮吞掉「ため」的「た」并挂上 -た / 关西方言标签。
// 修复在 lookup.cpp 的候选合并：同一 (expression, reading) 长短竞争时，短候选无需
// 变形、长候选带关西规则、短候选原文结束处起是保护结构（ために / ためには /
// ためにも / ための / たびに / たびには）、长候选跨进了该结构——四条全成立才留短的。
//
// 本测试用真 ja.json + 带词性的 Yomitan 词典跑真实 Lookup，覆盖规格列出的全部用例：
// 修复用例、真方言、单独的「もらうた」、标准语变形、保护名单之外、假名原文对汉字
// 词条、扫描窗口边缘、maxResults=1、词典重定向、多词典释义保留，以及小补丁方案的
// 两个反例（また / あなた 后接「び / め」开头的词）。
//
// Usage: ja_kansai_ta_boundary_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <set>
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

bool has_kansai(const LookupResult& r) {
  for (const TransformGroup& g : r.trace) {
    if (g.name == "kansai-ben") return true;
  }
  return false;
}

// 首条结果（用户看到的卡片 + 高亮长度 + 变形标签）必须是 [expression]、原文匹配
// [matched]；[kansai] 指定变形链里是否带关西规则，[want_trace_empty] 为真时变形链
// 必须为空（「无过去式 / 关西方言标签」）。
void expect_top(Lookup& lk, const std::string& query, const std::string& matched, const std::string& expression,
                bool kansai, const char* what, int max_results = 16, std::size_t scan_length = 16,
                bool want_trace_empty = false) {
  std::vector<LookupResult> results = lk.lookup(query, max_results, scan_length);
  if (results.empty()) {
    fail(std::string(what) + ": lookup(\"" + query + "\") returned nothing");
    return;
  }
  const LookupResult& top = results.front();
  if (top.matched != matched || top.term.expression != expression || has_kansai(top) != kansai ||
      (want_trace_empty && !top.trace.empty())) {
    fail(std::string(what) + ": lookup(\"" + query + "\") top should be [" + expression + " <- " + matched +
         (kansai ? " /kansai-ben" : "") + "]; got " + dump(results));
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

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_ja_kansai_ta_out";
  std::filesystem::remove_all(out_dir);

  // 主词典：带词性，读音齐全（假名原文对汉字词条用）。
  const std::string main_dict = import_dict(
      "ja_kansai_main", "JaKansaiMain",
      {
          row("もらう", "", "v5", gloss("receive (main)")),
          row("買う", "かう", "v5", gloss("buy")),
          row("会う", "あう", "v5", gloss("meet")),
          row("言う", "いう", "v5", gloss("say")),
          row("話す", "はなす", "v5", gloss("speak")),
          row("食べる", "たべる", "v1", gloss("eat")),
          row("為", "ため", "", gloss("sake")),
          row("度", "たび", "", gloss("time")),
          row("また", "", "", gloss("again")),
          row("あなた", "", "", gloss("you")),
          row("びっくり", "", "", gloss("surprise")),
          row("ま", "", "", gloss("interval")),
          row("あな", "", "", gloss("hole")),
          row("目掛ける", "めがける", "v1", gloss("aim at")),
      },
      out_dir);
  // 第二本词典：同一 (もらう, "") 的另一份释义——修复后释义必须仍是两本都在。
  const std::string second_dict = import_dict("ja_kansai_second", "JaKansaiSecond",
                                              {row("もらう", "", "v5", gloss("receive (second)"))}, out_dir);
  // 第三本词典：纯重定向记录「もらう」→「貰う」（Yomitan 词典自带变形），目标在
  // 同一本里。「もらうた」经关西方言还原成 もらう 再跟随重定向，与无变形的「もらう」
  // 跟随重定向落到同一 (貰う, もらう) 键上——同一判据必须同样作用于重定向结果。
  const std::string redirect_dict = import_dict(
      "ja_kansai_redirect", "JaKansaiRedirect",
      {
          row("もらう", "", "v5", "[[\"貰う\",[]]]"),
          row("貰う", "もらう", "v5", gloss("receive (redirect target)")),
      },
      out_dir);
  if (g_fail) return 1;

  Deinflector d;
  d.load_transforms_json(ja_json);
  DictionaryQuery q;
  q.add_term_dict(main_dict);
  q.add_term_dict(second_dict);
  q.add_term_dict(redirect_dict);
  Lookup lk(q, d);

  // ---- 修复用例：保护结构前的「た」不再被关西方言吞掉 ------------------------
  expect_top(lk, "もらうためには", "もらう", "もらう", false, "F1 誓ってもらうためには", 16, 16, true);
  expect_top(lk, "買うために", "買う", "買う", false, "F2 本を買うために", 16, 16, true);
  expect_top(lk, "会うたびに", "会う", "会う", false, "F3 彼に会うたびに", 16, 16, true);
  expect_top(lk, "もらうためには", "もらう", "もらう", false, "F4 maxResults=1", 1, 16, true);
  expect_top(lk, "もらうための", "もらう", "もらう", false, "F5 ための");
  expect_top(lk, "会うたびには", "会う", "会う", false, "F6 たびには");
  expect_top(lk, "買うためにも", "買う", "買う", false, "F7 ためにも");

  // ---- 真方言保持完整匹配 ----------------------------------------------------
  expect_top(lk, "買うたんや", "買うた", "買う", true, "K1 昨日、本を買うたんや");
  expect_top(lk, "会うて話す", "会うて", "会う", true, "K2 明日、彼に会うて話す");
  expect_top(lk, "言うたらあかん", "言うたら", "言う", true, "K3 そんなこと言うたらあかん");
  expect_top(lk, "もらうた", "もらうた", "もらう", true, "K4 もらうた alone");

  // ---- 标准语变形不受影响 ----------------------------------------------------
  expect_top(lk, "買った", "買った", "買う", false, "S1 買った");
  expect_top(lk, "会って", "会って", "会う", false, "S2 会って");
  expect_top(lk, "食べました", "食べました", "食べる", false, "S3 食べました");

  // ---- 保护名单之外保持原有行为（「ためだ」不在名单里）-----------------------
  expect_top(lk, "買うためだ", "買うた", "買う", true, "N1 ためだ is not protected");
  expect_top(lk, "買うたら", "買うたら", "買う", true, "N2 たら is not protected");

  // ---- 小补丁方案的反例：没有关西规则，四条判据不成立 -------------------------
  expect_top(lk, "またびっくりした", "また", "また", false, "C1 また + びっくり");
  expect_top(lk, "あなためがけて", "あなた", "あなた", false, "C2 あなた + めがけて");

  // ---- 假名原文对汉字词条：长度按原文字节算，不按词条文字算 ------------------
  expect_top(lk, "かうために", "かう", "買う", false, "R1 kana source / kanji entry");
  expect_top(lk, "かうたんや", "かうた", "買う", true, "R2 kana source / kanji entry, real dialect");

  // ---- 扫描窗口边缘：保护结构完整落在窗口内才生效 ----------------------------
  // 窗口 6 码点「もらうために」：结构完整可见 → もらう。
  expect_top(lk, "もらうためには", "もらう", "もらう", false, "W1 window covers ために", 16, 6);
  // 窗口 5 码点「もらうため」：结构被截断、看不全 → 保持原行为（もらうた）。
  expect_top(lk, "もらうためには", "もらうた", "もらう", true, "W2 window cuts ために", 16, 5);

  // ---- 多词典释义保留 --------------------------------------------------------
  {
    std::vector<LookupResult> results = lk.lookup("もらうためには", 16);
    std::set<std::string> dicts;
    for (const LookupResult& r : results) {
      if (r.term.expression != "もらう") continue;
      for (const GlossaryEntry& g : r.term.glossaries) dicts.insert(g.dict_name);
    }
    if (dicts.size() != 2) {
      fail("M1 both dictionaries' glossaries for もらう must survive; got " + std::to_string(dicts.size()) +
           " dict(s): " + dump(results));
    }
  }

  // ---- 词典重定向：跟随照旧，同一判据作用于重定向结果 ------------------------
  {
    std::vector<LookupResult> results = lk.lookup("もらうためには", 16);
    bool saw_target = false;
    for (const LookupResult& r : results) {
      if (r.term.expression != "貰う") continue;
      saw_target = true;
      if (r.matched != "もらう" || has_kansai(r)) {
        fail("D1 redirect target 貰う must match もらう without kansai; got " + dump(results));
      }
    }
    if (!saw_target) fail("D1 redirect target 貰う must still be followed; got " + dump(results));
    // 单独的「もらうた」：重定向结果照旧是关西方言、完整匹配。
    std::vector<LookupResult> alone = lk.lookup("もらうた", 16);
    bool saw_alone = false;
    for (const LookupResult& r : alone) {
      if (r.term.expression == "貰う" && r.matched == "もらうた" && has_kansai(r)) saw_alone = true;
    }
    if (!saw_alone) fail("D2 redirect target for lone もらうた must stay dialect; got " + dump(alone));
  }

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("PASS ja_kansai_ta_boundary_test\n");
  return 0;
}

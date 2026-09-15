// 英语词形变化还原的端到端闭环（用户实测：OALDPE10 / OALDPE En-Cn 上「各种形态的
// 变形」都查不到原形）。两条独立的断链，各钉一半：
//
//   1) 规则表只有 Yomitan 移植的 en.json（规则后缀），0 条 wholeWord：went / took /
//      children / mice / better / was 这类替补形（suppletive）根本没有还原路径，
//      better 只会被 comparative 拆成 bett / bet。修法是数据层新增
//      fushi/assets/transforms/en_irregular.json（本测试经 argv[2] 读真文件）。
//
//   2) Yomitan 格式词典若整本没写词性（OALDPE10：~86 万条 rules 全空），
//      Lookup::filter_by_pos 按 Yomitan 契约「空 rules = 非变形词」把**每一个**变形
//      还原命中全部丢掉——连 walked → walk 这种规则形也不生效，等于整张英语规则表
//      对这类词典是关的。修法是 term_rules.flag sidecar（util/term_rules_flag.hpp）：
//      整本无词性 → 读侧把空 rules 当通配 "*"；带词性的词典（日语 JMdict 系）语义
//      不变，名词不会被拿去当动词变形的原形。
//
// 跑的是 app 真正调用的路径 Lookup::lookup()（scan_candidates → text_processor →
// Deinflector::deinflect → query_raw → filter_by_pos），词典分别是真的
// write_simple_dict 产物（MDX/StarDict/DSL 存储形态）与真的 Yomitan zip 导入产物。
//
// Red/green：删掉 en_irregular.json 的规则 → A 组红；删掉 query.cpp 的
// rules_wildcard 分支 → B 组红；把空 rules 无条件当 "*" → C 组红。
//
//   3) 短语动词（BUG-2549）：Yomitan english-transforms.js 的 phrasal 规则是正则型
//      `other` 规则，移植成 JSON 时整体丢失，v_phr 条件存在但零条规则用到它——
//      "gave up" / "walked away" / "picked it up" 都还原不到 "give up" / "walk away" /
//      "pick up"。修法是 en.json 顶层 phrasalVerbs 词表 + 动词组 phrasalVerb 标记 +
//      Deinflector::deinflect_phrasal（动词头变形、宾语插入）。D 组覆盖；删掉
//      deinflect_phrasal 的调用 → D 组红；C5/C6 钉住 v_phr 经 filter_by_pos 的语义。
//
// Usage: en_inflection_lookup_test <en.json> <en_irregular.json>
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

// 命中必须来自**整个**查询串（scan_candidates 顺手生成的短前缀不算），且必须真的
// 经过了变形还原（trace 非空）——否则 "went" 恰好也是词条时这条恒真。
bool has_whole_deinflected_hit(const std::vector<LookupResult>& results, const std::string& query,
                               const std::string& want_expression) {
  for (const LookupResult& r : results) {
    if (r.term.expression == want_expression && r.matched == query && !r.trace.empty()) return true;
  }
  return false;
}

void expect_lemma(Lookup& lk, const std::string& query, const std::string& want, const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 32);
  if (!has_whole_deinflected_hit(results, query, want)) {
    fail(std::string(what) + ": lookup(\"" + query + "\") did not deinflect to \"" + want + "\"; got " +
         dump(results));
  }
}

// 同上，但命中的匹配段是查询串的某个候选前缀（scan_candidates 的产物）而非整串。
void expect_lemma_matched(Lookup& lk, const std::string& query, const std::string& matched, const std::string& want,
                          const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 32);
  if (!has_whole_deinflected_hit(results, matched, want)) {
    fail(std::string(what) + ": lookup(\"" + query + "\") did not deinflect \"" + matched + "\" to \"" + want +
         "\"; got " + dump(results));
  }
}

void expect_no_lemma(Lookup& lk, const std::string& query, const std::string& unwanted, const char* what) {
  std::vector<LookupResult> results = lk.lookup(query, 32);
  if (has_whole_deinflected_hit(results, query, unwanted)) {
    fail(std::string(what) + ": lookup(\"" + query + "\") must NOT deinflect to \"" + unwanted + "\"; got " +
         dump(results));
  }
}

void expect_flag(const std::string& dict_dir, char want, const char* what) {
  const std::string content = read_file(dict_dir + "/term_rules.flag");
  if (content.empty() || content[0] != want) {
    fail(std::string(what) + ": term_rules.flag should start with '" + want + "', got \"" + content + "\"");
  }
}

// Yomitan term bank v3 行：[expr, reading, def_tags, rules, score, [glossary], sequence, term_tags]
std::string term_row(const std::string& expr, const std::string& rules) {
  return "[\"" + expr + "\",\"\",\"\",\"" + rules + "\",0,[\"gloss of " + expr + "\"],0,\"\"]";
}

std::string import_yomitan(const char* label, const std::string& title, const std::vector<std::string>& rows,
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
  const std::string zip_path = fushi_test::write_zip(label, files);
  ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    fail(std::string("import ") + label + " failed: " + (r.errors.empty() ? "(no error)" : r.errors.front()));
    return {};
  }
  return out_dir + "/" + r.title;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <en.json> <en_irregular.json>\n", argv[0]);
    return 2;
  }
  const std::string en_json = read_file(argv[1]);
  const std::string en_irregular_json = read_file(argv[2]);
  if (en_json.empty()) fail("cannot read en.json");
  if (en_irregular_json.empty()) fail("cannot read en_irregular.json");
  if (g_fail) return 1;

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_en_inflection_out";
  std::filesystem::remove_all(out_dir);

  // 加载顺序故意与 manifest 相反（先 irregular 后 en）：条件块在两份文件里是同一份
  // 拷贝，位分配必须顺序无关。
  Deinflector d;
  d.load_transforms_json(en_irregular_json);
  d.load_transforms_json(en_json);

  // ---- A) simple dict（rules 恒 "*"）+ 不规则形 ------------------------------
  {
    std::vector<SimpleEntry> entries;
    for (const char* w : {"go", "child", "grandchild", "good", "well", "be", "take", "mouse", "woman", "walk",
                          "do", "can", "person", "many", "have"}) {
      entries.push_back({w, std::string("definition of ") + w});
    }
    ImportResult r = dictionary_importer::write_simple_dict("EnIrregularSimple", entries, out_dir);
    if (!r.success) {
      fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
      return 1;
    }
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);
    Lookup lk(q, d);

    expect_lemma(lk, "walked", "walk", "A0 regular past still works");
    expect_lemma(lk, "went", "go", "A1 suppletive past");
    expect_lemma(lk, "Went", "go", "A1b capitalised suppletive past (text_processor lowercases)");
    expect_lemma(lk, "gone", "go", "A2 irregular participle");
    expect_lemma(lk, "took", "take", "A3 vowel-change past");
    expect_lemma(lk, "taken", "take", "A4 -en participle");
    expect_lemma(lk, "was", "be", "A5 be: was");
    expect_lemma(lk, "been", "be", "A6 be: been");
    expect_lemma(lk, "has", "have", "A7 has -> have");
    expect_lemma(lk, "children", "child", "A8 irregular plural");
    expect_lemma(lk, "grandchildren", "grandchild", "A9 irregular plural suffix over compound");
    expect_lemma(lk, "mice", "mouse", "A10 mice -> mouse");
    expect_lemma(lk, "women", "woman", "A11 women -> woman via -men");
    expect_lemma(lk, "people", "person", "A12 people -> person");
    expect_lemma(lk, "better", "good", "A13 irregular comparative (adj)");
    expect_lemma(lk, "better", "well", "A14 irregular comparative (adv)");
    expect_lemma(lk, "most", "many", "A15 irregular superlative");
    expect_lemma(lk, "didn't", "do", "A16 negative contraction chained through irregular past");
    expect_lemma(lk, "can't", "can", "A17 can't -> can");
    expect_lemma(lk, "children's", "child", "A18 possessive chained into irregular plural");
    expect_lemma(lk, "children\xE2\x80\x99s", "child", "A19 typographic possessive chained into irregular plural");
  }

  // ---- B) Yomitan 词典整本无词性：空 rules 当通配 -------------------------------
  {
    const std::string dict_dir = import_yomitan("en_posless", "EnPosless",
                                                {term_row("walk", ""), term_row("go", ""), term_row("child", "")},
                                                out_dir);
    if (dict_dir.empty()) return 1;
    expect_flag(dict_dir, '0', "B0 importer records no-POS");
    {
      DictionaryQuery q;
      q.add_term_dict(dict_dir);
      Lookup lk(q, d);
      expect_lemma(lk, "walked", "walk", "B1 regular past on POS-less Yomitan dict");
      expect_lemma(lk, "went", "go", "B2 irregular past on POS-less Yomitan dict");
      expect_lemma(lk, "children", "child", "B3 irregular plural on POS-less Yomitan dict");
    }
    // 存量词典：没有 sidecar → 加载时扫描一次并回填。
    std::filesystem::remove(dict_dir + "/term_rules.flag");
    {
      DictionaryQuery q;
      q.add_term_dict(dict_dir);
      Lookup lk(q, d);
      expect_lemma(lk, "walked", "walk", "B4 legacy dict without sidecar is scanned on load");
    }
    expect_flag(dict_dir, '0', "B5 sidecar backfilled after legacy scan");
    // 失效的 sidecar（blobs 大小对不上）不可信：重新扫描并覆盖。
    {
      std::ofstream stale(dict_dir + "/term_rules.flag", std::ios::binary | std::ios::trunc);
      stale << "1 12345\n";
    }
    {
      DictionaryQuery q;
      q.add_term_dict(dict_dir);
      Lookup lk(q, d);
      expect_lemma(lk, "walked", "walk", "B6 stale sidecar (size mismatch) is ignored and rescanned");
    }
    expect_flag(dict_dir, '0', "B7 stale sidecar rewritten");
  }

  // ---- C) Yomitan 词典带词性：Yomitan 语义不变 ----------------------------------
  {
    // walke 是个「名词」（rules 空）：walked 经 past(ed -> e) 会落到它，但 Yomitan 契约
    // 说空 rules 不是变形词，filter_by_pos 必须继续把它挡掉。
    const std::string dict_dir = import_yomitan("en_pos", "EnPos",
                                                {term_row("walk", "v"), term_row("walke", ""), term_row("go", "v"),
                                                 term_row("child", "n"), term_row("give up", "v"),
                                                 term_row("pick up", "n")},
                                                out_dir);
    if (dict_dir.empty()) return 1;
    expect_flag(dict_dir, '1', "C0 importer records POS present");
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    Lookup lk(q, d);
    expect_lemma(lk, "walked", "walk", "C1 POS-tagged verb still deinflects");
    expect_no_lemma(lk, "walked", "walke", "C2 empty-rules noun is NOT a verb lemma (Yomitan semantics kept)");
    expect_lemma(lk, "went", "go", "C3 irregular past on POS-tagged dict");
    expect_lemma(lk, "children", "child", "C4 irregular plural on POS-tagged noun");
    // v_phr 是 v 的子条件：rules "v" 的词条必须接住短语动词还原（v 位集包含 v_phr 位），
    // 而 rules "n" 的 "pick up" 必须继续被 filter_by_pos 挡掉。
    expect_lemma(lk, "gave up", "give up", "C5 phrasal head deinflection accepted by POS 'v'");
    expect_no_lemma(lk, "picked up", "pick up", "C6 phrasal head deinflection rejected by POS 'n'");
  }

  // ---- D) 短语动词：动词头变形 + 宾语插入 --------------------------------------
  {
    std::vector<SimpleEntry> entries;
    for (const char* w : {"give up", "give", "pick up", "pick", "take out", "take", "look up", "look", "walk away",
                          "walk", "give upstairs", "cat"}) {
      entries.push_back({w, std::string("definition of ") + w});
    }
    ImportResult r = dictionary_importer::write_simple_dict("EnPhrasalSimple", entries, out_dir);
    if (!r.success) {
      fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
      return 1;
    }
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);
    Lookup lk(q, d);

    expect_lemma(lk, "gave up", "give up", "D1 suppletive past head");
    expect_lemma(lk, "given up", "give up", "D2 irregular participle head");
    expect_lemma(lk, "gives up", "give up", "D3 3sg head");
    expect_lemma(lk, "giving up", "give up", "D4 -ing head");
    expect_lemma(lk, "walked away", "walk away", "D5 regular past head");
    expect_lemma(lk, "Gave Up", "give up", "D6 capitalised phrasal (text_processor lowercases)");
    expect_lemma(lk, "picked it up", "pick up", "D7 interposed object chained into regular past");
    // 查询串要压在默认 scan_length=16 码点以内，否则整串根本不进候选。
    expect_lemma(lk, "took it all out", "take out", "D8 multi-word interposed object chained into suppletive past");
    expect_lemma(lk, "look it up", "look up", "D9 interposed object on an uninflected head");
    // 尾随的词不是整串的一部分时，命中来自短候选 "gave up"（matched 也应是它）。
    expect_lemma_matched(lk, "gave up on me", "gave up", "give up", "D10 phrasal hit inside a longer scan window");
    // 小品词按整个 token 匹配：Yomitan 的正则不封尾会把 "gave upstairs" 当 "gave up…"，
    // 这里 "upstairs" 不是小品词，动词头不变形。
    expect_no_lemma(lk, "gave upstairs", "give upstairs", "D11 particle must match a whole token");
    // 动词头变形不能丢掉小品词：整串 "gave up" 不得还原成裸 "give"。
    expect_no_lemma(lk, "gave up", "give", "D12 phrasal deinflection keeps the particle");
    // 宾语里夹着短语动词用词就不是宾语插入（"walked up the hill" 的 "up" 是小品词本身）。
    expect_no_lemma(lk, "walked up the cat", "walk cat", "D13 object containing a phrasal word is not interposed");
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}

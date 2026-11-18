// 反馈 WIZUEQx1fY：英语查词 My → M、Our → O、One → On 排在原词前面。两层根因各钉一半：
//
//   1) 变形表是所有语言一起装进同一个 Deinflector 的，拉丁字母语言共用后缀：
//      阿尔巴尼亚语 sq.json 的 participle（-ur → ''）把 Our 还原成 O，拉丁语 la.json 的
//      plural（-e → ''）把 One 还原成 On。修法：规则带语言、一条链只用一门语言的规则，
//      标了语言的词典只接受本语言的还原链（DictionaryQuery::add_term_dict 的 language +
//      Lookup::lookup 的语言把关）。未标注语言的词典无从判断，行为不变。
//
//   2) My → M 是英语自己的 -y 规则（y → ''）造成的，与语言无关；它排在 my 前面是因为
//      比较器先比预处理步数（My 小写成 my 算 1 步）再比变形链长（M 是 0 步预处理、
//      1 步变形）。修法：变形链长先于预处理步数（lookup.cpp more_direct）。
//
// 跑的是 app 真正调用的路径 Lookup::lookup()，变形表是真文件（经 argv 传入）。
//
// Red/green：
//   * 去掉 lookup.cpp 的 scope_for（恒用 scope）→ B / C / D 组红；
//   * 把 more_direct 改回先比步数 → A 组红；
//   * Deinflector::deinflect 忽略 allowed_languages → E2 红。
//
// Usage: dictionary_language_gate_lookup_test <en.json> <en_irregular.json> <sq.json> <la.json>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/language_tag.hpp"
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
    for (const GlossaryEntry& g : r.term.glossaries) s += " @" + g.dict_name;
    s += "] ";
  }
  return s.empty() ? "(none)" : s;
}

// 整个查询串经过变形还原（trace 非空）命中 [expression] 的那条结果；没有返回 nullptr。
const LookupResult* deinflected_hit(const std::vector<LookupResult>& results, const std::string& query,
                                    const std::string& expression) {
  for (const LookupResult& r : results) {
    if (r.term.expression == expression && r.matched == query && !r.trace.empty()) return &r;
  }
  return nullptr;
}

void expect_lemma(Lookup& lk, const std::string& query, const std::string& want, const char* what) {
  const std::vector<LookupResult> results = lk.lookup(query, 32);
  if (deinflected_hit(results, query, want) == nullptr) {
    fail(std::string(what) + ": lookup(\"" + query + "\") did not deinflect to \"" + want + "\"; got " +
         dump(results));
  }
}

void expect_no_lemma(Lookup& lk, const std::string& query, const std::string& unwanted, const char* what) {
  const std::vector<LookupResult> results = lk.lookup(query, 32);
  if (deinflected_hit(results, query, unwanted) != nullptr) {
    fail(std::string(what) + ": lookup(\"" + query + "\") must NOT deinflect to \"" + unwanted + "\"; got " +
         dump(results));
  }
}

void expect_first(Lookup& lk, const std::string& query, const std::string& want, const char* what) {
  const std::vector<LookupResult> results = lk.lookup(query, 32);
  if (results.empty() || results.front().term.expression != want) {
    fail(std::string(what) + ": lookup(\"" + query + "\") should rank \"" + want + "\" first; got " +
         dump(results));
  }
}

// 精确命中（不经变形）必须在。
void expect_exact(Lookup& lk, const std::string& query, const char* what) {
  const std::vector<LookupResult> results = lk.lookup(query, 32);
  for (const LookupResult& r : results) {
    if (r.term.expression == query && r.matched == query && r.trace.empty()) return;
  }
  fail(std::string(what) + ": lookup(\"" + query + "\") lost its exact hit; got " + dump(results));
}

std::string write_simple(const std::string& title, const std::vector<const char*>& words,
                         const std::string& out_dir) {
  std::vector<SimpleEntry> entries;
  for (const char* w : words) entries.push_back({w, std::string("definition of ") + w + " in " + title});
  const ImportResult r = dictionary_importer::write_simple_dict(title, entries, out_dir);
  if (!r.success) {
    fail(title + ": " + (r.errors.empty() ? "write_simple_dict failed" : r.errors.front()));
    return {};
  }
  return out_dir + "/" + r.title;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s <en.json> <en_irregular.json> <sq.json> <la.json>\n", argv[0]);
    return 2;
  }
  Deinflector d;
  for (int i = 1; i <= 4; i++) {
    const std::string json = read_file(argv[i]);
    if (json.empty()) {
      fail(std::string("cannot read ") + argv[i]);
      return 1;
    }
    d.load_transforms_json(json);
  }

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_dict_language_gate";
  // 原词与「被别的语言 / 英语自己的规则还原出来的」短词都在词典里——真实的英语词典
  // 都收单字母词条和 on / o 这类短词，这正是误命中能冒出来的条件。
  const std::vector<const char*> words = {"my", "M", "our", "O", "one", "On", "March", "march", "walk"};
  const std::string dict_dir = write_simple("LangGateDict", words, out_dir);
  if (dict_dir.empty()) return 1;

  // ---- 0) 标签归一 ------------------------------------------------------------
  {
    const auto expect_tag = [](const char* raw, const char* want) {
      const std::string got = fushi::primary_language_tag(raw);
      if (got != want) {
        fail(std::string("primary_language_tag(\"") + raw + "\") = \"" + got + "\", want \"" + want + "\"");
      }
    };
    expect_tag("en", "en");
    expect_tag("EN-us", "en");
    expect_tag("en_GB", "en");
    expect_tag(" ja-JP ", "ja");
    expect_tag("eng", "en");
    expect_tag("kat", "ka");
    expect_tag("grc", "grc");
    expect_tag("zh-Hant", "zh");
    expect_tag("", "");
    expect_tag("   ", "");
    // en.json 与 en_irregular.json 是同一门语言。
    if (d.language_count() != 3) fail("en + en_irregular + sq + la should load as 3 languages");
    if (d.language_id("en") < 0 || d.language_id("sq") < 0 || d.language_id("la") < 0) {
      fail("language_id lost a loaded language");
    }
  }

  // ---- A) 排序：变形链长先于预处理步数（与词典标没标语言无关）---------------------
  {
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    Lookup lk(q, d);
    expect_first(lk, "My", "my", "A1 My: case-folded exact hit outranks the -y guess");
    expect_first(lk, "Our", "our", "A2 Our: case-folded exact hit outranks a deinflected guess");
    expect_first(lk, "One", "one", "A3 One: case-folded exact hit outranks a deinflected guess");
    // 大小写完全一致的命中仍然排在折叠后的命中前面（两边变形链都是 0，再比步数）。
    expect_first(lk, "March", "March", "A4 exact-case hit still outranks the case-folded one");
    expect_first(lk, "march", "march", "A5 lowercase query hits lowercase entry");
    // 未标注语言：无从判断，别的语言的还原链照旧接受（行为不变，记录在案）。
    expect_lemma(lk, "Our", "O", "A6 unlabeled dictionary keeps accepting any language's chain");
    expect_lemma(lk, "walked", "walk", "A7 unlabeled dictionary still deinflects English");
  }

  // ---- B) 标成英语的词典：只接受英语变形表的还原链 -------------------------------
  for (const char* tag : {"en", "en-US", "EN", "eng"}) {
    DictionaryQuery q;
    q.add_term_dict(dict_dir, tag);
    Lookup lk(q, d);
    const std::string label = std::string("[") + tag + "] ";
    expect_no_lemma(lk, "Our", "O", (label + "B1 Albanian -ur must not read an English dictionary").c_str());
    expect_no_lemma(lk, "One", "On", (label + "B2 Latin -e must not read an English dictionary").c_str());
    expect_lemma(lk, "walked", "walk", (label + "B3 English deinflection still works").c_str());
    expect_lemma(lk, "My", "M", (label + "B4 English -y is an English rule, still applies").c_str());
    expect_first(lk, "My", "my", (label + "B5 ...but ranks after the exact hit").c_str());
    expect_first(lk, "Our", "our", (label + "B6 Our ranks our first").c_str());
    expect_exact(lk, "O", (label + "B7 exact lookups are not language-gated").c_str());
    expect_exact(lk, "On", (label + "B8 exact lookups are not language-gated").c_str());
  }

  // ---- C) 标成别的语言：接受本语言的链，拒绝英语的链；精确命中不受影响 -------------
  {
    DictionaryQuery q;
    q.add_term_dict(dict_dir, "sq");
    Lookup lk(q, d);
    expect_lemma(lk, "Our", "O", "C1 Albanian dictionary accepts the Albanian chain");
    expect_no_lemma(lk, "walked", "walk", "C2 Albanian dictionary rejects the English chain");
    expect_exact(lk, "walk", "C3 exact hit in a dictionary of another language");
  }
  {
    // 没有变形表的语言（中文）：任何还原链都不接受，精确命中照旧。
    DictionaryQuery q;
    q.add_term_dict(dict_dir, "zh-Hans");
    Lookup lk(q, d);
    expect_no_lemma(lk, "walked", "walk", "C4 a language without transforms accepts no chain");
    expect_exact(lk, "walk", "C5 exact hit in a dictionary whose language has no transforms");
  }

  // ---- D) 标注词典与未标注词典并存：把关按词典逐本生效 ----------------------------
  {
    const std::string other_dir = write_simple("LangGateUnlabeled", {"O", "walk"}, out_dir);
    if (other_dir.empty()) return 1;
    DictionaryQuery q;
    q.add_term_dict(dict_dir, "en");
    q.add_term_dict(other_dir);
    Lookup lk(q, d);
    const std::vector<LookupResult> results = lk.lookup("Our", 32);
    const LookupResult* hit = deinflected_hit(results, "Our", "O");
    if (hit == nullptr) {
      fail("D1 unlabeled dictionary should still surface O for Our; got " + dump(results));
    } else {
      for (const GlossaryEntry& g : hit->term.glossaries) {
        if (g.dict_name == "LangGateDict") {
          fail("D2 the English-labeled dictionary must not contribute to the Albanian chain; got " + dump(results));
        }
      }
    }
    // 英语的链两本都接受。
    const std::vector<LookupResult> walked = lk.lookup("walked", 32);
    const LookupResult* walk = deinflected_hit(walked, "walked", "walk");
    if (walk == nullptr || walk->term.glossaries.size() != 2) {
      fail("D3 both dictionaries should contribute walk for walked; got " + dump(walked));
    }
    // 本次查词把未标注的那本排除掉：剩下的全标了语言，O 不该再出现。
    LookupOptions options;
    options.excluded_dictionaries = {"LangGateUnlabeled"};
    const std::vector<LookupResult> excluded = lk.lookup("Our", 32, 16, options);
    if (deinflected_hit(excluded, "Our", "O") != nullptr) {
      fail("D4 with the unlabeled dictionary excluded, O must be gone; got " + dump(excluded));
    }
  }

  // ---- E) Deinflector：链带语言、不跨语言、allowed_languages 只约束链首 -----------
  {
    const int en = d.language_id("en");
    const int sq = d.language_id("sq");
    bool saw_sq_o = false;
    for (const DeinflectionResult& r : d.deinflect("Our")) {
      if (r.trace.empty() != (r.language < 0)) fail("E0 language must be -1 exactly when the trace is empty");
      if (r.text == "O" && r.language == sq) saw_sq_o = true;
    }
    if (!saw_sq_o) fail("E1 Our -> O should be tagged as an Albanian chain");
    for (const DeinflectionResult& r : d.deinflect("Our", uint64_t{1} << en)) {
      if (r.language >= 0 && r.language != en) {
        fail("E2 allowed_languages = {en} still produced a chain of language " + d.language_name(r.language) +
             " (" + r.text + ")");
      }
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}

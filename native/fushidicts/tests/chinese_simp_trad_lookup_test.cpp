// 中文查词的简体 → 繁體回落（OpenCC STCharacters 全部候选 + 台/港字形）。
//
// 用户场景：查简体「这个」，而词典按繁體「這個」建索引——此前引擎没有任何简繁处理，
// 永远查不到。繁體拼写作为额外的文本变体挂在 text_processor 链尾，只在调用方声明
// 查询语言为中文（LookupOptions::chinese_simp_to_trad / process 的第二参）时才启用。
//
// 本测试钉：
//   1) 一简多繁全展开：发 → 發 + 髮，头发 → 頭髮（只取首选项会得到不存在的「頭發」），
//      关系 → 關係，里面 → 裏面 + 台湾字形 裡面，只在台/港字形表里的 污 → 汙；
//      组合数有上限且首选项组合排第一；表外文本不产出任何拼写；
//   2) 开关关（默认）：同一输入不产出繁體变体——日语里大量带简体形的汉字（国/学/
//      当…）查询必须与此前逐字一致，变体集一个都不能多；
//   3) 开关开时原形变体保留且 steps=0，不含简体字的文本不多出变体；
//   4) 端到端：词典只有繁體词条时开关开能命中，matched 回报原始简体串；「我们」命中
//      更长的「我們」（所以不能做成「原文零结果才回落」——单字「我」总能命中）；开关
//      关查不到；简繁词条并存时原形结果同长度排在繁體之前。
//
// Usage: chinese_simp_trad_lookup_test (no args) -> exit 0 PASS, non-zero FAIL.
#include <algorithm>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include <utf8.h>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "text_processor.hpp"
#include "zip_fixture.hpp"

namespace {

struct Failures {
  int count = 0;
  void fail(std::string_view msg) {
    std::fprintf(stderr, "FAIL: %.*s\n", static_cast<int>(msg.size()), msg.data());
    ++count;
  }
  void expect(bool ok, std::string_view msg) {
    if (!ok) fail(msg);
  }
};

const TextVariant* find_variant(const std::vector<TextVariant>& vs, std::string_view text) {
  const auto it = std::ranges::find_if(vs, [text](const TextVariant& v) { return v.text == text; });
  return it == vs.end() ? nullptr : &*it;
}

std::vector<std::string> spellings(std::string_view simplified) {
  std::vector<std::string> out;
  for (const auto& v : text_processor::simplified_to_traditional_variants(utf8::utf8to32(simplified))) {
    out.push_back(utf8::utf32to8(v));
  }
  return out;
}

bool contains(const std::vector<std::string>& vs, std::string_view s) {
  return std::ranges::find(vs, s) != vs.end();
}

void check_spellings(Failures& f) {
  const auto zhege = spellings("这个");
  f.expect(!zhege.empty() && zhege.front() == "這個", "这个: first spelling must be 這個");

  const auto fa = spellings("发");
  f.expect(contains(fa, "發") && contains(fa, "髮"), "发 must expand to both 發 and 髮");
  f.expect(!fa.empty() && fa.front() == "發", "发: OpenCC primary 發 must come first");

  const auto toufa = spellings("头发");
  f.expect(contains(toufa, "頭髮"), "头发 must reach 頭髮 (first-candidate-only gives 頭發)");

  f.expect(contains(spellings("关系"), "關係"), "关系 must reach 關係");
  f.expect(contains(spellings("干燥"), "乾燥"), "干燥 must reach 乾燥");
  f.expect(contains(spellings("以后"), "以後"), "以后 must reach 以後");

  const auto limian = spellings("里面");
  f.expect(contains(limian, "裏面") && contains(limian, "裡面"), "里面 must yield 裏面 and the Taiwan form 裡面");

  f.expect(contains(spellings("污"), "汙"), "污 must yield the Taiwan form 汙 (TWVariants-only key)");
  f.expect(contains(spellings("污渍"), "污漬"), "污渍 must keep the standard 污漬 besides 汙漬");

  f.expect(spellings("a这b") == std::vector<std::string>{"a這b"}, "ASCII around a simplified char is untouched");
  for (const char* s : {"這個", "たべる", "food", ""}) {
    f.expect(spellings(s).empty(), std::string("text without table chars must yield nothing: ") + s);
  }

  // 组合上限：20 个歧义字（发）的组合数是 2^20，必须截在上限内、首选项组合排第一。
  std::string many;
  for (int i = 0; i < 20; ++i) many += "发";
  const auto capped = spellings(many);
  f.expect(capped.size() <= text_processor::kMaxChineseTraditionalVariants, "variant count must respect the cap");
  std::string primary;
  for (int i = 0; i < 20; ++i) primary += "發";
  f.expect(!capped.empty() && capped.front() == primary, "the all-primary spelling must survive the cap first");
}

void check_process_gating(Failures& f) {
  const auto on = text_processor::process("这个", true);
  const TextVariant* trad = find_variant(on, "這個");
  const TextVariant* orig = find_variant(on, "这个");
  f.expect(trad != nullptr, "flag on: 这个 produced no 這個 variant");
  f.expect(orig != nullptr && orig->steps == 0, "flag on: the original 这个 variant must stay with steps=0");
  f.expect(trad == nullptr || trad->steps >= 1, "flag on: the traditional variant must cost at least one step");

  const auto off_default = text_processor::process("这个");
  const auto off_explicit = text_processor::process("这个", false);
  f.expect(find_variant(off_default, "這個") == nullptr, "default (flag off) must not produce 這個");
  f.expect(find_variant(off_explicit, "這個") == nullptr, "explicit flag off must not produce 這個");
  f.expect(off_default.size() == off_explicit.size(), "default and explicit-off variant sets differ");

  // 日语：国語 的「国」有简体→繁體映射；关着开关时变体集必须不含 國語。
  f.expect(find_variant(text_processor::process("国語"), "國語") == nullptr,
           "Japanese 国語 must not gain a 國語 variant when the flag is off");
  f.expect(find_variant(text_processor::process("国語", true), "國語") != nullptr,
           "国語 with the flag on should convert 国 -> 國 (table sanity)");

  for (const char* s : {"這個", "たべる", "food", ""}) {
    f.expect(text_processor::process(s, true).size() == text_processor::process(s, false).size(),
             std::string("flag on added variants to text without simplified chars: ") + s);
  }
}

std::vector<LookupResult> lookup_zh(const Lookup& lookup, const std::string& text, bool zh) {
  LookupOptions options;
  options.chinese_simp_to_trad = zh;
  return lookup.lookup(text, 32, 16, options);
}

const LookupResult* find_result(const std::vector<LookupResult>& rs, std::string_view expression) {
  const auto it = std::ranges::find_if(rs, [expression](const LookupResult& r) { return r.term.expression == expression; });
  return it == rs.end() ? nullptr : &*it;
}

bool write_dict(Failures& f, const std::string& title, const std::vector<SimpleEntry>& entries, DictionaryQuery& q) {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_zh_s2t_" + title;
  ImportResult r = dictionary_importer::write_simple_dict(title, entries, out_dir);
  if (!r.success) {
    f.fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
    return false;
  }
  q.add_term_dict(out_dir + "/" + r.title);
  return true;
}

void check_end_to_end(Failures& f) {
  DictionaryQuery q;
  if (!write_dict(f, "ZhTradDict",
                  {{"這個", "this"}, {"頭髮", "hair"}, {"關係", "relation"}, {"我", "I"}, {"我們", "we"},
                   {"發", "to send"}, {"髮", "hair (char)"}},
                  q)) {
    return;
  }
  Deinflector d;
  Lookup lookup(q, d);

  const auto zhege = lookup_zh(lookup, "这个是", true);
  const LookupResult* hit = find_result(zhege, "這個");
  f.expect(hit != nullptr, "flag on: 这个 did not find the 這個 entry");
  f.expect(hit == nullptr || hit->matched == "这个", "matched must be the original simplified prefix");
  f.expect(hit == nullptr || hit->deinflected == "這個", "deinflected must carry the traditional form");
  f.expect(find_result(lookup_zh(lookup, "这个", false), "這個") == nullptr, "flag off: 这个 must not reach 這個");

  f.expect(find_result(lookup_zh(lookup, "头发很长", true), "頭髮") != nullptr, "头发 must find 頭髮");
  f.expect(find_result(lookup_zh(lookup, "关系", true), "關係") != nullptr, "关系 must find 關係");

  const auto fa = lookup_zh(lookup, "发", true);
  f.expect(find_result(fa, "發") && find_result(fa, "髮"), "发 must find both 發 and 髮");

  // 「我」原样就能命中，但用户要的是更长的「我們」：回落不能只在零结果时触发。
  const auto women = lookup_zh(lookup, "我们是", true);
  f.expect(!women.empty() && women.front().term.expression == "我們", "我们 must rank the longer 我們 first");
  f.expect(find_result(women, "我") != nullptr, "the single-char 我 hit is still listed");

  DictionaryQuery q2;
  if (!write_dict(f, "ZhBothDict", {{"这个", "simplified entry"}, {"這個", "traditional entry"}}, q2)) return;
  Lookup lookup2(q2, d);
  const auto both = lookup_zh(lookup2, "这个", true);
  const auto simp = std::ranges::find_if(both, [](const LookupResult& r) { return r.term.expression == "这个"; });
  const auto trad = std::ranges::find_if(both, [](const LookupResult& r) { return r.term.expression == "這個"; });
  f.expect(simp != both.end(), "original simplified entry must still be found with the flag on");
  f.expect(trad != both.end(), "traditional entry should also be found with the flag on");
  f.expect(simp == both.end() || trad == both.end() || simp < trad,
           "at equal length the untransformed hit must rank before the traditional one");
}

}  // namespace

int main() {
  Failures f;
  check_spellings(f);
  check_process_gating(f);
  check_end_to_end(f);
  std::fprintf(stderr, "chinese_simp_trad_lookup_test: %s\n", f.count ? "FAILED" : "PASSED");
  return f.count ? 1 : 0;
}

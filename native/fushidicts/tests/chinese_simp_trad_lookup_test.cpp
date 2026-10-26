// 中文查词的简体 → 繁體回落（OpenCC STCharacters 单字表）。
//
// 用户场景：查简体「这个」，而词典按繁體「這個」建索引——此前引擎没有任何简繁处理，
// 永远查不到。回落作为额外的文本变体挂在 text_processor 链尾，只在调用方声明查询
// 语言为中文（LookupOptions::chinese_simp_to_trad / process 的第二参）时才启用。
//
// 本测试钉：
//   1) 开关开：「这个」产出「這個」变体，原形仍在且 steps=0（原查询照样先试）；
//   2) 开关关（默认）：同一输入不产出繁體变体——日语里大量带简体形的汉字（国/学/
//      当…）查询必须与此前逐字一致，变体集一个都不能多；
//   3) 不含简体字的文本（繁體、假名、拉丁）开关开也不产出多余变体；
//   4) 端到端：词典只有「這個」，开关开时查「这个」命中，matched 回报原始简体串
//      （高亮长度吃它），deinflected 是繁體形；开关关查不到；原样存在简体词条时
//      原查询仍命中它。
//
// Usage: chinese_simp_trad_lookup_test (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <vector>

#include <utf8.h>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "text_processor.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

const TextVariant* find_variant(const std::vector<TextVariant>& vs, const std::string& text) {
  for (const auto& v : vs) {
    if (v.text == text) return &v;
  }
  return nullptr;
}

const std::string kZheGeSimp = "\xE8\xBF\x99\xE4\xB8\xAA";    // 这个
const std::string kZheGeTrad = "\xE9\x80\x99\xE5\x80\x8B";    // 這個
const std::string kZhe = "\xE8\xBF\x99";                      // 这
const std::string kZheTrad = "\xE9\x80\x99";                  // 這

}  // namespace

int main() {
  // ── 1. 开关开：额外变体 + 原形保留 ──────────────────────────────────
  {
    auto vs = text_processor::process(kZheGeSimp, true);
    const TextVariant* trad = find_variant(vs, kZheGeTrad);
    const TextVariant* orig = find_variant(vs, kZheGeSimp);
    if (!trad) fail("flag on: 这个 produced no 這個 variant");
    if (!orig) fail("flag on: the original 这个 variant is gone");
    else if (orig->steps != 0) fail("flag on: the original variant must stay steps=0");
    if (trad && trad->steps < 1) fail("flag on: the traditional variant must cost at least one step");
  }
  // 导出的转换函数本身：逐字、取首选项；混合串里非简体字原样。
  {
    auto conv = [](const std::string& s) {
      return utf8::utf32to8(text_processor::simplified_to_traditional(utf8::utf8to32(s)));
    };
    if (conv(kZheGeSimp) != kZheGeTrad) fail("simplified_to_traditional(这个) != 這個");
    // 发 -> 發（首选项；备选 髮 不取）
    if (conv("\xE5\x8F\x91") != "\xE7\x99\xBC") fail("发 must convert to its first candidate 發");
    // 混合：「a这b」里 ASCII 不动
    if (conv("a\xE8\xBF\x99" "b") != "a\xE9\x80\x99" "b") fail("ASCII around a simplified char must be untouched");
  }

  // ── 2. 开关关（默认）：不得多出繁體变体 ─────────────────────────────
  {
    auto off_default = text_processor::process(kZheGeSimp);
    auto off_explicit = text_processor::process(kZheGeSimp, false);
    if (find_variant(off_default, kZheGeTrad)) fail("default (flag off) must not produce 這個");
    if (find_variant(off_explicit, kZheGeTrad)) fail("explicit flag off must not produce 這個");
    if (off_default.size() != off_explicit.size()) fail("default and explicit-off variant sets differ");

    // 日语：国語 / 学校 里的「国」「学」有简体形；关着开关时变体集必须不含 國語 / 學校。
    const std::string kokugo = "\xE5\x9B\xBD\xE8\xAA\x9E";        // 国語
    const std::string kokugoTrad = "\xE5\x9C\x8B\xE8\xAA\x9E";    // 國語
    if (find_variant(text_processor::process(kokugo), kokugoTrad)) {
      fail("Japanese 国語 must not gain a 國語 variant when the flag is off");
    }
    // 对照：同一输入开着开关就会出（证明上面的断言不是因为表里根本没有）。
    if (!find_variant(text_processor::process(kokugo, true), kokugoTrad)) {
      fail("国語 with the flag on should convert 国 -> 國 (table sanity)");
    }
  }

  // ── 3. 无简体字的文本：开关开也不多出变体 ───────────────────────────
  for (const char* s : {"\xE9\x80\x99\xE5\x80\x8B",                // 這個（已是繁體）
                        "\xE3\x81\x9F\xE3\x81\xB9\xE3\x82\x8B",    // たべる
                        "food", ""}) {
    auto on = text_processor::process(s, true);
    auto off = text_processor::process(s, false);
    if (on.size() != off.size()) {
      fail(std::string("flag on added variants to text without simplified chars: ") + s);
    }
  }

  // ── 4. 端到端 ─────────────────────────────────────────────────────
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_zh_s2t_out";
  std::vector<SimpleEntry> entries = {{kZheGeTrad, "this; this one"}};
  ImportResult r = dictionary_importer::write_simple_dict("ZhTradDict", entries, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
    std::fprintf(stderr, "chinese_simp_trad_lookup_test: FAILED\n");
    return 1;
  }
  DictionaryQuery q;
  q.add_term_dict(out_dir + "/" + r.title);
  Deinflector d;
  Lookup lookup(q, d);

  {
    LookupOptions on;
    on.chinese_simp_to_trad = true;
    auto results = lookup.lookup(kZheGeSimp + "\xE6\x98\xAF", 16, 16, on);  // 这个是
    bool hit = false;
    for (const auto& res : results) {
      if (res.term.expression != kZheGeTrad) continue;
      hit = true;
      if (res.matched != kZheGeSimp) fail("matched must be the original simplified prefix, got " + res.matched);
      if (res.deinflected != kZheGeTrad) fail("deinflected must carry the traditional form, got " + res.deinflected);
    }
    if (!hit) fail("flag on: 这个 did not find the 這個 entry");
  }
  {
    auto results = lookup.lookup(kZheGeSimp);  // 默认选项
    for (const auto& res : results) {
      if (res.term.expression == kZheGeTrad) fail("flag off: 这个 must not reach the 這個 entry");
    }
  }
  // 词典里同时有简体原词条：原查询照样命中它（回落是额外的，不是替换）。
  {
    const std::string out2 = fushi_test::temp_dir() + "/fushi_zh_s2t_out2";
    std::vector<SimpleEntry> both = {{kZheGeSimp, "simplified entry"}, {kZheGeTrad, "traditional entry"}};
    ImportResult r2 = dictionary_importer::write_simple_dict("ZhBothDict", both, out2);
    if (!r2.success) {
      fail("write_simple_dict (both) failed");
    } else {
      DictionaryQuery q2;
      q2.add_term_dict(out2 + "/" + r2.title);
      Lookup lookup2(q2, d);
      LookupOptions on;
      on.chinese_simp_to_trad = true;
      bool saw_simp = false, saw_trad = false;
      for (const auto& res : lookup2.lookup(kZheGeSimp, 16, 16, on)) {
        if (res.term.expression == kZheGeSimp) saw_simp = true;
        if (res.term.expression == kZheGeTrad) saw_trad = true;
      }
      if (!saw_simp) fail("original simplified entry must still be found with the flag on");
      if (!saw_trad) fail("traditional entry should also be found with the flag on");
    }
  }
  (void)kZhe;
  (void)kZheTrad;

  std::fprintf(stderr, "chinese_simp_trad_lookup_test: %s\n", g_fail ? "FAILED" : "PASSED");
  return g_fail ? 1 : 0;
}

// 弹窗 JSON 的 deinflectionTrace：词形变化链 + 每一层的语法说明。
//
// 这条链早就全线铺好——assets/transforms/<lang>.json 里每个 transform 都带
// Yomitan 的语法说明，deinflector 解析进 TransformGroup{name, description}，
// lookup 把整条 trace 挂在 LookupResult 上——唯独 build_popup_json 以前把 trace
// 丢了，改用一条现编的 "matched → deinflected" 且 description 恒为空串，于是
// 弹窗里永远没有语法说明。
//
// 本测试锁住 build_popup_json 的输出，并与 Dart 侧 buildDeinflectionTags
// （packages/fushi_dictionary/lib/src/language/language.dart）逐字节对齐——两条
// 弹窗路径必须给出同一份 JSON。Dart 侧对应用例见
// fushi/test/dictionary/deinflection_grammar_tags_test.dart。
//
// Usage: popup_json_deinflection_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/popup_json.hpp"

static int g_fail = 0;

static void expect_contains(const char* name, const std::string& haystack,
                            const std::string& needle) {
  if (haystack.find(needle) == std::string::npos) {
    std::fprintf(stderr, "FAIL %s:\n  want substring: %s\n  in: %s\n", name,
                 needle.c_str(), haystack.c_str());
    ++g_fail;
  }
}

static void expect_absent(const char* name, const std::string& haystack,
                          const std::string& needle) {
  if (haystack.find(needle) != std::string::npos) {
    std::fprintf(stderr, "FAIL %s:\n  unwanted substring: %s\n  in: %s\n", name,
                 needle.c_str(), haystack.c_str());
    ++g_fail;
  }
}

static LookupResult make(const std::string& matched,
                         const std::string& deinflected,
                         std::vector<TransformGroup> trace) {
  LookupResult r;
  r.matched = matched;
  r.deinflected = deinflected;
  r.trace = std::move(trace);
  r.preprocessor_steps = 0;
  r.term.expression = "\xe5\xbd\x93\xe3\x81\x9f\xe3\x82\x8b";  // 当たる
  r.term.reading = "\xe3\x81\x82\xe3\x81\x9f\xe3\x82\x8b";     // あたる
  r.term.rules = "";
  GlossaryEntry g;
  g.dict_name = "JMdict";
  g.glossary = "[\"to hit\"]";
  g.definition_tags = "";
  g.term_tags = "";
  r.term.glossaries.push_back(g);
  return r;
}

int main() {
  // 引擎压栈顺序 = 剥离顺序：当たっていた 先剥最外层的 -た，再剥 -いる，最后 -て。
  const std::vector<TransformGroup> trace = {
      {"-\xe3\x81\x9f", "Indicates the past."},                 // -た
      {"-\xe3\x81\x84\xe3\x82\x8b", "Indicates continuation."},  // -いる
      {"-\xe3\x81\xa6", "\xe3\x81\xa6-form."},                   // -て
  };
  const std::string atteita =
      "\xe5\xbd\x93\xe3\x81\x9f\xe3\x81\xa3\xe3\x81\xa6\xe3\x81\x84\xe3\x81\x9f";  // 当たっていた
  const std::string ataru = "\xe5\xbd\x93\xe3\x81\x9f\xe3\x82\x8b";                // 当たる

  // ① 有 trace：整体反转成接续顺序（-て « -いる « -た），语法说明逐条带上。
  //    这一串必须与 Dart 侧 buildPopupJsonFromLookup 的输出逐字节相同。
  {
    std::vector<LookupResult> results = {make(atteita, ataru, trace)};
    const std::string json = build_popup_json(results, 100);
    expect_contains(
        "trace-reversed-with-descriptions", json,
        "\"deinflectionTrace\":["
        "{\"name\":\"-\xe3\x81\xa6\",\"description\":\"\xe3\x81\xa6-form.\"},"
        "{\"name\":\"-\xe3\x81\x84\xe3\x82\x8b\",\"description\":\"Indicates continuation.\"},"
        "{\"name\":\"-\xe3\x81\x9f\",\"description\":\"Indicates the past.\"}]");
    // 有真实变形链时不该再退回那条没有语法说明的合并标签。
    expect_absent("no-synthetic-step-when-trace-present", json,
                  "\xe2\x86\x92");  // →
  }

  // ② 无 trace 但 matched != deinflected：文本变体归一（colour→color 一类），
  //    不经过任何变形规则，故只回落成一条、且没有语法说明。这条分支不能删。
  {
    std::vector<LookupResult> results = {make("colour", "color", {})};
    const std::string json = build_popup_json(results, 100);
    expect_contains("variant-fallback", json,
                    "\"deinflectionTrace\":[{\"name\":\"colour \xe2\x86\x92 "
                    "color\",\"description\":\"\"}]");
  }

  // ③ 原形直查（matched == deinflected）→ 空数组，不生成自指标签。
  {
    std::vector<LookupResult> results = {make(ataru, ataru, {})};
    const std::string json = build_popup_json(results, 100);
    expect_contains("no-self-step", json, "\"deinflectionTrace\":[]");
  }

  // ④ 引擎未回填 deinflected（空串）→ 同样空数组，不生成「x → 」残缺标签。
  {
    std::vector<LookupResult> results = {make(atteita, "", {})};
    const std::string json = build_popup_json(results, 100);
    expect_contains("no-partial-step", json, "\"deinflectionTrace\":[]");
  }

  // ⑤ 单层 trace：反转是恒等，但语法说明照样要带上。
  {
    std::vector<LookupResult> results = {
        make(atteita, ataru, {{"-\xe3\x81\xa6", "\xe3\x81\xa6-form."}})};
    const std::string json = build_popup_json(results, 100);
    expect_contains("single-step", json,
                    "\"deinflectionTrace\":[{\"name\":\"-\xe3\x81\xa6\","
                    "\"description\":\"\xe3\x81\xa6-form.\"}]");
  }

  if (g_fail != 0) {
    std::fprintf(stderr, "popup_json_deinflection_test: %d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("popup_json_deinflection_test: PASS\n");
  return 0;
}

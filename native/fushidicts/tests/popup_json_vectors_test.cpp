// 弹窗 JSON 迁移回归：原生 build_popup_json(results, PopupJsonOptions) 必须与被删掉的
// Dart `buildPopupJsonFromLookup`（packages/fushi_dictionary/lib/src/language/language.dart）
// **逐字节**一致。
//
// popup_json_vectors.inc 是删 Dart 版之前，用旧实现对 161 组固定输入（伪随机，种子固定）
// 生成的「输入 → 输出」向量：覆盖词头预算（BUG-1472）、隐藏词典、词典顺序（含重复项与
// 未知词典，BUG-2579）、空读音并卡（BUG-2753 / BUG-791）、频率 / 音调去重、变形链与
// 回落标签、变形说明译文（BUG-2038）、释义原样 JSON 与字符串转义（控制字符、引号、
// 反斜杠、增补平面字）。向量文件不可手改——它记录的是旧实现的行为。
//
// Usage: popup_json_vectors_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "fushidicts/popup_json.hpp"

namespace {

struct VTrace {
  const char* name;
  const char* description;
};
struct VGloss {
  const char* dict;
  const char* glossary;
  const char* definition_tags;
  const char* term_tags;
};
struct VFreqValue {
  int value;
  const char* display;
};
struct VFreq {
  const char* dict;
  std::vector<VFreqValue> values;
};
struct VPitch {
  const char* dict;
  std::vector<int> positions;
  std::vector<std::string> patterns;
  std::vector<std::string> transcriptions;
};
struct VResult {
  const char* matched;
  const char* deinflected;
  int steps;
  std::vector<VTrace> trace;
  const char* expression;
  const char* reading;
  std::vector<VGloss> glossaries;
  std::vector<VFreq> frequencies;
  std::vector<VPitch> pitches;
};
struct VCase {
  const char* name;
  int max_terms;
  std::vector<std::string> hidden;
  std::vector<std::string> order;
  std::vector<std::pair<std::string, std::string>> translations;
  std::vector<VResult> results;
  const char* expected;
};

const std::vector<VCase>& cases() {
  static const std::vector<VCase> kCases = {
#include "popup_json_vectors.inc"
  };
  return kCases;
}

LookupResult to_lookup(const VResult& v) {
  LookupResult r;
  r.matched = v.matched;
  r.deinflected = v.deinflected;
  r.preprocessor_steps = v.steps;
  for (const VTrace& t : v.trace) r.trace.push_back(TransformGroup{.name = t.name, .description = t.description});
  r.term.expression = v.expression;
  r.term.reading = v.reading;
  for (const VGloss& g : v.glossaries) {
    GlossaryEntry e;
    e.dict_name = g.dict;
    e.glossary = g.glossary;
    e.definition_tags = g.definition_tags;
    e.term_tags = g.term_tags;
    r.term.glossaries.push_back(std::move(e));
  }
  for (const VFreq& f : v.frequencies) {
    FrequencyEntry e;
    e.dict_name = f.dict;
    for (const VFreqValue& value : f.values) e.frequencies.push_back(Frequency{value.value, value.display});
    r.term.frequencies.push_back(std::move(e));
  }
  for (const VPitch& p : v.pitches) {
    PitchEntry e;
    e.dict_name = p.dict;
    // FFI 把数字位与 pattern 位拆成两个平行数组（Dart 侧看到的就是这个形状）；拼回
    // native Pitch 时先数字后 pattern，输出与去重键都按两段分别写，顺序等价。
    for (int position : p.positions) e.pitches.push_back(Pitch{.position = position});
    for (const std::string& pattern : p.patterns) e.pitches.push_back(Pitch{.pattern = pattern});
    e.transcriptions = p.transcriptions;
    r.term.pitches.push_back(std::move(e));
  }
  return r;
}

}  // namespace

int main() {
  int failures = 0;
  for (const VCase& c : cases()) {
    std::vector<LookupResult> results;
    for (const VResult& v : c.results) results.push_back(to_lookup(v));
    PopupTranslations translations(c.translations.begin(), c.translations.end());
    PopupJsonOptions options;
    options.max_terms = c.max_terms;
    options.hidden.insert(c.hidden.begin(), c.hidden.end());
    options.dictionary_order = c.order;
    options.translations = &translations;
    const std::string got = build_popup_json(results, options);
    if (got != c.expected) {
      std::fprintf(stderr, "FAIL %s\n  want: %s\n  got:  %s\n", c.name, c.expected, got.c_str());
      ++failures;
    }
  }
  std::printf("%zu popup vectors, %d failed\n", cases().size(), failures);
  // 向量文件被截空 / 换掉也得红，不能「0 条全过」。
  if (cases().size() < 100) {
    std::fprintf(stderr, "FAIL: expected the 162 generated vectors, found %zu\n", cases().size());
    return 1;
  }
  return failures == 0 ? 0 : 1;
}

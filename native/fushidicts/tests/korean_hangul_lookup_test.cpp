// 韩语词形还原：拆字预处理 + 合字后处理（BUG-2148）。
//
// assets/transforms/ko.json 导自 Yomitan 的 korean-transforms.js，**整表用 Hangul
// 兼容字母书写**——`부드러운 → 부드럽다` 那条 ㅂ 不规则是
// {"fromSuffix":"ㅇㅜㄴ","toSuffix":"ㅂㄷㅏ"}。而 Deinflector 是字节级精确查表，
// 预合成音节串 "부드러운" 里永远没有 "ㅇㅜㄴ" 那三个码点，于是韩语 450 条 transform
// 一条都点不着火：查 부드러운 只能一路降级到词典里唯一存在的 "부"，字幕上只亮一个
// 音节。上游靠 disassembleHangul（预处理）+ reassembleHangul（后处理）把两边编码
// 对齐，本引擎此前两半都没有——连「后处理」这个阶段都不存在。
//
// 本测试钉三件事：
//   1) 拆字/合字互为逆变换（含复合元音 ㅘㅚㅝㅟㅢ 与复合终声 ㄺㅄ 的拆到底/拼回来），
//      且对非谚文文本恒等；
//   2) 「终声还是下一个音节的初声」这条唯一判据（后面跟元音 = 不收）；
//   3) 端到端：用**真的 ko.json 规则形状**，查 부드러운 命中词典里的 부드럽다，
//      且 matched 回报的是**原始预合成串**（字幕高亮长度直接吃它）。
//
// Red/green：把 get_korean_processors 从 process() 的处理器链里摘掉，或把
// lookup.cpp 里的 reassemble 那一路去掉，第 3 组立刻红。
//
// Usage: korean_hangul_lookup_test  (no args) -> exit 0 PASS, non-zero FAIL.
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

std::string dis(const std::string& s) {
  return utf8::utf32to8(text_processor::disassemble_hangul(utf8::utf8to32(s)));
}

std::string rea(const std::string& s) {
  return utf8::utf32to8(text_processor::reassemble_hangul(utf8::utf8to32(s)));
}

void expect_eq(const std::string& got, const std::string& want, const char* what) {
  if (got != want) {
    fail(std::string(what) + ": got \"" + got + "\" want \"" + want + "\"");
  }
}

void expect_round_trip(const std::string& word) {
  const std::string back = rea(dis(word));
  if (back != word) {
    fail("round-trip broke \"" + word + "\": disassemble -> \"" + dis(word) + "\" -> \"" + back + "\"");
  }
}

// ko.json 的真实规则形状（只截出本用例需要的那几条，逐字对齐真表的写法：
// fromSuffix/toSuffix 全用兼容字母）。
const std::string kKoreanTransforms =
    "{\"language\":\"ko\",\"conditions\":{"
    "\"v\":{\"name\":\"verb\",\"isDictionaryForm\":true,\"subConditions\":[]},"
    "\"adj\":{\"name\":\"adjective\",\"isDictionaryForm\":true,\"subConditions\":[]}"
    "},\"transforms\":{"
    "\"-(\xEC\x9C\xBC)\xE3\x84\xB4\":{\"name\":\"-(\xEC\x9C\xBC)\xE3\x84\xB4\",\"description\":\"\","
    "\"rules\":["
    // {"type":"suffix","fromSuffix":"ㅇㅜㄴ","toSuffix":"ㅂㄷㅏ",...} —— ㅂ 不规则
    "{\"type\":\"suffix\",\"fromSuffix\":\"\xE3\x85\x87\xE3\x85\x9C\xE3\x84\xB4\","
    "\"toSuffix\":\"\xE3\x85\x82\xE3\x84\xB7\xE3\x85\x8F\",\"conditionsIn\":[],"
    "\"conditionsOut\":[\"v\",\"adj\"]},"
    // {"type":"suffix","fromSuffix":"ㄴ","toSuffix":"ㄷㅏ",...}
    "{\"type\":\"suffix\",\"fromSuffix\":\"\xE3\x84\xB4\","
    "\"toSuffix\":\"\xE3\x84\xB7\xE3\x85\x8F\",\"conditionsIn\":[],"
    "\"conditionsOut\":[\"v\",\"adj\"]}"
    "]}}}";

}  // namespace

int main() {
  // ── 1. 拆字 / 合字互逆 ──────────────────────────────────────────────
  // 覆盖：无终声、单终声、复合终声（ㄺ ㅄ）、复合元音（ㅘ ㅚ ㅝ ㅟ ㅢ）、
  // 谚文与拉丁/汉字混排、空串。
  for (const char* w : {
           "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xAC\xEC\x9A\xB4",              // 부드러운
           "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xBD\xEB\x8B\xA4",              // 부드럽다
           "\xEA\xB3\xB1\xEC\x8A\xAC\xEA\xB1\xB0\xEB\xA6\xAC\xEB\x8A\x94",  // 곱슬거리는
           "\xEA\xB0\x88\xEC\x83\x89",                                      // 갈색
           "\xEC\x9D\xBD\xEB\x8B\xA4",                                      // 읽다 (복합 종성 ㄺ)
           "\xEA\xB0\x92",                                                  // 값  (복합 종성 ㅄ)
           "\xEA\xB4\x9C\xEC\xB0\xAE\xEC\x95\x84\xEC\x9A\x94",              // 괜찮아요 (ㅙ)
           "\xEC\x9D\x98\xEC\x82\xAC",                                      // 의사 (ㅢ)
           "\xEC\x99\x94\xEB\x8B\xA4",                                      // 왔다 (ㅘ)
           "\xEC\x89\xAC\xEC\x9B\xA0\xEC\x96\xB4",                          // 쉬웠어 (ㅟ ㅝ)
           "\xED\x95\x98\xEA\xB3\xA0",                                      // 하고
           "abc",
           "\xE9\xA3\x9F\xE3\x81\xB9\xE3\x82\x8B",  // 食べる：非谚文必须原样透传
           "",
       }) {
    expect_round_trip(w);
  }
  // 非谚文文本拆字后必须一字不变（否则日/英查询会白白多出变体）。
  expect_eq(dis("\xE9\xA3\x9F\xE3\x81\xB9\xE3\x82\x8B"), "\xE9\xA3\x9F\xE3\x81\xB9\xE3\x82\x8B",
            "disassemble must be identity on non-Hangul");
  expect_eq(rea("abc123"), "abc123", "reassemble must be identity on ASCII");

  // 拆到**简单字母**，不是按音节三分：ko.json 的字符表里复合元音/复合终声一个都
  // 没有，表就是按拆到底写的。읽 = ㅇ + ㅣ + ㄹ + ㄱ（ㄺ 拆开）。
  expect_eq(dis("\xEC\x9D\xBD"), "\xE3\x85\x87\xE3\x85\xA3\xE3\x84\xB9\xE3\x84\xB1",
            "읽 must disassemble to ㅇㅣㄹㄱ (complex final split)");
  // 왔 = ㅇ + ㅗ + ㅏ + ㅆ（ㅘ 拆开）。
  expect_eq(dis("\xEC\x99\x94"), "\xE3\x85\x87\xE3\x85\x97\xE3\x85\x8F\xE3\x85\x86",
            "왔 must disassemble to ㅇㅗㅏㅆ (complex vowel split)");

  // ── 2. 「终声 vs 下一个音节的初声」唯一判据 ─────────────────────────
  // ㅂㅜㄷㅡㄹㅓㅂㄷㅏ：第二个 ㅂ 后面是 ㄷ（非元音）-> 收作 러 的终声 -> 럽。
  expect_eq(rea("\xE3\x85\x82\xE3\x85\x9C\xE3\x84\xB7\xE3\x85\xA1\xE3\x84\xB9\xE3\x85\x93"
                "\xE3\x85\x82\xE3\x84\xB7\xE3\x85\x8F"),
            "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xBD\xEB\x8B\xA4",  // 부드럽다
            "a consonant NOT followed by a vowel is a trailing jamo");
  // ㅎㅏㄱㅗ：ㄱ 后面是 ㅗ（元音）-> 不收，另起音节 -> 하고。
  expect_eq(rea("\xE3\x85\x8E\xE3\x85\x8F\xE3\x84\xB1\xE3\x85\x97"),
            "\xED\x95\x98\xEA\xB3\xA0",  // 하고
            "a consonant followed by a vowel starts the next syllable");
  // 拼不成音节的散字母原样透传（`ㄱ` 是韩语里正经会出现的字母名）。
  expect_eq(rea("\xE3\x84\xB1"), "\xE3\x84\xB1", "a lone leading jamo must pass through");

  // ── 3. 端到端：부드러운 -> 부드럽다 ────────────────────────────────
  const std::string kBudeureopda = "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xBD\xEB\x8B\xA4";  // 부드럽다
  const std::string kBudeureoun = "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xAC\xEC\x9A\xB4";   // 부드러운
  const std::string kBu = "\xEB\xB6\x80";                                               // 부

  const std::string out_dir = fushi_test::temp_dir() + "/fushi_korean_hangul_out";
  // 词典里同时放 부드럽다 和 부（后者正是用户实际看到的那个「只划一个音节」的结果），
  // 这样测试才能证明修复后拿到的是**更长**的匹配，而不是词典里根本没有短词。
  std::vector<SimpleEntry> entries = {{kBudeureopda, "soft; smooth"}, {kBu, "division; department"}};
  ImportResult r = dictionary_importer::write_simple_dict("KoDict", entries, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front());
    std::fprintf(stderr, "korean_hangul_lookup_test: %s\n", g_fail ? "FAILED" : "PASSED");
    return g_fail ? 1 : 0;
  }

  DictionaryQuery q;
  q.add_term_dict(out_dir + "/" + r.title);
  Deinflector d;
  d.load_transforms_json(kKoreanTransforms);
  Lookup lookup(q, d);

  // 用户的真实句子片段：点在 부 上，扫描窗口从这里向后。
  const std::string sentence = kBudeureoun + " \xEA\xB0\x88\xEC\x83\x89";  // "부드러운 갈색"
  auto results = lookup.lookup(sentence);

  bool found_lemma = false;
  size_t best_matched_codepoints = 0;
  for (const auto& res : results) {
    const size_t len = utf8::distance(res.matched.begin(), res.matched.end());
    if (len > best_matched_codepoints) best_matched_codepoints = len;
    if (res.term.expression == kBudeureopda) {
      found_lemma = true;
      // matched 必须是**原始预合成串**——字幕高亮长度直接吃它，若这里回报的是
      // 拆字后的字母串，高亮会算成 8 个音节而不是 4 个。
      expect_eq(res.matched, kBudeureoun, "matched must be the original precomposed prefix");
    }
  }
  if (!found_lemma) {
    fail("looking up 부드러운 did not surface the 부드럽다 entry (deinflection never fired)");
  }
  if (best_matched_codepoints < 4) {
    fail("longest matched form is " + std::to_string(best_matched_codepoints) +
         " codepoints; the whole point is that it is no longer 1 (부)");
  }

  std::fprintf(stderr, "korean_hangul_lookup_test: %s\n", g_fail ? "FAILED" : "PASSED");
  return g_fail ? 1 : 0;
}

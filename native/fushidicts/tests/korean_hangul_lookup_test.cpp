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
  // 独立复合字母没有初声打头，重组是透传 —— 合字在完整音节上是拆字的逆，但不是它
  // 在任意输入上的逆。这不丢结果（未拆字的原形变体照样精确命中 ㅘ 条目），但要钉住
  // 它**不会**被错拼成别的音节。
  expect_eq(rea("\xE3\x85\x97\xE3\x85\x8F"), "\xE3\x85\x97\xE3\x85\x8F",
            "ㅗㅏ with no leading consonant must pass through, not compose");

  // 混合串：ko.json 有 116 条 rule 的 toSuffix 直接写预合成音节，还原输出本就是
  // 「字母前缀 + 预合成后缀」的混合形态，重组必须只动字母那半边。
  // ㅈㅐㅁㅣ + 없다 -> 재미없다
  expect_eq(rea("\xE3\x85\x88\xE3\x85\x90\xE3\x85\x81\xE3\x85\xA3\xEC\x97\x86\xEB\x8B\xA4"),
            "\xEC\x9E\xAC\xEB\xAF\xB8\xEC\x97\x86\xEB\x8B\xA4",
            "a jamo prefix + precomposed suffix must reassemble only the jamo half");

  // ── 2b. UTF-8 包装层的字节级前置判据 ─────────────────────────────
  // 生产链路（lookup.cpp）走的是这个版本，不是上面的 u32 版；判据写错会让韩语
  // 整条静默失效（当成「没有兼容字母」原样返回）。两个方向都要钉。
  expect_eq(text_processor::reassemble_hangul_utf8(
                "\xE3\x85\x82\xE3\x85\x9C\xE3\x84\xB7\xE3\x85\xA1\xE3\x84\xB9\xE3\x85\x93"
                "\xE3\x85\x82\xE3\x84\xB7\xE3\x85\x8F"),
            "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xBD\xEB\x8B\xA4",
            "the utf8 wrapper must actually convert when compat jamo are present");
  // 判据边界：U+3130 = E3 84 B0，U+318F = E3 86 8F —— 两端都必须被认出来。
  expect_eq(text_processor::reassemble_hangul_utf8("\xE3\x84\xB1\xE3\x85\x8F"),
            "\xEA\xB0\x80",  // ㄱㅏ -> 가
            "the byte prefilter must catch the low end of the compat jamo block");
  // 不含兼容字母时原样返回（非韩语查询的零成本路径）。
  for (const char* s : {"food", "\xE9\xA3\x9F\xE3\x81\xB9\xE3\x82\x8B",
                        "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xAC\xEC\x9A\xB4", ""}) {
    expect_eq(text_processor::reassemble_hangul_utf8(s), s,
              "the utf8 wrapper must be identity when there are no compat jamo");
  }

  // ── 2c. 拆字必须真的挂进 process() 链，且必须在 nfkc **之后** ────────────
  //
  // 上面所有往返断言都直接调导出函数、**绕过 process() 链**，所以哪怕
  // get_korean_processors 根本没被注册，它们照样全绿。这里断言链的产物。
  const std::string precomposed = "\xEB\xB6\x80\xEB\x93\x9C\xEB\x9F\xAC\xEC\x9A\xB4";  // 부드러운
  const std::string disassembled = dis(precomposed);
  {
    bool saw_disassembled = false;
    bool saw_original = false;
    for (const auto& v : text_processor::process(precomposed)) {
      if (v.text == disassembled) saw_disassembled = true;
      if (v.text == precomposed) saw_original = true;
    }
    if (!saw_disassembled) {
      fail("process() produced no disassembled variant for 부드러운 — the korean processor "
           "is not registered in the chain");
    }
    if (!saw_original) {
      fail("process() dropped the original precomposed variant (exact hits need it)");
    }
  }

  // 链**序**不变式，靠 NFD 韩语才钉得住。
  //
  // 每个处理器都带 option 0（恒等），变体扇出保留所有组合，所以对**预合成**输入
  // 顺序其实无所谓——nfkc 不会「撤销」拆字，拆字形经 nfkc 的 option 0 照样活着。
  // 真正依赖顺序的是 **NFD 形式的韩语**（U+1100 组合字母块，macOS 文件名与部分
  // 字幕里常见）：disassemble_hangul 的早退范围只认 U+AC00..D7A3 与 U+3130..318F，
  // 认不出 U+1100 块，必须靠链首的 nfkc 先归一成预合成音节，韩语处理器在链尾接住。
  // 把 get_korean_processors 前移到 nfkc 之前，NFD 输入就再也产不出拆字形。
  {
    // NFD("부드러운") = 부 드 러 운（U+1107 U+116E U+1103 U+1173
    //                                 U+1105 U+1165 U+110B U+116E U+11AB）
    const std::string nfd =
        "\xE1\x84\x87\xE1\x85\xAE\xE1\x84\x83\xE1\x85\xB3"
        "\xE1\x84\x85\xE1\x85\xA5\xE1\x84\x8B\xE1\x85\xAE\xE1\x86\xAB";
    bool saw_disassembled = false;
    for (const auto& v : text_processor::process(nfd)) {
      if (v.text == disassembled) saw_disassembled = true;
    }
    if (!saw_disassembled) {
      fail("NFD Korean produced no disassembled variant — the korean processor must run "
           "AFTER nfkc, which is what turns U+1100-block jamo into precomposed syllables");
    }
  }

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

  // 不需要任何变形的韩语词，preprocessor_steps 必须是 0。
  // process() 的变体是 std::map、按码点序迭代，拆字形（首字 ㅂ U+3142）排在原形
  // （부 U+BD80）之前，所以 steps=1 的那份**先**落进 result_map；原形随后长度相等，
  // 若覆盖条件只看「严格更长」就进不来，整批韩语结果的 steps 被无谓抬成 1。
  // 它是排序的第 3 档键并经 FFI 出到 Dart，与其它语言混排时会把韩语精确命中往后压。
  {
    auto exact = lookup.lookup(kBu);
    bool checked = false;
    for (const auto& res : exact) {
      if (res.term.expression == kBu) {
        checked = true;
        if (res.preprocessor_steps != 0) {
          fail("an exact Korean hit reports preprocessor_steps=" +
               std::to_string(res.preprocessor_steps) + "; the disassembled variant won the tie");
        }
      }
    }
    if (!checked) fail("looking up 부 did not surface the 부 entry at all");
  }

  std::fprintf(stderr, "korean_hangul_lookup_test: %s\n", g_fail ? "FAILED" : "PASSED");
  return g_fail ? 1 : 0;
}

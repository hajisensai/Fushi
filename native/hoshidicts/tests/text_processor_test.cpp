// 通用文本归一化守卫（补全 Yomitan 多语言查词召回）：
//   P1 Unicode 范围小写（ASCII/Latin-1/希腊/西里尔）
//   P2 组合记号 / 阿拉伯 harakat / 希伯来点 删除
//   P3 预合成拉丁变音字母 -> 基字母
// text_processor::process() 必须在变体集合中产出归一化形（option-1 变体）。
//
// Usage: text_processor_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <vector>

#include "text_processor.hpp"

static bool has_variant(const std::vector<TextVariant>& vs, const char* utf8) {
  for (const auto& v : vs) {
    if (v.text == utf8) return true;
  }
  return false;
}

static int g_fail = 0;
static void expect(const char* name, const std::string& src, const char* want) {
  std::vector<TextVariant> vs = text_processor::process(src);
  if (!has_variant(vs, want)) {
    std::fprintf(stderr, "FAIL %s: no variant '%s' for src '%s' (got %zu variants)\n", name, want,
                 src.c_str(), vs.size());
    ++g_fail;
  }
}

int main() {
  // P2: 阿拉伯 harakat 去除  كَتَبَ -> كتب
  expect("ar-harakat", "\xD9\x83\xD9\x8E\xD8\xAA\xD9\x8E\xD8\xA8\xD9\x8E", "\xD9\x83\xD8\xAA\xD8\xA8");
  // P1: Latin-1 大写小写  Ü -> ü
  expect("latin1-lower", "\xC3\x9C", "\xC3\xBC");
  // P1: 希腊大写小写  Λ -> λ
  expect("greek-lower", "\xCE\x9B", "\xCE\xBB");
  // P1: 西里尔大写小写  Д -> д
  expect("cyrillic-lower", "\xD0\x94", "\xD0\xB4");
  // P3: 预合成去变音  café -> cafe
  expect("latin-strip", "caf\xC3\xA9", "cafe");
  // 回归：纯 ASCII 大写仍小写  Gehen -> gehen
  expect("ascii-lower", "Gehen", "gehen");
  // P2 Latin 分解记号路径（0x0300–036F）：e + U+0301 组合锐音 -> e   cafe
  expect("latin-combining", "caf\x65\xCC\x81", "cafe");
  // P2 希伯来点（0x0591–05BD）：ב + sheva(U+05B0) -> ב
  expect("hebrew-point", "\xD7\x91\xD6\xB0", "\xD7\x91");
  // 身份不变：纯日语原文必须始终作为变体存在（option-0 恒等，不被处理器破坏）
  expect("ja-identity", "\xE6\x97\xA5\xE6\x9C\xAC", "\xE6\x97\xA5\xE6\x9C\xAC");

  // NFKC：全角拉丁 Ａ(U+FF21) 折半角 -> A。验 utf8proc 接进链路（非恒真）。
  expect("nfkc-fullwidth-A", "\xEF\xBC\xA1", "A");
  // 顺序关键：全角大写 Ａ 先经 NFKC 折成 A，再被 to_lowercase 小写成 a。
  // 若 NFKC 排在 to_lowercase 之后，则永远产不出 'a' 这个变体。
  expect("nfkc-then-lower", "\xEF\xBC\xA1", "a");
  // NFKC 串：ＡＢＣ(全角) -> abc（折半角 + 小写组合变体）。
  expect("nfkc-fullwidth-abc", "\xEF\xBC\xA1\xEF\xBC\xA2\xEF\xBC\xA3", "abc");
  // alphanumeric_to_fullwidth：半角 abc -> 全角 ａｂｃ(U+FF41..43)。
  expect("ascii-to-fullwidth", "abc", "\xEF\xBD\x81\xEF\xBD\x82\xEF\xBD\x83");

  // standardize_kanji（上游 e7dfdea，异体字 -> 親字，来源 kanji-processor MIT）。
  // 方向（README "Convert 異体字 to 親字"）：itaiji 變體 -> oyaji 親字。非恒真。
  // 國(U+570B itaiji) -> 国(U+56FD oyaji)。
  expect("kanji-kuni-itaiji", "\xE5\x9C\x8B", "\xE5\x9B\xBD");
  // 學(U+5B78 itaiji) -> 学(U+5B66 oyaji)。
  expect("kanji-gaku-itaiji", "\xE5\xAD\xB8", "\xE5\xAD\xA6");
  // 體(U+9AD4 itaiji) -> 体(U+4F53 oyaji)。
  expect("kanji-tai-itaiji", "\xE9\xAB\x94", "\xE4\xBD\x93");

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}

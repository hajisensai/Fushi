// 查词扫描的词边界守卫（对齐 Yomitan 的 searchResolution='word'）：
//   空格分词语言（阿拉伯/拉丁/西里尔…）的游标扫描不得在单词中间切断，
//   否则会把 "أمنيات" 砍成词头 "أم"(=母亲) 返回完全无关的结果（BUG）。
//   CJK（无空格）必须保持逐码点扫描（searchResolution='letter'），日语零变化。
//
// scan_candidates(text, scan_length) 返回「从开头锚定、由长到短」的候选前缀串，
// 跳过落在两个空格分词类字母之间的切点，并丢弃以空白结尾的冗余前缀。
//
// Usage: word_scan_test   (无参，纯内存断言)  Exit 0=PASS, 非零=FAIL
#include <cstdio>
#include <string>
#include <vector>

#include "word_scan.hpp"

static int g_fail = 0;

static std::string join(const std::vector<std::string>& v) {
  std::string out = "[";
  for (size_t i = 0; i < v.size(); ++i) {
    if (i) out += ", ";
    out += '"';
    out += v[i];
    out += '"';
  }
  out += "]";
  return out;
}

static void expect_eq(const char* name, const std::vector<std::string>& got,
                      const std::vector<std::string>& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s:\n  got  %s\n  want %s\n", name, join(got).c_str(),
                 join(want).c_str());
    ++g_fail;
  }
}

static bool contains(const std::vector<std::string>& v, const std::string& s) {
  for (const auto& e : v) {
    if (e == s) return true;
  }
  return false;
}

int main() {
  // 阿拉伯短语 "أمنيات العيد"（开斋节的祝愿）：
  //   只能产出 整串 与 第一个完整词 "أمنيات"，绝不能产出词中片段 "أم"。
  const std::string ar_full =
      "\xD8\xA3\xD9\x85\xD9\x86\xD9\x8A\xD8\xA7\xD8\xAA \xD8\xA7\xD9\x84\xD8\xB9\xD9\x8A\xD8\xAF";
  const std::string ar_word1 = "\xD8\xA3\xD9\x85\xD9\x86\xD9\x8A\xD8\xA7\xD8\xAA";  // "أمنيات"
  const std::string ar_frag = "\xD8\xA3\xD9\x85";                                    // "أم"
  expect_eq("ar-phrase", scan_candidates(ar_full, 16), {ar_full, ar_word1});
  if (contains(scan_candidates(ar_full, 16), ar_frag)) {
    std::fprintf(stderr, "FAIL ar-no-midword-fragment: scan produced mid-word fragment\n");
    ++g_fail;
  }

  // 阿拉伯单词单独扫描：只它自己（无更短词头碎片）。
  expect_eq("ar-single-word", scan_candidates(ar_word1, 16), {ar_word1});

  // 拉丁多词 "running fast"：整串 + 第一个完整词，不出现 "runnin"/"run" 之类的词中片段。
  expect_eq("latin-phrase", scan_candidates("running fast", 16), {"running fast", "running"});

  // 日语（无空格）必须逐码点扫描，行为与旧实现一致。
  const std::string jp_full = "\xE6\xAF\x8D\xE8\xA6\xAA";  // "母親"
  const std::string jp_one = "\xE6\xAF\x8D";              // "母"
  expect_eq("ja-letter-resolution", scan_candidates(jp_full, 16), {jp_full, jp_one});

  // 混合：日文 + 拉丁词 "猫dog" —— 拉丁段按整词(不在 dog 中间切)，CJK↔拉丁边界合法。
  //   合法切点：末尾(整串 "猫dog")、'猫'与'd'之间(CJK↔拉丁)→ "猫"。
  const std::string cat = "\xE7\x8C\xAB";  // "猫"
  expect_eq("mixed-cjk-latin", scan_candidates(cat + "dog", 16), {cat + "dog", cat});

  // scan_length 截断：长串只取前 N 个码点窗口（日语逐字）。
  expect_eq("scan-length-window", scan_candidates(jp_full, 1), {jp_one});

  // 空串与全空白：无候选。
  expect_eq("empty", scan_candidates("", 16), {});
  expect_eq("spaces-only", scan_candidates("   ", 16), {});

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}

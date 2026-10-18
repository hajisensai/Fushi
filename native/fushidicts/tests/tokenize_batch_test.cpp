// 批量分词（tokenize.hpp）必须与被删掉的 Dart 逐位置循环逐位一致。
//
// 旧实现（packages/fushi_dictionary/lib/src/language/implementations/japanese_language.dart
// 的 textToWords，删于本次改动）在这里被原样转写成 [reference_tokenize]：按 UTF-16 码元
// 走位置，每个位置把**整段余文**（孤立代理按 Dart UTF-8 编码器换成 U+FFFD）交给
// `lookup(max_results = 1)`，命中切 matched 的 UTF-16 长度、未命中切一个码元。读音口径
// 同浏览器扩展旧的 readingResolver：对每段再 `lookup(段, 1)` 取首条读音。
//
// 新实现只拷 scan_length + 1 个码点的窗口、跳过释义解压、带匹配长度缓存——三者都必须
// 不改变任何一段的边界与读音。用例：真 ja.json + 两本 Yomitan 词典（含关西方言保护结构、
// 增补平面字词头、半角片假名、拉丁长词跨扫描窗口），外加 600 段确定性伪随机文本。
//
// Usage: tokenize_batch_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <utf8.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "fushidicts/tokenize.hpp"
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

// Dart `utf8.encode`：配对代理 → 4 字节；孤立代理 → U+FFFD。
std::string dart_utf8(const std::u16string& s) {
  std::string out;
  for (size_t i = 0; i < s.size(); i++) {
    char32_t cp = s[i];
    if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
      cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
      i++;
    } else if (cp >= 0xD800 && cp <= 0xDFFF) {
      cp = 0xFFFD;
    }
    utf8::append(cp, std::back_inserter(out));
  }
  return out;
}

int32_t utf16_len(const std::string& s) {
  int32_t n = 0;
  for (auto it = s.begin(); it != s.end();) n += utf8::next(it, s.end()) >= 0x10000 ? 2 : 1;
  return n;
}

// 旧 Dart 实现的逐字转写（无缓存：缓存只是旧实现的加速层，见 tokenize.hpp）。
TokenizeOutput reference_tokenize(const Lookup& lk, const std::string& text, bool with_readings) {
  std::u16string u16 = utf8::utf8to16(text);
  TokenizeOutput out;
  size_t pos = 0;
  while (pos < u16.size()) {
    const auto results = lk.lookup(dart_utf8(u16.substr(pos)), 1, 16);
    const int32_t len = results.empty() ? 0 : utf16_len(results.front().matched);
    const size_t take = len > 0 ? static_cast<size_t>(len) : 1;
    out.lengths.push_back(static_cast<int32_t>(take));
    if (with_readings) {
      const auto r = lk.lookup(dart_utf8(u16.substr(pos, take)), 1, 16);
      out.readings.push_back(r.empty() ? std::string() : r.front().term.reading);
    }
    pos += take;
  }
  return out;
}

std::string describe(const TokenizeOutput& t) {
  std::string s;
  for (size_t i = 0; i < t.lengths.size(); i++) {
    s += std::to_string(t.lengths[i]);
    if (i < t.readings.size()) s += "(" + t.readings[i] + ")";
    s += " ";
  }
  return s;
}

void expect_same(const Lookup& lk, MatchLengthCache& cache, const std::string& text) {
  const TokenizeOutput want = reference_tokenize(lk, text, true);
  for (int round = 0; round < 2; round++) {  // 冷缓存 + 热缓存
    const TokenizeOutput got = tokenize(lk, text, 16, true, &cache);
    if (got.lengths != want.lengths || got.readings != want.readings) {
      fail("tokenize(\"" + text + "\") round " + std::to_string(round) + "\n  want " + describe(want) +
           "\n  got  " + describe(got));
      return;
    }
    const TokenizeOutput plain = tokenize(lk, text, 16, false, nullptr);
    if (plain.lengths != want.lengths || !plain.readings.empty()) {
      fail("tokenize(\"" + text + "\") without readings/cache diverged: " + describe(plain));
      return;
    }
  }
  // 单点：每个码点起点上的 match_length_utf16 = 旧实现在该位置的匹配长度。
  std::u16string u16 = utf8::utf8to16(text);
  for (size_t pos = 0; pos < u16.size(); pos++) {
    if (u16[pos] >= 0xDC00 && u16[pos] <= 0xDFFF) continue;  // Dart 侧不会从代理后半起单点查
    const std::string rest = dart_utf8(u16.substr(pos));
    const auto results = lk.lookup(rest, 1, 16);
    const int32_t want_len = results.empty() ? 0 : utf16_len(results.front().matched);
    const int32_t got_len = match_length_utf16(lk, rest, 16, &cache);
    if (want_len != got_len) {
      fail("match_length(\"" + rest + "\") want " + std::to_string(want_len) + " got " + std::to_string(got_len));
    }
  }
}

std::string row(const std::string& expr, const std::string& reading, const std::string& rules,
                const std::string& text) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"" + rules + "\",0,[\"" + text + "\"],0,\"\"]";
}

std::string import_dict(const char* label, const std::string& title, const std::vector<std::string>& rows,
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
  ImportResult r = dictionary_importer::import(fushi_test::write_zip(label, files), out_dir);
  if (!r.success) {
    fail(std::string("import ") + label + " failed");
    return {};
  }
  return out_dir + "/" + r.title;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <ja.json>\n", argv[0]);
    return 2;
  }
  const std::string ja_json = read_file(argv[1]);
  if (ja_json.empty()) {
    fail("cannot read ja.json");
    return 1;
  }
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_tokenize_batch_out";
  std::filesystem::remove_all(out_dir);

  const std::string main_dict = import_dict(
      "tokenize_main", "TokenizeMain",
      {
          row("日本語", "にほんご", "", "Japanese"),
          row("日本", "にほん", "", "Japan"),
          row("難しい", "むずかしい", "adj-i", "difficult"),
          row("です", "", "", "copula"),
          row("は", "", "", "topic"),
          row("を", "", "", "object"),
          row("食べる", "たべる", "v1", "eat"),
          row("もらう", "", "v5", "receive"),
          row("買う", "かう", "v5", "buy"),
          row("為", "ため", "", "sake"),
          row("𠮷野家", "よしのや", "", "Yoshinoya"),
          row("😀", "", "", "grin"),
          row("メガネ", "めがね", "", "glasses"),
          row("時時", "ときどき", "", "sometimes"),
          row("abcdefghijklmnop", "", "", "sixteen letters"),
          row("hello", "", "", "hi"),
          row("world", "", "", "earth"),
          row("\xEF\xBF\xBD", "", "", "replacement char"),
      },
      out_dir);
  const std::string second_dict = import_dict("tokenize_second", "TokenizeSecond",
                                              {row("日本語", "にっぽんご", "", "Japanese (alt)"),
                                               row("食べ物", "たべもの", "", "food")},
                                              out_dir);
  if (g_fail) return 1;

  Deinflector d;
  d.load_transforms_json(ja_json);
  DictionaryQuery q;
  q.add_term_dict(main_dict);
  q.add_term_dict(second_dict);
  Lookup lk(q, d);
  MatchLengthCache cache(64);  // 小容量：顺带走淘汰路径

  const std::vector<std::string> fixed = {
      "",
      "日本語は難しいです。",
      "𠮷野家で😀を食べた",
      "𠮷𠮷😀😀x",
      "ﾒｶﾞﾈをかけた",
      "もらうためには何をすればいいのかしらと思った",
      "時々々",
      "abcdefghijklmnop",
      "abcdefghijklmnopq",
      "abcdefghijklmnop q",
      "xxabcdefghijklmnopqrstuvwxyz",
      "hello world, hello",
      "\xEF\xBF\xBD\xEF\xBF\xBD日本",
      "食べさせられたくなかった食べ物",
      "　全角\tタブ\n改行",
  };
  for (const std::string& text : fixed) expect_same(lk, cache, text);

  // 确定性伪随机：从词头碎片与单字里拼文本，覆盖词与词的任意邻接。
  const std::vector<std::string> alphabet = {
      "日本", "語", "は", "難し", "い", "です", "。", "𠮷", "野家", "😀", "ﾒ", "ｶﾞ", "ﾈ", "食べ", "た", "ら",
      "もらう", "ため", "に", "は", "時", "々", "a", "b", "abcdefghijklmnop", " ", "hello", "x", "、", "物",
  };
  std::mt19937 rng(20261018);
  for (int i = 0; i < 600; i++) {
    std::string text;
    const int parts = 1 + static_cast<int>(rng() % 24);
    for (int j = 0; j < parts; j++) text += alphabet[rng() % alphabet.size()];
    expect_same(lk, cache, text);
  }

  // 缓存：容量上限 + clear。
  if (cache.size() > 64) fail("cache exceeded capacity: " + std::to_string(cache.size()));
  cache.clear();
  if (cache.size() != 0) fail("cache.clear() left entries");

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("tokenize_batch_test: PASS (%zu fixed + 600 random texts)\n", fixed.size());
  return 0;
}

// 原文振假名参与查词排序（LookupOptions::ruby_readings）。
//
// 用户场景：EPUB 正文 `<ruby>忙<rt>せわ</rt></ruby>しい`，点「忙」，弹窗首条却是高频的
// 「いそがしい」。取词串只剩「忙しい」，同匹配长度候选按频率排。调用方现在把基字的码点
// 区间与 <rt> 读音带进来，比较器在「匹配长度」之后按读音一致度排。
//
// 本测试钉：
//   1) 无 ruby：比较器逐字不变（いそがしい 按频率居首）；
//   2) 有 ruby：せわしい 居首，冲突的 いそがしい 其后；更短的 忙 不被提到长匹配之前；
//   3) 截断之前生效：max_results=1 时留下的那一条就是 せわしい；
//   4) 片假名 ruby 与平假名读音等价；
//   5) Matcher 单元：去屈折（忙しく → 忙しい）按公共前缀比对、无 ruby 的汉字当通配、
//      从中间切开基字的匹配不判断、假名表记词头不臆断。
//
// Usage: ruby_reading_lookup_test (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "ruby_reading.hpp"
#include "zip_fixture.hpp"

namespace {

struct Failures {
  int count = 0;
  void expect(bool ok, std::string_view msg) {
    if (!ok) {
      std::fprintf(stderr, "FAIL: %.*s\n", static_cast<int>(msg.size()), msg.data());
      ++count;
    }
  }
};

std::string term(const char* expression, const char* reading, const char* gloss) {
  return std::string("[\"") + expression + "\",\"" + reading + "\",\"\",\"\",0,[\"" + gloss + "\"],0,\"\"]";
}

std::string freq(const char* expression, const char* reading, int value) {
  return std::string("[\"") + expression + "\",\"freq\",{\"reading\":\"" + reading +
         "\",\"frequency\":" + std::to_string(value) + "}]";
}

std::vector<std::string> readings(const std::vector<LookupResult>& rs) {
  std::vector<std::string> out;
  for (const auto& r : rs) out.push_back(r.term.expression + "/" + r.term.reading);
  return out;
}

std::string join(const std::vector<std::string>& v) {
  std::string out;
  for (const auto& s : v) out += (out.empty() ? "" : ", ") + s;
  return out;
}

std::vector<LookupResult> lookup_with(const Lookup& lookup, const std::string& text, int max_results,
                                      std::vector<RubyReading> ruby) {
  LookupOptions options;
  options.ruby_readings = std::move(ruby);
  return lookup.lookup(text, max_results, 16, options);
}

void check_end_to_end(Failures& f) {
  const std::string bank = "[" + term("忙しい", "いそがしい", "busy") + "," + term("忙しい", "せわしい", "restless") +
                           "," + term("忙", "ぼう", "busy (kanji)") + "]";
  const std::string meta = "[" + freq("忙しい", "いそがしい", 1488) + "," + freq("忙しい", "せわしい", 32666) + "," +
                           freq("忙", "ぼう", 50000) + "]";
  const std::string zip = fushi_test::write_zip(
      "ruby_reading", {{"index.json", "{\"title\":\"RubyDict\",\"format\":3,\"revision\":\"t\"}"},
                       {"term_bank_1.json", bank},
                       {"term_meta_bank_1.json", meta}});
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_ruby_reading_out";
  ImportResult r = dictionary_importer::import(zip, out_dir);
  f.expect(r.success, "fixture import failed");
  if (!r.success) return;
  DictionaryQuery q;
  q.add_term_dict(out_dir + "/" + r.title);
  q.add_freq_dict(out_dir + "/" + r.title);
  Deinflector d;
  Lookup lookup(q, d);

  const auto plain = readings(lookup_with(lookup, "忙しい。", 16, {}));
  f.expect(plain.size() == 3 && plain[0] == "忙しい/いそがしい" && plain[1] == "忙しい/せわしい" &&
               plain[2] == "忙/ぼう",
           "no ruby: comparator must be unchanged (frequency first): " + join(plain));

  const auto ruby = readings(lookup_with(lookup, "忙しい。", 16, {{0, 1, "せわ"}}));
  f.expect(ruby.size() == 3 && ruby[0] == "忙しい/せわしい" && ruby[1] == "忙しい/いそがしい" && ruby[2] == "忙/ぼう",
           "ruby せわ: せわしい first, shorter 忙 stays after the longest match: " + join(ruby));

  const auto top1 = readings(lookup_with(lookup, "忙しい。", 1, {{0, 1, "せわ"}}));
  f.expect(top1.size() == 1 && top1[0] == "忙しい/せわしい",
           "ruby must rank before the max_results truncation: " + join(top1));

  const auto kata = readings(lookup_with(lookup, "忙しい", 16, {{0, 1, "セワ"}}));
  f.expect(!kata.empty() && kata[0] == "忙しい/せわしい", "katakana ruby must match the hiragana reading: " + join(kata));

  // ruby 区间越界（指向查询串外）：无从判断，原序。
  const auto stray = readings(lookup_with(lookup, "忙しい", 16, {{5, 6, "せわ"}}));
  f.expect(!stray.empty() && stray[0] == "忙しい/いそがしい", "out-of-range ruby must not reorder: " + join(stray));
}

void check_matcher(Failures& f) {
  const ruby_reading::Matcher sewa({{0, 1, "せわ"}});
  f.expect(sewa.agreement("忙しい", "忙しい", "せわしい") == 1, "せわしい agrees");
  f.expect(sewa.agreement("忙しい", "忙しい", "いそがしい") == -1, "いそがしい conflicts");
  f.expect(sewa.agreement("忙", "忙", "ぼう") == -1, "single-kanji ぼう conflicts");
  f.expect(sewa.agreement("忙しく", "忙しい", "せわしい") == 1, "inflected 忙しく compares on the common prefix");
  f.expect(sewa.agreement("忙しく", "忙しい", "いそがしい") == -1, "inflected 忙しく vs いそがしい conflicts");
  f.expect(sewa.agreement("忙しい", "せわしい", "") == 0, "kana-written headword: no common prefix, no verdict");

  // 「毎日忙しい」：毎日 无 ruby（通配），忙 有 ruby。
  const ruby_reading::Matcher later({{2, 3, "せわ"}});
  f.expect(later.agreement("毎日忙しい", "毎日忙しい", "まいにちせわしい") == 1, "uncovered kanji act as wildcard");
  f.expect(later.agreement("毎日忙しい", "毎日忙しい", "まいにちいそがしい") == -1, "wildcard does not swallow conflict");
  f.expect(later.agreement("毎日", "毎日", "まいにち") == 0, "match ending before the ruby base has no verdict");

  // <ruby>今日<rt>きょう</rt></ruby>：只匹配到 今 时不能按字拆读音。
  const ruby_reading::Matcher kyou({{0, 2, "きょう"}});
  f.expect(kyou.agreement("今", "今", "いま") == 0, "partial ruby base has no verdict");
  f.expect(kyou.agreement("今日", "今日", "きょう") == 1, "きょう agrees");
  f.expect(kyou.agreement("今日", "今日", "こんにち") == -1, "こんにち conflicts");

  const ruby_reading::Matcher none({});
  f.expect(none.empty() && none.agreement("忙しい", "忙しい", "せわしい") == 0, "no ruby, no verdict");
}

}  // namespace

int main() {
  Failures f;
  check_matcher(f);
  check_end_to_end(f);
  std::fprintf(stderr, "ruby_reading_lookup_test: %s\n", f.count ? "FAILED" : "PASSED");
  return f.count ? 1 : 0;
}

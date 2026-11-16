#include "mixed_orthography.hpp"

#include <utf8.h>

#include <algorithm>

namespace mixed_orthography {
namespace {

// 汉字：CJK 统一表意文字及扩展、兼容表意文字，外加在词头里占一个「汉字位」的
// 々 〆 ヶ（一ヶ月 = いっかげつ，ヶ 读 か）。ヶ 落在片假名区段，必须先于假名判定。
bool is_kanji(char32_t c) {
  return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x20000 && c <= 0x2A6DF) ||
         (c >= 0x2A700 && c <= 0x2EBEF) || (c >= 0x30000 && c <= 0x3134F) || (c >= 0xF900 && c <= 0xFAFF) ||
         (c >= 0x2F800 && c <= 0x2FA1F) || c == 0x3005 || c == 0x3006 || c == 0x30F6;
}


}  // namespace

bool is_kana(char32_t c) {
  if (is_kanji(c)) return false;
  return (c >= 0x3041 && c <= 0x3096) || (c >= 0x309D && c <= 0x309F) || (c >= 0x30A1 && c <= 0x30FA) ||
         (c >= 0x30FC && c <= 0x30FE);
}

char32_t fold_kana(char32_t c) {
  if (c >= 0x30A1 && c <= 0x30F6) return c - 0x60;
  if (c == 0x30FD || c == 0x30FE) return c - 0x60;  // ヽ ヾ → ゝ ゞ
  return c;
}

namespace {

std::u32string to_u32(const std::string& s) {
  std::u32string out;
  utf8::utf8to32(s.begin(), s.end(), std::back_inserter(out));
  return out;
}

std::string to_u8(const std::u32string& s) {
  std::string out;
  utf8::utf32to8(s.begin(), s.end(), std::back_inserter(out));
  return out;
}

// 一个汉字在读音里最多占几个假名（承る = うけたまわ る 是 4，留余量到 6）；一段汉字
// 按段长乘上去。
constexpr std::size_t kMaxKanaPerKanji = 6;

bool match_from(const std::u32string& q, std::size_t qi, const std::u32string& e, std::size_t ei,
                const std::u32string& r, std::size_t ri) {
  if (ei == e.size()) return qi == q.size() && ri == r.size();
  const char32_t c = e[ei];
  if (is_kanji(c)) {
    // 词头里的一段连续汉字是一个单位：要么整段原样出现在查询里，要么整段写成它在读音
    // 里对应的那段假名。不允许拆半——「足がく」不是「足掻く」、「水を」不是「水脈」：
    // 半段写成假名时，那个假名几乎总是紧跟汉字的助词（が / を / に），误命中远多于
    // 真混写（真实文本里的混写是整词换写：棚にあげる、目をつける、子供がなく）。
    std::size_t run_end = ei;
    while (run_end < e.size() && is_kanji(e[run_end])) ++run_end;
    const std::size_t run_len = run_end - ei;
    const bool literal = qi + run_len <= q.size() && std::equal(e.begin() + ei, e.begin() + run_end, q.begin() + qi);
    const std::size_t max_len = std::min(kMaxKanaPerKanji * run_len, r.size() - ri);
    for (std::size_t len = 1; len <= max_len; ++len) {
      // 原样写出：读音里占 len 个假名（每个汉字至少一个，具体几个由后文决定）。
      if (literal && len >= run_len && match_from(q, qi + run_len, e, run_end, r, ri + len)) return true;
      // 写成假名：查询里的 len 个假名与读音的同一段逐字相等。
      if (qi + len <= q.size()) {
        bool same = true;
        for (std::size_t k = 0; k < len && same; ++k) {
          same = is_kana(q[qi + k]) && fold_kana(q[qi + k]) == fold_kana(r[ri + k]);
        }
        if (same && match_from(q, qi + len, e, run_end, r, ri + len)) return true;
      }
    }
    return false;
  }
  if (is_kana(c)) {
    // 词头里的假名：查询与读音都得在这里是同一个假名。
    if (qi < q.size() && ri < r.size() && fold_kana(q[qi]) == fold_kana(c) && fold_kana(r[ri]) == fold_kana(c)) {
      return match_from(q, qi + 1, e, ei + 1, r, ri + 1);
    }
    return false;
  }
  // 其它字符（・ 数字 拉丁等）：查询原样对上；读音里可能有也可能没有它。
  if (qi < q.size() && q[qi] == c) {
    if (ri < r.size() && r[ri] == c && match_from(q, qi + 1, e, ei + 1, r, ri + 1)) return true;
    return match_from(q, qi + 1, e, ei + 1, r, ri);
  }
  return false;
}

}  // namespace

bool is_mixed(const std::string& text) {
  bool kanji = false;
  bool kana = false;
  for (auto it = text.begin(); it != text.end();) {
    const char32_t c = utf8::next(it, text.end());
    if (is_kanji(c)) {
      kanji = true;
    } else if (is_kana(c)) {
      kana = true;
    }
    if (kanji && kana) return true;
  }
  return false;
}

std::string to_hiragana(const std::string& text) {
  std::u32string s = to_u32(text);
  for (auto& c : s) c = fold_kana(c);
  return to_u8(s);
}

namespace {

void append_utf8(std::string& out, char32_t c) { utf8::append(c, std::back_inserter(out)); }

// [text] 逐码点折成平假名后接到 [out] 末尾；返回 [text] 是否非空且全是假名。
bool append_folded(std::string& out, std::string_view text) {
  bool all_kana = !text.empty();
  for (auto it = text.begin(); it != text.end();) {
    const char32_t c = fold_kana(utf8::next(it, text.end()));
    all_kana = all_kana && is_kana(c);
    append_utf8(out, c);
  }
  return all_kana;
}

}  // namespace

std::vector<std::string> reading_candidates(const std::string& text, const RunReadings& run_readings) {
  // 全程在 UTF-8 上做：一次查词要给三十来个还原形各拼最多 kMaxCandidates 个候选，
  // 逐候选转 UTF-32 再转回来是这条通路上最大的一笔开销。
  //
  // 先切成交替的段（字节区间）：一段连续汉字 / 一段非汉字。
  struct Segment {
    std::size_t begin;
    std::size_t end;
    bool kanji;
  };
  std::vector<Segment> segments;
  std::size_t runs = 0;
  for (auto it = text.begin(); it != text.end();) {
    const std::size_t at = static_cast<std::size_t>(it - text.begin());
    const bool kanji = is_kanji(utf8::next(it, text.end()));
    const std::size_t next = static_cast<std::size_t>(it - text.begin());
    if (!segments.empty() && segments.back().kanji == kanji) {
      segments.back().end = next;
    } else {
      segments.push_back({.begin = at, .end = next, .kanji = kanji});
      if (kanji) ++runs;
    }
  }
  if (runs == 0 || runs > kMaxKanjiRuns) return {};
  // 每段可取的读音数：段数越多每段越少，组合总数不超过 kMaxCandidates。读音按
  // [run_readings] 给的顺序（常用在前）截取。
  std::size_t per_run = kMaxReadingsPerRun;
  while (per_run > 1) {
    std::size_t total = 1;
    for (std::size_t k = 0; k < runs; ++k) total *= per_run;
    if (total <= kMaxCandidates) break;
    --per_run;
  }

  // 汉字段换成读音，其余字符（假名转平假名）原样拼接。
  std::vector<std::vector<std::string>> pieces;
  pieces.reserve(segments.size());
  std::size_t total = 1;
  for (const Segment& segment : segments) {
    const std::string_view part(text.data() + segment.begin, segment.end - segment.begin);
    std::vector<std::string> options;
    if (segment.kanji) {
      for (const std::string& reading : run_readings(std::string(part))) {
        std::string folded;
        folded.reserve(reading.size());
        if (!append_folded(folded, reading)) continue;
        if (std::ranges::find(options, folded) != options.end()) continue;
        options.push_back(std::move(folded));
        if (options.size() >= per_run) break;
      }
      if (options.empty()) return {};
    } else {
      std::string literal;
      literal.reserve(part.size());
      append_folded(literal, part);
      options.push_back(std::move(literal));
    }
    total *= options.size();
    pieces.push_back(std::move(options));
  }

  // 只有一段汉字时候选两两不同（同一段的读音已去重、其余段是定值），不必再查重；
  // 多段时不同的读音组合可能拼出同一个串（あ + いう / あい + う）。
  const bool may_repeat = runs > 1;
  std::vector<std::string> out;
  out.reserve(total);
  std::string candidate;
  for (std::size_t n = 0; n < total; ++n) {
    candidate.clear();
    std::size_t rest = n;
    for (const auto& options : pieces) {
      candidate += options[rest % options.size()];
      rest /= options.size();
    }
    if (candidate == text) continue;
    if (may_repeat && std::ranges::find(out, candidate) != out.end()) continue;
    out.push_back(candidate);
  }
  return out;
}

bool matches_mixed_orthography(const std::string& query, const std::string& expression,
                               const std::string& reading) {
  if (reading.empty() || query == expression) return false;
  return match_from(to_u32(query), 0, to_u32(expression), 0, to_u32(reading), 0);
}

}  // namespace mixed_orthography

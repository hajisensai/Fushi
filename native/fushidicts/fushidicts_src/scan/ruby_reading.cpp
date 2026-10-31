#include "ruby_reading.hpp"

#include <utf8.h>

#include <algorithm>
#include <iterator>

#include "mixed_orthography.hpp"

namespace ruby_reading {
namespace {

std::u32string folded_u32(const std::string& s) {
  std::u32string out;
  utf8::utf8to32(s.begin(), s.end(), std::back_inserter(out));
  for (auto& c : out) c = mixed_orthography::fold_kana(c);
  return out;
}

// 读音模式：字面假名段 / 通配（一个以上任意码点，对应没有 ruby 的汉字等）。
struct Token {
  bool wildcard;
  std::u32string literal;
};

// [tokens] 是否能匹配 [reading] 的某个前缀（通配非贪婪回溯；输入恒在扫描窗口内，很短）。
bool match_prefix(const std::vector<Token>& tokens, std::size_t ti, const std::u32string& reading,
                  std::size_t ri) {
  if (ti == tokens.size()) return true;
  const Token& token = tokens[ti];
  if (!token.wildcard) {
    if (reading.compare(ri, token.literal.size(), token.literal) != 0) return false;
    return match_prefix(tokens, ti + 1, reading, ri + token.literal.size());
  }
  for (std::size_t next = ri + 1; next <= reading.size(); ++next) {
    if (match_prefix(tokens, ti + 1, reading, next)) return true;
  }
  return false;
}

}  // namespace

Matcher::Matcher(const std::vector<RubyReading>& readings) {
  for (const auto& r : readings) {
    if (r.end <= r.start || r.reading.empty()) continue;
    if (!utf8::is_valid(r.reading.begin(), r.reading.end())) continue;
    spans_.push_back(Span{r.start, r.end, folded_u32(r.reading)});
  }
  std::ranges::sort(spans_, {}, &Span::start);
}

int Matcher::agreement(const std::string& matched, const std::string& expression, const std::string& reading) const {
  if (spans_.empty()) return 0;
  std::u32string source;
  std::u32string headword;
  utf8::utf8to32(matched.begin(), matched.end(), std::back_inserter(source));
  utf8::utf8to32(expression.begin(), expression.end(), std::back_inserter(headword));
  const std::u32string target = folded_u32(reading.empty() ? expression : reading);
  if (target.empty()) return 0;

  // 原文与词头表记的公共前缀：去屈折只改词尾假名（忙しく → 忙しい），公共前缀之内
  // 原文的每个字都对应词头的同一个字，它的读音必然是词头读音的前缀。
  std::size_t prefix = 0;
  while (prefix < source.size() && prefix < headword.size() && source[prefix] == headword[prefix]) ++prefix;
  // 不能把一个 ruby 基字从中间切开（基字的读音无法按字拆分）。
  for (const auto& span : spans_) {
    if (span.start < prefix && prefix < span.end) prefix = span.start;
  }

  std::vector<Token> tokens;
  auto push_literal = [&tokens](const std::u32string& text) {
    if (text.empty()) return;
    if (!tokens.empty() && !tokens.back().wildcard) {
      tokens.back().literal += text;
    } else {
      tokens.push_back(Token{false, text});
    }
  };
  std::size_t i = 0;
  auto plain_until = [&](std::size_t end) {
    for (; i < end; ++i) {
      const char32_t c = source[i];
      if (mixed_orthography::is_kana(c)) {
        push_literal(std::u32string(1, mixed_orthography::fold_kana(c)));
      } else if (tokens.empty() || !tokens.back().wildcard) {
        tokens.push_back(Token{true, {}});
      }
    }
  };
  bool used_ruby = false;
  for (const auto& span : spans_) {
    if (span.start < i || span.end > prefix) continue;
    plain_until(span.start);
    push_literal(span.reading);
    used_ruby = true;
    i = span.end;
  }
  if (!used_ruby) return 0;
  plain_until(prefix);

  return match_prefix(tokens, 0, target, 0) ? 1 : -1;
}

}  // namespace ruby_reading

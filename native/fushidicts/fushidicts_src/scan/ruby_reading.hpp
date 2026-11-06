#pragma once

// 按原文自带振假名（EPUB / 歌词 / 卡片 / 网页里的 <ruby>）判断一条查词结果的读音。
//
// 原文 `<ruby>忙<rt>せわ</rt></ruby>しい` 已经告诉读者这里读「せわしい」，但取词串
// 只剩「忙しい」，同匹配长度的候选按频率排，「いそがしい」永远压在前面。调用方把
// 取词串里每个 ruby 基字的码点区间与 <rt> 读音经 LookupOptions::ruby_readings 带进来，
// 比较器在「匹配长度」之后、「变形步数 / 频率」之前按这里的一致度排。
//
// 只用来源自带的读音，不做任何读音推断（全仓禁自动注音）：没有 ruby 的汉字一律当
// 通配，不臆造读音。

#include <string>
#include <vector>

#include "fushidicts/lookup.hpp"

namespace ruby_reading {

// 一次 lookup 内复用：读音预先转成码点并统一成平假名。
class Matcher {
 public:
  explicit Matcher(const std::vector<RubyReading>& readings);

  bool empty() const { return spans_.empty(); }

  // 1 = 结果读音与原文 ruby 吻合，-1 = 冲突，0 = 无从判断（匹配段里没有完整的 ruby
  // 基字，或表记与原文没有公共前缀）。[matched] 是原文前缀，[expression] / [reading]
  // 是词头表记与读音（读音为空时以表记当读音）。
  int agreement(const std::string& matched, const std::string& expression, const std::string& reading) const;

 private:
  struct Span {
    std::size_t start;
    std::size_t end;
    std::u32string reading;
  };
  std::vector<Span> spans_;
};

}  // namespace ruby_reading

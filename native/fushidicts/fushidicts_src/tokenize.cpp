#include "fushidicts/tokenize.hpp"

#include <utf8.h>

#include <algorithm>
#include <unordered_map>

namespace {

constexpr char kReplacementChar[] = "\xEF\xBF\xBD";  // U+FFFD

// 一个码点在源 UTF-8 里的字节区间，以及它在 Dart 字符串里占几个 UTF-16 码元。
struct CodePoint {
  std::size_t begin;
  std::size_t end;
  int units;
};

std::vector<CodePoint> decode(const std::string& text) {
  std::vector<CodePoint> cps;
  cps.reserve(text.size());
  auto it = text.begin();
  while (it != text.end()) {
    const std::size_t begin = static_cast<std::size_t>(it - text.begin());
    const uint32_t cp = utf8::next(it, text.end());
    cps.push_back({begin, static_cast<std::size_t>(it - text.begin()), cp >= 0x10000 ? 2 : 1});
  }
  return cps;
}

int32_t utf16_length(const std::string& s) {
  int32_t units = 0;
  auto it = s.begin();
  while (it != s.end()) {
    units += utf8::next(it, s.end()) >= 0x10000 ? 2 : 1;
  }
  return units;
}

// 分词只要匹配长度和读音：跳过排序之后的 pitch 富化与释义解压（排序、截断、
// matched 都不受影响，见 LookupOptions::materialize）。
LookupOptions tokenize_options() {
  LookupOptions options;
  options.materialize = false;
  return options;
}

// [window] 已是截好的查询窗口（≤ scan_length + 1 个码点）。
int32_t window_match_length(const Lookup& lookup, const std::string& window, std::size_t scan_length,
                            MatchLengthCache* cache) {
  std::string key;
  if (cache) {
    key = std::to_string(scan_length);
    key.push_back('\x1f');
    key += window;
    int32_t cached = 0;
    if (cache->get(key, cached)) return cached;
  }
  const auto results = lookup.lookup(window, 1, scan_length, tokenize_options());
  const int32_t length = results.empty() ? 0 : utf16_length(results.front().matched);
  if (cache) cache->put(key, length);
  return length;
}

// 从码点 [first] 起拼查询窗口：[prefix_fffd] 为真时先放一个 U+FFFD（代理对后半），
// 窗口总长 scan_length + 1 个码点。
std::string build_window(const std::string& text, const std::vector<CodePoint>& cps, std::size_t first,
                         bool prefix_fffd, std::size_t scan_length) {
  std::string window;
  std::size_t budget = scan_length + 1;
  if (prefix_fffd) {
    window = kReplacementChar;
    budget -= 1;
  }
  if (first < cps.size() && budget > 0) {
    const std::size_t last = std::min(cps.size(), first + budget);
    window.append(text, cps[first].begin, cps[last - 1].end - cps[first].begin);
  }
  return window;
}

}  // namespace

bool MatchLengthCache::get(const std::string& key, int32_t& out) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = index_.find(key);
  if (it == index_.end()) return false;
  order_.splice(order_.begin(), order_, it->second);
  out = it->second->second;
  return true;
}

void MatchLengthCache::put(const std::string& key, int32_t value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (capacity_ == 0) return;
  auto it = index_.find(key);
  if (it != index_.end()) {
    it->second->second = value;
    order_.splice(order_.begin(), order_, it->second);
    return;
  }
  order_.emplace_front(key, value);
  index_.emplace(key, order_.begin());
  while (order_.size() > capacity_) {
    index_.erase(order_.back().first);
    order_.pop_back();
  }
}

void MatchLengthCache::clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  order_.clear();
  index_.clear();
}

std::size_t MatchLengthCache::size() {
  std::lock_guard<std::mutex> lock(mutex_);
  return order_.size();
}

int32_t match_length_utf16(const Lookup& lookup, const std::string& text_utf8, std::size_t scan_length,
                           MatchLengthCache* cache) {
  const std::vector<CodePoint> cps = decode(text_utf8);
  return window_match_length(lookup, build_window(text_utf8, cps, 0, false, scan_length), scan_length, cache);
}

TokenizeOutput tokenize(const Lookup& lookup, const std::string& text_utf8, std::size_t scan_length,
                        bool with_readings, MatchLengthCache* cache) {
  TokenizeOutput out;
  const std::vector<CodePoint> cps = decode(text_utf8);
  out.lengths.reserve(cps.size());

  // 段文本 → 读音。同一段（助词、标点）在一段文本里反复出现，各查一次就够。
  std::unordered_map<std::string, std::string> reading_memo;
  auto reading_of = [&](const std::string& segment) -> std::string {
    auto [it, inserted] = reading_memo.try_emplace(segment);
    if (inserted) {
      const auto results = lookup.lookup(segment, 1, scan_length, tokenize_options());
      if (!results.empty()) it->second = results.front().term.reading;
    }
    return it->second;
  };

  std::size_t i = 0;     // 当前码点
  bool half = false;     // 当前位置落在码点 i（代理对）的后半个码元上
  while (i < cps.size()) {
    const int32_t matched = window_match_length(lookup, build_window(text_utf8, cps, half ? i + 1 : i, half,
                                                                     scan_length),
                                                scan_length, cache);
    std::string segment;
    if (matched > 0) {
      int32_t units = matched;
      if (half) {
        if (with_readings) segment = kReplacementChar;
        units -= 1;
        i += 1;
        half = false;
      }
      const std::size_t first = i;
      while (units > 0 && i < cps.size()) {
        units -= cps[i].units;
        i += 1;
      }
      if (with_readings && i > first) {
        segment.append(text_utf8, cps[first].begin, cps[i - 1].end - cps[first].begin);
      }
      out.lengths.push_back(matched);
    } else {
      // 未命中：只前进一个 UTF-16 码元。代理对先停在后半，下一轮从那里起查。
      if (with_readings) {
        segment = (half || cps[i].units == 2)
                      ? std::string(kReplacementChar)
                      : text_utf8.substr(cps[i].begin, cps[i].end - cps[i].begin);
      }
      if (!half && cps[i].units == 2) {
        half = true;
      } else {
        half = false;
        i += 1;
      }
      out.lengths.push_back(1);
    }
    if (with_readings) out.readings.push_back(reading_of(segment));
  }
  return out;
}

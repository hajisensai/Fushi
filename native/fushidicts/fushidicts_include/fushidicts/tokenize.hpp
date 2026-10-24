#pragma once

#include <cstddef>
#include <cstdint>
#include <list>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "lookup.hpp"

// 最长匹配分词（Dart `JapaneseLanguage.textToWords` / `wordFromIndex` 的原生实现）。
//
// 语义与此前的 Dart 逐位置循环逐位一致：从位置 pos 起对剩余文本做一次
// `lookup(max_results = 1)`，命中就切出「首条结果的 matched」那么长，未命中就切出
// **一个 UTF-16 码元**再前进一个码元。所有长度、位置都按 UTF-16 码元计，因为调用方
// 是 Dart 字符串：
//   * 未命中的增补平面字（😀）被切成两个半码元碎片——这是旧实现的既有行为，
//     subtitle_word_sweep / texthooker 都依赖它（BUG-3086），不能「顺手修好」；
//   * 落在代理对后半的位置上，旧实现交给引擎的是「孤立低代理 + 余下文本」，Dart 的
//     UTF-8 编码器把孤立代理换成 U+FFFD。这里照样拼 U+FFFD 再查，结果逐位相同。
//
// 引擎的结果只依赖查询串的前 scan_length + 1 个码点（scan_candidates 读窗口内的前缀，
// 外加窗口后的第一个码点判断是否切在拉丁单词中间；BUG-3212 的关西方言保护结构只看窗口
// 内），所以每个位置只拷这一段、不拷整段余文——这也是匹配长度缓存的键。

// 每个引擎句柄一份的匹配长度 LRU（键 = scan_length + 窗口文本，值 = UTF-16 匹配长度）。
// 句柄随词典集合重建，add_*_dict / load_transforms 时也必须 clear()——结果依赖词典与
// 变形表，旧 Dart 静态缓存从不失效，换了词典还在吐旧长度。
class MatchLengthCache {
 public:
  explicit MatchLengthCache(std::size_t capacity = 5000) : capacity_(capacity) {}

  bool get(const std::string& key, int32_t& out);
  void put(const std::string& key, int32_t value);
  void clear();
  std::size_t size();

 private:
  using Entry = std::pair<std::string, int32_t>;
  std::size_t capacity_;
  std::mutex mutex_;
  std::list<Entry> order_;  // 前 = 最近使用
  std::unordered_map<std::string, std::list<Entry>::iterator> index_;
};

// 一段文本的分词结果。lengths[i] 是第 i 段的 UTF-16 码元数（恒 ≥ 1，总和 = 文本的
// UTF-16 长度）；readings 只在 with_readings 时填，与 lengths 等长。
struct TokenizeOutput {
  std::vector<int32_t> lengths;
  std::vector<std::string> readings;
  // 只在 with_terms 时填：每段首条结果的词头（词典形，未命中为空），与 lengths 等长。
  // 音乐歌词生词覆盖率按它去复习库里查「认不认识」（变形后的表层形查不到）。
  std::vector<std::string> expressions;
};

// 文本开头的最长匹配长度（UTF-16 码元；0 = 未命中）。[cache] 可为 nullptr。
int32_t match_length_utf16(const Lookup& lookup, const std::string& text_utf8, std::size_t scan_length,
                           MatchLengthCache* cache);

// 整段分词。[text_utf8] 必须是合法 UTF-8（Dart 侧编码保证；孤立代理已是 U+FFFD）。
// with_readings：每段另做一次 `lookup(段文本, 1)` 取首条结果的读音（未命中为空）——
// 与浏览器扩展 yomitan tokenize 以前逐词调用 lookup 的口径相同。
// with_terms：另外填 expressions（隐含 with_readings，同一次 lookup 取读音与词头）。
TokenizeOutput tokenize(const Lookup& lookup, const std::string& text_utf8, std::size_t scan_length,
                        bool with_readings, MatchLengthCache* cache, bool with_terms = false);

// ── 语料词元（「我库里的例句」：native/fushi_corpus 的倒排索引键） ─────────────
//
// 与 [tokenize] 同一条最长匹配，但目的不同：不是给 UI 切段，而是给出每个**命中**位置的
// 词典形（首条结果的 `term.expression`，也就是查词弹窗词头显示的那个写法），让用户库里的
// 句子按「查词时会看到的词头」建倒排。于是：
//   * 只输出命中的词元（未命中的位置不可能是弹窗里的词头，不进索引）；
//   * 未命中时若落在空格分词类字母上，整串字母一起跳过（不从词中间起查，免得 "zephyr"
//     未收录时切出 "e" / "phy" 一类伪词元）；空白直接跳过，不查；
//   * 位置与长度按 UTF-16 码元计（调用方是 Dart 字符串，高亮直接用）。
// 词形还原、文本变体归一都在 [Lookup] 里，按已加载的变形表与词典生效——**不分语言、
// 不假设日语**：没装词典 / 变形表的语言自然一个词元都不出。
struct CorpusToken {
  int32_t start;   // UTF-16 码元偏移
  int32_t length;  // UTF-16 码元数（≥ 1）
  std::string lemma;
};

// 一次批量调用内共享的窗口 → (匹配长度, 词典形) 记忆。同一批句子里高频词反复出现，
// 窗口相同的位置只查一次。容量到顶时整表清空（批内命中率已足够，不做 LRU）。
class CorpusLemmaMemo {
 public:
  bool get(const std::string& window, int32_t& length, std::string& lemma) const;
  void put(const std::string& window, int32_t length, const std::string& lemma);

 private:
  static constexpr std::size_t kCapacity = 200000;
  std::unordered_map<std::string, std::pair<int32_t, std::string>> entries_;
};

std::vector<CorpusToken> tokenize_corpus(const Lookup& lookup, const std::string& text_utf8,
                                         std::size_t scan_length, CorpusLemmaMemo* memo);

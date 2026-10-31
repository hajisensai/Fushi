#pragma once

#include <optional>
#include <string>
#include <vector>

#include "deinflector.hpp"
#include "query.hpp"

struct LookupResult {
  std::string matched;
  std::string deinflected;
  std::vector<TransformGroup> trace;
  TermResult term;
  int preprocessor_steps;
  // 与 LookupOptions::ruby_readings 的一致度（1 吻合 / 0 无从判断 / -1 冲突），比较器用。
  int ruby_agreement = 0;
};

// 查询串里一段带原文振假名的基字：[start, end) 是查询串的**码点**区间，reading 是该
// 基字自带的 <rt> 读音（来源读音，不是推断）。
struct RubyReading {
  std::size_t start = 0;
  std::size_t end = 0;
  std::string reading;
};

// 上游 bc62d2b/86c6e2f：调用方可控的排序选项。默认 Auto 逐字节复刻既有比较器
//（零行为变化）；显式指定 frequency_dictionary + Ascending/Descending 时按该词典
// 排序，且发生在 max_results 截断**之前**（前端截断后自己重排是排不回被丢掉的
// 条目的——这是该选项存在的意义）。primary_reading：reading 精确匹配者排最前
//（Yomitan `?query=食べる&primary_reading=たべる` 内链语义）。
enum class LookupFrequencyOrder { Auto, Ascending, Descending, Disabled };

struct LookupOptions {
  std::optional<std::string> frequency_dictionary;
  LookupFrequencyOrder frequency_order = LookupFrequencyOrder::Auto;
  std::optional<std::string> primary_reading;
  // false：跳过截断之后的 pitch 富化与释义解压（materialize）。比较器只读 freq，
  // 两者都发生在 partial_sort + resize 之后，所以结果集合、顺序、matched / reading
  // 逐字不变；返回的 glossary 只剩压缩指针、glossary 文本为空、pitches 为空。
  // 只给只要匹配长度 / 读音的调用方（分词，见 tokenize.hpp）用。
  bool materialize = true;
  // 查询语言为中文时置 true：文本预处理额外产出简体 → 繁體变体（原查询仍先试）。
  // 引擎本身语言无关，由调用方（Dart 的内容语言 / 查词来源语言）声明。
  bool chinese_simp_to_trad = false;
  // 原文自带振假名（阅读器 / 歌词 / 卡片 / 网页取词时从 <ruby> 读出）。非空时同匹配
  // 长度的候选里读音与 ruby 吻合的排前、冲突的排后（截断前生效），见
  // scan/ruby_reading.hpp。空 = 比较器逐字不变。
  std::vector<RubyReading> ruby_readings;
};

class Lookup {
 public:
  Lookup(DictionaryQuery& query, Deinflector& deinflector) : query_(query), deinflector_(deinflector) {};
  std::vector<LookupResult> lookup(const std::string& lookup_string, int max_results = 16, size_t scan_length = 16,
                                   const LookupOptions& options = {}) const;

 private:
  void filter_by_pos(std::vector<TermResult>& terms, const DeinflectionResult& d) const;

  DictionaryQuery& query_;
  Deinflector& deinflector_;
};
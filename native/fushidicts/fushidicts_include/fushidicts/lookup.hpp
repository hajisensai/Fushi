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
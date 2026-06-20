#include "hoshidicts/lookup.hpp"

#include <utf8.h>

#include <algorithm>
#include <map>
#include <ranges>
#include <sstream>

#include "scan/word_scan.hpp"
#include "text_processor/text_processor.hpp"

namespace {
std::vector<std::string> split_whitespace(const std::string& str) {
  std::vector<std::string> result;
  std::istringstream iss(str);
  std::string token;
  while (iss >> token) {
    result.push_back(std::move(token));
  }
  return result;
}

std::vector<int> get_freq_values_for_dict(const TermResult& term, const std::string& dict_name) {
  for (const auto& frequency_entry : term.frequencies) {
    if (frequency_entry.dict_name != dict_name) {
      continue;
    }

    std::vector<int> values;
    for (const auto& frequency : frequency_entry.frequencies) {
      if (frequency.value >= 0) {
        values.push_back(frequency.value);
      }
    }
    std::ranges::sort(values);
    return values;
  }

  return {INT_MAX};
}
}

std::vector<LookupResult> Lookup::lookup(const std::string& lookup_string, int max_results, size_t scan_length) const {
  std::map<std::pair<std::string, std::string>, LookupResult> result_map;

  // 候选前缀由词边界感知的扫描器生成（对齐 Yomitan searchResolution）：
  // 空格分词语言不在单词中间切断，CJK 仍逐码点。详见 scan/word_scan.hpp。
  for (const std::string& search_str : scan_candidates(lookup_string, scan_length)) {
    auto processor_results = text_processor::process(search_str);
    for (auto& variant : processor_results) {
      auto deinflection_results = deinflector_.deinflect(variant.text);
      for (auto& deinflection : deinflection_results) {
        auto terms = query_.query_raw(deinflection.text);
        filter_by_pos(terms, deinflection);

        for (auto& term : terms) {
          // deduplicate glossaries
          auto key = std::make_pair(term.expression, term.reading);
          auto it = result_map.find(key);
          if (it != result_map.end()) {
            // we only need the longest matched form
            if (utf8::distance(search_str.begin(), search_str.end()) >
                utf8::distance(it->second.matched.begin(), it->second.matched.end())) {
              it->second = LookupResult{.matched = search_str,
                                        .deinflected = deinflection.text,
                                        .trace = deinflection.trace,
                                        .term = std::move(term),
                                        .preprocessor_steps = variant.steps};
            }
          } else {
            result_map.emplace(key, LookupResult{.matched = search_str,
                                                 .deinflected = deinflection.text,
                                                 .trace = deinflection.trace,
                                                 .term = std::move(term),
                                                 .preprocessor_steps = variant.steps});
          }
        }
      }
    }
  }

  auto results = result_map | std::views::values | std::views::as_rvalue | std::ranges::to<std::vector>();
  const auto freq_dict_order = query_.get_freq_dict_order();
  auto middle_iter = std::ranges::next(results.begin(), max_results, results.end());
  std::ranges::partial_sort(results, middle_iter, [&freq_dict_order](const auto& a, const auto& b) {
    auto len_a = utf8::distance(a.matched.begin(), a.matched.end());
    auto len_b = utf8::distance(b.matched.begin(), b.matched.end());
    if (len_a != len_b) {
      return len_a > len_b;
    }

    auto steps_a = a.preprocessor_steps;
    auto steps_b = b.preprocessor_steps;
    if (steps_a != steps_b) {
      return steps_a < steps_b;
    }

    auto trace_len_a = a.trace.size();
    auto trace_len_b = b.trace.size();
    if (trace_len_a != trace_len_b) {
      return trace_len_a < trace_len_b;
    }

    auto match_a = a.term.expression == a.deinflected;
    auto match_b = b.term.expression == b.deinflected;
    if (match_a != match_b) {
      return match_a > match_b;
    }

    for (const auto& dict_name : freq_dict_order) {
      const auto freq_a = get_freq_values_for_dict(a.term, dict_name);
      const auto freq_b = get_freq_values_for_dict(b.term, dict_name);
      if (freq_a != freq_b) {
        return freq_a < freq_b;
      }
    }

    auto a_reading_expr_match = a.term.expression == a.term.reading;
    auto b_reading_expr_match = b.term.expression == b.term.reading;
    return a_reading_expr_match > b_reading_expr_match;
  });

  if (results.size() > static_cast<size_t>(max_results)) {
    results.resize(max_results);
  }

  for (auto& r : results) {
    query_.materialize(r.term);
  }

  return results;
}

void Lookup::filter_by_pos(std::vector<TermResult>& terms, const DeinflectionResult& d) const {
  if (d.conditions == 0) {
    return;
  }
  std::erase_if(terms, [&](const TermResult& term) {
    auto dict_conditions = deinflector_.pos_to_conditions(split_whitespace(term.rules));
    return (dict_conditions & d.conditions) == 0;
  });
}

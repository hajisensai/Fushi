#include "hoshidicts/lookup.hpp"

#include <utf8.h>

#include <algorithm>
#include <map>
#include <ranges>
#include <sstream>

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

int get_freq_value_for_dict(const TermResult& term, const std::string& dict_name) {
  for (const auto& frequency_entry : term.frequencies) {
    if (frequency_entry.dict_name != dict_name) {
      continue;
    }

    int min_frequency = INT_MAX;
    for (const auto& frequency : frequency_entry.frequencies) {
      if (frequency.value >= 0) {
        min_frequency = std::min(min_frequency, frequency.value);
      }
    }
    return min_frequency;
  }

  return INT_MAX;
}

bool freq_sort_order(const LookupResult& a, const LookupResult& b, const std::vector<std::string>& freq_dict_order) {
  for (const auto& dict_name : freq_dict_order) {
    const int freq_a = get_freq_value_for_dict(a.term, dict_name);
    const int freq_b = get_freq_value_for_dict(b.term, dict_name);
    if (freq_a != freq_b) {
      return freq_a < freq_b;
    }
  }

  return false;
}
}

std::vector<LookupResult> Lookup::lookup(const std::string& lookup_string, int max_results, size_t scan_length) const {
  std::map<std::pair<std::string, std::string>, LookupResult> result_map;

  size_t text_len = utf8::distance(lookup_string.begin(), lookup_string.end());
  size_t start = std::min(scan_length, text_len);
  auto search_str_it = lookup_string.begin();
  utf8::advance(search_str_it, start, lookup_string.end());

  for (size_t i = std::min(scan_length, text_len); i > 0; i--) {
    std::string search_str(lookup_string.begin(), search_str_it);
    auto processor_results = text_processor::process(search_str);
    for (auto& variant : processor_results) {
      auto deinflection_results = deinflector_.deinflect(variant.text);
      for (auto& deinflection : deinflection_results) {
        auto terms = query_.query(deinflection.text);
        filter_by_pos(terms, deinflection);

        for (const auto& term : terms) {
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
                                        .term = term,
                                        .preprocessor_steps = variant.steps};
            }
          } else {
            result_map.emplace(key, LookupResult{.matched = search_str,
                                                 .deinflected = deinflection.text,
                                                 .trace = deinflection.trace,
                                                 .term = term,
                                                 .preprocessor_steps = variant.steps});
          }
        }
      }
    }
    if (i > 1) {
      utf8::prior(search_str_it, lookup_string.begin());
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

    return freq_sort_order(a, b, freq_dict_order);
  });

  if (results.size() > static_cast<size_t>(max_results)) {
    results.resize(max_results);
  }

  return results;
}

void Lookup::filter_by_pos(std::vector<TermResult>& terms, const DeinflectionResult& d) {
  if (d.conditions == 0) {
    return;
  }
  std::erase_if(terms, [&](const TermResult& term) {
    auto dict_conditions = Deinflector::pos_to_conditions(split_whitespace(term.rules));
    return (dict_conditions & d.conditions) == 0;
  });
}

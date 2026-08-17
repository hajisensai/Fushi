#include "fushidicts/lookup.hpp"

#include <utf8.h>

#include <algorithm>
#include <climits>
#include <map>
#include <optional>
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

// 上游 909c854 revert 了 4975788 的向量比较（作者自己否掉的实验：每次比较
// 分配+排序一个 vector，partial_sort 下纯浪费）；后随 bc62d2b 演化为 optional +
// 方向感知（Descending 时取该词典内最大值而非最小值）。
std::optional<int> get_freq_value_for_dict(const TermResult& term, std::string_view dictionary_name, bool descending) {
  std::optional<int> frequency;
  for (const auto& frequency_entry : term.frequencies) {
    if (frequency_entry.dict_name != dictionary_name || frequency_entry.frequencies.empty()) {
      continue;
    }

    for (const auto& candidate : frequency_entry.frequencies) {
      if (candidate.value < 0) {
        continue;
      }
      frequency = frequency.has_value() ? std::optional<int>(descending ? std::max(*frequency, candidate.value)
                                                                        : std::min(*frequency, candidate.value))
                                        : std::optional<int>(candidate.value);
    }
  }

  return frequency;
}

bool matches_primary_reading(const TermResult& term, std::string_view primary_reading) {
  return term.reading == primary_reading;
}
}

std::vector<LookupResult> Lookup::lookup(const std::string& lookup_string, int max_results, size_t scan_length,
                                         const LookupOptions& options) const {
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

  // BUG-1665: MDX/StarDict importers resolve redirects (@@@LINK= / .syn) by
  // copying the target's definition under the inflected key, so "belongs"
  // carries belong's bytes as its own entry. A lookup of "belongs" then
  // surfaces BOTH that alias exact hit and the deinflected lemma hit, and the
  // alias (0 transforms) sorts first — the popup header and the mined Anki
  // term become the inflected surface form instead of the lemma (Yomitan
  // mines the lemma). The importer dedupes identical definitions by hash into
  // ONE compressed blob, so within a dict an alias glossary and its lemma
  // glossary share the same blob pointer — a byte-exact redirect detector
  // that needs no re-import of already-imported dictionaries. For each
  // surface form, drop from the untransformed exact hit every glossary whose
  // blob also backs a lemma hit (a real transform whose result is the entry's
  // own expression) of the same surface; drop the result once empty. Spelling
  // variants (colour → color) have no deinflection rule and are untouched; a
  // dictionary with a genuinely distinct inflected entry keeps it (different
  // blob).
  auto same_blob = [](const GlossaryEntry& x, const GlossaryEntry& y) {
    return x.compressed_data == y.compressed_data && x.compressed_size == y.compressed_size &&
           x.dict_name == y.dict_name;
  };
  for (auto& r : results) {
    // Only an untransformed direct expression hit can be a redirect alias.
    if (!r.trace.empty() || r.term.expression != r.deinflected) {
      continue;
    }
    for (const auto& lemma : results) {
      if (&lemma == &r || lemma.matched != r.matched) continue;
      if (lemma.trace.empty() || lemma.term.expression != lemma.deinflected) continue;
      std::erase_if(r.term.glossaries, [&](const GlossaryEntry& g) {
        return std::ranges::any_of(lemma.term.glossaries,
                                   [&](const GlossaryEntry& lg) { return same_blob(g, lg); });
      });
    }
  }
  std::erase_if(results, [](const LookupResult& r) { return r.term.glossaries.empty(); });

  // BUG-1304: frequency enrichment happens ONCE here, on the deduplicated set,
  // instead of inside every query_raw() call above (which runs once per
  // scan-candidate x text-variant x deinflection -- ~69 times per user lookup,
  // measured, each one hitting every frequency dictionary with its own JSON
  // parse, for results that the dedup/sort/resize below mostly discard).
  // Measured effect: 9.4 -> 3.2 enrichments per lookup, ~5-9% end to end.
  // It must precede the sort because the comparator ranks by frequency.
  // Enriching per (expression, reading) is what query_freq did all along, so
  // the surviving results carry byte-identical frequency data.
  for (auto& r : results) {
    query_.enrich_freq(r.term);
  }

  // 上游 bc62d2b：排序选项解析。Auto = 既有比较器（按注册顺序遍历全部 freq 词典，
  // 零行为变化）；显式指定词典 + 升/降序时只按该词典排（找不到词典名则静默退回，
  // 不排序也不报错——与上游一致）。
  std::vector<std::string> auto_frequency_dictionaries;
  std::optional<std::string_view> frequency_dictionary;
  bool frequency_descending = false;
  switch (options.frequency_order) {
    case LookupFrequencyOrder::Auto:
      auto_frequency_dictionaries = query_.get_freq_dict_order();
      break;
    case LookupFrequencyOrder::Ascending:
    case LookupFrequencyOrder::Descending:
      if (options.frequency_dictionary.has_value()) {
        const auto selected =
            std::ranges::find(query_.freq_dicts_, *options.frequency_dictionary, &DictionaryQuery::Dictionary::name);
        if (selected != query_.freq_dicts_.end()) {
          frequency_dictionary = selected->name;
          frequency_descending = options.frequency_order == LookupFrequencyOrder::Descending;
        }
      }
      break;
    case LookupFrequencyOrder::Disabled:
      break;
  }
  std::string_view primary_reading;
  if (options.primary_reading.has_value()) {
    primary_reading = *options.primary_reading;
  }

  auto middle_iter = std::ranges::next(results.begin(), max_results, results.end());
  std::ranges::partial_sort(
      results, middle_iter,
      [&auto_frequency_dictionaries, frequency_dictionary, frequency_descending, primary_reading](const auto& a,
                                                                                                  const auto& b) {
        // 上游 86c6e2f：primary_reading 精确匹配者排最前（截断前生效）。
        if (!primary_reading.empty()) {
          const bool primary_a = matches_primary_reading(a.term, primary_reading);
          const bool primary_b = matches_primary_reading(b.term, primary_reading);
          if (primary_a != primary_b) {
            return primary_a;
          }
        }

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

        for (const auto& dictionary_name : auto_frequency_dictionaries) {
          const int freq_a = get_freq_value_for_dict(a.term, dictionary_name, false).value_or(INT_MAX);
          const int freq_b = get_freq_value_for_dict(b.term, dictionary_name, false).value_or(INT_MAX);
          if (freq_a != freq_b) {
            return freq_a < freq_b;
          }
        }

        if (frequency_dictionary.has_value()) {
          const auto freq_a = get_freq_value_for_dict(a.term, *frequency_dictionary, frequency_descending);
          const auto freq_b = get_freq_value_for_dict(b.term, *frequency_dictionary, frequency_descending);
          if (freq_a.has_value() != freq_b.has_value()) {
            return freq_a.has_value();
          }
          if (freq_a.has_value() && *freq_a != *freq_b) {
            return frequency_descending ? *freq_a > *freq_b : *freq_a < *freq_b;
          }
        }

        // 上游 909c854：Yomitan score 降序（v2 词典落盘；v1 恒 0 = 此档恒平）。
        if (a.term.score != b.term.score) {
          return a.term.score > b.term.score;
        }

        auto a_reading_expr_match = a.term.expression == a.term.reading;
        auto b_reading_expr_match = b.term.expression == b.term.reading;
        return a_reading_expr_match > b_reading_expr_match;
      });

  if (results.size() > static_cast<size_t>(max_results)) {
    results.resize(max_results);
  }

  // Pitch is not read by the comparator, so it waits until after the resize:
  // only the <=max_results terms the user actually receives get enriched
  // (BUG-1304).
  for (auto& r : results) {
    query_.enrich_pitch(r.term);
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

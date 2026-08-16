#include "fushidicts/lookup.hpp"

#include <utf8.h>

#include <algorithm>
#include <climits>
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

// 上游 909c854 revert 了 4975788 的向量比较（作者自己否掉的实验：每次比较
// 分配+排序一个 vector，partial_sort 下纯浪费）；回到单一最小值比较。
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
      const int freq_a = get_freq_value_for_dict(a.term, dict_name);
      const int freq_b = get_freq_value_for_dict(b.term, dict_name);
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

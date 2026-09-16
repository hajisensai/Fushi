#include "fushidicts/deinflector.hpp"

#include <glaze/glaze.hpp>
#include <utf8.h>

#include "fushidicts/platform.hpp"

#include <algorithm>
#include <cstddef>
#include <map>
#include <optional>
#include <string>
#include <vector>

#define LOGE FUSHI_LOGE
#define LOGW FUSHI_LOGW

namespace fushidicts_json {

struct Rule {
  std::string type;
  std::string fromSuffix;
  std::string toSuffix;
  std::string fromPrefix;
  std::string toPrefix;
  std::string from;
  std::string to;
  std::vector<std::string> conditionsIn;
  std::vector<std::string> conditionsOut;
};

struct Transform {
  std::string name;
  std::string description;
  std::vector<Rule> rules;
  // 本组的 suffix/wholeWord 规则同时作用于短语动词的动词头（Yomitan 对 past / ing /
  // 3sg 三组做的 createPhrasalVerbInflectionsFromSuffixInflections）。
  bool phrasalVerb = false;
};

// Yomitan english-transforms.js 的 phrasalVerbParticles / phrasalVerbPrepositions：
// 那边是正则型 `other` 规则，JSON 表达不了，所以这里把词表声明成数据、匹配逻辑进引擎。
struct PhrasalVerbs {
  std::string condition;  // 动词头还原后的输出条件名（en: "v_phr"）
  std::vector<std::string> particles;
  std::vector<std::string> prepositions;
};

struct Condition {
  std::string name;
  bool isDictionaryForm = false;
  std::vector<std::string> subConditions;
};

struct Descriptor {
  std::string language;
  std::map<std::string, Condition> conditions;
  std::map<std::string, Transform> transforms;
  std::optional<PhrasalVerbs> phrasalVerbs;
};

}  // namespace fushidicts_json

template <>
struct glz::meta<fushidicts_json::Rule> {
  using T = fushidicts_json::Rule;
  static constexpr auto value = object(
    "type", &T::type,
    "fromSuffix", &T::fromSuffix,
    "toSuffix", &T::toSuffix,
    "fromPrefix", &T::fromPrefix,
    "toPrefix", &T::toPrefix,
    "from", &T::from,
    "to", &T::to,
    "conditionsIn", &T::conditionsIn,
    "conditionsOut", &T::conditionsOut
  );
};

template <>
struct glz::meta<fushidicts_json::Transform> {
  using T = fushidicts_json::Transform;
  static constexpr auto value = object(
    "name", &T::name,
    "description", &T::description,
    "rules", &T::rules,
    "phrasalVerb", &T::phrasalVerb
  );
};

template <>
struct glz::meta<fushidicts_json::PhrasalVerbs> {
  using T = fushidicts_json::PhrasalVerbs;
  static constexpr auto value = object(
    "condition", &T::condition,
    "particles", &T::particles,
    "prepositions", &T::prepositions
  );
};

template <>
struct glz::meta<fushidicts_json::Condition> {
  using T = fushidicts_json::Condition;
  static constexpr auto value = object(
    "name", &T::name,
    "isDictionaryForm", &T::isDictionaryForm,
    "subConditions", &T::subConditions
  );
};

template <>
struct glz::meta<fushidicts_json::Descriptor> {
  using T = fushidicts_json::Descriptor;
  static constexpr auto value = object(
    "language", &T::language,
    "conditions", &T::conditions,
    "transforms", &T::transforms,
    "phrasalVerbs", &T::phrasalVerbs
  );
};

// Implementation

uint64_t Deinflector::resolve_condition(const std::string& name) const {
  auto it = condition_bits_.find(name);
  return (it != condition_bits_.end()) ? it->second : 0;
}

uint64_t Deinflector::resolve_conditions(const std::vector<std::string>& names) const {
  uint64_t result = 0;
  for (const auto& name : names) {
    result |= resolve_condition(name);
  }
  return result;
}

int Deinflector::add_group(const TransformGroup& group) {
  groups_.push_back(group);
  return static_cast<int>(groups_.size() - 1);
}

// 同一门语言的短语动词配置可能分散在多份文件里（en.json 带词表与宾语插入规则，
// en_irregular.json 只给动词组打 phrasalVerb 标记），且 manifest 顺序不保证谁先加载：
// 这里按语言名取/建槽位，规则只记下标，词表晚到也能对上。
int Deinflector::phrasal_lang_index(const std::string& lang) {
  for (size_t i = 0; i < phrasal_langs_.size(); i++) {
    if (phrasal_langs_[i].lang == lang) return static_cast<int>(i);
  }
  phrasal_langs_.push_back({.lang = lang});
  return static_cast<int>(phrasal_langs_.size() - 1);
}

void Deinflector::load_transforms_json(const std::string& json) {
  fushidicts_json::Descriptor descriptor;
  auto ec = glz::read<glz::opts{.error_on_unknown_keys = false}>(descriptor, json);
  if (ec) {
    LOGE("failed to parse transforms JSON: %s", glz::format_error(ec, json).c_str());
    return;
  }

  const std::string& lang = descriptor.language;

  // Per-language bit allocation
  int next_bit = 0;
  auto allocate_bit = [&]() -> uint64_t {
    if (next_bit >= 64) {
      LOGW("language '%s' exceeds 64 condition bits, extra conditions ignored", lang.c_str());
      return 0;
    }
    return uint64_t{1} << next_bit++;
  };

  for (const auto& [key, cond] : descriptor.conditions) {
    std::string qualified = lang + ":" + key;
    if (condition_bits_.find(qualified) == condition_bits_.end()) {
      condition_bits_[qualified] = allocate_bit();
    }
  }

  // Expand sub-conditions (iterative fixed-point)
  bool changed = true;
  int iterations = 0;
  static constexpr int kMaxExpansionIterations = 100;
  while (changed && iterations < kMaxExpansionIterations) {
    changed = false;
    ++iterations;
    for (const auto& [key, cond] : descriptor.conditions) {
      if (cond.subConditions.empty()) continue;
      std::string qualified = lang + ":" + key;
      uint64_t expanded = condition_bits_[qualified];
      for (const auto& sub : cond.subConditions) {
        expanded |= resolve_condition(lang + ":" + sub);
      }
      if (expanded != condition_bits_[qualified]) {
        condition_bits_[qualified] = expanded;
        changed = true;
      }
    }
  }
  if (iterations >= kMaxExpansionIterations) {
    LOGW("language '%s': sub-condition expansion hit iteration limit, possible cycle", lang.c_str());
  }

  // Bare POS tag → accumulated bits from all languages. |= means if two
  // languages share a tag name (e.g. both define "v"), the bits merge.
  // Suffix matching naturally routes by language (日語 suffixes ≠ English),
  // so cross-language false positives in filter_by_pos are near-impossible.
  for (const auto& [key, _] : descriptor.conditions) {
    std::string qualified = lang + ":" + key;
    pos_to_condition_cache_[key] |= condition_bits_[qualified];
  }

  // 短语动词词表（Yomitan phrasalVerbParticles / phrasalVerbPrepositions）
  if (descriptor.phrasalVerbs.has_value()) {
    const auto& pv = *descriptor.phrasalVerbs;
    const uint64_t out_bits = resolve_condition(lang + ":" + pv.condition);
    if (out_bits == 0) {
      LOGW("language '%s': phrasalVerbs.condition '%s' is not a declared condition", lang.c_str(),
           pv.condition.c_str());
    }
    PhrasalLanguage& pl = phrasal_langs_[phrasal_lang_index(lang)];
    pl.conditions_out = out_bits;
    for (const auto& w : pv.particles) {
      pl.particles.insert(w);
      pl.words.insert(w);
    }
    for (const auto& w : pv.prepositions) {
      pl.words.insert(w);
    }
  }

  // Load transform rules
  for (const auto& [transform_key, transform] : descriptor.transforms) {
    int group_id = add_group({.name = transform.name, .description = transform.description});
    const int phrasal_lang = transform.phrasalVerb ? phrasal_lang_index(lang) : -1;

    for (const auto& rule : transform.rules) {
      uint64_t cond_in = 0;
      for (const auto& c : rule.conditionsIn) {
        cond_in |= resolve_condition(lang + ":" + c);
      }
      uint64_t cond_out = 0;
      for (const auto& c : rule.conditionsOut) {
        cond_out |= resolve_condition(lang + ":" + c);
      }

      if (rule.type == "suffix") {
        auto& vec = suffix_transforms_[rule.fromSuffix];
        vec.push_back({.from = rule.fromSuffix, .to = rule.toSuffix,
                       .conditions_in = cond_in, .conditions_out = cond_out,
                       .group_id = group_id, .is_whole_word = false,
                       .phrasal_lang = phrasal_lang});
        size_t len = utf8::distance(rule.fromSuffix.begin(), rule.fromSuffix.end());
        max_suffix_length_ = std::max(max_suffix_length_, len);
      } else if (rule.type == "prefix") {
        auto& vec = prefix_transforms_[rule.fromPrefix];
        vec.push_back({.from = rule.fromPrefix, .to = rule.toPrefix,
                       .conditions_in = cond_in, .conditions_out = cond_out,
                       .group_id = group_id});
        size_t len = utf8::distance(rule.fromPrefix.begin(), rule.fromPrefix.end());
        max_prefix_length_ = std::max(max_prefix_length_, len);
      } else if (rule.type == "wholeWord") {
        auto& vec = suffix_transforms_[rule.from];
        vec.push_back({.from = rule.from, .to = rule.to,
                       .conditions_in = cond_in, .conditions_out = cond_out,
                       .group_id = group_id, .is_whole_word = true,
                       .phrasal_lang = phrasal_lang});
        size_t len = utf8::distance(rule.from.begin(), rule.from.end());
        max_suffix_length_ = std::max(max_suffix_length_, len);
      } else if (rule.type == "phrasalVerbInterposedObject") {
        phrasal_langs_[phrasal_lang_index(lang)].interposed.push_back(
            {.conditions_in = cond_in, .conditions_out = cond_out, .group_id = group_id});
      }
    }
  }
}

uint64_t Deinflector::pos_to_conditions(const std::vector<std::string>& part_of_speech) const {
  uint64_t result = 0;
  for (const auto& p : part_of_speech) {
    if (p == "*") {
      // Simple dictionaries (MDX / StarDict / DSL) carry no per-term part of
      // speech, so their terms are stored with the wildcard rule "*". Returning
      // all condition bits makes filter_by_pos keep them for ANY deinflected
      // lookup (its `(dict_conditions & d.conditions) == 0` erase test can never
      // fire), instead of dropping every inflected-form hit. Yomitan term banks
      // carry real POS tags and never use "*", so they are unaffected.
      return ~uint64_t{0};
    }
    auto it = pos_to_condition_cache_.find(p);
    if (it != pos_to_condition_cache_.end()) {
      result |= it->second;
    }
  }
  return result;
}

std::vector<DeinflectionResult> Deinflector::deinflect(const std::string& text) const {
  std::vector<DeinflectionResult> results;
  std::vector<TransformGroup> trace;
  deinflect_recursive(text, 0, trace, results, 0);
  return results;
}

void Deinflector::deinflect_recursive(const std::string& text, uint64_t conditions,
                                      std::vector<TransformGroup>& trace,
                                      std::vector<DeinflectionResult>& results,
                                      int depth) const {
  size_t text_len = utf8::distance(text.begin(), text.end());
  if (text_len == 0) return;
  if (depth > kMaxRecursionDepth) return;

  results.emplace_back(text, conditions, trace);

  if (text_len == 1) return;

  // Suffix matching: scan from longest to shortest
  size_t start = std::min(max_suffix_length_, text_len);
  auto prefix_it = text.begin();
  utf8::advance(prefix_it, text_len - start, text.end());

  for (size_t i = start; i > 0; i--) {
    std::string suffix(prefix_it, text.end());
    auto it = suffix_transforms_.find(suffix);
    if (it != suffix_transforms_.end()) {
      std::string prefix(text.begin(), prefix_it);
      for (const auto& rule : it->second) {
        if (rule.is_whole_word && !prefix.empty()) continue;
        if (conditions != 0 && !(conditions & rule.conditions_in)) continue;
        std::string transformed = prefix + rule.to;
        trace.push_back(groups_[rule.group_id]);
        deinflect_recursive(transformed, rule.conditions_out, trace, results, depth + 1);
        trace.pop_back();
      }
    }
    if (i > 1) {
      utf8::next(prefix_it, text.end());
    }
  }

  // Prefix matching
  if (max_prefix_length_ > 0) {
    size_t prefix_scan = std::min(max_prefix_length_, text_len - 1);
    auto end_it = text.begin();

    for (size_t i = 1; i <= prefix_scan; i++) {
      utf8::next(end_it, text.end());
      std::string prefix(text.begin(), end_it);
      auto it = prefix_transforms_.find(prefix);
      if (it != prefix_transforms_.end()) {
        std::string remainder(end_it, text.end());
        for (const auto& rule : it->second) {
          if (conditions != 0 && !(conditions & rule.conditions_in)) continue;
          std::string transformed = rule.to + remainder;
          trace.push_back(groups_[rule.group_id]);
          deinflect_recursive(transformed, rule.conditions_out, trace, results, depth + 1);
          trace.pop_back();
        }
      }
    }
  }

  // 短语动词（放在最后、同样参与递归链：宾语插入 → 动词头还原 → …）
  if (!phrasal_langs_.empty()) {
    deinflect_phrasal(text, conditions, trace, results, depth);
  }
}

// 短语动词还原（BUG-2549）。Yomitan english-transforms.js 的两类 `other` 规则的
// 等价实现——JSON 表达不了正则，所以词表进数据、匹配进引擎：
//
//   1) 动词头变形：`^\w*<inflected> (?:WORDS)` → 把第一个空格前的动词头单独过一遍
//      打了 phrasalVerb 标记的 suffix/wholeWord 规则，小品词原样接回去，输出条件
//      是 phrasalVerbs.condition（en: v_phr）。"gave up" → "give up"、"walked away"
//      → "walk away"。Yomitan 只给 past/ing/3sg 三组生成，这里由数据标记决定，
//      en_irregular.json 的动词组也打了标记，所以替补形一样能还原。
//   2) 宾语插入：`^\w* (?:(?!\b(WORDS)\b).)+ (?:PARTICLES)` → 动词头之后、第一个
//      小品词之前若夹着一段不含任何短语动词用词的宾语，把宾语抠掉。"picked it up"
//      → "picked up"（条件 v_phr），再由 1) 链到 "pick up"。
//
// 与 Yomitan 的两处刻意差异：小品词按**整个空格分隔的 token** 匹配（Yomitan 的正则
// 不封尾，"gave upstairs" 也会被当成 "gave up…"）；动词头的 prefix 规则不参与
// （"will give up" 这种整串前缀由主循环的 prefix 匹配处理，不必重复）。
void Deinflector::deinflect_phrasal(const std::string& text, uint64_t conditions,
                                    std::vector<TransformGroup>& trace,
                                    std::vector<DeinflectionResult>& results,
                                    int depth) const {
  const size_t sp = text.find(' ');
  if (sp == std::string::npos || sp == 0 || sp + 1 >= text.size()) return;
  const std::string head = text.substr(0, sp);
  const std::string tail = text.substr(sp + 1);
  const std::string next = tail.substr(0, tail.find(' '));
  if (next.empty()) return;

  for (size_t li = 0; li < phrasal_langs_.size(); li++) {
    const PhrasalLanguage& pl = phrasal_langs_[li];
    const bool next_is_phrasal_word = pl.words.count(next) > 0;

    // 1) 动词头变形：与主循环同一套后缀扫描，只放行本语言打了标记的规则。
    if (next_is_phrasal_word) {
      const size_t head_len = utf8::distance(head.begin(), head.end());
      const size_t start = std::min(max_suffix_length_, head_len);
      auto prefix_it = head.begin();
      utf8::advance(prefix_it, head_len - start, head.end());
      for (size_t i = start; i > 0; i--) {
        std::string suffix(prefix_it, head.end());
        auto it = suffix_transforms_.find(suffix);
        if (it != suffix_transforms_.end()) {
          std::string prefix(head.begin(), prefix_it);
          for (const auto& rule : it->second) {
            if (rule.phrasal_lang != static_cast<int>(li)) continue;
            if (rule.is_whole_word && !prefix.empty()) continue;
            if (conditions != 0 && !(conditions & rule.conditions_in)) continue;
            std::string transformed = prefix + rule.to + " " + tail;
            trace.push_back(groups_[rule.group_id]);
            deinflect_recursive(transformed, pl.conditions_out, trace, results, depth + 1);
            trace.pop_back();
          }
        }
        if (i > 1) {
          utf8::next(prefix_it, head.end());
        }
      }
    }

    // 2) 宾语插入：tail 的 token 从头数，遇到的第一个短语动词用词必须是小品词，
    //    且它前面至少有一个 token（宾语）。
    if (!next_is_phrasal_word && !pl.interposed.empty()) {
      size_t pos = 0;
      size_t particle_start = std::string::npos;
      while (pos < tail.size()) {
        size_t end = tail.find(' ', pos);
        if (end == std::string::npos) end = tail.size();
        const std::string token = tail.substr(pos, end - pos);
        if (pl.words.count(token) > 0) {
          if (pl.particles.count(token) > 0) particle_start = pos;
          break;
        }
        pos = end + 1;
      }
      if (particle_start != std::string::npos && particle_start > 0) {
        for (const auto& rule : pl.interposed) {
          if (conditions != 0 && !(conditions & rule.conditions_in)) continue;
          std::string transformed = head + " " + tail.substr(particle_start);
          trace.push_back(groups_[rule.group_id]);
          deinflect_recursive(transformed, rule.conditions_out, trace, results, depth + 1);
          trace.pop_back();
        }
      }
    }
  }
}

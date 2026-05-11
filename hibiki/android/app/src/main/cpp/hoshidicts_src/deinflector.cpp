#include "hoshidicts/deinflector.hpp"

#include <glaze/glaze.hpp>
#include <utf8.h>

#include <android/log.h>

#include <algorithm>
#include <cstddef>
#include <map>
#include <string>
#include <vector>

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "hoshidicts", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "hoshidicts", __VA_ARGS__)

namespace hoshidicts_json {

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
};

}  // namespace hoshidicts_json

template <>
struct glz::meta<hoshidicts_json::Rule> {
  using T = hoshidicts_json::Rule;
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
struct glz::meta<hoshidicts_json::Transform> {
  using T = hoshidicts_json::Transform;
  static constexpr auto value = object(
    "name", &T::name,
    "description", &T::description,
    "rules", &T::rules
  );
};

template <>
struct glz::meta<hoshidicts_json::Condition> {
  using T = hoshidicts_json::Condition;
  static constexpr auto value = object(
    "name", &T::name,
    "isDictionaryForm", &T::isDictionaryForm,
    "subConditions", &T::subConditions
  );
};

template <>
struct glz::meta<hoshidicts_json::Descriptor> {
  using T = hoshidicts_json::Descriptor;
  static constexpr auto value = object(
    "language", &T::language,
    "conditions", &T::conditions,
    "transforms", &T::transforms
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

void Deinflector::load_transforms_json(const std::string& json) {
  hoshidicts_json::Descriptor descriptor;
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
  while (changed) {
    changed = false;
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

  // Bare POS tag → accumulated bits from all languages. |= means if two
  // languages share a tag name (e.g. both define "v"), the bits merge.
  // Suffix matching naturally routes by language (日語 suffixes ≠ English),
  // so cross-language false positives in filter_by_pos are near-impossible.
  for (const auto& [key, _] : descriptor.conditions) {
    std::string qualified = lang + ":" + key;
    pos_to_condition_cache_[key] |= condition_bits_[qualified];
  }

  // Load transform rules
  for (const auto& [transform_key, transform] : descriptor.transforms) {
    int group_id = add_group({.name = transform.name, .description = transform.description});

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
                       .group_id = group_id, .is_whole_word = false});
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
                       .group_id = group_id, .is_whole_word = true});
        size_t len = utf8::distance(rule.from.begin(), rule.from.end());
        max_suffix_length_ = std::max(max_suffix_length_, len);
      }
    }
  }
}

uint64_t Deinflector::pos_to_conditions(const std::vector<std::string>& part_of_speech) const {
  uint64_t result = 0;
  for (const auto& p : part_of_speech) {
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
}

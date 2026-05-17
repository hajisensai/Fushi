#pragma once

#include <string>
#include <unordered_map>
#include <vector>
#include <cstdint>
#include <cstddef>

struct TransformGroup {
  std::string name;
  std::string description;
};

struct DeinflectionResult {
  std::string text;
  uint64_t conditions;
  std::vector<TransformGroup> trace;
};

class Deinflector {
 public:
  Deinflector() : max_suffix_length_(0), max_prefix_length_(0) {}

  void load_transforms_json(const std::string& json);
  std::vector<DeinflectionResult> deinflect(const std::string& text) const;
  uint64_t pos_to_conditions(const std::vector<std::string>& part_of_speech) const;

 private:
  struct SuffixRule {
    std::string from;
    std::string to;
    uint64_t conditions_in;
    uint64_t conditions_out;
    int group_id;
    bool is_whole_word;
  };

  struct PrefixRule {
    std::string from;
    std::string to;
    uint64_t conditions_in;
    uint64_t conditions_out;
    int group_id;
  };

  static constexpr int kMaxRecursionDepth = 10;

  void deinflect_recursive(const std::string& text, uint64_t conditions,
                           std::vector<TransformGroup>& trace,
                           std::vector<DeinflectionResult>& results,
                           int depth) const;

  uint64_t resolve_condition(const std::string& name) const;
  uint64_t resolve_conditions(const std::vector<std::string>& names) const;

  int add_group(const TransformGroup& group);

  std::unordered_map<std::string, uint64_t> condition_bits_;
  std::unordered_map<std::string, uint64_t> pos_to_condition_cache_;

  std::unordered_map<std::string, std::vector<SuffixRule>> suffix_transforms_;
  std::unordered_map<std::string, std::vector<PrefixRule>> prefix_transforms_;
  std::vector<TransformGroup> groups_;
  size_t max_suffix_length_;
  size_t max_prefix_length_;
};

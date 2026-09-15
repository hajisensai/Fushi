#pragma once

#include <string>
#include <unordered_map>
#include <unordered_set>
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
    // >= 0：这条规则同时作用于短语动词的动词头（"gave up" → "give up"），值是
    // phrasal_langs_ 的下标；-1 = 只作用于整个候选串。见 deinflect_phrasal。
    int phrasal_lang = -1;
  };

  struct PrefixRule {
    std::string from;
    std::string to;
    uint64_t conditions_in;
    uint64_t conditions_out;
    int group_id;
  };

  // 「宾语插在动词与小品词之间」规则（Yomitan `phrasalVerbInterposedObjectRule`）：
  // "picked it up" → "picked up"，再由动词头规则链到 "pick up"。
  struct InterposedObjectRule {
    uint64_t conditions_in;
    uint64_t conditions_out;
    int group_id;
  };

  // 一门语言的短语动词配置（transforms JSON 顶层 `phrasalVerbs` 块，目前只有 en.json）。
  struct PhrasalLanguage {
    std::string lang;
    uint64_t conditions_out = 0;  // `phrasalVerbs.condition` 解析出的条件位（en: v_phr）
    std::unordered_set<std::string> words;      // particles ∪ prepositions
    std::unordered_set<std::string> particles;  // 宾语插入规则只认 particles
    std::vector<InterposedObjectRule> interposed;
  };

  static constexpr int kMaxRecursionDepth = 10;

  void deinflect_recursive(const std::string& text, uint64_t conditions,
                           std::vector<TransformGroup>& trace,
                           std::vector<DeinflectionResult>& results,
                           int depth) const;

  void deinflect_phrasal(const std::string& text, uint64_t conditions,
                         std::vector<TransformGroup>& trace,
                         std::vector<DeinflectionResult>& results,
                         int depth) const;

  uint64_t resolve_condition(const std::string& name) const;
  uint64_t resolve_conditions(const std::vector<std::string>& names) const;

  int add_group(const TransformGroup& group);
  int phrasal_lang_index(const std::string& lang);

  std::unordered_map<std::string, uint64_t> condition_bits_;
  std::unordered_map<std::string, uint64_t> pos_to_condition_cache_;

  std::unordered_map<std::string, std::vector<SuffixRule>> suffix_transforms_;
  std::unordered_map<std::string, std::vector<PrefixRule>> prefix_transforms_;
  std::vector<PhrasalLanguage> phrasal_langs_;
  std::vector<TransformGroup> groups_;
  size_t max_suffix_length_;
  size_t max_prefix_length_;
};

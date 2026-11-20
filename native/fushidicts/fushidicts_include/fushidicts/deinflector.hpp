#pragma once

#include <string>
#include <string_view>
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
  // 这条还原链用的是哪门语言的规则（Deinflector::language_name 的下标）；-1 = 没有
  // 经过任何规则（原文本身）。一条链只用一门语言的规则，见 Deinflector::deinflect。
  int language = -1;
};

class Deinflector {
 public:
  Deinflector() : max_suffix_length_(0), max_prefix_length_(0) {}

  // 「全部语言」的掩码（deinflect 的默认值）。
  static constexpr uint64_t kAllLanguages = ~uint64_t{0};

  void load_transforms_json(const std::string& json);
  // 还原 [text]。每条规则属于它所在变形表的语言，**一条链只用一门语言的规则**，
  // 结果因此带得上语言（DeinflectionResult::language），调用方据此判断哪本词典该接受
  // 它。变形表是所有语言一起装的，链首什么规则都能起手——Our 会被 sq 的 -ur 规则
  // 还原成 O——挡不挡由调用方按词典语言决定，这里只负责标清楚。
  // [allowed_languages]：第 i 位为 1 = 允许 language_name(i) 的规则起手；调用方已知
  // 没有任何词典会接受的语言不必展开（见 Lookup::lookup）。下标 >= 64 的语言恒允许。
  std::vector<DeinflectionResult> deinflect(const std::string& text,
                                            uint64_t allowed_languages = kAllLanguages) const;
  // 已装载变形表的语言数；language_name(i) 是第 i 门的归一标签（fushi::primary_language_tag）。
  size_t language_count() const { return languages_.size(); }
  const std::string& language_name(int language) const { return languages_[static_cast<size_t>(language)]; }
  // 归一标签 [primary] 对应的语言下标；没有这门语言的变形表返回 -1。
  int language_id(std::string_view primary) const;
  uint64_t pos_to_conditions(const std::vector<std::string>& part_of_speech) const;
  // 与 pos_to_conditions(把 [rules] 按空白切开) 逐位相同：空白取 C locale 的
  // isspace 六个字符（istringstream >> 的切分口径），"*" 仍是通配。原地扫描、不建
  // 中间 vector / stringstream——Lookup::filter_by_pos 对每个候选命中都调一次。
  uint64_t rules_to_conditions(std::string_view rules) const;

 private:
  struct SuffixRule {
    std::string from;
    std::string to;
    uint64_t conditions_in;
    uint64_t conditions_out;
    int group_id;
    bool is_whole_word;
    int language = -1;  // languages_ 的下标
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
    int language = -1;  // languages_ 的下标
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
    int language = -1;  // languages_ 的下标
    uint64_t conditions_out = 0;  // `phrasalVerbs.condition` 解析出的条件位（en: v_phr）
    std::unordered_set<std::string> words;      // particles ∪ prepositions
    std::unordered_set<std::string> particles;  // 宾语插入规则只认 particles
    std::vector<InterposedObjectRule> interposed;
  };

  static constexpr int kMaxRecursionDepth = 10;

  // [language]：链上已用规则的语言（-1 = 链首）；[allowed_languages] 只约束链首。
  void deinflect_recursive(const std::string& text, uint64_t conditions,
                           std::vector<TransformGroup>& trace,
                           std::vector<DeinflectionResult>& results,
                           int depth, int language, uint64_t allowed_languages) const;

  void deinflect_phrasal(const std::string& text, uint64_t conditions,
                         std::vector<TransformGroup>& trace,
                         std::vector<DeinflectionResult>& results,
                         int depth, int language, uint64_t allowed_languages) const;

  uint64_t resolve_condition(const std::string& name) const;
  uint64_t resolve_conditions(const std::vector<std::string>& names) const;

  int add_group(const TransformGroup& group);
  int phrasal_lang_index(const std::string& lang);
  int language_index(const std::string& primary);

  std::unordered_map<std::string, uint64_t> condition_bits_;
  std::unordered_map<std::string, uint64_t> pos_to_condition_cache_;

  std::unordered_map<std::string, std::vector<SuffixRule>> suffix_transforms_;
  std::unordered_map<std::string, std::vector<PrefixRule>> prefix_transforms_;
  std::vector<PhrasalLanguage> phrasal_langs_;
  std::vector<TransformGroup> groups_;
  std::vector<std::string> languages_;
  size_t max_suffix_length_;
  size_t max_prefix_length_;
};

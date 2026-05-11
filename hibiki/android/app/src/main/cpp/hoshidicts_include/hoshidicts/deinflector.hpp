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
  uint32_t conditions;
  std::vector<TransformGroup> trace;
};

class Deinflector {
 public:
  Deinflector();
  std::vector<DeinflectionResult> deinflect(const std::string& text) const;
  static uint32_t pos_to_conditions(const std::vector<std::string>& part_of_speech);

 private:
  struct Rule {
    std::string from;
    std::string to;
    uint32_t conditions_in;
    uint32_t conditions_out;
    int group_id;
  };

  enum Conditions : uint32_t {
    NONE = 0,
    V1D = 1 << 0,
    V1P = 1 << 1,
    V5D = 1 << 2,
    V5SS = 1 << 3,
    V5SP = 1 << 4,
    VK = 1 << 5,
    VS = 1 << 6,
    VZ = 1 << 7,
    ADJ_I = 1 << 8,
    MASU = 1 << 9,
    MASEN = 1 << 10,
    TE = 1 << 11,
    BA = 1 << 12,
    KU = 1 << 13,
    TA = 1 << 14,
    NN = 1 << 15,
    NASAI = 1 << 16,
    YA = 1 << 17,
    V1 = V1D | V1P,
    V5S = V5SS | V5SP,
    V5 = V5D | V5S,
    V = V1 | V5 | VK | VS | VZ,

    // English conditions (bits 18-24)
    EN_V = 1 << 18,
    EN_V_PHR = 1 << 19,
    EN_N = 1 << 20,
    EN_NP = 1 << 21,
    EN_NS = 1 << 22,
    EN_ADJ = 1 << 23,
    EN_ADV = 1 << 24,
    // Compound English conditions (matching Yomitan subConditions)
    EN_V_ALL = EN_V | EN_V_PHR,
    EN_N_ALL = EN_N | EN_NP | EN_NS,
  };

  void deinflect_recursive(const std::string& text, uint32_t conditions, std::vector<TransformGroup>& trace,
                           std::vector<DeinflectionResult>& results) const;

  void init_transforms();
  void init_english_transforms();

  int add_group(const TransformGroup& group);
  void add_rule(const Rule& rule);
  void add_irregular(std::string_view suffix, uint32_t conditions_in, uint32_t conditions_out, int group_id);

  std::unordered_map<std::string, std::vector<Rule>> transforms_;
  std::vector<TransformGroup> groups_;
  size_t max_length_;
};
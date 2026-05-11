// rules and descriptions adopted from
// https://github.com/yomidevs/yomitan/blob/master/ext/js/language/ja/japanese-transforms.js
#include "hoshidicts/deinflector.hpp"

#include <utf8.h>

#include <algorithm>
#include <array>
#include <cstddef>

Deinflector::Deinflector() : max_length_(0) {
  init_transforms();
  init_english_transforms();
}

namespace {
constexpr std::string_view shimau_english_description =
    "1. Shows a sense of regret/surprise when you did have volition in doing something, but it turned out to be bad to "
    "do.\n"
    "2. Shows perfective/punctual achievement. This shows that an action has been completed.\n"
    "3. Shows unintentional action–“accidentally”.\n";

constexpr std::string_view passive_english_description =
    "1. Indicates an action received from an action performer.\n"
    "2. Expresses respect for the subject of action performer.\n";

constexpr std::array<std::pair<std::string_view, std::string_view>, 4> iku_verbs = {{
    {"いく", "いっ"},
    {"行く", "行っ"},
    {"逝く", "逝っ"},
    {"往く", "往っ"},
}};

constexpr std::array<std::string_view, 12> godan_u_special_verbs = {
    "こう", "とう", "請う", "乞う", "恋う", "問う", "訪う", "宣う", "曰う", "給う", "賜う", "揺蕩う",
};

constexpr std::array<std::pair<std::string_view, std::string_view>, 3> fu_verb_te_conjugations = {{
    {"のたまう", "のたもう"},
    {"たまう", "たもう"},
    {"たゆたう", "たゆとう"},
}};
}

void Deinflector::add_irregular(std::string_view suffix, uint32_t conditions_in, uint32_t conditions_out,
                                int group_id) {
  for (auto [verb, prefix] : iku_verbs) {
    add_rule({
        .from = std::string(prefix) + std::string(suffix),
        .to = std::string(verb),
        .conditions_in = conditions_in,
        .conditions_out = conditions_out,
        .group_id = group_id,
    });
  }

  for (auto verb : godan_u_special_verbs) {
    add_rule({
        .from = std::string(verb) + std::string(suffix),
        .to = std::string(verb),
        .conditions_in = conditions_in,
        .conditions_out = conditions_out,
        .group_id = group_id,
    });
  }

  for (auto [verb, te_root] : fu_verb_te_conjugations) {
    add_rule({
        .from = std::string(te_root) + std::string(suffix),
        .to = std::string(verb),
        .conditions_in = conditions_in,
        .conditions_out = conditions_out,
        .group_id = group_id,
    });
  }
}

void Deinflector::init_transforms() {
  int id =
      add_group({.name = "-ば",
                 .description = "1. Conditional form; shows that the previous stated condition\'s establishment is the "
                                "condition for the latter stated condition to occur.\n"
                                "2. Shows a trigger for a latter stated perception or judgment.\n"
                                "Usage: Attach ば to the hypothetical form (仮定形) of verbs and i-adjectives."});
  add_rule({.from = "ければ", .to = "い", .conditions_in = BA, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "えば", .to = "う", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "けば", .to = "く", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "げば", .to = "ぐ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "せば", .to = "す", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "てば", .to = "つ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ねば", .to = "ぬ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "べば", .to = "ぶ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "めば", .to = "む", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "れば", .to = "る", .conditions_in = BA, .conditions_out = V1 | V5 | VK | VS | VZ, .group_id = id});
  add_rule({.from = "れば", .to = "", .conditions_in = BA, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-ゃ", .description = "Contraction of -ば."});
  add_rule({.from = "けりゃ", .to = "ければ", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "きゃ", .to = "ければ", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "や", .to = "えば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "きゃ", .to = "けば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "ぎゃ", .to = "げば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "しゃ", .to = "せば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "ちゃ", .to = "てば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "にゃ", .to = "ねば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "びゃ", .to = "べば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "みゃ", .to = "めば", .conditions_in = YA, .conditions_out = BA, .group_id = id});
  add_rule({.from = "りゃ", .to = "れば", .conditions_in = YA, .conditions_out = BA, .group_id = id});

  id = add_group({.name = "-ちゃ",
                  .description = "Contraction of ～ては.\n"
                                 "1. Explains how something always happens under the condition that it marks.\n"
                                 "2. Expresses the repetition (of a series of) actions.\n"
                                 "3. Indicates a hypothetical situation in which the speaker gives a (negative) "
                                 "evaluation about the other party\'s intentions.\n"
                                 "4. Used in \"Must Not\" patterns like ～てはいけない.\n"
                                 "Usage: Attach は after the て-form of verbs, contract ては into ちゃ."});
  add_rule({.from = "ちゃ", .to = "る", .conditions_in = V5, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いじゃ", .to = "ぐ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いちゃ", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しちゃ", .to = "す", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃ", .to = "う", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃ", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃ", .to = "つ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃ", .to = "る", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃ", .to = "ぬ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃ", .to = "ぶ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃ", .to = "む", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じちゃ", .to = "ずる", .conditions_in = V5, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しちゃ", .to = "する", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ちゃ", .to = "為る", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きちゃ", .to = "くる", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ちゃ", .to = "来る", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ちゃ", .to = "來る", .conditions_in = V5, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ちゃう",
                  .description = "Contraction of -しまう.\n" + std::string(shimau_english_description) +
                                 "Usage: Attach しまう after the て-form of verbs, contract てしまう into ちゃう."});
  add_rule({.from = "ちゃう", .to = "る", .conditions_in = V5, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いじゃう", .to = "ぐ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いちゃう", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しちゃう", .to = "す", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃう", .to = "う", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃう", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃう", .to = "つ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちゃう", .to = "る", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃう", .to = "ぬ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃう", .to = "ぶ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじゃう", .to = "む", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じちゃう", .to = "ずる", .conditions_in = V5, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しちゃう", .to = "する", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ちゃう", .to = "為る", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きちゃう", .to = "くる", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ちゃう", .to = "来る", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ちゃう", .to = "來る", .conditions_in = V5, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ちまう",
                  .description = "Contraction of -しまう.\n" + std::string(shimau_english_description) +
                                 "Usage: Attach しまう after the て-form of verbs, contract てしまう into ちまう."});
  add_rule({.from = "ちまう", .to = "る", .conditions_in = V5, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いじまう", .to = "ぐ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いちまう", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しちまう", .to = "す", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちまう", .to = "う", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちまう", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちまう", .to = "つ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "っちまう", .to = "る", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじまう", .to = "ぬ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじまう", .to = "ぶ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んじまう", .to = "む", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じちまう", .to = "ずる", .conditions_in = V5, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しちまう", .to = "する", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ちまう", .to = "為る", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きちまう", .to = "くる", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ちまう", .to = "来る", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ちまう", .to = "來る", .conditions_in = V5, .conditions_out = VK, .group_id = id});

  id = add_group(
      {.name = "-しまう",
       .description = std::string(shimau_english_description) + "Usage: Attach しまう after the て-form of verbs."});
  add_rule({.from = "てしまう", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でしまう", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-なさい",
                  .description = "Polite imperative suffix.\n"
                                 "Usage: Attach なさい after the continuative form (連用形) of verbs."});
  add_rule({.from = "なさい", .to = "る", .conditions_in = NASAI, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いなさい", .to = "う", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きなさい", .to = "く", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎなさい", .to = "ぐ", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しなさい", .to = "す", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちなさい", .to = "つ", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "になさい", .to = "ぬ", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びなさい", .to = "ぶ", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みなさい", .to = "む", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りなさい", .to = "る", .conditions_in = NASAI, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じなさい", .to = "ずる", .conditions_in = NASAI, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しなさい", .to = "する", .conditions_in = NASAI, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為なさい", .to = "為る", .conditions_in = NASAI, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きなさい", .to = "くる", .conditions_in = NASAI, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来なさい", .to = "来る", .conditions_in = NASAI, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來なさい", .to = "來る", .conditions_in = NASAI, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-そう",
                  .description =
                      "Appearing that; looking like.\n"
                      "Usage: Attach そう to the continuative form (連用形) of verbs, or to the stem of adjectives."});
  add_rule({.from = "そう", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "そう", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いそう", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きそう", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎそう", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しそう", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちそう", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "にそう", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びそう", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みそう", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りそう", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じそう", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しそう", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為そう", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きそう", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来そう", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來そう", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id =
      add_group({.name = "-すぎる",
                 .description =
                     "Shows something \"is too...\" or someone is doing something \"too much\".\n"
                     "Usage: Attach すぎる to the continuative form (連用形) of verbs, or to the stem of adjectives."});
  add_rule({.from = "すぎる", .to = "い", .conditions_in = V1, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "すぎる", .to = "る", .conditions_in = V1, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いすぎる", .to = "う", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きすぎる", .to = "く", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎすぎる", .to = "ぐ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しすぎる", .to = "す", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちすぎる", .to = "つ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "にすぎる", .to = "ぬ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びすぎる", .to = "ぶ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みすぎる", .to = "む", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りすぎる", .to = "る", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じすぎる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しすぎる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為すぎる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きすぎる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来すぎる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來すぎる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id =
      add_group({.name = "-過ぎる",
                 .description =
                     "Shows something \"is too...\" or someone is doing something \"too much\".\n"
                     "Usage: Attach すぎる to the continuative form (連用形) of verbs, or to the stem of adjectives."});
  add_rule({.from = "過ぎる", .to = "い", .conditions_in = V1, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "過ぎる", .to = "る", .conditions_in = V1, .conditions_out = V1, .group_id = id});
  add_rule({.from = "い過ぎる", .to = "う", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "き過ぎる", .to = "く", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎ過ぎる", .to = "ぐ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "し過ぎる", .to = "す", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ち過ぎる", .to = "つ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "に過ぎる", .to = "ぬ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "び過ぎる", .to = "ぶ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "み過ぎる", .to = "む", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "り過ぎる", .to = "る", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じ過ぎる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "し過ぎる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為過ぎる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "き過ぎる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来過ぎる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來過ぎる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id = add_group(
      {.name = "-たい",
       .description =
           "1. Expresses the feeling of desire or hope.\n"
           "2. Used in ...たいと思います, an indirect way of saying what the speaker intends to do.\n"
           "Usage: Attach たい to the continuative form (連用形) of verbs. たい itself conjugates as i-adjective."});
  add_rule({.from = "たい", .to = "る", .conditions_in = ADJ_I, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いたい", .to = "う", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きたい", .to = "く", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎたい", .to = "ぐ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "したい", .to = "す", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちたい", .to = "つ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "にたい", .to = "ぬ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びたい", .to = "ぶ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みたい", .to = "む", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りたい", .to = "る", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じたい", .to = "ずる", .conditions_in = ADJ_I, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "したい", .to = "する", .conditions_in = ADJ_I, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為たい", .to = "為る", .conditions_in = ADJ_I, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きたい", .to = "くる", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来たい", .to = "来る", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來たい", .to = "來る", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-たら",
                  .description = "1. Denotes the latter stated event is a continuation of the previous stated event.\n"
                                 "2. Assumes that a matter has been completed or concluded.\n"
                                 "Usage: Attach たら to the continuative form (連用形) of verbs after euphonic change "
                                 "form, かったら to the stem of i-adjectives."});
  add_rule({.from = "かったら", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "たら", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いたら", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いだら", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "したら", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったら", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったら", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったら", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだら", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだら", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだら", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じたら", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "したら", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為たら", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きたら", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来たら", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來たら", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_irregular("たら", NONE, V5, id);
  add_rule({.from = "ましたら", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-たり",
                  .description =
                      "1. Shows two actions occurring back and forth (when used with two verbs).\n"
                      "2. Shows examples of actions and states (when used with multiple verbs and adjectives).\n"
                      "Usage: Attach たり to the continuative form (連用形) of verbs after euphonic change form, "
                      "かったり to the stem of i-adjectives"});
  add_rule({.from = "かったり", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "たり", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いたり", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いだり", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "したり", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったり", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったり", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ったり", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだり", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだり", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだり", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じたり", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "したり", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為たり", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きたり", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来たり", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來たり", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_irregular("たり", NONE, V5, id);

  id = add_group(
      {.name = "-て",
       .description =
           "て-form.\n"
           "It has a myriad of meanings. Primarily, it is a conjunctive particle that connects two clauses together.\n"
           "Usage: Attach て to the continuative form (連用形) of verbs after euphonic change form, くて to the stem "
           "of i-adjectives."});
  add_rule({.from = "くて", .to = "い", .conditions_in = TE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "て", .to = "る", .conditions_in = TE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いて", .to = "く", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いで", .to = "ぐ", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "して", .to = "す", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "って", .to = "う", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "って", .to = "つ", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "って", .to = "る", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んで", .to = "ぬ", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んで", .to = "ぶ", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んで", .to = "む", .conditions_in = TE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じて", .to = "ずる", .conditions_in = TE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "して", .to = "する", .conditions_in = TE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為て", .to = "為る", .conditions_in = TE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きて", .to = "くる", .conditions_in = TE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来て", .to = "来る", .conditions_in = TE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來て", .to = "來る", .conditions_in = TE, .conditions_out = VK, .group_id = id});
  add_irregular("て", TE, V5, id);
  add_rule({.from = "まして", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-ず",
                  .description = "1. Negative form of verbs.\n"
                                 "2. Continuative form (連用形) of the particle ぬ (nu).\n"
                                 "Usage: Attach ず to the irrealis form (未然形) of verbs."});
  add_rule({.from = "ず", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かず", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がず", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さず", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たず", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なず", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばず", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まず", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らず", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わず", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜず", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せず", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ず", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こず", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ず", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ず", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ぬ",
                  .description = "Negative form of verbs.\n"
                                 "Usage: Attach ぬ to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せぬ"});
  add_rule({.from = "ぬ", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かぬ", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がぬ", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さぬ", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たぬ", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なぬ", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばぬ", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まぬ", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らぬ", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わぬ", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜぬ", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せぬ", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ぬ", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こぬ", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ぬ", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ぬ", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ん",
                  .description = "Negative form of verbs; a sound change of ぬ.\n"
                                 "Usage: Attach ん to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せん"});
  add_rule({.from = "ん", .to = "る", .conditions_in = NN, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かん", .to = "く", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がん", .to = "ぐ", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さん", .to = "す", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たん", .to = "つ", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なん", .to = "ぬ", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばん", .to = "ぶ", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まん", .to = "む", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らん", .to = "る", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わん", .to = "う", .conditions_in = NN, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜん", .to = "ずる", .conditions_in = NN, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せん", .to = "する", .conditions_in = NN, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ん", .to = "為る", .conditions_in = NN, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こん", .to = "くる", .conditions_in = NN, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ん", .to = "来る", .conditions_in = NN, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ん", .to = "來る", .conditions_in = NN, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-んばかり",
                  .description =
                      "Shows an action or condition is on the verge of occurring, or an excessive/extreme degree.\n"
                      "Usage: Attach んばかり to the irrealis form (未然形) of verbs.\n"
                      "する becomes せんばかり"});
  add_rule({.from = "んばかり", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かんばかり", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がんばかり", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さんばかり", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たんばかり", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なんばかり", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばんばかり", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まんばかり", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らんばかり", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わんばかり", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜんばかり", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せんばかり", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為んばかり", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こんばかり", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来んばかり", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來んばかり", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-んとする",
                  .description = "1. Shows the speaker's will or intention.\n"
                                 "2. Shows an action or condition is on the verge of occurring.\n"
                                 "Usage: Attach んとする to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せんとする"});
  add_rule({.from = "んとする", .to = "る", .conditions_in = VS, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かんとする", .to = "く", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がんとする", .to = "ぐ", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さんとする", .to = "す", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たんとする", .to = "つ", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なんとする", .to = "ぬ", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばんとする", .to = "ぶ", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まんとする", .to = "む", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らんとする", .to = "る", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わんとする", .to = "う", .conditions_in = VS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜんとする", .to = "ずる", .conditions_in = VS, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せんとする", .to = "する", .conditions_in = VS, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為んとする", .to = "為る", .conditions_in = VS, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こんとする", .to = "くる", .conditions_in = VS, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来んとする", .to = "来る", .conditions_in = VS, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來んとする", .to = "來る", .conditions_in = VS, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-む",
                  .description = "Archaic.\n"
                                 "1. Shows an inference of a certain matter.\n"
                                 "2. Shows speaker's intention.\n"
                                 "Usage: Attach む to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せむ"});
  add_rule({.from = "む", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かむ", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がむ", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さむ", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たむ", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なむ", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばむ", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まむ", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らむ", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わむ", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜむ", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せむ", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為む", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こむ", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来む", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來む", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ざる",
                  .description = "Negative form of verbs.\n"
                                 "Usage: Attach ざる to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せざる"});
  add_rule({.from = "ざる", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かざる", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がざる", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さざる", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たざる", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なざる", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばざる", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まざる", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らざる", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わざる", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜざる", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せざる", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ざる", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こざる", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ざる", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ざる", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-ねば",
                  .description = "1. Shows a hypothetical negation; if not ...\n"
                                 "2. Shows a must. Used with or without ならぬ.\n"
                                 "Usage: Attach ねば to the irrealis form (未然形) of verbs.\n"
                                 "する becomes せねば"});
  add_rule({.from = "ねば", .to = "る", .conditions_in = BA, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かねば", .to = "く", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がねば", .to = "ぐ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さねば", .to = "す", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たねば", .to = "つ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なねば", .to = "ぬ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばねば", .to = "ぶ", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まねば", .to = "む", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らねば", .to = "る", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わねば", .to = "う", .conditions_in = BA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぜねば", .to = "ずる", .conditions_in = BA, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せねば", .to = "する", .conditions_in = BA, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ねば", .to = "為る", .conditions_in = BA, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こねば", .to = "くる", .conditions_in = BA, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ねば", .to = "来る", .conditions_in = BA, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ねば", .to = "來る", .conditions_in = BA, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-く", .description = "Adverbial form of i-adjectives."});
  add_rule({.from = "く", .to = "い", .conditions_in = KU, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "causative",
                  .description = "Describes the intention to make someone do something.\n"
                                 "Usage: Attach させる to the irrealis form (未然形) of ichidan verbs and くる.\n"
                                 "Attach せる to the irrealis form (未然形) of godan verbs and する.\n"
                                 "It itself conjugates as an ichidan verb."});
  add_rule({.from = "させる", .to = "る", .conditions_in = V1, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かせる", .to = "く", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がせる", .to = "ぐ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "させる", .to = "す", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たせる", .to = "つ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なせる", .to = "ぬ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばせる", .to = "ぶ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ませる", .to = "む", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らせる", .to = "る", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わせる", .to = "う", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じさせる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "ぜさせる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "させる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為せる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "せさせる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為させる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こさせる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来させる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來させる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "short causative",
                  .description = "Contraction of the causative form.\n"
                                 "Describes the intention to make someone do something.\n"
                                 "Usage: Attach す to the irrealis form (未然形) of godan verbs.\n"
                                 "Attach さす to the dictionary form (終止形) of ichidan verbs.\n"
                                 "する becomes さす, くる becomes こさす.\n"
                                 "It itself conjugates as an godan verb."});
  add_rule({.from = "さす", .to = "る", .conditions_in = V5SS, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かす", .to = "く", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がす", .to = "ぐ", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さす", .to = "す", .conditions_in = V5SS, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たす", .to = "つ", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なす", .to = "ぬ", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばす", .to = "ぶ", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ます", .to = "む", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らす", .to = "る", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わす", .to = "う", .conditions_in = V5SP, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じさす", .to = "ずる", .conditions_in = V5SS, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "ぜさす", .to = "ずる", .conditions_in = V5SS, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "さす", .to = "する", .conditions_in = V5SS, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為す", .to = "為る", .conditions_in = V5SS, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こさす", .to = "くる", .conditions_in = V5SS, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来さす", .to = "来る", .conditions_in = V5SS, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來さす", .to = "來る", .conditions_in = V5SS, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "imperative",
                  .description =
                      "1. To give orders.\n"
                      "2. (As あれ) Represents the fact that it will never change no matter the circumstances.\n"
                      "3. Express a feeling of hope."});
  add_rule({.from = "ろ", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "よ", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "え", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "け", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "げ", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "せ", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "て", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ね", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "べ", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "め", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "れ", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じろ", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "ぜよ", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しろ", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "せよ", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ろ", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為よ", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こい", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来い", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來い", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "ませ", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});
  add_rule({.from = "くれ", .to = "くれる", .conditions_in = NONE, .conditions_out = V1, .group_id = id});

  id = add_group({.name = "continuative",
                  .description =
                      "Used to indicate actions that are (being) carried out.\n"
                      "Refers to 連用形, the part of the verb after conjugating with -ます and dropping ます."});
  add_rule({.from = "い", .to = "いる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "え", .to = "える", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "き", .to = "きる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "ぎ", .to = "ぎる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "け", .to = "ける", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "げ", .to = "げる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "じ", .to = "じる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "せ", .to = "せる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "ぜ", .to = "ぜる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "ち", .to = "ちる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "て", .to = "てる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "で", .to = "でる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "に", .to = "にる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "ね", .to = "ねる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "ひ", .to = "ひる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "び", .to = "びる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "へ", .to = "へる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "べ", .to = "べる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "み", .to = "みる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "め", .to = "める", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "り", .to = "りる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "れ", .to = "れる", .conditions_in = NONE, .conditions_out = V1D, .group_id = id});
  add_rule({.from = "い", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "き", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎ", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "し", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ち", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "に", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "び", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "み", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "り", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "き", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "し", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "来", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "negative",
                  .description = "1. Negative form of verbs.\n"
                                 "2. Expresses a feeling of solicitation to the other party.\n"
                                 "Usage: Attach ない to the irrealis form (未然形) of verbs, くない to the stem of "
                                 "i-adjectives. ない itself conjugates as i-adjective. ます becomes ません."});
  add_rule({.from = "くない", .to = "い", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ない", .to = "る", .conditions_in = ADJ_I, .conditions_out = V1, .group_id = id});
  add_rule({.from = "かない", .to = "く", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がない", .to = "ぐ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "さない", .to = "す", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "たない", .to = "つ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なない", .to = "ぬ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばない", .to = "ぶ", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まない", .to = "む", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "らない", .to = "る", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "わない", .to = "う", .conditions_in = ADJ_I, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じない", .to = "ずる", .conditions_in = ADJ_I, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しない", .to = "する", .conditions_in = ADJ_I, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ない", .to = "為る", .conditions_in = ADJ_I, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こない", .to = "くる", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ない", .to = "来る", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ない", .to = "來る", .conditions_in = ADJ_I, .conditions_out = VK, .group_id = id});
  add_rule({.from = "ません", .to = "ます", .conditions_in = MASEN, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-さ",
                  .description = "Nominalizing suffix of i-adjectives indicating nature, state, mind or degree.\n"
                                 "Usage: Attach さ to the stem of i-adjectives."});
  add_rule({.from = "さ", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "passive",
                  .description = std::string(passive_english_description) +
                                 "Usage: Attach れる to the irrealis form (未然形) of godan verbs."});
  add_rule({.from = "かれる", .to = "く", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "がれる", .to = "ぐ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "される", .to = "す", .conditions_in = V1, .conditions_out = V5D | V5SP, .group_id = id});
  add_rule({.from = "たれる", .to = "つ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なれる", .to = "ぬ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ばれる", .to = "ぶ", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "まれる", .to = "む", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "われる", .to = "う", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "られる", .to = "る", .conditions_in = V1, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じされる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "ぜされる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "される", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為れる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こられる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来られる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來られる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-た",
                  .description =
                      "1. Indicates a reality that has happened in the past.\n"
                      "2. Indicates the completion of an action.\n"
                      "3. Indicates the confirmation of a matter.\n"
                      "4. Indicates the speaker's confidence that the action will definitely be fulfilled.\n"
                      "5. Indicates the events that occur before the main clause are represented as relative past.\n"
                      "6. Indicates a mild imperative/command.\n"
                      "Usage: Attach た to the continuative form (連用形) of verbs after euphonic change form, かった "
                      "to the stem of i-adjectives."});
  add_rule({.from = "かった", .to = "い", .conditions_in = TA, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "た", .to = "る", .conditions_in = TA, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いた", .to = "く", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "いだ", .to = "ぐ", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "した", .to = "す", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "った", .to = "う", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "った", .to = "つ", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "った", .to = "る", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだ", .to = "ぬ", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだ", .to = "ぶ", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "んだ", .to = "む", .conditions_in = TA, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じた", .to = "ずる", .conditions_in = TA, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "した", .to = "する", .conditions_in = TA, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為た", .to = "為る", .conditions_in = TA, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きた", .to = "くる", .conditions_in = TA, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来た", .to = "来る", .conditions_in = TA, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來た", .to = "來る", .conditions_in = TA, .conditions_out = VK, .group_id = id});
  add_irregular("た", TA, V5, id);
  add_rule({.from = "ました", .to = "ます", .conditions_in = TA, .conditions_out = MASU, .group_id = id});
  add_rule({.from = "でした", .to = "", .conditions_in = TA, .conditions_out = MASEN, .group_id = id});
  add_rule({.from = "かった", .to = "", .conditions_in = TA, .conditions_out = MASEN | NN, .group_id = id});

  id = add_group({.name = "-ます",
                  .description = "Polite conjugation of verbs and adjectives.\n"
                                 "Usage: Attach ます to the continuative form (連用形) of verbs."});
  add_rule({.from = "ます", .to = "る", .conditions_in = MASU, .conditions_out = V1, .group_id = id});
  add_rule({.from = "います", .to = "う", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "きます", .to = "く", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "ぎます", .to = "ぐ", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "します", .to = "す", .conditions_in = MASU, .conditions_out = V5D | V5S, .group_id = id});
  add_rule({.from = "ちます", .to = "つ", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "にます", .to = "ぬ", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "びます", .to = "ぶ", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "みます", .to = "む", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "ります", .to = "る", .conditions_in = MASU, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "じます", .to = "ずる", .conditions_in = MASU, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "します", .to = "する", .conditions_in = MASU, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ます", .to = "為る", .conditions_in = MASU, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きます", .to = "くる", .conditions_in = MASU, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ます", .to = "来る", .conditions_in = MASU, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ます", .to = "來る", .conditions_in = MASU, .conditions_out = VK, .group_id = id});
  add_rule({.from = "くあります", .to = "い", .conditions_in = MASU, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "くださいます", .to = "くださる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "下さいます", .to = "下さる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule(
      {.from = "いらっしゃいます", .to = "いらっしゃる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ございます", .to = "ござる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "なさいます", .to = "なさる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "おっしゃいます", .to = "おっしゃる", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "仰います", .to = "仰る", .conditions_in = MASU, .conditions_out = V5, .group_id = id});
  add_rule({.from = "仰有います", .to = "仰有る", .conditions_in = MASU, .conditions_out = V5, .group_id = id});

  id = add_group({.name = "potential",
                  .description = "Indicates a state of being (naturally) capable of doing an action.\n"
                                 "Usage: Attach (ら)れる to the irrealis form (未然形) of ichidan verbs.\n"
                                 "Attach る to the imperative form (命令形) of godan verbs.\n"
                                 "する becomes できる, くる becomes こ(ら)れる"});
  add_rule({.from = "れる", .to = "る", .conditions_in = V1, .conditions_out = V1 | V5D, .group_id = id});
  add_rule({.from = "える", .to = "う", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "ける", .to = "く", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "げる", .to = "ぐ", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "せる", .to = "す", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "てる", .to = "つ", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "ねる", .to = "ぬ", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "べる", .to = "ぶ", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "める", .to = "む", .conditions_in = V1, .conditions_out = V5D, .group_id = id});
  add_rule({.from = "できる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "出来る", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "これる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来れる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來れる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "potential or passive",
                  .description = std::string(passive_english_description) +
                                 "3. Indicates a state of being (naturally) capable of doing an action.\n"
                                 "Usage: Attach られる to the irrealis form (未然形) of ichidan verbs.\n"
                                 "する becomes せられる, くる becomes こられる"});
  add_rule({.from = "られる", .to = "る", .conditions_in = V1, .conditions_out = V1, .group_id = id});
  add_rule({.from = "ざれる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "ぜられる", .to = "ずる", .conditions_in = V1, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "せられる", .to = "する", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為られる", .to = "為る", .conditions_in = V1, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こられる", .to = "くる", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来られる", .to = "来る", .conditions_in = V1, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來られる", .to = "來る", .conditions_in = V1, .conditions_out = VK, .group_id = id});

  id = add_group(
      {.name = "volitional",
       .description =
           "1. Expresses speaker\'s will or intention.\n"
           "2. Expresses an invitation to the other party.\n"
           "3. (Used in …ようとする) Indicates being on the verge of initiating an action or transforming a state.\n"
           "4. Indicates an inference of a matter.\n"
           "Usage: Attach よう to the irrealis form (未然形) of ichidan verbs.\n"
           "Attach う to the irrealis form (未然形) of godan verbs after -o euphonic change form.\n"
           "Attach かろう to the stem of i-adjectives (4th meaning only)."});
  add_rule({.from = "よう", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "おう", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "こう", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ごう", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "そう", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "とう", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "のう", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぼう", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "もう", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ろう", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じよう", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しよう", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為よう", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こよう", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来よう", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來よう", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "ましょう", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});
  add_rule({.from = "かろう", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "volitional slang",
                  .description = "Contraction of volitional form + か\n"
                                 "1. Expresses speaker's will or intention.\n"
                                 "2. Expresses an invitation to the other party.\n"
                                 "Usage: Replace final う with っ of volitional form then add か.\n"
                                 "For example: 行こうか -> 行こっか."});
  add_rule({.from = "よっか", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "おっか", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "こっか", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ごっか", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "そっか", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "とっか", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "のっか", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぼっか", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "もっか", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ろっか", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じよっか", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しよっか", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為よっか", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こよっか", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来よっか", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來よっか", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "ましょっか", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-まい",
                  .description = "Negative volitional form of verbs.\n"
                                 "1. Expresses speaker's assumption that something is likely not true.\n"
                                 "2. Expresses speaker's will or intention not to do something.\n"
                                 "Usage: Attach まい to the dictionary form (終止形) of verbs.\n"
                                 "Attach まい to the irrealis form (未然形) of ichidan verbs.\n"
                                 "する becomes しまい, くる becomes こまい"});
  add_rule({.from = "まい", .to = "", .conditions_in = NONE, .conditions_out = V, .group_id = id});
  add_rule({.from = "まい", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "じまい", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しまい", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為まい", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "こまい", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来まい", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來まい", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "まい", .to = "", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});

  id =
      add_group({.name = "-おく",
                 .description = "To do certain things in advance in preparation (or in anticipation) of latter needs.\n"
                                "Usage: Attach おく to the て-form of verbs.\n"
                                "Attach でおく after ない negative form of verbs.\n"
                                "Contracts to とく・どく in speech."});
  add_rule({.from = "ておく", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でおく", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "とく", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "どく", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ないでおく", .to = "ない", .conditions_in = V5, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ないどく", .to = "ない", .conditions_in = V5, .conditions_out = ADJ_I, .group_id = id});

  id =
      add_group({.name = "-いる",
                 .description =
                     "1. Indicates an action continues or progresses to a point in time.\n"
                     "2. Indicates an action is completed and remains as is.\n"
                     "3. Indicates a state or condition that can be taken to be the result of undergoing some change.\n"
                     "Usage: Attach いる to the て-form of verbs. い can be dropped in speech.\n"
                     "Attach でいる after ない negative form of verbs.\n"
                     "(Slang) Attach おる to the て-form of verbs. Contracts to とる・でる in speech."});
  add_rule({.from = "ている", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ておる", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "てる", .to = "て", .conditions_in = V1P, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でいる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でおる", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でる", .to = "で", .conditions_in = V1P, .conditions_out = TE, .group_id = id});
  add_rule({.from = "とる", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ないでいる", .to = "ない", .conditions_in = V1, .conditions_out = ADJ_I, .group_id = id});

  id = add_group(
      {.name = "-き",
       .description = "Attributive form (連体形) of i-adjectives. An archaic form that remains in modern Japanese."});
  add_rule({.from = "き", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "-げ",
                  .description = "Describes a person's appearance. Shows feelings of the person.\n"
                                 "Usage: Attach げ or 気 to the stem of i-adjectives"});
  add_rule({.from = "げ", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "気", .to = "い", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "-がる",
                  .description =
                      "1. Shows subject’s feelings contrast with what is thought/known about them.\n"
                      "2. Indicates subject's behavior (stands out).\n"
                      "Usage: Attach がる to the stem of i-adjectives. It itself conjugates as a godan verb."});
  add_rule({.from = "がる", .to = "い", .conditions_in = V5, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "-え",
                  .description = "Slang. A sound change of i-adjectives.\n"
                                 "ai：やばい → やべぇ\n"
                                 "ui：さむい → さみぃ/さめぇ\n"
                                 "oi：すごい → すげぇ"});
  add_rule({.from = "ねえ", .to = "ない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "めえ", .to = "むい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "みい", .to = "むい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ちぇえ", .to = "つい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ちい", .to = "つい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "せえ", .to = "すい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ええ", .to = "いい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ええ", .to = "わい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ええ", .to = "よい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "いぇえ", .to = "よい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "うぇえ", .to = "わい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "けえ", .to = "かい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "げえ", .to = "がい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "げえ", .to = "ごい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "せえ", .to = "さい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "めえ", .to = "まい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ぜえ", .to = "ずい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "っぜえ", .to = "ずい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "れえ", .to = "らい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ちぇえ", .to = "ちゃい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "でえ", .to = "どい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "れえ", .to = "れい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "べえ", .to = "ばい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "てえ", .to = "たい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ねぇ", .to = "ない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "めぇ", .to = "むい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "みぃ", .to = "むい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ちぃ", .to = "つい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "せぇ", .to = "すい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "けぇ", .to = "かい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "げぇ", .to = "がい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "げぇ", .to = "ごい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "せぇ", .to = "さい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "めぇ", .to = "まい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ぜぇ", .to = "ずい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "っぜぇ", .to = "ずい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "れぇ", .to = "らい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "でぇ", .to = "どい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "れぇ", .to = "れい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "べぇ", .to = "ばい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "てぇ", .to = "たい", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "n-slang", .description = ""});
  add_rule({.from = "んなさい", .to = "りなさい", .conditions_in = NONE, .conditions_out = NASAI, .group_id = id});
  add_rule({.from = "らんない", .to = "られない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "んない", .to = "らない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "んなきゃ", .to = "らなきゃ", .conditions_in = NONE, .conditions_out = YA, .group_id = id});
  add_rule({.from = "んなきゃ", .to = "れなきゃ", .conditions_in = NONE, .conditions_out = YA, .group_id = id});

  id = add_group({.name = "imperative negative slang", .description = ""});
  add_rule({.from = "んな", .to = "る", .conditions_in = NONE, .conditions_out = V, .group_id = id});

  id = add_group({.name = "kansai-ben negative", .description = "Negative form of kansai-ben verbs"});
  add_rule({.from = "へん", .to = "ない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ひん", .to = "ない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "せえへん", .to = "しない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "へんかった", .to = "なかった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ひんかった", .to = "なかった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "うてへん", .to = "ってない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "kansai-ben -て", .description = "-て form of kansai-ben verbs"});
  add_rule({.from = "うて", .to = "って", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "おうて", .to = "あって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "こうて", .to = "かって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ごうて", .to = "がって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "そうて", .to = "さって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ぞうて", .to = "ざって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "とうて", .to = "たって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "どうて", .to = "だって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "のうて", .to = "なって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ほうて", .to = "はって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ぼうて", .to = "ばって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "もうて", .to = "まって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ろうて", .to = "らって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ようて", .to = "やって", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ゆうて", .to = "いって", .conditions_in = TE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "kansai-ben -た", .description = "-た form of kansai-ben terms"});
  add_rule({.from = "うた", .to = "った", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "おうた", .to = "あった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "こうた", .to = "かった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ごうた", .to = "がった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "そうた", .to = "さった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ぞうた", .to = "ざった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "とうた", .to = "たった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "どうた", .to = "だった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "のうた", .to = "なった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ほうた", .to = "はった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ぼうた", .to = "ばった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "もうた", .to = "まった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ろうた", .to = "らった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ようた", .to = "やった", .conditions_in = TA, .conditions_out = TA, .group_id = id});
  add_rule({.from = "ゆうた", .to = "いった", .conditions_in = TA, .conditions_out = TA, .group_id = id});

  id = add_group({.name = "kansai-ben -たら", .description = "-たら form of kansai-ben terms"});
  add_rule({.from = "うたら", .to = "ったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "おうたら", .to = "あったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "こうたら", .to = "かったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ごうたら", .to = "がったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "そうたら", .to = "さったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ぞうたら", .to = "ざったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "とうたら", .to = "たったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "どうたら", .to = "だったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "のうたら", .to = "なったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ほうたら", .to = "はったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ぼうたら", .to = "ばったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "もうたら", .to = "まったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ろうたら", .to = "らったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ようたら", .to = "やったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ゆうたら", .to = "いったら", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});

  id = add_group({.name = "kansai-ben -たり", .description = "-たり form of kansai-ben terms"});
  add_rule({.from = "うたり", .to = "ったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "おうたり", .to = "あったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "こうたり", .to = "かったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ごうたり", .to = "がったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "そうたり", .to = "さったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ぞうたり", .to = "ざったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "とうたり", .to = "たったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "どうたり", .to = "だったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "のうたり", .to = "なったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ほうたり", .to = "はったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ぼうたり", .to = "ばったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "もうたり", .to = "まったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ろうたり", .to = "らったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ようたり", .to = "やったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});
  add_rule({.from = "ゆうたり", .to = "いったり", .conditions_in = NONE, .conditions_out = NONE, .group_id = id});

  id = add_group({.name = "kansai-ben -く", .description = "-く stem of kansai-ben adjectives"});
  add_rule({.from = "う", .to = "く", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "こう", .to = "かく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "ごう", .to = "がく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "そう", .to = "さく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "とう", .to = "たく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "のう", .to = "なく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "ぼう", .to = "ばく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "もう", .to = "まく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "ろう", .to = "らく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "よう", .to = "よく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});
  add_rule({.from = "しゅう", .to = "しく", .conditions_in = NONE, .conditions_out = KU, .group_id = id});

  id = add_group({.name = "kansai-ben adjective -て", .description = "-て form of kansai-ben adjectives"});
  add_rule({.from = "うて", .to = "くて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "こうて", .to = "かくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ごうて", .to = "がくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "そうて", .to = "さくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "とうて", .to = "たくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "のうて", .to = "なくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ぼうて", .to = "ばくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "もうて", .to = "まくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ろうて", .to = "らくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "ようて", .to = "よくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "しゅうて", .to = "しくて", .conditions_in = TE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "kansai-ben adjective negative", .description = "Negative form of kansai-ben adjectives"});
  add_rule({.from = "うない", .to = "くない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "こうない", .to = "かくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ごうない", .to = "がくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "そうない", .to = "さくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "とうない", .to = "たくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "のうない", .to = "なくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ぼうない", .to = "ばくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "もうない", .to = "まくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ろうない", .to = "らくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "ようない", .to = "よくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});
  add_rule({.from = "しゅうない", .to = "しくない", .conditions_in = ADJ_I, .conditions_out = ADJ_I, .group_id = id});

  // additional rules
  id = add_group({.name = "-ましゅ",
                  .description = "Polite (childish).\n"
                                 "Usage: Replace ます with ましゅ."});
  add_rule({.from = "ましゅ", .to = "ます", .conditions_in = NONE, .conditions_out = MASU, .group_id = id});

  id = add_group({.name = "-ください",
                  .description = "Polite request.\n"
                                 "Usage: Attach ください after the て-form of verbs."});
  add_rule({.from = "てください", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でください", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-くださる",
                  .description = "Do something for the speaker (respectful).\n"
                                 "Usage: Attach くださる after the て-form of verbs."});
  add_rule({.from = "てくださる", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でくださる", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-ごらん",
                  .description = "Entice someone to try to do something.\n"
                                 "Usage: Attach ごらん after the て-form of verbs."});
  add_rule({.from = "てごらん", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でごらん", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "てご覧", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でご覧", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-ごらんなさい",
                  .description = "Politely telling someone to try doing something.\n"
                                 "Usage: Attach ごらんなさい after the て-form of verbs."});
  add_rule({.from = "てごらんなさい", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でごらんなさい", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "てご覧なさい", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でご覧なさい", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-いただく",
                  .description = "Receive the favor of someone doing (respectful).\n"
                                 "Usage: Attach いただく after the て-form of verbs."});
  add_rule({.from = "ていただく", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でいただく", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-あげる",
                  .description = "Do for someone.\n"
                                 "Usage: Attach あげる after the て-form of verbs."});
  add_rule({.from = "てあげる", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "であげる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-くれる",
                  .description = "Do for me/us.\n"
                                 "Usage: Attach くれる after the て-form of verbs."});
  add_rule({.from = "てくれる", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でくれる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-もらう",
                  .description = "Receive the favour of someone doing.\n"
                                 "Usage: Attach もらう after the て-form of verbs."});
  add_rule({.from = "てもらう", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でもらう", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-やる",
                  .description = "Do for someone (casual).\n"
                                 "Usage: Attach やる after the て-form of verbs."});
  add_rule({.from = "てやる", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でやる", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-さしあげる",
                  .description = "Do for someone (humble).\n"
                                 "Usage: Attach さしあげる after the て-form of verbs."});
  add_rule({.from = "てさしあげる", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でさしあげる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-みる",
                  .description = "Try to do something.\n"
                                 "Usage: Attach みる after the て-form of verbs."});
  add_rule({.from = "てみる", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でみる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-みせる",
                  .description = "Showing of an action to someone.\n"
                                 "Usage: Attach みせる after the て-form of verbs."});
  add_rule({.from = "てみせる", .to = "て", .conditions_in = V1, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でみせる", .to = "で", .conditions_in = V1, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-ある",
                  .description = "Resultant state (intentional).\n"
                                 "Usage: Attach ある after the て-form of verbs."});
  add_rule({.from = "てある", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "である", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-いく",
                  .description = "1. Action away from speaker.\n"
                                 "2. Indicates change continuing into the future.\n"
                                 "Usage: Attach いく after the て-form of verbs."});
  add_rule({.from = "ていく", .to = "て", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でいく", .to = "で", .conditions_in = V5, .conditions_out = TE, .group_id = id});
  add_rule({.from = "てく", .to = "て", .conditions_in = NONE, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でく", .to = "で", .conditions_in = NONE, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-くる",
                  .description = "1. Action towards speaker.\n"
                                 "2. Indicates ongoing change extending to present.\n"
                                 "3. Inception of a process.\n"
                                 "Usage: Attach くる after the て-form of verbs."});
  add_rule({.from = "てくる", .to = "て", .conditions_in = VK, .conditions_out = TE, .group_id = id});
  add_rule({.from = "でくる", .to = "で", .conditions_in = VK, .conditions_out = TE, .group_id = id});

  id = add_group({.name = "-なさそう",
                  .description = "Appearing not to be; does not seem like.\n"
                                 "Usage: Replace ない with なさそう."});
  add_rule({.from = "なさそう", .to = "ない", .conditions_in = NONE, .conditions_out = ADJ_I, .group_id = id});

  id = add_group({.name = "-ながら",
                  .description = "While doing something.\n"
                                 "Usage: Attach ながら after the continuative form (連用形) of verbs."});
  add_rule({.from = "ながら", .to = "る", .conditions_in = NONE, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いながら", .to = "う", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きながら", .to = "く", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎながら", .to = "ぐ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しながら", .to = "す", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちながら", .to = "つ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "にながら", .to = "ぬ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びながら", .to = "ぶ", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みながら", .to = "む", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りながら", .to = "る", .conditions_in = NONE, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じながら", .to = "ずる", .conditions_in = NONE, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しながら", .to = "する", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為ながら", .to = "為る", .conditions_in = NONE, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きながら", .to = "くる", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来ながら", .to = "来る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來ながら", .to = "來る", .conditions_in = NONE, .conditions_out = VK, .group_id = id});

  id = add_group({.name = "-やがる",
                  .description = "Expresses the speakers contempt/anger towards someone else's action.\n"
                                 "Usage: Attach やがる after the continuative form (連用形) of verbs."});
  add_rule({.from = "やがる", .to = "る", .conditions_in = V5, .conditions_out = V1, .group_id = id});
  add_rule({.from = "いやがる", .to = "う", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "きやがる", .to = "く", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ぎやがる", .to = "ぐ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "しやがる", .to = "す", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "ちやがる", .to = "つ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "にやがる", .to = "ぬ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "びやがる", .to = "ぶ", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "みやがる", .to = "む", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "りやがる", .to = "る", .conditions_in = V5, .conditions_out = V5, .group_id = id});
  add_rule({.from = "じやがる", .to = "ずる", .conditions_in = V5, .conditions_out = VZ, .group_id = id});
  add_rule({.from = "しやがる", .to = "する", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "為やがる", .to = "為る", .conditions_in = V5, .conditions_out = VS, .group_id = id});
  add_rule({.from = "きやがる", .to = "くる", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "来やがる", .to = "来る", .conditions_in = V5, .conditions_out = VK, .group_id = id});
  add_rule({.from = "來やがる", .to = "來る", .conditions_in = V5, .conditions_out = VK, .group_id = id});
}

void Deinflector::init_english_transforms() {
  // Helper: add doubled-consonant rules for a given suffix.
  // For each char c in consonants, adds rule c+c+suffix -> c.
  auto add_doubled = [&](const std::string& consonants, const std::string& suffix,
                         uint32_t cond_in, uint32_t cond_out, int gid) {
    for (char c : consonants) {
      std::string from;
      from += c;
      from += c;
      from += suffix;
      std::string to;
      to += c;
      add_rule({.from = from, .to = to, .conditions_in = cond_in, .conditions_out = cond_out, .group_id = gid});
    }
  };

  // ---------- plural ----------
  int id = add_group({.name = "plural", .description = "Plural form of a noun."});
  add_rule({.from = "s",   .to = "",   .conditions_in = EN_NP, .conditions_out = EN_NS, .group_id = id});
  add_rule({.from = "es",  .to = "",   .conditions_in = EN_NP, .conditions_out = EN_NS, .group_id = id});
  add_rule({.from = "ies", .to = "y",  .conditions_in = EN_NP, .conditions_out = EN_NS, .group_id = id});
  add_rule({.from = "ves", .to = "fe", .conditions_in = EN_NP, .conditions_out = EN_NS, .group_id = id});
  add_rule({.from = "ves", .to = "f",  .conditions_in = EN_NP, .conditions_out = EN_NS, .group_id = id});

  // ---------- possessive ----------
  id = add_group({.name = "possessive", .description = "Possessive form of a noun."});
  add_rule({.from = "'s", .to = "",  .conditions_in = EN_N_ALL, .conditions_out = EN_N_ALL, .group_id = id});
  add_rule({.from = "s'", .to = "s", .conditions_in = EN_N_ALL, .conditions_out = EN_N_ALL, .group_id = id});

  // ---------- past tense ----------
  id = add_group({.name = "past tense", .description = "Past tense form of a verb."});
  add_rule({.from = "ed",   .to = "",    .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "ed",   .to = "e",   .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "ied",  .to = "y",   .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "cked", .to = "c",   .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_doubled("bdgklmnprstz", "ed", EN_V_ALL, EN_V_ALL, id);
  add_rule({.from = "laid", .to = "lay", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "paid", .to = "pay", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "said", .to = "say", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});

  // ---------- present participle / -ing ----------
  id = add_group({.name = "-ing", .description = "Present participle / gerund form of a verb."});
  add_rule({.from = "ing",   .to = "",   .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "ing",   .to = "e",  .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "ying",  .to = "ie", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "cking", .to = "c",  .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_doubled("bdgklmnprstz", "ing", EN_V_ALL, EN_V_ALL, id);

  // ---------- 3rd person singular present ----------
  id = add_group({.name = "3rd person singular", .description = "3rd person singular present form of a verb."});
  add_rule({.from = "s",   .to = "",  .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "es",  .to = "",  .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});
  add_rule({.from = "ies", .to = "y", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});

  // ---------- archaic -'d ----------
  id = add_group({.name = "archaic past", .description = "Archaic contraction of -ed past tense."});
  add_rule({.from = "'d", .to = "ed", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});

  // ---------- adverb ----------
  id = add_group({.name = "adverb", .description = "Adverb form of an adjective."});
  add_rule({.from = "ly",  .to = "",   .conditions_in = EN_ADV, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "ily", .to = "y",  .conditions_in = EN_ADV, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "ly",  .to = "le", .conditions_in = EN_ADV, .conditions_out = EN_ADJ, .group_id = id});

  // ---------- comparative ----------
  id = add_group({.name = "comparative", .description = "Comparative form of an adjective."});
  add_rule({.from = "er",  .to = "",  .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "er",  .to = "e", .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "ier", .to = "y", .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_doubled("bdgmnt", "er", EN_ADJ, EN_ADJ, id);

  // ---------- superlative ----------
  id = add_group({.name = "superlative", .description = "Superlative form of an adjective."});
  add_rule({.from = "est",  .to = "",  .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "est",  .to = "e", .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "iest", .to = "y", .conditions_in = EN_ADJ, .conditions_out = EN_ADJ, .group_id = id});
  add_doubled("bdgmnt", "est", EN_ADJ, EN_ADJ, id);

  // ---------- dropped-g ----------
  id = add_group({.name = "dropped g", .description = "Informal dropped-g form (runnin' → running)."});
  add_rule({.from = "in'", .to = "ing", .conditions_in = EN_V_ALL, .conditions_out = EN_V_ALL, .group_id = id});

  // ---------- -y adjective / noun / verb ----------
  id = add_group({.name = "-y", .description = "-y suffix adjective derived from noun or verb."});
  add_rule({.from = "y",  .to = "",  .conditions_in = EN_ADJ, .conditions_out = EN_N_ALL | EN_V_ALL, .group_id = id});
  add_rule({.from = "y",  .to = "e", .conditions_in = EN_ADJ, .conditions_out = EN_N_ALL | EN_V_ALL, .group_id = id});
  add_doubled("glmnprst", "y", EN_ADJ, EN_N_ALL | EN_V_ALL, id);

  // ---------- -able ----------
  id = add_group({.name = "-able", .description = "-able suffix adjective derived from a verb."});
  add_rule({.from = "able",  .to = "",   .conditions_in = EN_V_ALL, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "able",  .to = "e",  .conditions_in = EN_V_ALL, .conditions_out = EN_ADJ, .group_id = id});
  add_rule({.from = "iable", .to = "y",  .conditions_in = EN_V_ALL, .conditions_out = EN_ADJ, .group_id = id});
  add_doubled("bdgklmnprstz", "able", EN_V_ALL, EN_ADJ, id);
}

int Deinflector::add_group(const TransformGroup& group) {
  auto id = static_cast<int>(groups_.size());
  groups_.emplace_back(group);
  return id;
}

void Deinflector::add_rule(const Rule& rule) {
  transforms_[rule.from].emplace_back(rule);
  max_length_ = std::max<size_t>(utf8::distance(rule.from.begin(), rule.from.end()), max_length_);
}

std::vector<DeinflectionResult> Deinflector::deinflect(const std::string& text) const {
  std::vector<DeinflectionResult> result{};
  std::vector<TransformGroup> trace{};
  size_t text_len = utf8::distance(text.begin(), text.end());
  if (text_len > 1) {
    deinflect_recursive(text, NONE, trace, result);
  } else {
    result.emplace_back(text, NONE, trace);
  }

  return result;
}

uint32_t Deinflector::pos_to_conditions(const std::vector<std::string>& part_of_speech) {
  uint32_t result = 0;
  for (const auto& p : part_of_speech) {
    if (p == "v1") {
      result |= V1;
    } else if (p == "v5") {
      result |= V5;
    } else if (p == "vk") {
      result |= VK;
    } else if (p == "vs") {
      result |= VS;
    } else if (p == "vz") {
      result |= VZ;
    } else if (p == "adj-i") {
      result |= ADJ_I;
    }
    // English POS tags (Yomitan english-transforms.js)
    else if (p == "v") {
      result |= EN_V_ALL;
    } else if (p == "v_phr") {
      result |= EN_V_PHR;
    } else if (p == "n") {
      result |= EN_N_ALL;
    } else if (p == "np") {
      result |= EN_NP;
    } else if (p == "ns") {
      result |= EN_NS;
    } else if (p == "adj") {
      result |= EN_ADJ;
    } else if (p == "adv") {
      result |= EN_ADV;
    }
  }
  return result;
}

void Deinflector::deinflect_recursive(const std::string& text, uint32_t conditions, std::vector<TransformGroup>& trace,
                                      std::vector<DeinflectionResult>& results) const {
  size_t text_len = utf8::distance(text.begin(), text.end());
  if (text_len <= 1) {
    return;
  }
  results.emplace_back(text, conditions, trace);

  size_t start = std::min(max_length_, text_len);
  auto prefix_it = text.begin();
  utf8::advance(prefix_it, text_len - start, text.end());

  for (size_t i = start; i > 0; i--) {
    std::string suffix(prefix_it, text.end());
    auto it = transforms_.find(suffix);
    if (it != transforms_.end()) {
      std::string prefix(text.begin(), prefix_it);
      for (const auto& rule : it->second) {
        if (conditions != NONE && !(conditions & rule.conditions_in)) {
          continue;
        }

        std::string transformed = prefix + rule.to;

        trace.push_back(groups_[rule.group_id]);
        deinflect_recursive(transformed, rule.conditions_out, trace, results);
        trace.pop_back();
      }
    }

    if (i > 1) {
      utf8::next(prefix_it, text.end());
    }
  }
}

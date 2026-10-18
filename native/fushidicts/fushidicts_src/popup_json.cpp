#include "fushidicts/popup_json.hpp"

#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

// 弹窗 JSON 的输出缓冲：直接往 std::string 追加（一次查词的 JSON 常有 200 KB 上下，
// std::ostringstream 的逐字符 sentry / locale 开销在这里是可测的）。只支持本文件用到的
// 几种写入；整数按十进制输出，与 ostream << int 逐字节相同。
namespace {
class JsonOut {
 public:
  JsonOut& operator<<(char c) {
    buf_.push_back(c);
    return *this;
  }
  JsonOut& operator<<(const char* s) {
    buf_.append(s);
    return *this;
  }
  JsonOut& operator<<(const std::string& s) {
    buf_.append(s);
    return *this;
  }
  JsonOut& operator<<(int v) {
    buf_.append(std::to_string(v));
    return *this;
  }
  void append(const char* data, size_t n) { buf_.append(data, n); }
  std::string str() { return std::move(buf_); }

 private:
  std::string buf_;
};
}  // namespace

static void json_escape(JsonOut& os, const std::string& s) {
  os << '"';
  const char* data = s.data();
  size_t run = 0;  // 尚未写出的、无需转义的连续字节的起点
  for (size_t i = 0; i < s.size(); i++) {
    const char c = data[i];
    const unsigned char uc = static_cast<unsigned char>(c);
    if (c != '"' && c != '\\' && uc >= 0x20) continue;
    os.append(data + run, i - run);
    run = i + 1;
    switch (c) {
      case '"': os << "\\\""; break;
      case '\\': os << "\\\\"; break;
      case '\b': os << "\\b"; break;
      case '\f': os << "\\f"; break;
      case '\n': os << "\\n"; break;
      case '\r': os << "\\r"; break;
      case '\t': os << "\\t"; break;
      default: {
        char buf[8];
        snprintf(buf, sizeof(buf), "\\u%04x", uc);
        os << buf;
      }
    }
  }
  os.append(data + run, s.size() - run);
  os << '"';
}

// 显示边界的变形名 / 语法说明本地化（Dart `TransformDescriptionCatalog.localize`
// 的镜像）：查不到原样返回；空表 = 不翻译。
static const std::string& localize(const PopupTranslations* translations,
                                   const std::string& text) {
  if (translations == nullptr || translations->empty() || text.empty()) {
    return text;
  }
  auto it = translations->find(text);
  return it == translations->end() ? text : it->second;
}

// 词形变化链 → 弹窗的 `deinflectionTrace` 数组。
//
// 与 Dart 侧 buildDeinflectionTags（fushi_dictionary/lib/src/language/language.dart）
// 逐字段对齐——弹窗 JSON（本文件）与 extra 路径（buildLookupEntriesJson）必须给出
// 同一份变形标签，parity 由 tests/popup_json_vectors_test.cpp（parity_taberu）与 Dart
// 侧的 dictionary_popup_webview_test 两头锁住。语义详见该函数的文档注释：
//   * trace 的压栈顺序是**剥离顺序**（最外层的变形最先被剥），显示要的是**接续
//     顺序**，所以整体反转：`当たっていた` 的 trace `[-た, -いる, -て]` 显示成
//     `-て « -いる « -た`。
//   * trace 为空而 matched != deinflected，说明这是 lookup.cpp 里的**文本变体归一**
//     （colour→color 一类），它不经过任何变形规则，故没有语法说明，只回落成一条
//     `matched → deinflected`。这条分支不能删。
static void write_deinflection_tags(JsonOut& os,
                                    const std::string& matched,
                                    const std::string& deinflected,
                                    const std::vector<TransformGroup>& trace,
                                    const PopupTranslations* translations) {
  os << '[';
  if (!trace.empty()) {
    for (size_t i = trace.size(); i-- > 0;) {
      if (i + 1 != trace.size()) os << ',';
      os << R"({"name":)";
      json_escape(os, localize(translations, trace[i].name));
      os << R"(,"description":)";
      json_escape(os, localize(translations, trace[i].description));
      os << '}';
    }
  } else if (matched != deinflected && !deinflected.empty()) {
    os << R"({"name":)";
    const std::string fallback = matched + " \xe2\x86\x92 " + deinflected;
    json_escape(os, localize(translations, fallback));
    os << R"(,"description":""})";
  }
  os << ']';
}

std::string build_popup_json(const std::vector<LookupResult>& results,
                             int max_terms) {
  PopupJsonOptions options;
  options.max_terms = max_terms;
  options.budget_counts_glossaries = true;
  return build_popup_json(results, options);
}

std::string build_popup_json(const std::vector<LookupResult>& results,
                             const PopupJsonOptions& options) {
  const int max_terms = options.max_terms;
  struct GroupData {
    std::string expression;
    std::string reading;
    std::string matched;
    std::string deinflected;
    std::vector<TransformGroup> trace;
    std::vector<FrequencyEntry> frequencies;
    std::vector<PitchEntry> pitches;
    std::set<std::string> seen_freqs;
    std::set<std::string> seen_pitches;
    struct Glossary {
      std::string dictionary;
      std::string content_json;
      std::string def_tags;
      std::string term_tags;
    };
    std::vector<Glossary> glossaries;
  };

  std::vector<std::string> group_order;
  std::map<std::string, GroupData> groups;
  int entry_count = 0;

  // 分组口径与 Dart 侧 lookupHeadwordKey / soleExplicitReadings 对齐：
  // BUG-2753：MDX/StarDict/DSL 导入时读音恒空；同表记在本次结果里只有一个显式读音
  //   时，空读音行补上它、并入同一张卡；有多个读音时不猜。
  // BUG-791：补完仍为空的读音按 Yomitan 约定视同表记。
  std::map<std::string, std::set<std::string>> explicit_readings;
  for (const auto& r : results) {
    if (!r.term.reading.empty()) {
      explicit_readings[r.term.expression].insert(r.term.reading);
    }
  }
  auto resolved_reading = [&](const LookupResult& r) -> std::string {
    if (!r.term.reading.empty()) return r.term.reading;
    auto it = explicit_readings.find(r.term.expression);
    if (it != explicit_readings.end() && it->second.size() == 1) {
      return *it->second.begin();
    }
    return std::string();
  };

  for (const auto& r : results) {
    const std::string reading = resolved_reading(r);
    const std::string key = r.term.expression + "\n" +
                            (reading.empty() ? r.term.expression : reading);
    // BUG-1472：预算的单位是词头（表记 + 有效读音），不是注释行——新词头只在还有
    // 预算时才能建卡；已有的词头继续收它后续结果行的注释。
    if (!options.budget_counts_glossaries && groups.find(key) == groups.end() &&
        static_cast<int>(group_order.size()) >= max_terms) {
      goto done;
    }
    for (const auto& g : r.term.glossaries) {
      // 被用户关掉的词典在源头就不进 popupJson：不建卡、不占词头预算、也不并入
      // 频率 / 音调（这些只随可见释义一起合并）。
      if (options.hidden.contains(g.dict_name)) continue;
      if (options.budget_counts_glossaries) {
        if (entry_count >= max_terms) goto done;
        entry_count++;
      }

      auto it = groups.find(key);
      if (it == groups.end()) {
        group_order.push_back(key);
        auto& gd = groups[key];
        gd.expression = r.term.expression;
        gd.reading = reading;
        gd.matched = r.matched;
        gd.deinflected = r.deinflected;
        gd.trace = r.trace;
        it = groups.find(key);
      } else if (it->second.matched == it->second.expression &&
                 r.matched != r.term.expression) {
        it->second.matched = r.matched;
        it->second.deinflected = r.deinflected;
        it->second.trace = r.trace;
      }

      auto& gd = it->second;

      for (const auto& f : r.term.frequencies) {
        std::string fkey = f.dict_name + ":";
        for (size_t i = 0; i < f.frequencies.size(); i++) {
          if (i > 0) fkey += ",";
          fkey += std::to_string(f.frequencies[i].value) + ":" +
                  f.frequencies[i].display_value;
        }
        if (gd.seen_freqs.insert(fkey).second) {
          gd.frequencies.push_back(f);
        }
      }

      for (const auto& p : r.term.pitches) {
        // key 形状 = "dict:数字位段,pattern段|transcriptions段"，与 Dart 镜像
        // buildPopupJsonFromLookup 的 pKey 逐字符同构（FFI 面就是数字/pattern 两个
        // 平行数组，key 也按此分段，避免两侧 dedup 分歧）。pattern 位若只按
        // position 建 key 会与 position 0 撞车被吞；IPA 记录无 accent，只按 accent
        // 建 key 会把同 dict 多 IPA 折叠成 "dict:" 被吞（TODO-687 block3 同型坑）。
        std::string pkey = p.dict_name + ":";
        {
          bool first = true;
          for (const auto& accent : p.pitches) {
            if (!accent.pattern.empty()) continue;
            if (!first) pkey += ",";
            first = false;
            pkey += std::to_string(accent.position);
          }
        }
        pkey += ",";
        {
          bool first = true;
          for (const auto& accent : p.pitches) {
            if (accent.pattern.empty()) continue;
            if (!first) pkey += ",";
            first = false;
            pkey += accent.pattern;
          }
        }
        pkey += "|";
        for (size_t i = 0; i < p.transcriptions.size(); i++) {
          if (i > 0) pkey += ",";
          pkey += p.transcriptions[i];
        }
        if (gd.seen_pitches.insert(pkey).second) {
          gd.pitches.push_back(p);
        }
      }

      const std::string& m = g.glossary;
      std::string content_json;
      if (!m.empty() && (m[0] == '[' || m[0] == '{')) {
        content_json = m;
      } else {
        JsonOut oss;
        json_escape(oss, m);
        content_json = oss.str();
      }
      gd.glossaries.push_back(
          {g.dict_name, std::move(content_json), g.definition_tags, g.term_tags});
    }
  }
done:

  // 同一词典名在顺序表里出现多次时取最后一次（与 Dart 侧 map 字面量覆盖语义一致）。
  std::unordered_map<std::string, size_t> dictionary_rank;
  for (size_t i = 0; i < options.dictionary_order.size(); i++) {
    dictionary_rank[options.dictionary_order[i]] = i;
  }

  JsonOut os;
  os << '[';
  for (size_t i = 0; i < group_order.size(); i++) {
    if (i > 0) os << ',';
    auto& gd = groups[group_order[i]];

    os << R"({"expression":)";
    json_escape(os, gd.expression);
    os << R"(,"reading":)";
    json_escape(os, gd.reading);
    os << R"(,"matched":)";
    json_escape(os, gd.matched);
    os << R"(,"rules":[],"deinflectionTrace":)";
    write_deinflection_tags(os, gd.matched, gd.deinflected, gd.trace,
                            options.translations);

    // BUG-2579：词典顺序按整张卡排（一张卡由多条结果行拼成：显式读音的 Yomitan
    // 行 + 空读音的 MDX 行），稳定排序——同词典多条释义、不在顺序表里的词典都保持
    // 原相对顺序，未知词典排最后。
    if (!dictionary_rank.empty() && gd.glossaries.size() > 1) {
      const size_t unknown_rank = options.dictionary_order.size();
      auto rank_of = [&](const std::string& dict) {
        auto rank_it = dictionary_rank.find(dict);
        return rank_it == dictionary_rank.end() ? unknown_rank : rank_it->second;
      };
      std::stable_sort(gd.glossaries.begin(), gd.glossaries.end(),
                       [&](const GroupData::Glossary& a,
                           const GroupData::Glossary& b) {
                         return rank_of(a.dictionary) < rank_of(b.dictionary);
                       });
    }

    os << R"(,"glossaries":[)";
    for (size_t j = 0; j < gd.glossaries.size(); j++) {
      if (j > 0) os << ',';
      os << R"({"dictionary":)";
      json_escape(os, gd.glossaries[j].dictionary);
      os << R"(,"content":)" << gd.glossaries[j].content_json;
      os << R"(,"definitionTags":)";
      json_escape(os, gd.glossaries[j].def_tags);
      os << R"(,"termTags":)";
      json_escape(os, gd.glossaries[j].term_tags);
      os << '}';
    }

    os << R"(],"frequencies":[)";
    for (size_t fi = 0; fi < gd.frequencies.size(); fi++) {
      if (fi > 0) os << ',';
      os << R"({"dictionary":)";
      json_escape(os, gd.frequencies[fi].dict_name);
      os << R"(,"frequencies":[)";
      for (size_t k = 0; k < gd.frequencies[fi].frequencies.size(); k++) {
        if (k > 0) os << ',';
        os << R"({"value":)" << gd.frequencies[fi].frequencies[k].value;
        os << R"(,"displayValue":)";
        json_escape(os, gd.frequencies[fi].frequencies[k].display_value);
        os << '}';
      }
      os << "]}";
    }

    os << R"(],"pitches":[)";
    for (size_t pi = 0; pi < gd.pitches.size(); pi++) {
      if (pi > 0) os << ',';
      os << R"({"dictionary":)";
      json_escape(os, gd.pitches[pi].dict_name);
      // pitchPositions 只含数字位（与历史输出字节兼容）；pattern 位单独成
      // "patterns" 数组（79c55c2 二期，JS 渲染为 [pattern] 文本项）。
      os << R"(,"pitchPositions":[)";
      {
        bool first = true;
        for (const auto& accent : gd.pitches[pi].pitches) {
          if (!accent.pattern.empty()) continue;
          if (!first) os << ',';
          first = false;
          os << accent.position;
        }
      }
      os << R"(],"patterns":[)";
      {
        bool first = true;
        for (const auto& accent : gd.pitches[pi].pitches) {
          if (accent.pattern.empty()) continue;
          if (!first) os << ',';
          first = false;
          json_escape(os, accent.pattern);
        }
      }
      os << R"(],"transcriptions":[)";
      for (size_t k = 0; k < gd.pitches[pi].transcriptions.size(); k++) {
        if (k > 0) os << ',';
        json_escape(os, gd.pitches[pi].transcriptions[k]);
      }
      os << "]}";
    }

    os << "]}";
  }
  os << ']';
  return os.str();
}

std::string build_styles_json(DictionaryQuery& query) {
  auto styles = query.get_styles();
  JsonOut os;
  os << '{';
  for (size_t i = 0; i < styles.size(); i++) {
    if (i > 0) os << ',';
    json_escape(os, styles[i].dict_name);
    os << ':';
    json_escape(os, styles[i].styles);
  }
  os << '}';
  return os.str();
}

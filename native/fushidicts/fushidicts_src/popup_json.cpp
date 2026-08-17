#include "fushidicts/popup_json.hpp"

#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

static void json_escape(std::ostringstream& os, const std::string& s) {
  os << '"';
  for (char c : s) {
    switch (c) {
      case '"': os << "\\\""; break;
      case '\\': os << "\\\\"; break;
      case '\b': os << "\\b"; break;
      case '\f': os << "\\f"; break;
      case '\n': os << "\\n"; break;
      case '\r': os << "\\r"; break;
      case '\t': os << "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
          os << buf;
        } else {
          os << c;
        }
    }
  }
  os << '"';
}

std::string build_popup_json(const std::vector<LookupResult>& results,
                             int max_terms) {
  struct GroupData {
    std::string expression;
    std::string reading;
    std::string matched;
    std::string deinflected;
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

  for (const auto& r : results) {
    for (const auto& g : r.term.glossaries) {
      if (entry_count >= max_terms) goto done;
      entry_count++;

      std::string key = r.term.expression + "\n" + r.term.reading;
      auto it = groups.find(key);
      if (it == groups.end()) {
        group_order.push_back(key);
        auto& gd = groups[key];
        gd.expression = r.term.expression;
        gd.reading = r.term.reading;
        gd.matched = r.matched;
        gd.deinflected = r.deinflected;
        it = groups.find(key);
      } else if (it->second.matched == it->second.expression &&
                 r.matched != r.term.expression) {
        it->second.matched = r.matched;
        it->second.deinflected = r.deinflected;
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
        std::ostringstream oss;
        json_escape(oss, m);
        content_json = oss.str();
      }
      gd.glossaries.push_back(
          {g.dict_name, std::move(content_json), g.definition_tags, g.term_tags});
    }
  }
done:

  std::ostringstream os;
  os << '[';
  for (size_t i = 0; i < group_order.size(); i++) {
    if (i > 0) os << ',';
    const auto& gd = groups[group_order[i]];

    os << R"({"expression":)";
    json_escape(os, gd.expression);
    os << R"(,"reading":)";
    json_escape(os, gd.reading);
    os << R"(,"matched":)";
    json_escape(os, gd.matched);
    os << R"(,"rules":[],"deinflectionTrace":)";

    if (gd.matched != gd.deinflected && !gd.deinflected.empty()) {
      os << R"([{"name":)";
      std::string trace_name = gd.matched;
      trace_name += " → ";
      trace_name += gd.deinflected;
      json_escape(os, trace_name);
      os << R"(,"description":""}])";
    } else {
      os << "[]";
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
  std::ostringstream os;
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

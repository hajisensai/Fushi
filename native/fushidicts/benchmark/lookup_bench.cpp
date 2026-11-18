// 查词基准：对一段真实正文的**每个码点位置**做一次 Lookup::lookup（等价于读者把
// 光标依次悬停在每个字上），量端到端耗时，并把结果集落盘成可逐字节比对的文本。
//
//   lookup_bench <manifest.tsv> <transforms 目录> <语料.txt>
//       [--iters N]        语料重复跑 N 轮（默认 3；第 1 轮含冷页，单独报）
//       [--scan N]         scan_length（默认 16）
//       [--max N]          max_results（默认 16）
//       [--window N]       每次查词送进引擎的码点数（默认 24）
//       [--no-materialize] LookupOptions::materialize = false（分词路径）
//       [--stages]         另外单量 文本预处理 / 预处理 + 变形还原 两段
//       [--dump <文件>]    把每次查词的完整结果写进文件（改引擎前后 diff 用）
//       [--union <目录>]   先同步准备联合过滤器（目录 = 缓存目录；写 mem = 只在内存建）
//       [--upgrade]        不查词：对清单里每本词典调 fushidicts::upgrade_dictionary
//                          （允许 meta 重写；--upgrade-index-only 只换索引），打印每本的
//                          结果与耗时、总耗时、升级前后索引文件与记录文件的总字节数。
//                          **会改写词典目录**，只对副本用。
//       [--query-compare]  查词之后另量「拿词形查词频」：词表 = 每个查询串的首个命中词条，
//                          DictionaryQuery::query 对 query_frequencies 各跑 iters 遍，并核对
//                          两者的词条 / 词频逐项相同（不同则退出码 1）。
//
// manifest.tsv：每行 `类型<TAB>词典目录[<TAB>备注]`，类型取 term / frequency / pitch
// （与 app 的 dictionary_metadata.type 同词），行序 = 注册顺序。
// transforms 目录：fushi/assets/transforms（读 manifest.json 列出的每种语言）。
//
// 结果指纹（fingerprint）覆盖 matched / deinflected / 变形链 / 预处理步数 / 词条 /
// 每条 glossary 的词典名与正文 / 频率 / 音调，顺序敏感：两次构建指纹相同即查词结果
// 逐字节相同。
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <numeric>
#include <string>
#include <unordered_set>
#include <string_view>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "fushidicts/upgrade.hpp"
#include "scan/word_scan.hpp"
#include "text_processor/text_processor.hpp"

namespace {

using Clock = std::chrono::steady_clock;

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "cannot open %s\n", path.c_str());
    std::exit(2);
  }
  return std::string(std::istreambuf_iterator<char>(in), {});
}

std::vector<std::string> split_lines(const std::string& text) {
  std::vector<std::string> lines;
  size_t start = 0;
  while (start <= text.size()) {
    size_t nl = text.find('\n', start);
    if (nl == std::string::npos) nl = text.size();
    std::string line = text.substr(start, nl - start);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (!line.empty()) lines.push_back(std::move(line));
    start = nl + 1;
  }
  return lines;
}

// manifest.json 是一个字符串数组（["ja","en",...]），不引 JSON 库，直接抠引号。
std::vector<std::string> parse_string_array(const std::string& json) {
  std::vector<std::string> out;
  size_t pos = 0;
  while ((pos = json.find('"', pos)) != std::string::npos) {
    const size_t end = json.find('"', pos + 1);
    if (end == std::string::npos) break;
    out.push_back(json.substr(pos + 1, end - pos - 1));
    pos = end + 1;
  }
  return out;
}

size_t utf8_len(unsigned char lead) {
  if (lead < 0x80) return 1;
  if ((lead >> 5) == 0x6) return 2;
  if ((lead >> 4) == 0xe) return 3;
  if ((lead >> 3) == 0x1e) return 4;
  return 1;
}

// 每个码点位置起、最多 window 个码点的查询串。
std::vector<std::string> build_queries(const std::vector<std::string>& lines, size_t window) {
  std::vector<std::string> queries;
  for (const std::string& line : lines) {
    std::vector<size_t> starts;
    for (size_t i = 0; i < line.size(); i += utf8_len(static_cast<unsigned char>(line[i]))) {
      starts.push_back(i);
    }
    starts.push_back(line.size());
    for (size_t i = 0; i + 1 < starts.size(); i++) {
      const size_t end = starts[std::min(i + window, starts.size() - 1)];
      if (line[starts[i]] == ' ') continue;
      queries.push_back(line.substr(starts[i], end - starts[i]));
    }
  }
  return queries;
}

struct Fnv {
  uint64_t h = 1469598103934665603ULL;
  void add(std::string_view s) {
    for (unsigned char c : s) {
      h ^= c;
      h *= 1099511628211ULL;
    }
    h ^= 0xff;
    h *= 1099511628211ULL;
  }
  void add(int64_t v) { add(std::string_view(reinterpret_cast<const char*>(&v), sizeof(v))); }
};

std::string describe(const std::string& query, const std::vector<LookupResult>& results) {
  std::string out = "Q " + query + "\n";
  for (const LookupResult& r : results) {
    out += "  R " + r.matched + " | " + r.deinflected + " | " + r.term.expression + " | " + r.term.reading +
           " | rules=" + r.term.rules + " | steps=" + std::to_string(r.preprocessor_steps) +
           " | score=" + std::to_string(r.term.score) + " | trace=";
    for (const TransformGroup& g : r.trace) out += g.name + ">";
    out += "\n";
    for (const GlossaryEntry& g : r.term.glossaries) {
      Fnv body;
      body.add(g.glossary);
      out += "    G " + g.dict_name + " | " + g.definition_tags + " | " + g.term_tags + " | csize=" +
             std::to_string(g.compressed_size) + " | len=" + std::to_string(g.glossary.size()) + " | h=" +
             std::to_string(body.h) + "\n";
    }
    for (const FrequencyEntry& f : r.term.frequencies) {
      out += "    F " + f.dict_name + " |";
      for (const Frequency& v : f.frequencies) out += " " + std::to_string(v.value) + "(" + v.display_value + ")";
      out += "\n";
    }
    for (const PitchEntry& p : r.term.pitches) {
      out += "    P " + p.dict_name + " |";
      for (const Pitch& v : p.pitches) {
        out += " " + std::to_string(v.position) + "[" + v.pattern + "]n";
        for (int n : v.nasal) out += std::to_string(n) + ",";
        out += "d";
        for (int d : v.devoice) out += std::to_string(d) + ",";
      }
      for (const std::string& t : p.transcriptions) out += " ipa:" + t;
      out += "\n";
    }
  }
  return out;
}

struct Stats {
  double total_ms = 0;
  double avg_us = 0;
  double p50_us = 0;
  double p90_us = 0;
  double p99_us = 0;
  double max_us = 0;
};

Stats summarize(std::vector<double> us) {
  Stats s;
  if (us.empty()) return s;
  std::ranges::sort(us);
  const double total = std::accumulate(us.begin(), us.end(), 0.0);
  const auto at = [&us](double q) { return us[std::min(us.size() - 1, static_cast<size_t>(q * us.size()))]; };
  s.total_ms = total / 1000.0;
  s.avg_us = total / us.size();
  s.p50_us = at(0.50);
  s.p90_us = at(0.90);
  s.p99_us = at(0.99);
  s.max_us = us.back();
  return s;
}

void print_stats(const char* label, const Stats& s) {
  std::printf("%-22s total %9.1f ms | avg %8.1f us | p50 %8.1f | p90 %8.1f | p99 %8.1f | max %9.1f\n", label,
              s.total_ms, s.avg_us, s.p50_us, s.p90_us, s.p99_us, s.max_us);
}

double elapsed_us(Clock::time_point start) {
  return std::chrono::duration<double, std::micro>(Clock::now() - start).count();
}

// 词典目录里索引文件（key.index + hash.table + bloom.filter）与记录文件（blobs.bin +
// blobs3.bin）的字节数。
struct DirBytes {
  uint64_t index = 0;
  uint64_t records = 0;
};

DirBytes dir_bytes(const std::string& dir) {
  DirBytes out;
  const auto size_of = [&](const char* name) -> uint64_t {
    std::error_code ec;
    const auto n = std::filesystem::file_size(std::filesystem::u8path(dir + "/" + name), ec);
    return ec ? 0 : static_cast<uint64_t>(n);
  };
  out.index = size_of("key.index") + size_of("hash.table") + size_of("bloom.filter");
  out.records = size_of("blobs.bin") + size_of("blobs3.bin");
  return out;
}

int run_upgrade(const std::vector<std::string>& dirs, bool allow_meta_rewrite) {
  const char* names[] = {"failed", "up-to-date", "upgraded", "not-applicable"};
  DirBytes before_total;
  DirBytes after_total;
  int failures = 0;
  const auto all_start = Clock::now();
  for (const std::string& dir : dirs) {
    const DirBytes before = dir_bytes(dir);
    const auto start = Clock::now();
    fushidicts::UpgradeResult r = fushidicts::UpgradeResult::Failed;
    try {
      r = fushidicts::upgrade_dictionary(dir, allow_meta_rewrite);
    } catch (const std::exception& e) {
      std::fprintf(stderr, "%s: exception %s\n", dir.c_str(), e.what());
    }
    const double ms = elapsed_us(start) / 1000.0;
    const DirBytes after = dir_bytes(dir);
    if (r == fushidicts::UpgradeResult::Failed) failures++;
    std::printf("upgrade %-50s %-14s %9.1f ms | index %11llu -> %11llu | records %11llu -> %11llu\n", dir.c_str(),
                names[static_cast<int>(r) + 1], ms, static_cast<unsigned long long>(before.index),
                static_cast<unsigned long long>(after.index), static_cast<unsigned long long>(before.records),
                static_cast<unsigned long long>(after.records));
    before_total.index += before.index;
    before_total.records += before.records;
    after_total.index += after.index;
    after_total.records += after.records;
  }
  std::printf("upgrade total %.1f ms | index bytes %llu -> %llu | record bytes %llu -> %llu | failures %d\n",
              elapsed_us(all_start) / 1000.0, static_cast<unsigned long long>(before_total.index),
              static_cast<unsigned long long>(after_total.index), static_cast<unsigned long long>(before_total.records),
              static_cast<unsigned long long>(after_total.records), failures);
  return failures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr,
                 "usage: %s <manifest.tsv> <transforms dir> <corpus.txt> [--iters N] [--scan N] [--max N] "
                 "[--window N] [--no-materialize] [--stages] [--dump file] [--union dir|mem] [--upgrade|--upgrade-index-only]\n",
                 argv[0]);
    return 1;
  }
  const std::string manifest_path = argv[1];
  const std::string transforms_dir = argv[2];
  const std::string corpus_path = argv[3];
  int iters = 3;
  size_t scan_length = 16;
  int max_results = 16;
  size_t window = 24;
  bool materialize = true;
  bool stages = false;
  std::string dump_path;
  bool use_union = false;
  std::string union_dir;
  int upgrade = 0;  // 0 不升级 / 1 允许 meta 重写 / 2 只换索引
  bool query_compare = false;
  for (int i = 4; i < argc; i++) {
    const std::string_view arg = argv[i];
    const auto next = [&]() -> const char* { return i + 1 < argc ? argv[++i] : "0"; };
    if (arg == "--iters") {
      iters = std::atoi(next());
    } else if (arg == "--scan") {
      scan_length = static_cast<size_t>(std::atoi(next()));
    } else if (arg == "--max") {
      max_results = std::atoi(next());
    } else if (arg == "--window") {
      window = static_cast<size_t>(std::atoi(next()));
    } else if (arg == "--no-materialize") {
      materialize = false;
    } else if (arg == "--stages") {
      stages = true;
    } else if (arg == "--dump") {
      dump_path = next();
    } else if (arg == "--union") {
      use_union = true;
      union_dir = next();
      if (union_dir == "mem") union_dir.clear();
    } else if (arg == "--query-compare") {
      query_compare = true;
    } else if (arg == "--upgrade") {
      upgrade = 1;
    } else if (arg == "--upgrade-index-only") {
      upgrade = 2;
    }
  }

  if (upgrade != 0) {
    std::vector<std::string> dirs;
    for (const std::string& line : split_lines(read_file(manifest_path))) {
      const size_t tab = line.find('\t');
      if (tab == std::string::npos) continue;
      size_t tab2 = line.find('\t', tab + 1);
      if (tab2 == std::string::npos) tab2 = line.size();
      dirs.push_back(line.substr(tab + 1, tab2 - tab - 1));
    }
    return run_upgrade(dirs, upgrade == 1);
  }

  DictionaryQuery query;
  size_t terms = 0;
  size_t freqs = 0;
  size_t pitches = 0;
  const auto load_start = Clock::now();
  for (const std::string& line : split_lines(read_file(manifest_path))) {
    const size_t tab = line.find('\t');
    if (tab == std::string::npos) continue;
    const std::string type = line.substr(0, tab);
    size_t tab2 = line.find('\t', tab + 1);
    if (tab2 == std::string::npos) tab2 = line.size();
    const std::string path = line.substr(tab + 1, tab2 - tab - 1);
    if (type == "term") {
      query.add_term_dict(path);
      terms++;
    } else if (type == "frequency" || type == "freq") {
      query.add_freq_dict(path);
      freqs++;
    } else if (type == "pitch") {
      query.add_pitch_dict(path);
      pitches++;
    }
  }
  const double load_ms = elapsed_us(load_start) / 1000.0;
  if (use_union) {
    const auto union_start = Clock::now();
    query.prepare_union_filter(union_dir, /*wait=*/true);
    std::printf("union filter: %s in %.1f ms (%s)\n",
                query.union_filter_state() == UnionFilterState::Ready ? "ready" : "NOT READY",
                elapsed_us(union_start) / 1000.0, union_dir.empty() ? "memory" : union_dir.c_str());
  }

  Deinflector deinflector;
  for (const std::string& lang : parse_string_array(read_file(transforms_dir + "/manifest.json"))) {
    deinflector.load_transforms_json(read_file(transforms_dir + "/" + lang + ".json"));
  }
  Lookup lookup(query, deinflector);

  const std::vector<std::string> queries = build_queries(split_lines(read_file(corpus_path)), window);
  std::printf("dicts: %zu term / %zu freq / %zu pitch (load %.1f ms) | queries: %zu | scan %zu | max %d | %s\n",
              terms, freqs, pitches, load_ms, queries.size(), scan_length, max_results,
              materialize ? "materialize" : "no-materialize");

  LookupOptions options;
  options.materialize = materialize;

  Fnv fingerprint;
  size_t total_results = 0;
  std::string dump;
  for (int iter = 0; iter < iters; iter++) {
    std::vector<double> us;
    us.reserve(queries.size());
    for (const std::string& q : queries) {
      const auto start = Clock::now();
      const std::vector<LookupResult> results = lookup.lookup(q, max_results, scan_length, options);
      us.push_back(elapsed_us(start));
      if (iter == 0) {
        total_results += results.size();
        const std::string text = describe(q, results);
        fingerprint.add(text);
        if (!dump_path.empty()) dump += text;
      }
    }
    char label[32];
    std::snprintf(label, sizeof(label), "lookup iter %d%s", iter, iter == 0 ? " (cold)" : "");
    print_stats(label, summarize(us));
  }
  std::printf("results: %zu | fingerprint: %016llx\n", total_results,
              static_cast<unsigned long long>(fingerprint.h));

  if (!dump_path.empty()) {
    std::ofstream out(dump_path, std::ios::binary);
    out.write(dump.data(), static_cast<std::streamsize>(dump.size()));
  }

  if (query_compare) {
    // 「拿一个词形查它的词频」（Anki 卡组按词频重排）：词表取每个查询串的首个命中词条，
    // 去重；query() 与 query_frequencies() 各跑 iters 遍，并核对两者的词条与词频逐项相同。
    std::vector<std::string> words;
    {
      std::unordered_set<std::string> seen;
      for (const std::string& q : queries) {
        const std::vector<LookupResult> results = lookup.lookup(q, 1, scan_length, options);
        if (!results.empty() && seen.insert(results[0].term.expression).second) {
          words.push_back(results[0].term.expression);
        }
      }
    }
    const auto describe_freq = [](const std::vector<TermResult>& terms) {
      std::string out;
      for (const TermResult& t : terms) {
        out += t.expression + "|" + t.reading + "|" + t.rules + "|";
        for (const FrequencyEntry& f : t.frequencies) {
          out += f.dict_name + ":";
          for (const Frequency& v : f.frequencies) out += std::to_string(v.value) + "/" + v.display_value + ",";
          out += ";";
        }
        out += "\n";
      }
      return out;
    };
    size_t mismatches = 0;
    size_t glossary_bytes = 0;
    for (const std::string& w : words) {
      const std::vector<TermResult> full = query.query(w);
      const std::vector<TermResult> freq = query.query_frequencies(w);
      if (describe_freq(full) != describe_freq(freq)) mismatches++;
      for (const TermResult& t : full) {
        for (const GlossaryEntry& g : t.glossaries) glossary_bytes += g.glossary.size();
      }
    }
    std::printf("query-compare: %zu words | mismatches %zu | query() decompresses %.1f KB per word\n", words.size(),
                mismatches, words.empty() ? 0.0 : glossary_bytes / 1024.0 / words.size());
    for (int iter = 0; iter < iters; iter++) {
      std::vector<double> full_us;
      std::vector<double> freq_us;
      for (const std::string& w : words) {
        auto start = Clock::now();
        const std::vector<TermResult> a = query.query(w);
        full_us.push_back(elapsed_us(start));
        start = Clock::now();
        const std::vector<TermResult> b = query.query_frequencies(w);
        freq_us.push_back(elapsed_us(start));
      }
      char label[48];
      std::snprintf(label, sizeof(label), "query() iter %d", iter);
      print_stats(label, summarize(full_us));
      std::snprintf(label, sizeof(label), "query_frequencies() iter %d", iter);
      print_stats(label, summarize(freq_us));
    }
    return mismatches == 0 ? 0 : 1;
  }

  if (stages) {
    // 预处理：每个查询串的每个扫描候选各跑一遍 text_processor::process。
    size_t variants = 0;
    size_t deinflections = 0;
    std::vector<double> process_us;
    std::vector<double> deinflect_us;
    for (const std::string& q : queries) {
      auto start = Clock::now();
      std::vector<std::vector<TextVariant>> per_candidate;
      for (const std::string& candidate : scan_candidates(q, scan_length)) {
        per_candidate.push_back(text_processor::process(candidate));
      }
      process_us.push_back(elapsed_us(start));
      start = Clock::now();
      for (const auto& vs : per_candidate) {
        variants += vs.size();
        for (const TextVariant& v : vs) deinflections += deinflector.deinflect(v.text).size();
      }
      deinflect_us.push_back(elapsed_us(start));
    }
    print_stats("stage: preprocess", summarize(process_us));
    print_stats("stage: deinflect", summarize(deinflect_us));
    std::printf("per lookup: %.1f variants, %.1f deinflections (= query_raw calls, before reassembly / mixed)\n",
                static_cast<double>(variants) / queries.size(), static_cast<double>(deinflections) / queries.size());
  }
  return 0;
}

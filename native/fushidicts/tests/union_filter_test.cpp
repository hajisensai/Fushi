// 联合过滤器（hash/union_filter.hpp）：一条缓存行回答「这个键可能在哪几本词典里」，
// 取代查库时逐本词典各探一次自己的 bloom.filter。
//
// 它是纯加速结构，契约只有一条：**不改变任何查词结果**。所以这里验的是：
//   1. 过滤器层——无假阴性（每本词典 hash.table 的每个键都判「可能在」）、假阳性率在
//      设计值附近、与词典次序无关；
//   2. 缓存文件——落盘后二次装载、坏文件（校验和不符 / 截断 / 魔数错）被拒并重建、
//      超集缓存可复用、过大的超集不复用、目录不可用时退回堆内；
//   2b. key.index 来源——过滤器建在键的 tag 上，从 key.index 枚举出的 tag 与从 hash.table
//      取的 tag 一样能建；混装两种来源时同样无假阴性、假阳性在设计值附近；
//   3. 引擎层——真导入的 term / freq / pitch 词典上（新式 key.index 与旧式 hash.table
//      两种导入各跑一遍），有过滤器与没有过滤器时
//      Lookup::lookup / DictionaryQuery::query 的结果逐字段相同（含排除词典）；
//      add_*_dict 之后过滤器作废、新词典立刻查得到；后台构建最终就绪；引擎销毁时
//      构建线程已收回、不留文件映射。
//
// Usage: union_filter_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <optional>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "hash/hash.hpp"
#include "hash/key_index.hpp"
#include "hash/union_filter.hpp"
#include "memory/memory.hpp"
#include "legacy_index_env.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

void expect(bool ok, const std::string& what) {
  if (!ok) fail(what);
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::ostringstream buf;
  buf << in.rdbuf();
  return buf.str();
}

// ── 合成 hash.table ──────────────────────────────────────────────────────────
//
// 与导入端同布局：[u32 capacity][slot{u64 hash, u64 offset} x capacity]，线性探测，
// capacity = max(n * 10 / 7, 16)（hash.cpp build_to_file）。
struct FakeTable {
  uint64_t identity = 0;
  std::vector<uint64_t> keys;
  std::vector<uint8_t> bytes;

  hash::union_filter::source source() const {
    return {.identity = identity, .table = bytes.data(), .table_size = bytes.size()};
  }
};

// 假键哈希的来源：确定性的 splitmix64 序列。真键是词条的 XXH3，同样是均匀的 64 位值；
// 这里只要「均匀、可复现」，与随机性的安全强度无关。
struct KeySequence {
  uint64_t state;

  uint64_t operator()() {
    uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
  }
};

FakeTable make_table(uint64_t identity, size_t count, KeySequence& rng) {
  FakeTable t;
  t.identity = identity;
  const uint32_t capacity = static_cast<uint32_t>(std::max<size_t>(count * 10 / 7, 16));
  t.bytes.assign(sizeof(uint32_t) + static_cast<size_t>(capacity) * 16, 0);
  std::memcpy(t.bytes.data(), &capacity, sizeof(capacity));
  uint8_t* slots = t.bytes.data() + sizeof(uint32_t);
  while (t.keys.size() < count) {
    const uint64_t h = rng();
    if (h == 0) continue;
    uint64_t pos = h % capacity;
    bool duplicate = false;
    while (true) {
      uint64_t stored = 0;
      std::memcpy(&stored, slots + pos * 16, sizeof(stored));
      if (stored == 0) break;
      if (stored == h) {
        duplicate = true;
        break;
      }
      pos = (pos + 1) % capacity;
    }
    if (duplicate) continue;
    const uint64_t offset = t.keys.size() + 1;
    std::memcpy(slots + pos * 16, &h, sizeof(h));
    std::memcpy(slots + pos * 16 + 8, &offset, sizeof(offset));
    t.keys.push_back(h);
  }
  return t;
}

std::vector<hash::union_filter::source> sources_of(const std::vector<const FakeTable*>& tables) {
  std::vector<hash::union_filter::source> out;
  for (const FakeTable* t : tables) out.push_back(t->source());
  return out;
}

// 每本词典的每个键都得判「可能在」。
void expect_no_false_negatives(const hash::union_filter& filter, const std::vector<const FakeTable*>& tables,
                               const char* what) {
  for (const FakeTable* t : tables) {
    for (const uint64_t h : t->keys) {
      if (!hash::union_filter::maybe(filter.at(h), t->identity)) {
        fail(std::string(what) + ": false negative (a key the dictionary holds was rejected)");
        return;
      }
    }
  }
}

std::vector<std::string> cache_files(const std::string& dir) {
  std::vector<std::string> names;
  std::error_code ec;
  for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
    names.push_back(entry.path().filename().string());
  }
  std::ranges::sort(names);
  return names;
}

void test_filter_properties() {
  KeySequence rng{20261116};
  const FakeTable a = make_table(0xA11CE0000000001ULL, 40000, rng);
  const FakeTable b = make_table(0xB0B00000000002ULL, 25000, rng);
  const FakeTable c = make_table(0xC0FFEE0000000003ULL, 9, rng);  // 小到只有最小 capacity
  const std::vector<const FakeTable*> all = {&a, &b, &c};

  const auto filter = hash::union_filter::build(sources_of(all));
  if (!filter) {
    fail("build returned null for a non-empty source set");
    return;
  }
  expect(!filter->file_backed(), "build() must be heap-backed");
  expect(filter->identities().size() == 3, "identities must list every source once");
  expect(std::ranges::is_sorted(filter->identities()), "identities must be sorted");
  expect_no_false_negatives(*filter, all, "heap filter");

  // 假阳性：键不在任何词典里时，每本词典被判「可能在」的概率。设计值约千分之一；
  // 放到 1% 作上限（防的是位布局写错后假阳性成十倍抬升，那会让过滤器白建）。
  size_t false_positives = 0;
  const size_t trials = 200000;
  for (size_t i = 0; i < trials; i++) {
    const uint64_t h = rng();
    const auto probe = filter->at(h);
    for (const FakeTable* t : all) {
      if (hash::union_filter::maybe(probe, t->identity)) ++false_positives;
    }
  }
  const double rate = static_cast<double>(false_positives) / static_cast<double>(trials * all.size());
  if (rate > 0.01) {
    fail("false positive rate too high: " + std::to_string(rate));
  }

  // 一本词典的键对另一本词典同样只是「偶尔假阳性」：位的位置取决于（键, 词典身份），
  // 不是只取决于键——否则装了五十本词典时每个命中都会把其余四十九本一起放行。
  size_t cross = 0;
  for (const uint64_t h : a.keys) {
    if (hash::union_filter::maybe(filter->at(h), b.identity)) ++cross;
  }
  if (static_cast<double>(cross) / static_cast<double>(a.keys.size()) > 0.01) {
    fail("keys of one dictionary leak into another: " + std::to_string(cross) + " of " +
         std::to_string(a.keys.size()));
  }

  // 与词典次序、重复登记无关（同一本词典被装进多个桶时只算一次）。
  const auto shuffled = hash::union_filter::build(sources_of({&c, &a, &b, &a}));
  expect(shuffled && shuffled->identities() == filter->identities(), "order / duplicates must not matter");
  expect(shuffled && shuffled->num_blocks() == filter->num_blocks(), "duplicate source must not grow the filter");

  expect(hash::union_filter::build({}) == nullptr, "empty source set yields no filter");

  // 截断的 hash.table（capacity 字段大于文件实际容纳的槽数，BUG-1303 的同一口径）：
  // 按实际槽数建，不越界读。
  FakeTable truncated = make_table(0xD00D0000000004ULL, 1000, rng);
  truncated.bytes.resize(sizeof(uint32_t) + 16 * 100 + 7);
  const auto from_truncated = hash::union_filter::build(sources_of({&truncated}));
  expect(from_truncated != nullptr, "truncated table still yields a filter");
}

// 用同一组键建一份 key.index（offset / single 随便给：过滤器只看 tag）。
struct FakeKeyIndex {
  uint64_t identity = 0;
  std::vector<uint64_t> keys;
  memory::mapped_file file;
  hash::key_index index;

  FakeKeyIndex() = default;
  FakeKeyIndex(const FakeKeyIndex&) = delete;
  FakeKeyIndex& operator=(const FakeKeyIndex&) = delete;
  ~FakeKeyIndex() {
    if (file) memory::unmap_unflushed(file);
  }

  hash::union_filter::source source() const { return {.identity = identity, .keys = &index}; }
};

bool make_key_index(const FakeTable& from, const std::string& path, FakeKeyIndex& out) {
  std::vector<hash::key_index::entry> entries;
  for (size_t i = 0; i < from.keys.size(); i++) {
    entries.push_back({.hash = from.keys[i], .offset = i, .single = (i & 1) != 0});
  }
  std::filesystem::remove(path);
  if (!hash::key_index::build_to_file(entries, hash::key_index::blobs_file::original, path)) return false;
  out.identity = from.identity;
  out.keys = from.keys;
  out.file = memory::map_rd(path);
  return out.file && out.index.load(out.file.data, out.file.size);
}

void test_key_index_sources(const std::string& root) {
  KeySequence rng{777};
  const FakeTable a = make_table(0x5151000000000001ULL, 40000, rng);
  const FakeTable b = make_table(0x6262000000000002ULL, 30000, rng);
  const FakeTable c = make_table(0x7373000000000003ULL, 20000, rng);
  FakeKeyIndex ka;
  FakeKeyIndex kb;
  if (!make_key_index(a, root + "/a.index", ka) || !make_key_index(b, root + "/b.index", kb)) {
    fail("could not build key.index sources");
    return;
  }
  expect(ka.index.num_keys() == a.keys.size(), "key.index source reports its key count");

  // 混装：两本 key.index + 一本旧式 hash.table。
  const std::vector<hash::union_filter::source> sources = {ka.source(), kb.source(), c.source()};
  const auto filter = hash::union_filter::build(sources);
  if (!filter) {
    fail("build returned null for key.index sources");
    return;
  }
  expect(filter->identities().size() == 3, "mixed sources: every identity listed");
  for (const FakeKeyIndex* k : {&ka, &kb}) {
    for (const uint64_t h : k->keys) {
      if (!hash::union_filter::maybe(filter->at(h), k->identity)) {
        fail("key.index source: false negative");
        break;
      }
    }
  }
  expect_no_false_negatives(*filter, {&c}, "legacy source next to key.index sources");

  size_t false_positives = 0;
  const size_t trials = 200000;
  for (size_t i = 0; i < trials; i++) {
    const auto probe = filter->at(rng());
    for (const uint64_t id : {ka.identity, kb.identity, c.identity}) {
      if (hash::union_filter::maybe(probe, id)) ++false_positives;
    }
  }
  const double rate = static_cast<double>(false_positives) / static_cast<double>(trials * 3);
  if (rate > 0.01) fail("key.index sources: false positive rate too high: " + std::to_string(rate));

  // 同一组键，从 key.index 建与从 hash.table 建：键数估计不同（key.index 有确数）所以块数
  // 可能不同，但都无假阴性；文件后备的那份也一样。
  const auto from_table = hash::union_filter::build(sources_of({&a}));
  const auto from_index = hash::union_filter::open_or_build(std::vector<hash::union_filter::source>{ka.source()},
                                                            root + "/ki_cache");
  expect(from_table && from_index && from_index->file_backed(), "single-source filters build");
  if (from_table && from_index) {
    for (const uint64_t h : a.keys) {
      if (!hash::union_filter::maybe(from_table->at(h), a.identity) ||
          !hash::union_filter::maybe(from_index->at(h), a.identity)) {
        fail("single-source filter: false negative");
        break;
      }
    }
    expect(from_index->num_blocks() <= from_table->num_blocks(),
           "a key.index source sizes the filter from its exact key count");
  }
}

void test_cache_file(const std::string& root) {
  KeySequence rng{42};
  const FakeTable a = make_table(0x1111000000000001ULL, 30000, rng);
  const FakeTable b = make_table(0x2222000000000002ULL, 30000, rng);
  const FakeTable c = make_table(0x3333000000000003ULL, 2000, rng);
  const FakeTable big = make_table(0x4444000000000004ULL, 200000, rng);

  const std::string dir = root + "/cache";
  std::filesystem::remove_all(dir);

  // 首次：目录不存在也要建出来，产物是文件后备。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &c}), dir);
    if (!filter) {
      fail("open_or_build returned null");
      return;
    }
    expect(filter->file_backed(), "first open_or_build must produce a file-backed filter");
    expect_no_false_negatives(*filter, {&a, &b, &c}, "file filter");
  }
  const std::vector<std::string> first = cache_files(dir);
  expect(first.size() == 1, "exactly one cache file after the first build");
  if (first.size() != 1) return;
  const std::string cache_path = dir + "/" + first.front();
  {
    std::vector<uint64_t> ids = {a.identity, b.identity, c.identity};
    std::ranges::sort(ids);
    expect(first.front() == hash::union_filter::cache_file_name(ids), "cache file is named after the identity set");
  }
  const auto first_time = std::filesystem::last_write_time(cache_path);
  const auto first_size = std::filesystem::file_size(cache_path);

  // 二次：直接装载，不重写。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&c, &b, &a}), dir);
    expect(filter && filter->file_backed(), "second open must load the cache");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &c}, "reloaded filter");
    expect(cache_files(dir) == first, "reload must not create another file");
    expect(std::filesystem::last_write_time(cache_path) == first_time, "reload must not rewrite the cache");
  }

  // 超集复用：关掉一本词典（集合变成 {a, b}），原来那份照用。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b}), dir);
    expect(filter && filter->file_backed(), "subset must be served from the superset cache");
    expect(filter && filter->identities().size() == 3, "superset cache keeps its own identity list");
    if (filter) expect_no_false_negatives(*filter, {&a, &b}, "superset filter");
    expect(cache_files(dir) == first, "superset reuse must not create another file");
  }

  // 校验和不符（块区被改了一个字节）：不能用，重建。断电留下的整片零块同此路径——
  // 零块意味着「哪本词典都没有这个键」，照用就是无声的漏查。
  {
    std::fstream f(cache_path, std::ios::in | std::ios::out | std::ios::binary);
    f.seekp(static_cast<std::streamoff>(first_size - 64));
    const char zeros[64] = {};
    f.write(zeros, sizeof(zeros));
  }
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &c}), dir);
    expect(filter != nullptr, "corrupt cache must be rebuilt, not fail");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &c}, "filter rebuilt over a corrupt cache");
  }

  // 截断。
  std::filesystem::resize_file(cache_path, first_size / 2);
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &c}), dir);
    expect(filter != nullptr, "truncated cache must be rebuilt, not fail");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &c}, "filter rebuilt over a truncated cache");
    expect(std::filesystem::file_size(cache_path) == first_size, "rebuilt cache has the full size again");
  }

  // 魔数不对（别的格式 / 将来的版本）。
  {
    std::fstream f(cache_path, std::ios::in | std::ios::out | std::ios::binary);
    f.write("NOTAFILT", 8);
  }
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &c}), dir);
    expect(filter != nullptr, "foreign-magic cache must be rebuilt, not fail");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &c}, "filter rebuilt over a foreign file");
  }

  // 身份列表被改（最后一项 c 换成另一本词典 d 的身份，仍然有序）：这份文件自称覆盖
  // {a, b, d}，可块区里根本没有 d 的键——照用的话 d 的每个键都判「肯定不在」。校验和
  // 把文件头和身份列表也算在内，所以它装不进来，{a, b, d} 得到一份真正含 d 的过滤器。
  {
    const FakeTable d = make_table(c.identity + 1, 2000, rng);
    {
      std::fstream f(cache_path, std::ios::in | std::ios::out | std::ios::binary);
      f.seekp(64 + 2 * sizeof(uint64_t));
      f.write(reinterpret_cast<const char*>(&d.identity), sizeof(d.identity));
    }
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &d}), dir);
    expect(filter != nullptr, "a cache with a tampered identity list must be rebuilt, not fail");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &d}, "filter rebuilt over a tampered identity list");
  }

  // 集合变了（多了一本）：建新文件，旧文件清掉，不无限堆积。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b, &c, &big}), dir);
    expect(filter && filter->file_backed(), "a grown set must get its own cache");
    if (filter) expect_no_false_negatives(*filter, {&a, &b, &c, &big}, "grown filter");
  }
#ifndef _WIN32
  // Windows 上仍被映射着的旧文件删不掉（上面的 filter 已析构，但不依赖这点）。
  expect(cache_files(dir).size() == 1, "stale cache files are removed once a new one is in place");
#endif

  // 过大的超集不复用：只剩 c（两千键）时，为二十多万键建的那份大出一倍以上，
  // 白占页缓存，重建一份合身的。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&c}), dir);
    expect(filter && filter->identities().size() == 1, "an oversized superset cache must not be reused");
    if (filter) expect_no_false_negatives(*filter, {&c}, "right-sized filter");
  }

  // 缓存目录不可用（这里：路径是个普通文件）：退回堆内，照常可用。
  {
    const std::string blocker = root + "/not_a_dir";
    std::filesystem::remove_all(blocker);
    {
      std::ofstream out(blocker, std::ios::binary);
      out << "x";
    }
    const auto filter = hash::union_filter::open_or_build(sources_of({&a, &b}), blocker);
    expect(filter != nullptr, "unusable cache dir must fall back to a heap filter");
    expect(filter && !filter->file_backed(), "fallback filter is heap-backed");
    if (filter) expect_no_false_negatives(*filter, {&a, &b}, "fallback filter");
  }

  // 空目录参数 = 只在内存里建。
  {
    const auto filter = hash::union_filter::open_or_build(sources_of({&a}), "");
    expect(filter && !filter->file_backed(), "empty cache dir means heap-only");
  }

  // 叫停：不出成果，也不在缓存目录里留下半截文件。
  {
    const std::string cancel_dir = root + "/cancelled";
    std::filesystem::remove_all(cancel_dir);
    const std::atomic<bool> cancel{true};
    expect(hash::union_filter::build(sources_of({&big, &a}), &cancel) == nullptr, "a cancelled heap build yields nothing");
    expect(hash::union_filter::open_or_build(sources_of({&big, &a}), cancel_dir, &cancel) == nullptr,
           "a cancelled file build yields nothing");
    expect(cache_files(cancel_dir).empty(), "a cancelled build leaves no file behind");
    // 没被叫停的标志不影响结果。
    const std::atomic<bool> go{false};
    const auto filter = hash::union_filter::open_or_build(sources_of({&big, &a}), cancel_dir, &go);
    expect(filter && filter->file_backed(), "an un-cancelled flag builds normally");
    if (filter) expect_no_false_negatives(*filter, {&big, &a}, "filter built with a cancel flag attached");
  }
}

// ── 引擎层 ───────────────────────────────────────────────────────────────────

std::string row(const std::string& expr, const std::string& reading, const std::string& rules,
                const std::string& glossary) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"" + rules + "\",0,[\"" + glossary + "\"],0,\"\"]";
}

std::string bank(const std::vector<std::string>& rows) {
  std::string out = "[";
  for (size_t i = 0; i < rows.size(); i++) {
    if (i) out += ",";
    out += rows[i];
  }
  return out + "]";
}

std::string import_zip(const char* label, const std::string& title, const std::vector<fushi_test::ZipFile>& extra,
                       const std::string& out_dir) {
  std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"1\"}"},
  };
  files.insert(files.end(), extra.begin(), extra.end());
  ImportResult r = dictionary_importer::import(fushi_test::write_zip(label, files), out_dir);
  if (!r.success) {
    fail(std::string("import ") + label + " failed: " + (r.errors.empty() ? "(no error)" : r.errors.front()));
    return {};
  }
  return out_dir + "/" + r.title;
}

// 一次查词的完整结果，逐字段、顺序敏感。
std::string dump(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.matched + "|" + r.deinflected + "|" + r.term.expression + "|" + r.term.reading + "|" +
         r.term.rules + "|" + std::to_string(r.preprocessor_steps);
    for (const TransformGroup& g : r.trace) s += "/" + g.name;
    for (const GlossaryEntry& g : r.term.glossaries) s += "{" + g.dict_name + ":" + g.glossary + "}";
    for (const FrequencyEntry& f : r.term.frequencies) {
      s += "<" + f.dict_name;
      for (const Frequency& v : f.frequencies) s += ":" + std::to_string(v.value) + "," + v.display_value;
      s += ">";
    }
    for (const PitchEntry& p : r.term.pitches) {
      s += "(" + p.dict_name;
      for (const Pitch& v : p.pitches) s += ":" + std::to_string(v.position);
      s += ")";
    }
    s += "]";
  }
  return s;
}

std::string dump_terms(const std::vector<TermResult>& terms) {
  std::string s;
  for (const TermResult& t : terms) {
    s += "[" + t.expression + "|" + t.reading + "|" + t.rules;
    for (const GlossaryEntry& g : t.glossaries) s += "{" + g.dict_name + ":" + g.glossary + "}";
    for (const FrequencyEntry& f : t.frequencies) s += "<" + f.dict_name + ">";
    for (const PitchEntry& p : t.pitches) s += "(" + p.dict_name + ")";
    s += "]";
  }
  return s;
}

bool wait_ready(const DictionaryQuery& query) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
  while (query.union_filter_state() != UnionFilterState::Ready) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return true;
}

// [legacy]：词典按旧式导入（hash.table + bloom.filter），否则新式（key.index）。
void test_engine(const std::string& ja_json, const std::string& root, bool legacy) {
  std::optional<fushi_test::ScopedLegacyIndex> legacy_scope;
  if (legacy) legacy_scope.emplace();
  const std::string out_dir = root + "/dicts";
  std::filesystem::remove_all(out_dir);

  // 三本释义词典，键互有重叠（猫 三本都有、食べる 两本、其余各一本），再加频率 / 音调。
  const std::string main_dict = import_zip(
      "uf_main", "UfMain",
      {{"term_bank_1.json", bank({
                                row("猫", "ねこ", "n", "cat"),
                                row("食べる", "たべる", "v1", "to eat"),
                                row("棚", "たな", "n", "shelf"),
                                row("棚に上げる", "たなにあげる", "v1", "to shelve"),
                                row("上げる", "あげる", "v1", "to raise"),
                                row("走る", "はしる", "v5", "to run"),
                            })}},
      out_dir);
  const std::string second_dict = import_zip(
      "uf_second", "UfSecond",
      {{"term_bank_1.json", bank({
                                row("猫", "ねこ", "n", "feline"),
                                row("食べる", "たべる", "v1", "to consume"),
                                row("犬", "いぬ", "n", "dog"),
                            })}},
      out_dir);
  const std::string third_dict = import_zip(
      "uf_third", "UfThird",
      {{"term_bank_1.json", bank({
                                row("猫", "ねこ", "n", "neko"),
                                row("鳥", "とり", "n", "bird"),
                            })}},
      out_dir);
  const std::string freq_dict = import_zip(
      "uf_freq", "UfFreq",
      {{"term_meta_bank_1.json",
        "[[\"猫\",\"freq\",120],[\"食べる\",\"freq\",{\"reading\":\"たべる\",\"frequency\":45}],"
        "[\"犬\",\"freq\",300],[\"走る\",\"freq\",77]]"}},
      out_dir);
  const std::string pitch_dict = import_zip(
      "uf_pitch", "UfPitch",
      {{"term_meta_bank_1.json",
        "[[\"猫\",\"pitch\",{\"reading\":\"ねこ\",\"pitches\":[{\"position\":1}]}],"
        "[\"食べる\",\"pitch\",{\"reading\":\"たべる\",\"pitches\":[{\"position\":2}]}]]"}},
      out_dir);
  const std::string late_dict = import_zip(
      "uf_late", "UfLate",
      {{"term_bank_1.json", bank({
                                row("魚", "さかな", "n", "fish"),
                                row("猫", "ねこ", "n", "late cat"),
                            })}},
      out_dir);
  if (main_dict.empty() || second_dict.empty() || third_dict.empty() || freq_dict.empty() || pitch_dict.empty() ||
      late_dict.empty()) {
    return;
  }
  for (const std::string& dir : {main_dict, freq_dict, pitch_dict}) {
    expect(std::filesystem::exists(dir + "/key.index") == !legacy &&
               std::filesystem::exists(dir + "/hash.table") == legacy,
           std::string("fixture is in the ") + (legacy ? "legacy" : "key.index") + " layout: " + dir);
  }

  const auto load = [&](DictionaryQuery& q) {
    q.add_term_dict(main_dict);
    q.add_term_dict(second_dict);
    q.add_term_dict(third_dict);
    q.add_freq_dict(freq_dict);
    q.add_pitch_dict(pitch_dict);
  };
  Deinflector deinflector;
  deinflector.load_transforms_json(ja_json);

  DictionaryQuery plain;
  load(plain);
  expect(plain.union_filter_state() == UnionFilterState::None, "no filter until one is prepared");
  Lookup plain_lookup(plain, deinflector);

  const std::string cache_dir = root + "/engine_cache";
  std::filesystem::remove_all(cache_dir);
  DictionaryQuery filtered;
  load(filtered);
  filtered.prepare_union_filter(cache_dir, /*wait=*/true);
  expect(filtered.union_filter_state() == UnionFilterState::Ready, "synchronous prepare leaves the filter ready");
  expect(!cache_files(cache_dir).empty(), "prepare writes the cache file into the given directory");
  Lookup filtered_lookup(filtered, deinflector);

  const std::vector<std::string> queries = {
      "猫",          "猫が食べた",     "食べられなかった", "棚にあげて、", "棚に上げる", "走った犬",
      "鳥",          "いぬ",           "ねこ",             "とりあえず",   "存在しない", "zzz",
      "たべませんでした", "犬と猫と鳥", "",
  };
  for (const std::string& q : queries) {
    const std::string want = dump(plain_lookup.lookup(q, 16, 16));
    const std::string got = dump(filtered_lookup.lookup(q, 16, 16));
    if (want != got) {
      fail("lookup(\"" + q + "\") differs with the union filter:\n  plain   : " + want + "\n  filtered: " + got);
    }
    const std::string want_terms = dump_terms(plain.query(q));
    const std::string got_terms = dump_terms(filtered.query(q));
    if (want_terms != got_terms) {
      fail("query(\"" + q + "\") differs with the union filter:\n  plain   : " + want_terms +
           "\n  filtered: " + got_terms);
    }
  }
  // 自检：上面的比较不是两边都空。
  expect(dump(filtered_lookup.lookup("猫が食べた", 16, 16)).find("{UfThird:") != std::string::npos,
         "fixture sanity: 猫 is served from all three term dictionaries");
  expect(dump(filtered_lookup.lookup("猫", 16, 16)).find("<UfFreq:120") != std::string::npos,
         "fixture sanity: frequency enrichment goes through the filter");
  expect(dump(filtered_lookup.lookup("猫", 16, 16)).find("(UfPitch:1") != std::string::npos,
         "fixture sanity: pitch enrichment goes through the filter");

  // 排除词典：与没有过滤器时相同（排除在过滤器之前判）。
  {
    LookupOptions options;
    options.excluded_dictionaries = {"UfSecond", "UfFreq"};
    const std::string want = dump(plain_lookup.lookup("猫が食べた", 16, 16, options));
    const std::string got = dump(filtered_lookup.lookup("猫が食べた", 16, 16, options));
    expect(want == got, "excluded dictionaries behave the same with the union filter");
    expect(got.find("UfSecond") == std::string::npos && got.find("UfFreq") == std::string::npos,
           "excluded dictionaries stay excluded");
  }

  // 装进一本新词典：旧过滤器不认识它，必须作废（否则新词典的键全被判「肯定不在」）。
  filtered.add_term_dict(late_dict);
  plain.add_term_dict(late_dict);
  expect(filtered.union_filter_state() == UnionFilterState::None, "add_dict invalidates the filter");
  {
    const std::string got = dump(filtered_lookup.lookup("魚", 16, 16));
    expect(got.find("{UfLate:") != std::string::npos, "a dictionary added after the filter is still found");
    expect(got == dump(plain_lookup.lookup("魚", 16, 16)), "post-add lookup matches the unfiltered engine");
  }

  // 后台构建：不等，轮询到就绪；期间与之后的结果都与无过滤器一致。
  filtered.prepare_union_filter(cache_dir, /*wait=*/false);
  expect(filtered.union_filter_state() != UnionFilterState::None, "async prepare reports building or ready");
  expect(dump(filtered_lookup.lookup("猫", 16, 16)) == dump(plain_lookup.lookup("猫", 16, 16)),
         "lookups during the build match the unfiltered engine");
  if (!wait_ready(filtered)) {
    fail("async prepare never became ready");
    return;
  }
  for (const std::string& q : {std::string("魚"), std::string("猫が食べた"), std::string("存在しない")}) {
    expect(dump(filtered_lookup.lookup(q, 16, 16)) == dump(plain_lookup.lookup(q, 16, 16)),
           "lookup(\"" + q + "\") after the async rebuild matches the unfiltered engine");
  }
  expect(dump(filtered_lookup.lookup("猫", 16, 16)).find("{UfLate:") != std::string::npos,
         "the rebuilt filter covers the late dictionary");

  // 重复 prepare 幂等（后一次叫停并取代前一次）。
  filtered.prepare_union_filter(cache_dir, /*wait=*/false);
  filtered.prepare_union_filter(cache_dir, /*wait=*/false);
  filtered.prepare_union_filter(cache_dir, /*wait=*/true);
  expect(filtered.union_filter_state() == UnionFilterState::Ready, "repeated prepare stays ready");

  // 引擎销毁时构建线程必须已经收回：线程撑着每本词典 hash.table 的映射，留着它的话
  // 「释放映射后马上删词典目录」在 Windows 上会撞文件占用（BUG-1756 的形状）。
  // 反复「起后台构建 → 立刻销毁」，每一轮结束后进程里的共享映射数都必须回到起点。
  // 这是概率性的探测（线程若没被收回，要它恰好还没跑完才看得出来），所以多跑几十轮；
  // 这本词典很小、构建是亚毫秒级的，真正的保证在 ~DictionaryQuery 的 join 上。
  {
    const size_t before = memory::live_shared_mappings();
    for (int round = 0; round < 50; round++) {
      {
        DictionaryQuery transient;
        transient.add_term_dict(third_dict);
        transient.prepare_union_filter(root + "/transient_cache", /*wait=*/false);
      }
      if (memory::live_shared_mappings() != before) {
        fail("a destroyed engine left file mappings behind (build thread still running?)");
        break;
      }
    }
  }

  // 没有词典的引擎：无事可做，不建过滤器、不崩。
  {
    DictionaryQuery empty;
    empty.prepare_union_filter(cache_dir, /*wait=*/true);
    expect(empty.union_filter_state() == UnionFilterState::None, "an empty engine has no filter");
    expect(empty.query("猫").empty(), "an empty engine finds nothing");
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <ja.json>\n", argv[0]);
    return 2;
  }
  const std::string ja_json = read_file(argv[1]);
  if (ja_json.empty()) {
    fail("cannot read ja.json");
    return 1;
  }
  const std::string root = fushi_test::temp_dir() + "/fushi_union_filter_test";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);

  test_filter_properties();
  test_cache_file(root);
  test_key_index_sources(root);
  test_engine(ja_json, root + "/engine_new", /*legacy=*/false);
  test_engine(ja_json, root + "/engine_legacy", /*legacy=*/true);

  if (g_fail == 0) std::printf("PASS union_filter_test\n");
  return g_fail == 0 ? 0 : 1;
}

// key.index（hash/key_index.hpp）的性质：
//   1. 无假阴性——每个键都能在主桶或备桶的候选里找到自己的位置（offset / single 原样）；
//      主桶里没有、且主桶不带溢出位时，键一定不存在（这是「一条缓存行判不在」的依据）。
//   2. 枚举出的 slot 正好是全部键（联合过滤器与整本扫描靠它）。
//   3. 大小在预期之内（约 9 字节 / 键），住在主桶的键占多数。
//   4. 装不进本格式的输入（offset 超 32 位）返回 false 而不是写出坏文件；坏文件（魔数 /
//      截断 / 多余字节）装载失败。
//   5. 空索引、只有一个键的索引可用。
//   6. 一个键的查找路径上 tag 相同的 slot 只有它自己（「核对第一条记录」精确的前提）；
//      构建遇到歧义会换桶数拆开，拆不开就拒绝。

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "hash/key_index.hpp"
#include "memory/memory.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

void expect(bool ok, const std::string& what) {
  if (!ok) fail(what);
}

// 确定性的 splitmix64 序列：均匀、可复现的假键哈希。
struct KeySequence {
  uint64_t state;

  uint64_t operator()() {
    uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
  }
};

std::vector<hash::key_index::entry> make_entries(size_t count, uint64_t seed) {
  KeySequence seq{seed};
  std::vector<hash::key_index::entry> entries;
  entries.reserve(count);
  for (size_t i = 0; i < count; i++) {
    const uint64_t h = seq();
    entries.push_back({.hash = h, .offset = (seq() & 0xFFFFFFFFULL), .single = (seq() & 3) != 0});
  }
  return entries;
}

struct Loaded {
  memory::mapped_file file;
  hash::key_index index;

  ~Loaded() { memory::unmap_unflushed(file); }
};

bool open_index(const std::string& path, Loaded& out) {
  out.file = memory::map_rd(path);
  return out.file && out.index.load(out.file.data, out.file.size);
}

bool has(const hash::key_index::candidates& c, const hash::key_index::entry& e) {
  for (uint32_t i = 0; i < c.count; i++) {
    if (c.at[i].offset == e.offset && c.at[i].single == e.single) {
      return true;
    }
  }
  return false;
}

void check_roundtrip(const std::string& dir, size_t count, uint64_t seed) {
  const std::string label = "n=" + std::to_string(count);
  const std::string path = dir + "/key_" + std::to_string(count) + ".index";
  const auto entries = make_entries(count, seed);
  expect(hash::key_index::build_to_file(entries, hash::key_index::blobs_file::original, path), label + ": build");

  Loaded loaded;
  if (!open_index(path, loaded)) {
    fail(label + ": load");
    return;
  }
  const hash::key_index& index = loaded.index;
  expect(index.num_keys() == count, label + ": num_keys");
  expect(index.blobs() == hash::key_index::blobs_file::original, label + ": blobs file");

  size_t in_primary = 0;
  size_t missing = 0;
  size_t ambiguous = 0;
  for (const auto& e : entries) {
    const auto first = index.primary(e.hash);
    if (has(first, e)) {
      in_primary++;
      // 查找路径上 tag 相同的只有它自己。
      if (first.count != 1) ambiguous++;
      continue;
    }
    // 不在主桶的键：主桶必须带溢出位，否则查询端会在这里断定「不在」。
    const auto second = index.alternate(e.hash);
    if (!first.more || !has(second, e)) {
      missing++;
    }
    // 住在备桶的键：主桶里不得有 tag 相同的别人，备桶里只有它自己。
    if (first.count != 0 || second.count != 1) ambiguous++;
  }
  expect(missing == 0, label + ": " + std::to_string(missing) + " keys not reachable (false negatives)");
  expect(ambiguous == 0, label + ": " + std::to_string(ambiguous) + " keys share a tag with another key on their path");
  if (count >= 1000) {
    expect(in_primary * 10 >= count * 7, label + ": most keys should sit in their primary bucket, got " +
                                             std::to_string(in_primary) + "/" + std::to_string(count));
    const double bytes_per_key = static_cast<double>(std::filesystem::file_size(path)) / static_cast<double>(count);
    expect(bytes_per_key < 9.5, label + ": bytes per key " + std::to_string(bytes_per_key));
  }

  // 枚举 = 全部键，各一次。
  std::vector<std::pair<uint32_t, uint64_t>> listed;
  index.for_each_slot([&](uint32_t tag, hash::key_index::location where) -> bool {
    listed.emplace_back(tag, (where.offset << 1) | (where.single ? 1 : 0));
    return true;
  });
  std::vector<std::pair<uint32_t, uint64_t>> expected;
  for (const auto& e : entries) {
    expected.emplace_back(hash::key_index::tag_of(e.hash), (e.offset << 1) | (e.single ? 1 : 0));
  }
  std::ranges::sort(listed);
  std::ranges::sort(expected);
  expect(listed == expected, label + ": enumeration must list every key exactly once");

  // 不存在的键：候选极少（tag 29 位），且绝大多数只看主桶就结束。
  KeySequence other{seed ^ 0xABCDEF};
  size_t candidates = 0;
  size_t second_probes = 0;
  const size_t probes = 200000;
  for (size_t i = 0; i < probes; i++) {
    const uint64_t h = other();
    const auto first = index.primary(h);
    candidates += first.count;
    if (first.more) {
      second_probes++;
      candidates += index.alternate(h).count;
    }
  }
  expect(candidates <= 2, label + ": absent keys produced " + std::to_string(candidates) + " tag candidates");
  std::printf("%s: primary %.1f%%, absent probes needing alternate %.1f%%, %.2f bytes/key\n", label.c_str(),
              count ? 100.0 * static_cast<double>(in_primary) / static_cast<double>(count) : 0.0,
              100.0 * static_cast<double>(second_probes) / static_cast<double>(probes),
              count ? static_cast<double>(std::filesystem::file_size(path)) / static_cast<double>(count) : 0.0);
  if (count >= 1000) {
    expect(second_probes * 2 < probes, label + ": too many absent probes need the alternate bucket (" +
                                           std::to_string(second_probes) + "/" + std::to_string(probes) + ")");
  }
}

// tag 歧义：两个 tag 相同的键落进同一条查找路径时，构建要换桶数把它们拆开；拆不开
// （哈希高 32 位也相同，主桶永远是同一个）就拒绝，交还调用方用旧式索引。
void check_tag_ambiguity(const std::string& dir) {
  using hash::key_index;
  const uint64_t tag = 0x1234567;

  // 可拆开：20 个键起步是 3 个桶。两个键 tag 相同、哈希高 32 位分别在 0x40000000 两侧
  // ——3 个桶时都落在 0 号桶（< 0x55555555），4 个桶时一个在 0 号、一个在 1 号。放在最前
  // 面，第一遍排布就一起进主桶。
  {
    std::vector<key_index::entry> entries = {
        {.hash = (0x3FFFFFFFULL << 32) | tag, .offset = 111, .single = true},
        {.hash = (0x40000001ULL << 32) | tag, .offset = 222, .single = false},
    };
    for (const auto& e : make_entries(18, 21)) {
      entries.push_back(e);
    }
    expect(key_index::bucket1(entries[0].hash, 3) == key_index::bucket1(entries[1].hash, 3),
           "fixture: the pair must collide with 3 buckets");
    const std::string path = dir + "/ambiguous.index";
    expect(key_index::build_to_file(entries, key_index::blobs_file::original, path),
           "a separable tag collision must still build");
    Loaded loaded;
    if (!open_index(path, loaded)) {
      fail("ambiguous: load");
    } else {
      for (size_t i = 0; i < 2; i++) {
        const auto first = loaded.index.primary(entries[i].hash);
        const auto second = loaded.index.alternate(entries[i].hash);
        const bool in_first = has(first, entries[i]);
        const std::string label = "ambiguous pair key " + std::to_string(i);
        expect(in_first || (first.more && has(second, entries[i])), label + ": reachable");
        // 路径上 tag 相同的 slot 只有它自己——候选唯一，核对第一条记录即精确。
        expect(in_first ? first.count == 1 : (first.count == 0 && second.count == 1),
               label + ": must be the only tag match on its path");
      }
    }
  }

  // 拆不开：哈希只在 29～31 位不同，tag 与主桶恒相同。
  {
    auto entries = make_entries(50, 22);
    entries.push_back({.hash = (0x80000000ULL << 32) | tag, .offset = 1, .single = true});
    entries.push_back({.hash = (0x80000000ULL << 32) | (1ULL << 30) | tag, .offset = 2, .single = true});
    const std::string path = dir + "/inseparable.index";
    expect(!key_index::build_to_file(entries, key_index::blobs_file::original, path),
           "an inseparable tag collision must be refused");
    expect(!std::filesystem::exists(path), "a refused build must not create the file");
  }
}

void check_rejects(const std::string& dir) {
  // offset 超 32 位：装不进，返回 false，不留文件给人误用。
  auto entries = make_entries(100, 7);
  entries[42].offset = 0x1'0000'0000ULL;
  const std::string big = dir + "/big.index";
  expect(!hash::key_index::build_to_file(entries, hash::key_index::blobs_file::original, big),
         "offsets beyond 32 bits must be refused");
  expect(!std::filesystem::exists(big), "a refused build must not create the file");

  // 记录文件标记原样带回。
  entries = make_entries(100, 8);
  const std::string rewritten = dir + "/rewritten.index";
  expect(hash::key_index::build_to_file(entries, hash::key_index::blobs_file::rewritten, rewritten),
         "build with rewritten blobs");
  {
    Loaded loaded;
    expect(open_index(rewritten, loaded) && loaded.index.blobs() == hash::key_index::blobs_file::rewritten,
           "blobs file marker roundtrip");
  }

  const auto size = std::filesystem::file_size(rewritten);
  // 截断 / 多出字节 / 魔数错：都不是合法索引。
  std::filesystem::resize_file(rewritten, size - 64);
  {
    Loaded loaded;
    expect(!open_index(rewritten, loaded), "truncated index must not load");
  }
  std::filesystem::resize_file(rewritten, size + 64);
  {
    Loaded loaded;
    expect(!open_index(rewritten, loaded), "oversized index must not load");
  }
  std::filesystem::resize_file(rewritten, size);
  {
    std::fstream f(rewritten, std::ios::in | std::ios::out | std::ios::binary);
    f.write("NOTINDEX", 8);
  }
  {
    Loaded loaded;
    expect(!open_index(rewritten, loaded), "foreign magic must not load");
  }
}

}

int main() {
  const std::string dir = (std::filesystem::temp_directory_path() / "fushi_key_index_test").string();
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);

  check_roundtrip(dir, 0, 1);
  check_roundtrip(dir, 1, 2);
  check_roundtrip(dir, 9, 3);
  check_roundtrip(dir, 5000, 4);
  check_roundtrip(dir, 300000, 5);
  check_roundtrip(dir, 2000000, 6);
  check_tag_ambiguity(dir);
  check_rejects(dir);

  std::filesystem::remove_all(dir);
  if (g_fail != 0) {
    std::fprintf(stderr, "key_index_test: %d failure(s)\n", g_fail);
    return 1;
  }
  std::puts("PASS key_index_test");
  return 0;
}

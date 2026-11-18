#include "union_filter.hpp"

#include <xxh3.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <thread>

#include "../util/fs_utf8.hpp"
#include "hash.hpp"

namespace hash {
namespace {

// 缓存文件：
//   [file_header 64 字节][u64 identity x num_dicts（升序）][补零到 blocks_offset]
//   [块 x num_blocks，每块 64 字节]
// blocks_offset 是 4096 的倍数，映射后块按缓存行对齐。校验和覆盖文件头、身份列表和
// 整个块区（file_checksum）：断电留下的半截文件（改名已落盘、数据没落盘）会是整片的
// 零，零块 = 「哪本词典都没有这个键」；身份列表坏了则会谎称覆盖了某本词典——两种都是
// 无声的漏查，所以每次装载都验，不吻合就当没有这份缓存。也因为有它兜底，写文件时
// 不做同步刷盘。
constexpr uint64_t kMagic = 0x314C46494E554446ULL;  // "FDUNIFL1"（小端字节序）
// 2：块与块内位改由键的 tag（key_index::tag_of）决定（1 是完整 64 位哈希），旧文件
// 的位对不上，必须被拒。
constexpr uint32_t kVersion = 2;
constexpr uint64_t kBlocksAlign = 4096;
constexpr uint32_t kMaxDicts = 1U << 16;
constexpr std::string_view kFilePrefix = "union-";
constexpr std::string_view kFileSuffix = ".filter";
// 遗留临时文件（构建中途进程被杀）放过这么久才清：一次构建是秒级的。
constexpr std::chrono::minutes kStaleTmpAge{10};

struct file_header {
  uint64_t magic;
  uint32_t version;
  uint32_t num_dicts;
  uint64_t num_blocks;
  uint64_t blocks_offset;
  uint64_t checksum;
  // 位布局参数：改 kBitsPerPair / kPairsPerBlock / pair_bits 的任何一处都要让旧文件失效。
  uint64_t layout;
  uint64_t reserved[2];
};
static_assert(sizeof(file_header) == 64);

constexpr uint64_t kLayout =
    static_cast<uint64_t>(union_filter::kBitsPerPair) | (union_filter::kPairsPerBlock << 8) |
    (static_cast<uint64_t>(union_filter::kBlockBytes) << 24) | (static_cast<uint64_t>(key_index::kTagBits) << 40);

// [header]（checksum 字段按 0 计）+ 身份列表 + 块区的校验和。
uint64_t file_checksum(file_header header, std::span<const uint64_t> identities, const void* blocks,
                       uint64_t num_blocks) {
  header.checksum = 0;
  uint64_t seed = XXH3_64bits(&header, sizeof(header));
  seed = XXH3_64bits_withSeed(identities.data(), identities.size_bytes(), seed);
  return XXH3_64bits_withSeed(blocks, static_cast<size_t>(num_blocks * union_filter::kBlockBytes), seed);
}

uint64_t blocks_offset_for(size_t num_dicts) {
  const uint64_t raw = sizeof(file_header) + static_cast<uint64_t>(num_dicts) * sizeof(uint64_t);
  return (raw + kBlocksAlign - 1) / kBlocksAlign * kBlocksAlign;
}

// 去重、按身份升序的 sources（同一本词典被装进多个桶时只算一次）。
std::vector<union_filter::source> unique_sources(std::span<const union_filter::source> sources) {
  std::vector<union_filter::source> out(sources.begin(), sources.end());
  std::ranges::sort(out, {}, &union_filter::source::identity);
  const auto dup = std::ranges::unique(out, {}, &union_filter::source::identity);
  out.erase(dup.begin(), dup.end());
  return out;
}

// 键数（上界）：key.index 文件头里有确数；hash.table 按导入端的 capacity =
// max(n * 10 / 7, 16)（hash.cpp build_to_file）反推，n <= (capacity + 1) * 7 / 10。
// 多估只是过滤器略大，少估才抬假阳性。
uint64_t estimated_pairs(std::span<const union_filter::source> sources) {
  uint64_t total = 0;
  for (const union_filter::source& s : sources) {
    if (s.keys) {
      total += s.keys->num_keys() + 1;
      continue;
    }
    const uint64_t capacity = slot_capacity(s.table, s.table_size);
    total += (capacity + 1) * 7 / 10 + 1;
  }
  return total;
}

// 一本词典索引里每个键的 tag：visit(tag) 返回 false = 提前停止。
template <typename Visit>
void for_each_tag(const union_filter::source& s, Visit&& visit) {
  if (s.keys) {
    s.keys->for_each_slot([&](uint32_t tag, key_index::location) -> bool { return visit(tag); });
    return;
  }
  for_each_slot(s.table, s.table_size, [&](uint64_t h, uint64_t) -> bool { return visit(key_index::tag_of(h)); });
}

uint64_t blocks_for(uint64_t pairs) {
  const uint64_t blocks = (pairs + union_filter::kPairsPerBlock - 1) / union_filter::kPairsPerBlock;
  // block_index 用 32 位乘法定位，块数必须放得进 32 位（2^32 块 = 256 GB，到不了）。
  return std::clamp<uint64_t>(blocks, 1, 0xFFFFFFFFULL);
}

bool is_cache_file(const std::string& name) {
  return name.size() > kFilePrefix.size() + kFileSuffix.size() && name.starts_with(kFilePrefix) &&
         name.ends_with(kFileSuffix);
}

std::string join(const std::string& dir, const std::string& name) {
  if (dir.empty() || dir.back() == '/' || dir.back() == '\\') {
    return dir + name;
  }
  return dir + "/" + name;
}

}  // namespace

std::string union_filter::cache_file_name(std::span<const uint64_t> sorted_identities) {
  const uint64_t key = XXH3_64bits_withSeed(sorted_identities.data(), sorted_identities.size_bytes(), kLayout);
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(key));
  return std::string(kFilePrefix) + buf + std::string(kFileSuffix);
}

bool union_filter::fill(uint64_t* blocks, uint64_t num_blocks, std::span<const source> sources,
                        cancel_flag cancel) {
  // 每填这么多个键看一眼叫停标志：几万个键是几百微秒，叫停的响应在毫秒以内。
  constexpr uint32_t kCancelCheckEvery = 1U << 15;
  uint32_t until_check = kCancelCheckEvery;
  bool cancelled = false;
  for (const source& s : sources) {
    const uint64_t identity = s.identity;
    for_each_tag(s, [&](uint32_t tag) -> bool {
      if (cancel && --until_check == 0) {
        until_check = kCancelCheckEvery;
        if (cancel->load(std::memory_order_relaxed)) {
          cancelled = true;
          return false;
        }
      }
      uint64_t* block = blocks + block_index(tag, num_blocks) * kBlockWords;
      uint64_t x = pair_bits(tag, identity);
      for (unsigned i = 0; i < kBitsPerPair; i++) {
        const unsigned bit = static_cast<unsigned>(x & 511U);
        block[bit >> 6] |= uint64_t{1} << (bit & 63U);
        x >>= 9;
      }
      return true;
    });
    if (cancelled || (cancel && cancel->load(std::memory_order_relaxed))) {
      return false;
    }
  }
  return true;
}

std::shared_ptr<const union_filter> union_filter::build(std::span<const source> sources, cancel_flag cancel) {
  const std::vector<source> unique = unique_sources(sources);
  if (unique.empty()) {
    return nullptr;
  }
  auto filter = std::make_shared<union_filter>();
  filter->num_blocks_ = blocks_for(estimated_pairs(unique));
  filter->heap_.assign(filter->num_blocks_ * kBlockWords, 0);
  if (!fill(filter->heap_.data(), filter->num_blocks_, unique, cancel)) {
    return nullptr;
  }
  filter->blocks_ = filter->heap_.data();
  filter->identities_.reserve(unique.size());
  for (const source& s : unique) {
    filter->identities_.push_back(s.identity);
  }
  return filter;
}

std::shared_ptr<const union_filter> union_filter::load(const std::string& path, std::span<const uint64_t> needed,
                                                       uint64_t max_blocks) {
  memory::shared_mapping mapping = memory::map_rd_shared(path);
  if (!mapping || mapping->size < sizeof(file_header)) {
    return nullptr;
  }
  file_header header;
  std::memcpy(&header, mapping->data, sizeof(header));
  if (header.magic != kMagic || header.version != kVersion || header.layout != kLayout ||
      header.num_dicts == 0 || header.num_dicts > kMaxDicts || header.num_blocks == 0 ||
      header.num_blocks > 0xFFFFFFFFULL || header.blocks_offset != blocks_offset_for(header.num_dicts) ||
      mapping->size != header.blocks_offset + header.num_blocks * kBlockBytes) {
    return nullptr;
  }
  if (header.num_blocks > max_blocks) {
    return nullptr;
  }

  std::vector<uint64_t> identities(header.num_dicts);
  std::memcpy(identities.data(), mapping->data + sizeof(file_header), identities.size() * sizeof(uint64_t));
  if (!std::ranges::is_sorted(identities) || !std::ranges::includes(identities, needed)) {
    return nullptr;
  }

  const uint8_t* blocks = mapping->data + header.blocks_offset;
  if (file_checksum(header, identities, blocks, header.num_blocks) != header.checksum) {
    return nullptr;
  }

  auto filter = std::make_shared<union_filter>();
  filter->blocks_ = reinterpret_cast<const uint64_t*>(blocks);
  filter->num_blocks_ = header.num_blocks;
  filter->identities_ = std::move(identities);
  filter->mapping_ = std::move(mapping);
  return filter;
}

std::shared_ptr<const union_filter> union_filter::build_to_file(std::span<const source> sources,
                                                                std::span<const uint64_t> identities,
                                                                uint64_t num_blocks, const std::string& path,
                                                                cancel_flag cancel) {
  const uint64_t blocks_offset = blocks_offset_for(identities.size());
  const uint64_t file_size = blocks_offset + num_blocks * kBlockBytes;

  // 先写临时文件再改名：别的引擎（重载期的 shadow / 旧实例）可能正映射着同名文件，
  // 也可能同时在建同一份。
  const auto stamp = static_cast<unsigned long long>(std::chrono::steady_clock::now().time_since_epoch().count());
  const auto tid = static_cast<unsigned long long>(std::hash<std::thread::id>{}(std::this_thread::get_id()));
  char suffix[64];
  std::snprintf(suffix, sizeof(suffix), ".%llx-%llx.tmp", stamp, tid);
  const std::string tmp_path = path + suffix;

  memory::mapped_file out = memory::map_rw(tmp_path, static_cast<size_t>(file_size));
  if (!out) {
    return nullptr;
  }
  std::memset(out.data, 0, out.size);
  auto* blocks = reinterpret_cast<uint64_t*>(out.data + blocks_offset);
  if (!fill(blocks, num_blocks, sources, cancel)) {
    // 被叫停：调用方（引擎析构）正等着这条线程退出，别为一个马上要删的文件刷盘。
    memory::unmap_unflushed(out);
    std::error_code ignored;
    std::filesystem::remove(fushi::fs_path(tmp_path), ignored);
    return nullptr;
  }

  file_header header{};
  header.magic = kMagic;
  header.version = kVersion;
  header.num_dicts = static_cast<uint32_t>(identities.size());
  header.num_blocks = num_blocks;
  header.blocks_offset = blocks_offset;
  header.layout = kLayout;
  header.checksum = file_checksum(header, identities, blocks, num_blocks);
  std::memcpy(out.data, &header, sizeof(header));
  std::memcpy(out.data + sizeof(header), identities.data(), identities.size_bytes());
  // 不同步刷盘：没落盘就断电的文件过不了装载时的校验和，下次重建即可；而这里的刷盘
  // 是几十 MB 的阻塞 IO，期间引擎析构（叫停并等本线程）会被它拖住。
  memory::unmap_unflushed(out);

  std::error_code ec;
  std::filesystem::rename(fushi::fs_path(tmp_path), fushi::fs_path(path), ec);
  if (ec) {
    // 目标被占着换不掉（Windows：另一个引擎正映射着它）。那份若可用就直接用。
    std::error_code ignored;
    std::filesystem::remove(fushi::fs_path(tmp_path), ignored);
  }
  return load(path, identities, num_blocks);
}

std::shared_ptr<const union_filter> union_filter::open_or_build(std::span<const source> sources,
                                                                const std::string& cache_dir,
                                                                cancel_flag cancel) {
  const std::vector<source> unique = unique_sources(sources);
  if (unique.empty()) {
    return nullptr;
  }
  if (cache_dir.empty()) {
    return build(unique, cancel);
  }

  std::vector<uint64_t> identities;
  identities.reserve(unique.size());
  for (const source& s : unique) {
    identities.push_back(s.identity);
  }
  const uint64_t num_blocks = blocks_for(estimated_pairs(unique));
  // 超集缓存可用的上限：再大就说明它是为一套大得多的词典集合建的，位密度没问题但
  // 白占一倍以上的页缓存，重建一份合身的。
  const uint64_t max_blocks = num_blocks > 0x7FFFFFFFULL ? 0xFFFFFFFFULL : num_blocks * 2;

  const std::string exact_name = cache_file_name(identities);
  const std::string exact_path = join(cache_dir, exact_name);
  const std::filesystem::path dir = fushi::fs_path(cache_dir);
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);

  if (auto filter = load(exact_path, identities, max_blocks)) {
    return filter;
  }
  std::vector<std::string> others;
  for (std::filesystem::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
    const std::string name = fushi::fs_to_utf8(it->path().filename());
    if (is_cache_file(name) && name != exact_name) {
      others.push_back(name);
    }
  }
  for (const std::string& name : others) {
    if (auto filter = load(join(cache_dir, name), identities, max_blocks)) {
      return filter;
    }
  }

  auto filter = build_to_file(unique, identities, num_blocks, exact_path, cancel);
  if (!filter) {
    if (cancel && cancel->load(std::memory_order_relaxed)) {
      return nullptr;
    }
    // 写不了（只读目录 / 磁盘满 / 同名坏文件被占着换不掉）：这次用堆内的。
    return build(unique, cancel);
  }
  // 新文件已就位：别的缓存文件都覆盖不了当前集合（否则上面就用了），连同遗留的临时
  // 文件一起清掉。删不掉（仍被旧引擎映射着）就留给下一次。临时文件只清放了一阵子的
  // ——刚写的可能是另一个进程（主进程 / 查词弹窗进程）正在建的那份。
  const auto now = std::filesystem::file_time_type::clock::now();
  for (std::filesystem::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
    const std::string name = fushi::fs_to_utf8(it->path().filename());
    const bool stale_cache = is_cache_file(name) && name != exact_name;
    bool stale_tmp = false;
    if (name.starts_with(kFilePrefix) && name.ends_with(".tmp")) {
      std::error_code time_ec;
      const auto written = std::filesystem::last_write_time(it->path(), time_ec);
      stale_tmp = !time_ec && now - written > kStaleTmpAge;
    }
    if (stale_cache || stale_tmp) {
      std::error_code ignored;
      std::filesystem::remove(it->path(), ignored);
    }
  }
  return filter;
}

}  // namespace hash

#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string>

#include "../util/prefetch.hpp"

namespace hash {

// 一本词典的键索引（key.index），取代 hash.table + bloom.filter。
//
// 布局：[64 字节文件头][桶 x num_buckets]，一个桶正好一条缓存行：
//   [u32 word x 8][u32 offset x 8]
//   word = 键哈希的低 29 位（tag）| bit29 桶溢出 | bit30 占用 | bit31 single
// 每个键有主桶、备桶两个去处（都只由键哈希决定）。装载率 85%，约 9.4 字节 / 键
// （hash.table 是 16 字节 slot、70% 装载率 ≈ 22.9 字节 / 键，再加 bloom.filter）；
// 约 86% 的键住在主桶，查它们只读一条缓存行。
//
// 「桶溢出」记在主桶的 0 号 word 上：有键以本桶为主桶却住进了备桶。没有这个位的桶，
// 查一条缓存行就能断定「不在」；有的桶（不到四成）在主桶没找到时再看备桶。
//
// tag 只有 29 位，所以这里给出的是**候选**：tag 相同的 slot 未必就是要找的键，调用方
// 必须去 blobs 里核对记录上的键（hash/dict_index.hpp 的 record_has_key，看候选的第一条
// 记录）。核对之后结果是精确的——比 hash.table 的「64 位哈希相等即命中」还严。也正因为
// 有核对，才用得起截断 tag。
//
// 构建保证：一个键的查找路径（主桶；它住在备桶时还有备桶）上，tag 相同的 slot 只有它
// 自己。所以查一个存在的键，候选里 tag 相同的只会是它本人；查一个不存在的键，撞上的
// 候选的第一条记录上不会有这个键（记录上的键全都进了索引）。「只核对第一条记录」因此
// 不会把别的键的位置当成本键的返回。
//
// 上游 hoshidicts 2f0e5c5 换成了 PHF（4096 字节分区 + pilot 表，约 11 字节 / 键外加
// 一份 bloom，命中要读 pilot 和 slot 两处，且 30 位 tag 不核对记录）。这里采纳它的两个
// 思路——8 字节的截断 slot、单记录的键直接指向记录（single，省掉 offset 表那一跳）——
// 没有采纳 PHF 本身：有了记录核对，两选一的桶表更小、命中多数只读一条缓存行、构建是
// 线性的。
class key_index {
 public:
  static constexpr size_t kSlotsPerBucket = 8;
  static constexpr size_t kBucketBytes = 64;
  static constexpr size_t kHeaderBytes = 64;
  static constexpr uint32_t kTagBits = 29;
  static constexpr uint32_t kTagMask = (1U << kTagBits) - 1;

  // 键在 blobs 里的位置。single：offset 就是那唯一一条记录；否则 offset 指向
  // offset 表 [u32 count][u64 x count]。
  struct location {
    uint64_t offset = 0;
    bool single = false;
  };

  // 构建输入：一个键哈希一项（调用方保证哈希不重复）。
  struct entry {
    uint64_t hash;
    uint64_t offset;
    bool single;
  };

  // 记录所在的文件。存量 meta 词典原地升级时记录要重写，新记录写进另一个文件
  // （旧 blobs.bin 可能正被别的引擎映射着，Windows 上换不掉），由索引指明读哪一个。
  enum class blobs_file : uint32_t {
    original = 0,   // blobs.bin
    rewritten = 1,  // blobs3.bin
  };

  // 键哈希的 tag。联合过滤器按它建（hash/union_filter.hpp）：索引里只存得下 tag，
  // 过滤器要能从索引枚举出来，就只能建在 tag 上。
  static uint32_t tag_of(uint64_t h) { return static_cast<uint32_t>(h) & kTagMask; }

  // 写出 [path]（调用方负责 tmp + rename）。false = 这套键装不进本格式（某个 offset
  // 超过 32 位 / 键太多 / 排不出无 tag 歧义的布局——后者只有哈希高 32 位与 tag 都相同
  // 的键对才会），调用方保留旧式 hash.table。IO 失败抛 memory::map_error。
  static bool build_to_file(std::span<const entry> entries, blobs_file blobs, const std::string& path);

  // [data, size) 是 key.index 的整份映射。false = 不是合法的 key.index（魔数 / 版本 /
  // 大小对不上），对象保持未装载。
  bool load(const uint8_t* data, size_t size);
  bool loaded() const { return buckets_ != nullptr; }
  uint64_t num_keys() const { return num_keys_; }
  blobs_file blobs() const { return blobs_; }

  struct candidates {
    location at[kSlotsPerBucket];
    uint32_t count = 0;
    // 主桶带溢出位：[at] 里没有一个核对得上时，还要看 alternate()。
    bool more = false;
  };

  candidates primary(uint64_t h) const { return scan(bucket1(h, num_buckets_), tag_of(h), true); }
  candidates alternate(uint64_t h) const { return scan(bucket2(h, num_buckets_), tag_of(h), false); }
  void prefetch_primary(uint64_t h) const { FUSHI_PREFETCH(buckets_ + bucket1(h, num_buckets_) * kBucketBytes); }
  void prefetch_alternate(uint64_t h) const { FUSHI_PREFETCH(buckets_ + bucket2(h, num_buckets_) * kBucketBytes); }

  // 每个被占用的 slot：visit(tag, location) 返回 false = 提前停止。整本扫描与联合
  // 过滤器构建用。
  template <typename Visit>
  void for_each_slot(Visit&& visit) const {
    for (uint64_t b = 0; b < num_buckets_; b++) {
      uint32_t words[2 * kSlotsPerBucket];
      std::memcpy(words, buckets_ + b * kBucketBytes, sizeof(words));
      for (size_t s = 0; s < kSlotsPerBucket; s++) {
        if ((words[s] & kOccupiedBit) == 0) {
          continue;
        }
        if (!visit(words[s] & kTagMask,
                   location{.offset = words[kSlotsPerBucket + s], .single = (words[s] & kSingleBit) != 0})) {
          return;
        }
      }
    }
  }

  // 主桶 / 备桶编号（构建与查询共用）。num_buckets < 2^32。
  static uint64_t bucket1(uint64_t h, uint64_t num_buckets) { return ((h >> 32) * num_buckets) >> 32; }
  static uint64_t bucket2(uint64_t h, uint64_t num_buckets) {
    uint64_t x = h + 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    x ^= x >> 31;
    return ((x >> 32) * num_buckets) >> 32;
  }

 private:
  static constexpr uint32_t kOverflowBit = 1U << 29;
  static constexpr uint32_t kOccupiedBit = 1U << 30;
  static constexpr uint32_t kSingleBit = 1U << 31;

  candidates scan(uint64_t bucket, uint32_t tag, bool is_primary) const {
    candidates out;
    uint32_t words[2 * kSlotsPerBucket];
    std::memcpy(words, buckets_ + bucket * kBucketBytes, sizeof(words));
    out.more = is_primary && (words[0] & kOverflowBit) != 0;
    const uint32_t want = tag | kOccupiedBit;
    for (size_t s = 0; s < kSlotsPerBucket; s++) {
      if ((words[s] & (kTagMask | kOccupiedBit)) == want) {
        out.at[out.count++] = {.offset = words[kSlotsPerBucket + s], .single = (words[s] & kSingleBit) != 0};
      }
    }
    return out;
  }

  const uint8_t* buckets_ = nullptr;
  uint64_t num_buckets_ = 0;
  uint64_t num_keys_ = 0;
  blobs_file blobs_ = blobs_file::original;
};

}

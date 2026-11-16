#include "key_index.hpp"

#include <algorithm>
#include <limits>
#include <vector>

#include "../memory/memory.hpp"

namespace hash {
namespace {

constexpr char kMagic[8] = {'F', 'D', 'K', 'E', 'Y', 'I', 'X', '1'};
constexpr uint32_t kVersion = 1;
// 装载率目标 85%（每桶平均 6.8 个键）。实测（200 万键）：
//   90%  8.9 字节 / 键，80% 的键住主桶，50% 的桶带溢出位
//   85%  9.4 字节 / 键，86%，37%
//   80% 10.0 字节 / 键，90%，28%
// 再往高省不了多少字节，查询却要多读缓存行（住备桶的键、带溢出位的桶上的「不在」）。
constexpr uint64_t kKeysPerBucketX10 = 68;
constexpr int kMaxKicks = 512;

struct file_header {
  char magic[8];
  uint32_t version;
  uint32_t slots_per_bucket;
  uint64_t num_buckets;
  uint64_t num_keys;
  uint32_t blobs;
  uint8_t reserved[28];
};
static_assert(sizeof(file_header) == key_index::kHeaderBytes);

uint64_t next_random(uint64_t& state) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

// 把每个键放进主桶或备桶；[placed] 是 num_buckets x 8 格，存「键下标 + 1」，0 = 空。
// false = 这个桶数放不下（调用方加桶重来）。
bool place_all(std::span<const key_index::entry> entries, uint64_t num_buckets, std::vector<uint32_t>& placed) {
  constexpr size_t kSlots = key_index::kSlotsPerBucket;
  const auto free_slot = [&](uint64_t bucket) -> int {
    for (size_t s = 0; s < kSlots; s++) {
      if (placed[bucket * kSlots + s] == 0) {
        return static_cast<int>(s);
      }
    }
    return -1;
  };

  // 第一遍：主桶有空位的全放主桶（查它们只读一条缓存行）。
  std::vector<uint32_t> pending;
  for (size_t i = 0; i < entries.size(); i++) {
    const uint64_t b1 = key_index::bucket1(entries[i].hash, num_buckets);
    const int s = free_slot(b1);
    if (s >= 0) {
      placed[b1 * kSlots + static_cast<size_t>(s)] = static_cast<uint32_t>(i + 1);
    } else {
      pending.push_back(static_cast<uint32_t>(i + 1));
    }
  }

  // 第二遍：主桶满了的去备桶；备桶也满就随机踢一个出去，被踢的去它自己的另一个桶。
  uint64_t rng = 0x2545F4914F6CDD1DULL ^ (entries.size() * 0x9E3779B97F4A7C15ULL);
  for (uint32_t cur : pending) {
    uint64_t bucket = key_index::bucket2(entries[cur - 1].hash, num_buckets);
    int s = free_slot(bucket);
    if (s >= 0) {
      placed[bucket * kSlots + static_cast<size_t>(s)] = cur;
      continue;
    }
    bool done = false;
    for (int kick = 0; kick < kMaxKicks; kick++) {
      std::swap(cur, placed[bucket * kSlots + (next_random(rng) % kSlots)]);
      const uint64_t h = entries[cur - 1].hash;
      const uint64_t c1 = key_index::bucket1(h, num_buckets);
      const uint64_t c2 = key_index::bucket2(h, num_buckets);
      bucket = bucket == c1 ? c2 : c1;
      s = free_slot(bucket);
      if (s >= 0) {
        placed[bucket * kSlots + static_cast<size_t>(s)] = cur;
        done = true;
        break;
      }
    }
    if (!done) {
      return false;
    }
  }
  return true;
}

}

bool key_index::build_to_file(std::span<const entry> entries, blobs_file blobs, const std::string& path) {
  const uint64_t n = entries.size();
  if (n >= std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  if (std::ranges::any_of(entries,
                          [](const entry& e) { return e.offset > std::numeric_limits<uint32_t>::max(); })) {
    return false;
  }

  std::vector<uint32_t> placed;
  uint64_t num_buckets = std::max<uint64_t>(1, (n * 10 + kKeysPerBucketX10 - 1) / kKeysPerBucketX10);
  while (true) {
    if (num_buckets >= std::numeric_limits<uint32_t>::max()) {
      return false;
    }
    placed.assign(static_cast<size_t>(num_buckets) * kSlotsPerBucket, 0);
    if (place_all(entries, num_buckets, placed)) {
      break;
    }
    num_buckets += num_buckets / 64 + 1;
  }

  const size_t file_size = kHeaderBytes + static_cast<size_t>(num_buckets) * kBucketBytes;
  memory::mapped_file out = memory::map_rw(path, file_size);
  if (!out) {
    throw memory::map_error("failed to create key index");
  }

  file_header header{};
  std::memcpy(header.magic, kMagic, sizeof(kMagic));
  header.version = kVersion;
  header.slots_per_bucket = kSlotsPerBucket;
  header.num_buckets = num_buckets;
  header.num_keys = n;
  header.blobs = static_cast<uint32_t>(blobs);
  std::memcpy(out.data, &header, sizeof(header));

  // map_rw 给的是全零文件，逐桶在本地拼好再整桶写入。
  uint8_t* buckets = out.data + kHeaderBytes;
  for (uint64_t b = 0; b < num_buckets; b++) {
    uint32_t words[2 * kSlotsPerBucket] = {};
    bool any = false;
    for (size_t s = 0; s < kSlotsPerBucket; s++) {
      const uint32_t index = placed[b * kSlotsPerBucket + s];
      if (index == 0) {
        continue;
      }
      const entry& e = entries[index - 1];
      words[s] = tag_of(e.hash) | kOccupiedBit | (e.single ? kSingleBit : 0);
      words[kSlotsPerBucket + s] = static_cast<uint32_t>(e.offset);
      any = true;
    }
    if (any) {
      std::memcpy(buckets + b * kBucketBytes, words, sizeof(words));
    }
  }
  // 溢出位：键没住在主桶 → 主桶的 0 号 word 记一笔。
  for (uint64_t b = 0; b < num_buckets; b++) {
    for (size_t s = 0; s < kSlotsPerBucket; s++) {
      const uint32_t index = placed[b * kSlotsPerBucket + s];
      if (index == 0) {
        continue;
      }
      const uint64_t home = bucket1(entries[index - 1].hash, num_buckets);
      if (home == b) {
        continue;
      }
      uint32_t word0 = 0;
      std::memcpy(&word0, buckets + home * kBucketBytes, sizeof(word0));
      word0 |= kOverflowBit;
      std::memcpy(buckets + home * kBucketBytes, &word0, sizeof(word0));
    }
  }

  // 落盘再返回：调用方紧接着 rename 成 key.index，而它没有校验和可兜底。
  memory::unmap(out);
  return true;
}

bool key_index::load(const uint8_t* data, size_t size) {
  buckets_ = nullptr;
  num_buckets_ = 0;
  num_keys_ = 0;
  blobs_ = blobs_file::original;
  if (!data || size < kHeaderBytes) {
    return false;
  }
  file_header header;
  std::memcpy(&header, data, sizeof(header));
  if (std::memcmp(header.magic, kMagic, sizeof(kMagic)) != 0 || header.version != kVersion ||
      header.slots_per_bucket != kSlotsPerBucket || header.num_buckets == 0 ||
      header.num_buckets >= std::numeric_limits<uint32_t>::max() ||
      header.blobs > static_cast<uint32_t>(blobs_file::rewritten) ||
      size != kHeaderBytes + header.num_buckets * kBucketBytes) {
    return false;
  }
  buckets_ = data + kHeaderBytes;
  num_buckets_ = header.num_buckets;
  num_keys_ = header.num_keys;
  blobs_ = static_cast<blobs_file>(header.blobs);
  return true;
}

}

#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "../memory/memory.hpp"

// 联合过滤器：一条缓存行回答「这个键可能在哪几本词典里」。
//
// 一次用户查词要查库几百次（扫描前缀 × 文本变体 × 还原形，汉字假名混写通路还要再乘
// 候选读音数），每次查库原本要逐本词典各探一次自己的 bloom.filter——装了 50 本释义
// 词典就是一次查词近两万次探测，而这些探测九成九落空。各词典的 bloom 是互不相干的
// 文件，每次探测都是一次（常常是两次）缓存未命中，冷缓存下这就是查词耗时的大头。
//
// 这里把引擎里**全部词典**的键并进一份分块 Bloom：键哈希 h 选一个 64 字节的块（一条
// 缓存行），「键 h 在词典 d 里」在这个块里点 kBitsPerPair 个位，位的位置由 (h, d 的
// 身份) 决定。于是一次查库只读一条缓存行，就能对每本词典各判一次「肯定不在 / 可能在」，
// 只有「可能在」的那几本才去走各自的 hash.table。
//
// 性质：
//   * 无假阴性——过滤器由每本词典 hash.table 的全部非空槽位建成，与查询路径读的是同一
//     份槽位；说「肯定不在」的词典确实没有这个键，查词结果与逐本探测逐字节相同。
//   * 假阳性只多付一次 hash.table 探测（那里按 64 位哈希精确比较），不影响结果。
//   * 派生物，不是词典格式的一部分：不改任何词典目录，存量词典不必重导；文件丢了 /
//     坏了 / 词典集合变了就重建，没建好之前查询照走各词典自己的 bloom。
//
// 词典身份（identity）由调用方给（query.cpp：hash.table 的大小 + 修改时间 + 首页内容
// 哈希）。位的位置只依赖身份、不依赖词典在引擎里的次序，所以调整词典顺序不必重建；
// 一份过滤器覆盖的词典集合是当前集合的超集时同样可用（多出来的位只抬高假阳性），
// 关掉一本词典也不必重建。
namespace hash {

class union_filter {
 public:
  static constexpr size_t kBlockBytes = 64;
  static constexpr size_t kBlockWords = kBlockBytes / sizeof(uint64_t);
  // 每个（键, 词典）对点 7 个位、平均占 16 bit：块内约 32 对、位占用约 35%，单本词典
  // 的假阳性约千分之一——50 本词典一次查库平均多付不到 0.1 次 hash.table 探测。
  static constexpr unsigned kBitsPerPair = 7;
  static constexpr uint64_t kPairsPerBlock = 32;

  // 一本词典的 hash.table（已映射）与它的身份。
  struct source {
    uint64_t identity = 0;
    const uint8_t* table = nullptr;
    size_t table_size = 0;
  };

  // 键哈希 h 落在哪个块；随后对每本词典调 [maybe]。
  struct probe {
    const uint64_t* block = nullptr;
    uint64_t h = 0;
  };

  probe at(uint64_t h) const {
    return {.block = blocks_ + block_index(h, num_blocks_) * kBlockWords, .h = h};
  }

  // false = 身份为 [identity] 的词典肯定没有这个键。
  static bool maybe(const probe& p, uint64_t identity) {
    uint64_t x = pair_bits(p.h, identity);
    for (unsigned i = 0; i < kBitsPerPair; i++) {
      const unsigned bit = static_cast<unsigned>(x & 511U);
      if (((p.block[bit >> 6] >> (bit & 63U)) & 1U) == 0) {
        return false;
      }
      x >>= 9;
    }
    return true;
  }

  uint64_t num_blocks() const { return num_blocks_; }
  // 覆盖的词典身份（升序、去重）。
  const std::vector<uint64_t>& identities() const { return identities_; }
  // 文件后备（true）还是堆内（false）。只给测试 / 诊断观测。
  bool file_backed() const { return static_cast<bool>(mapping_); }

  // 构建中途可以叫停：[cancel] 非空且被置 true 后，构建尽快（毫秒内）放弃并返回空指针，
  // 写到一半的临时文件删掉。引擎销毁时靠它立刻收回构建线程——线程撑着每本词典
  // hash.table 的映射，不收回的话「释放映射后马上删词典目录」会撞文件占用。
  using cancel_flag = const std::atomic<bool>*;

  // 在堆里建一份。sources 为空（或被叫停）时返回空指针。
  static std::shared_ptr<const union_filter> build(std::span<const source> sources, cancel_flag cancel = nullptr);

  // 取一份覆盖 [sources] 的过滤器：[cache_dir] 非空时先找可用的缓存文件（身份集合是
  // 所需集合的超集、且不比现建的大一倍以上、校验和吻合），没有就建一份写进去再映射；
  // 目录不可写 / 磁盘满 / [cache_dir] 为空时退回堆内构建。sources 为空（或被叫停）时
  // 返回空指针。
  static std::shared_ptr<const union_filter> open_or_build(std::span<const source> sources,
                                                           const std::string& cache_dir,
                                                           cancel_flag cancel = nullptr);

  // 缓存文件名（不含目录）：由覆盖的身份集合决定。
  static std::string cache_file_name(std::span<const uint64_t> sorted_identities);

 private:
  static uint64_t block_index(uint64_t h, uint64_t num_blocks) { return ((h >> 32) * num_blocks) >> 32; }

  // (h, identity) → 63 个伪随机位，每 9 位是块内一个位的下标。固定 identity 时对 h 是
  // 双射，同一块里的不同键不会撞成同一组位。
  static uint64_t pair_bits(uint64_t h, uint64_t identity) {
    uint64_t x = (h ^ identity) * 0x9E3779B97F4A7C15ULL;
    x ^= x >> 32;
    x *= 0xD6E8FEB86659FD93ULL;
    x ^= x >> 32;
    return x;
  }

  // false = 被叫停，blocks 只填了一部分、不可用。
  static bool fill(uint64_t* blocks, uint64_t num_blocks, std::span<const source> sources, cancel_flag cancel);
  static std::shared_ptr<const union_filter> load(const std::string& path, std::span<const uint64_t> needed,
                                                  uint64_t max_blocks);
  static std::shared_ptr<const union_filter> build_to_file(std::span<const source> sources,
                                                           std::span<const uint64_t> identities,
                                                           uint64_t num_blocks, const std::string& path,
                                                           cancel_flag cancel);

  const uint64_t* blocks_ = nullptr;
  uint64_t num_blocks_ = 0;
  std::vector<uint64_t> identities_;
  std::vector<uint64_t> heap_;      // 堆内构建时的存储
  memory::shared_mapping mapping_;  // 文件后备时的映射
};

}  // namespace hash

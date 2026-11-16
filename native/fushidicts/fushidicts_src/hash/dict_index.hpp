#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>

#include "../memory/memory.hpp"
#include "bloom.hpp"
#include "hash.hpp"
#include "key_index.hpp"
#include "union_filter.hpp"

// 一本词典的键索引 + 记录文件：打开、查找、核对、整本枚举只在这里写一次。查询引擎
// （query.cpp add_dict）、整本扫描（词性 / 内容探测、redirect_glossary）、联合过滤器
// 的输入与存量升级（upgrade.cpp）都经它。
//
// 词典目录里有两种索引：
//   * key.index（hash/key_index.hpp）——新导入与升级过的词典。合法时只用它，旧文件
//     （若还在）不再映射。它的 blobs_file 标记决定记录在 blobs.bin 还是 blobs3.bin。
//   * hash.table + bloom.filter——旧式（存量词典、超 4 GiB 的词典）。
//
// 两种索引给出的位置都要核对记录上的键（record_has_key）：key.index 只存 29 位 tag，
// 给的是候选；hash.table 按 64 位哈希相等命中，核对之后连 64 位碰撞也排除了。
namespace hash {

using location = key_index::location;

// 词典目录里的文件名。
inline constexpr std::string_view kKeyIndexFile = "key.index";
inline constexpr std::string_view kHashTableFile = "hash.table";
inline constexpr std::string_view kBloomFilterFile = "bloom.filter";
inline constexpr std::string_view kBlobsFile = "blobs.bin";
inline constexpr std::string_view kRewrittenBlobsFile = "blobs3.bin";

// [dir]/[name]。
std::string dict_file(const std::string& dir, std::string_view name);

// 记录开头恒为 [u8 type][u16 len][str]，type 0（term）之后紧跟 [u16 len][reading]。
// 键等于第一个串、或（term）等于 reading 时为真。导入端的键全部来自这两处（term 的
// expression / reading，meta 的 expression，kanji 的字符，simple dict 的 headword），
// 所以对真正指向这个键的位置恒真。
bool record_has_key(const memory::blob_file& blobs, uint64_t record, std::string_view key);

// [loc] 列出的每条记录的偏移：single 时就是 loc.offset 本身，否则读 offset 表
// [u32 count][u64 x count]（坏 count / 截断表按 memory::read_offset_list 的口径收住）。
// visit(uint64_t) 返回 false = 提前停止。
template <typename Visit>
void for_each_record_offset(const memory::blob_file& blobs, location loc, Visit&& visit) {
  if (loc.single) {
    visit(loc.offset);
    return;
  }
  const memory::offset_list list = memory::read_offset_list(blobs, loc.offset);
  if (!list.span) {
    return;
  }
  const uint8_t* p = list.span.data;
  for (uint32_t i = 0; i < list.count; i++) {
    uint64_t offset = 0;
    std::memcpy(&offset, p + static_cast<size_t>(i) * sizeof(uint64_t), sizeof(uint64_t));
    if (!visit(offset)) {
      return;
    }
  }
}

// [loc] 是不是 [key] 的位置：核对它列出的第一条记录（记录都带着自己的键）。
bool location_has_key(const memory::blob_file& blobs, location loc, std::string_view key);

class dict_index {
 public:
  dict_index() = default;
  dict_index(const dict_index&) = delete;
  dict_index& operator=(const dict_index&) = delete;

  // 打开 [dir] 的索引与记录文件（经 map_rd_shared / open_blob_file，进程内按文件身份
  // 共享）。key.index 合法且它指的记录文件打得开就用它；否则用旧式 hash.table（+ 可选
  // 的 bloom.filter）+ blobs.bin。false = 两种都用不了。不写盘。
  bool open(const std::string& dir);

  bool uses_key_index() const { return keys_.loaded(); }
  const memory::blob_file& blobs() const { return *blobs_; }
  const memory::shared_blob_file& shared_blobs() const { return blobs_; }
  // 实际在用的索引文件（key.index 或 hash.table）的映射。
  const memory::shared_mapping& index_mapping() const { return index_; }
  const key_index* keys() const { return keys_.loaded() ? &keys_ : nullptr; }
  const linear& table() const { return table_; }

  // 联合过滤器（hash/union_filter.hpp）用的词典身份：实际在用的索引文件的大小 + 修改
  // 时间 + 首页内容，再加记录文件的大小。键集合变了（重导 / 升级换了索引）它就变。
  uint64_t identity() const { return identity_; }

  // 没有联合过滤器时的预筛：旧式词典探自己的 bloom.filter；key.index 没有私有过滤器，
  // 直接放行（随后探主桶，一条缓存行，与原来探 bloom 同价）。false = 肯定不在。
  bool own_filter_passes(uint64_t h) const { return keys_.loaded() || !table_.bloom_rejects(h); }

  // [key]（哈希 [h]）在本词典里的位置，已核对；nullopt = 没有。不经任何过滤器。
  std::optional<location> locate(uint64_t h, std::string_view key) const;

  // 本词典的每个位置（每个键一个）：visit(location) 返回 false = 提前停止。
  template <typename Visit>
  void for_each_location(Visit&& visit) const {
    if (keys_.loaded()) {
      keys_.for_each_slot([&](uint32_t, location loc) -> bool { return visit(loc); });
      return;
    }
    if (!index_) {
      return;
    }
    for_each_slot(index_->data, index_->size,
                  [&](uint64_t, uint64_t offset) -> bool { return visit(location{.offset = offset, .single = false}); });
  }

  // 联合过滤器的输入（指针指向本对象与它的映射，用完之前本对象要活着）。
  union_filter::source filter_source() const;

 private:
  bool open_key_index(const std::string& dir);
  bool open_legacy(const std::string& dir);

  memory::shared_mapping index_;  // key.index 或 hash.table
  memory::shared_mapping bloom_;  // 旧式才有
  key_index keys_;
  linear table_;
  bloom bloom_filter_;
  memory::shared_blob_file blobs_;
  uint64_t identity_ = 0;
};

}  // namespace hash

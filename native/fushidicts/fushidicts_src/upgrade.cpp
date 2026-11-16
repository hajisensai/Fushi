#include "fushidicts/upgrade.hpp"

#include <ankerl/unordered_dense.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

#include "hash/dict_index.hpp"
#include "hash/hash.hpp"
#include "hash/key_index.hpp"
#include "json/meta_record.hpp"
#include "memory/memory.hpp"
#include "util/fs_utf8.hpp"

namespace fushidicts {
namespace {

using hash::key_index;

// 遗留临时文件（升级中途进程被杀）放过这么久才清：一次升级是秒级的，更新的可能是
// 另一个进程（主进程 / 查词弹窗进程）正在写的那份。与联合过滤器缓存同一口径。
constexpr std::chrono::minutes kStaleTmpAge{10};

bool exists(const std::string& path) {
  std::error_code ec;
  return std::filesystem::exists(fushi::fs_path(path), ec);
}

// 尽力删除：删不掉（Windows 上仍被映射 / 已不存在）不是错误，由之后的调用再清。
void remove_if_possible(const std::string& path) {
  std::error_code ec;
  std::filesystem::remove(fushi::fs_path(path), ec);
}

// 导入完成的标记（query.cpp dict_format_version 同一组名字）。
bool has_marker(const std::string& dir) {
  for (const char* name : {"/.fushidicts_2", "/.fushidicts_1", "/.hoshidicts_1"}) {
    std::error_code ec;
    if (std::filesystem::is_regular_file(fushi::fs_path(dir + name), ec)) {
      return true;
    }
  }
  return false;
}

// [final_path] 的临时文件名：同目录、唯一（时间戳 + 线程），两个进程同时升级同一本
// 词典时各写各的，不会一个截断另一个正映射着的文件。
std::string tmp_path_for(const std::string& final_path) {
  const auto stamp = static_cast<unsigned long long>(std::chrono::steady_clock::now().time_since_epoch().count());
  const auto tid = static_cast<unsigned long long>(std::hash<std::thread::id>{}(std::this_thread::get_id()));
  char suffix[64];
  std::snprintf(suffix, sizeof(suffix), ".%llx-%llx.tmp", stamp, tid);
  return final_path + suffix;
}

// 没提交（改名）就析构的临时文件删掉。
struct TmpFile {
  std::string path;
  bool committed = false;

  ~TmpFile() {
    if (!committed && !path.empty()) {
      remove_if_possible(path);
    }
  }
};

// 目录里合法的 key.index 指的记录文件；nullopt = 没有可用的 key.index。
std::optional<key_index::blobs_file> current_key_index(const std::string& dir) {
  const memory::shared_mapping mapping = memory::map_rd_shared(hash::dict_file(dir, hash::kKeyIndexFile));
  key_index keys;
  if (!mapping || !keys.load(mapping->data, mapping->size)) {
    return std::nullopt;
  }
  const std::string_view blobs_name =
      keys.blobs() == key_index::blobs_file::rewritten ? hash::kRewrittenBlobsFile : hash::kBlobsFile;
  std::error_code ec;
  if (!std::filesystem::is_regular_file(fushi::fs_path(hash::dict_file(dir, blobs_name)), ec)) {
    return std::nullopt;
  }
  return keys.blobs();
}

// 提交之后（或发现已是最新时）清掉不再需要的文件。
void remove_superseded(const std::string& dir, key_index::blobs_file blobs) {
  remove_if_possible(hash::dict_file(dir, hash::kHashTableFile));
  remove_if_possible(hash::dict_file(dir, hash::kBloomFilterFile));
  remove_if_possible(hash::dict_file(dir, blobs == key_index::blobs_file::rewritten ? hash::kBlobsFile
                                                                                    : hash::kRewrittenBlobsFile));
  const auto now = std::filesystem::file_time_type::clock::now();
  std::error_code ec;
  for (std::filesystem::directory_iterator it(fushi::fs_path(dir), ec), end; !ec && it != end; it.increment(ec)) {
    const std::string name = fushi::fs_to_utf8(it->path().filename());
    const bool ours = (name.starts_with(std::string(hash::kKeyIndexFile) + ".") ||
                       name.starts_with(std::string(hash::kRewrittenBlobsFile) + ".")) &&
                      name.ends_with(".tmp");
    if (!ours) {
      continue;
    }
    std::error_code time_ec;
    const auto written = std::filesystem::last_write_time(it->path(), time_ec);
    if (!time_ec && now - written > kStaleTmpAge) {
      std::error_code ignored;
      std::filesystem::remove(it->path(), ignored);
    }
  }
}

// 写完 [bytes] 再返回（unmap 刷盘）：调用方紧接着把它改名成正式文件。
void write_file(const std::string& path, const std::vector<char>& bytes) {
  memory::mapped_file out = memory::map_rw(path, bytes.size());
  if (!out) {
    throw memory::map_error("failed to create " + path);
  }
  std::memcpy(out.data, bytes.data(), bytes.size());
  memory::unmap(out);
}

bool rename_onto(const std::string& from, const std::string& to) {
  std::error_code ec;
  std::filesystem::rename(fushi::fs_path(from), fushi::fs_path(to), ec);
  return !ec;
}

// 旧式索引读出来的一个键：哈希 + 它列出的记录——Legacy::records 里的
// [first, first + count) 一段，按原顺序。
struct LegacyKey {
  uint64_t hash;
  uint64_t table;  // 原 offset 表的地址
  uint64_t first;
  uint32_t count;
};

// 整张旧式索引。所有键的记录偏移首尾相接放在一个数组里：大词典有几百万个键，各配一个
// vector 的话光堆分配的头就是上百 MB，而升级是在用户设备（含手机）的后台跑的。
struct Legacy {
  std::vector<LegacyKey> keys;
  std::vector<uint64_t> records;
};

// type 1 meta 记录 [1][u16 expr_len][expr][u8 mode_len][mode][u32 data_len][data] 的
// 三个字段；记录不完整时 nullopt。
struct RawMeta {
  std::string_view expr;
  std::string_view mode;
  std::string_view data;
};

std::optional<RawMeta> read_raw_meta(const memory::blob_file& blobs, uint64_t offset) {
  const memory::blob_span rec = blobs.record(offset);
  const uint8_t* p = rec.data;
  const uint8_t* end = rec.data + rec.size;
  const auto take = [&](size_t n) -> const uint8_t* {
    if (!p || static_cast<size_t>(end - p) < n) {
      p = nullptr;
      return nullptr;
    }
    const uint8_t* at = p;
    p += n;
    return at;
  };
  const uint8_t* type = take(1);
  if (!type || *type != meta_record::kRawType) {
    return std::nullopt;
  }
  RawMeta out;
  uint16_t expr_len = 0;
  if (const uint8_t* q = take(2)) std::memcpy(&expr_len, q, 2);
  if (const uint8_t* q = take(expr_len)) out.expr = {reinterpret_cast<const char*>(q), expr_len};
  uint8_t mode_len = 0;
  if (const uint8_t* q = take(1)) mode_len = *q;
  if (const uint8_t* q = take(mode_len)) out.mode = {reinterpret_cast<const char*>(q), mode_len};
  uint32_t data_len = 0;
  if (const uint8_t* q = take(4)) std::memcpy(&data_len, q, 4);
  if (const uint8_t* q = take(data_len)) out.data = {reinterpret_cast<const char*>(q), data_len};
  if (!p) {
    return std::nullopt;
  }
  return out;
}

// 记录重写成 blobs3.bin 的内容 + 新索引项。nullopt = 有记录读不全（坏词典），不重写，
// 只换索引（行为与原样一致）。
struct Rewritten {
  std::vector<char> blobs;
  std::vector<key_index::entry> entries;
};

std::optional<Rewritten> rewrite_meta(const memory::blob_file& blobs, const Legacy& legacy) {
  Rewritten out;
  ankerl::unordered_dense::map<uint64_t, uint64_t> moved;  // 原记录偏移 → 新偏移
  // 与 legacy.records 逐项对应的新偏移。记录按「键的次序、键内原顺序」写出，产物只由
  // 输入决定（两个进程同时升级同一本词典写出的 blobs3.bin 逐字节相同）。
  std::vector<uint64_t> relocated(legacy.records.size(), 0);
  for (const LegacyKey& key : legacy.keys) {
    for (uint64_t i = key.first; i < key.first + key.count; i++) {
      const uint64_t record = legacy.records[i];
      auto [it, inserted] = moved.try_emplace(record, out.blobs.size());
      if (inserted) {
        const std::optional<RawMeta> meta = read_raw_meta(blobs, record);
        if (!meta) {
          return std::nullopt;
        }
        meta_record::append(out.blobs, meta->expr, meta->mode, meta->data, /*allow_parsed=*/true);
      }
      relocated[i] = it->second;
    }
  }
  out.entries.reserve(legacy.keys.size());
  for (const LegacyKey& key : legacy.keys) {
    if (key.count == 1) {
      out.entries.push_back({.hash = key.hash, .offset = relocated[key.first], .single = true});
      continue;
    }
    out.entries.push_back({.hash = key.hash, .offset = out.blobs.size(), .single = false});
    const size_t at = out.blobs.size();
    out.blobs.resize(at + sizeof(uint32_t) + static_cast<size_t>(key.count) * sizeof(uint64_t));
    std::memcpy(out.blobs.data() + at, &key.count, sizeof(key.count));
    if (key.count != 0) {
      std::memcpy(out.blobs.data() + at + sizeof(uint32_t), relocated.data() + key.first,
                  static_cast<size_t>(key.count) * sizeof(uint64_t));
    }
  }
  return out;
}

// 写 [entries] 的 key.index 并改名成正式文件（提交点）。
UpgradeResult commit_key_index(const std::string& dir, const std::vector<key_index::entry>& entries,
                               key_index::blobs_file blobs) {
  const std::string final_path = hash::dict_file(dir, hash::kKeyIndexFile);
  TmpFile tmp{tmp_path_for(final_path)};
  if (!key_index::build_to_file(entries, blobs, tmp.path)) {
    return UpgradeResult::NotApplicable;
  }
  if (!rename_onto(tmp.path, final_path)) {
    // 换不上：另一个进程刚好先提交了（Windows 上它的 key.index 已被映射）。
    return current_key_index(dir) ? UpgradeResult::UpToDate : UpgradeResult::Failed;
  }
  tmp.committed = true;
  return UpgradeResult::Upgraded;
}

}  // namespace

UpgradeResult upgrade_dictionary(const std::string& dir, bool allow_meta_rewrite) {
  if (!has_marker(dir)) {
    return UpgradeResult::Failed;
  }
  if (const std::optional<key_index::blobs_file> kind = current_key_index(dir)) {
    remove_superseded(dir, *kind);
    return UpgradeResult::UpToDate;
  }
  // 有 key.index 但不合法（截断 / 坏头）：没有引擎会用它（装载时验过就不映射），删掉
  // 再写新的；删不掉就不能提交。
  const std::string key_index_path = hash::dict_file(dir, hash::kKeyIndexFile);
  if (exists(key_index_path)) {
    remove_if_possible(key_index_path);
    if (exists(key_index_path)) {
      return UpgradeResult::Failed;
    }
  }

  UpgradeResult result = UpgradeResult::Failed;
  {
    // 读旧式索引。映射经 map_rd_shared 与正装着这本词典的引擎共享，只读。
    hash::dict_index index;
    if (!index.open(dir)) {
      return UpgradeResult::Failed;
    }
    if (index.uses_key_index()) {
      // 另一个进程刚好先提交了。
      return UpgradeResult::UpToDate;
    }
    const memory::blob_file& blobs = index.blobs();
    const memory::shared_mapping& table = index.index_mapping();

    Legacy legacy;
    std::vector<LegacyKey>& keys = legacy.keys;
    bool all_raw_meta = true;
    hash::for_each_slot(table->data, table->size, [&](uint64_t h, uint64_t at) -> bool {
      LegacyKey key{.hash = h, .table = at, .first = legacy.records.size(), .count = 0};
      hash::for_each_record_offset(blobs, hash::location{.offset = at, .single = false}, [&](uint64_t record) -> bool {
        legacy.records.push_back(record);
        key.count++;
        if (all_raw_meta) {
          const memory::blob_span type = blobs.view(record, 1);
          all_raw_meta = type && type.data[0] == meta_record::kRawType;
        }
        return true;
      });
      keys.push_back(key);
      return true;
    });
    if (keys.empty()) {
      // 一个键都没有（空词典，或索引坏到读不出槽位）：没有可搬的东西，留在旧式。
      return UpgradeResult::NotApplicable;
    }
    // 按哈希排序（与导入端的 key_index::entry 次序一致，产物与 hash.table 的槽位排布
    // 无关），重复的哈希（坏表）只留第一个。
    std::ranges::stable_sort(keys, {}, &LegacyKey::hash);
    const auto dup = std::ranges::unique(keys, {}, &LegacyKey::hash);
    keys.erase(dup.begin(), dup.end());

    std::optional<Rewritten> rewritten;
    if (allow_meta_rewrite && all_raw_meta) {
      rewritten = rewrite_meta(blobs, legacy);
    }

    if (rewritten) {
      // 先放好 blobs3.bin（还没有 key.index 认领它，引擎不会读），再提交 key.index。
      const std::string blobs3 = hash::dict_file(dir, hash::kRewrittenBlobsFile);
      TmpFile tmp{tmp_path_for(blobs3)};
      write_file(tmp.path, rewritten->blobs);
      if (!rename_onto(tmp.path, blobs3)) {
        return current_key_index(dir) ? UpgradeResult::UpToDate : UpgradeResult::Failed;
      }
      tmp.committed = true;
      result = commit_key_index(dir, rewritten->entries, key_index::blobs_file::rewritten);
      if (result == UpgradeResult::NotApplicable) {
        // 重写后的记录装不进 key.index（不会发生：重写只会变小）：撤掉 blobs3.bin，
        // 照普通升级再试。
        remove_if_possible(blobs3);
        rewritten.reset();
      }
    }
    if (!rewritten) {
      std::vector<key_index::entry> entries;
      entries.reserve(keys.size());
      for (const LegacyKey& key : keys) {
        if (key.count == 1) {
          // 单记录：直指记录，原 offset 表留在 blobs.bin 里成为死字节。
          entries.push_back({.hash = key.hash, .offset = legacy.records[key.first], .single = true});
        } else {
          // 多条（或读不出来的坏表）：照旧指向原 offset 表，读侧与原来同口径收住。
          entries.push_back({.hash = key.hash, .offset = key.table, .single = false});
        }
      }
      result = commit_key_index(dir, entries, key_index::blobs_file::original);
    }
  }  // 放掉本函数自己的映射，下面才删得掉（别的引擎还映射着就删不掉，留给下一次）。

  if (result == UpgradeResult::Upgraded || result == UpgradeResult::UpToDate) {
    if (const std::optional<key_index::blobs_file> kind = current_key_index(dir)) {
      remove_superseded(dir, *kind);
    }
  }
  return result;
}

}  // namespace fushidicts

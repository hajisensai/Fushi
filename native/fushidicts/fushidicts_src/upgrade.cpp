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

// 尽力删除：删不掉（已不存在 / 仍被别的句柄打开）不是错误，由之后的调用再清。仍被映射
// 的旧文件也删得掉（memory::remove_file 在 Windows 上走 POSIX 语义），映射着它的引擎照常读。
void remove_if_possible(const std::string& path) {
  (void)memory::remove_file(path);
}

// 导入完成的标记（query.cpp dict_format_version 同一组名字）的路径；没有 = 不是完整
// 导入的词典目录。
std::optional<std::string> marker_path(const std::string& dir) {
  for (const char* name : {"/.fushidicts_2", "/.fushidicts_1", "/.hoshidicts_1"}) {
    std::error_code ec;
    if (std::filesystem::is_regular_file(fushi::fs_path(dir + name), ec)) {
      return dir + name;
    }
  }
  return std::nullopt;
}

// [final_path] 的临时文件名：同目录、唯一（时间戳 + 线程）。升级本身由目录锁串行化，
// 唯一命名只为不去截断上一次被杀留下的那份。
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

bool exists(const std::string& path) {
  std::error_code ec;
  return std::filesystem::exists(fushi::fs_path(path), ec);
}

// 提交之后（或发现已是最新时）清掉不再需要的文件。
//
// 落盘次序：新文件的内容在改名之前已经 sync_file（write_file / commit_key_index），这里
// 删旧文件之前再把目录项落盘——否则断电后可能「改名没生效、删除却生效了」，能兜底的
// 旧文件没了而新文件的名字还不在。目录项没能落盘就不删，留给下一次调用。不按正式
// 文件名再刷一次内容：Windows 上引擎以只读共享打开着它们，写方式打不开。
void remove_superseded(const std::string& dir, key_index::blobs_file blobs) {
  const std::string superseded[] = {
      hash::dict_file(dir, hash::kHashTableFile),
      hash::dict_file(dir, hash::kBloomFilterFile),
      hash::dict_file(dir, blobs == key_index::blobs_file::rewritten ? hash::kBlobsFile : hash::kRewrittenBlobsFile),
  };
  bool any = false;
  for (const std::string& path : superseded) {
    any = any || exists(path);
  }
  // 常态（早就清干净了）不碰磁盘：每次启动每本词典都会走到这里。
  if (any && memory::sync_directory(dir)) {
    for (const std::string& path : superseded) {
      remove_if_possible(path);
    }
  }
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

// 写完 [bytes] 并落盘再返回：调用方紧接着把它改名成正式文件。false = 没能落盘。
bool write_file(const std::string& path, const std::vector<char>& bytes) {
  memory::mapped_file out = memory::map_rw(path, bytes.size());
  if (!out) {
    throw memory::map_error("failed to create " + path);
  }
  std::memcpy(out.data, bytes.data(), bytes.size());
  memory::unmap(out);
  return memory::sync_file(path);
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
  // 重写后的大小与原文件相近（预解析的记录多数更小，单记录键的 offset 表不再写）；
  // 一次留够，免得几百 MB 的缓冲区在翻倍扩容时新旧两份同时在世。
  out.blobs.reserve(static_cast<size_t>(blobs.size()));
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

// 写 [entries] 的 key.index、落盘、改名成正式文件（提交点）。目录里若有一份不合法的
// key.index（截断 / 坏头——没有引擎会映射它），改名直接把它换掉。
UpgradeResult commit_key_index(const std::string& dir, const std::vector<key_index::entry>& entries,
                               key_index::blobs_file blobs) {
  const std::string final_path = hash::dict_file(dir, hash::kKeyIndexFile);
  TmpFile tmp{tmp_path_for(final_path)};
  if (!key_index::build_to_file(entries, blobs, tmp.path)) {
    return UpgradeResult::NotApplicable;
  }
  // 内容先落盘、名字后出现：key.index 没有校验和，一份大小对、内容没写全的文件会被
  // 引擎当真。
  if (!memory::sync_file(tmp.path) || !rename_onto(tmp.path, final_path)) {
    return UpgradeResult::Failed;
  }
  tmp.committed = true;
  return UpgradeResult::Upgraded;
}

}  // namespace

UpgradeResult upgrade_dictionary(const std::string& dir, bool allow_meta_rewrite) {
  const std::optional<std::string> marker = marker_path(dir);
  if (!marker) {
    return UpgradeResult::Failed;
  }
  // 同一本词典的升级跨进程、跨线程串行化（锁加在导入标记文件上，不新建文件）。「看
  // 目录现状 → 写新文件 → 删旧文件」不是原子的：两个调用交错时，后到的会按它开头看到
  // 的旧状态行事，而先到的已经提交并删掉了旧索引。拿到锁之后再看现状，后到的那个只会
  // 看到「已是最新」。引擎装载不拿这把锁，它那一侧的次序见 dict_index::open。
  const memory::file_lock lock(*marker);
  if (!lock.held()) {
    return UpgradeResult::Failed;
  }
  if (const std::optional<key_index::blobs_file> kind = current_key_index(dir)) {
    remove_superseded(dir, *kind);
    return UpgradeResult::UpToDate;
  }

  UpgradeResult result = UpgradeResult::Failed;
  {
    // 读旧式索引。映射经 map_rd_shared 与正装着这本词典的引擎共享，只读。目录里没有
    // 合法的 key.index（上面刚看过，且持有锁），所以打开的一定是旧式。
    hash::dict_index index;
    if (!index.open(dir) || index.uses_key_index()) {
      return UpgradeResult::Failed;
    }
    const memory::blob_file& blobs = index.blobs();
    const memory::shared_mapping& table = index.index_mapping();

    Legacy legacy;
    std::vector<LegacyKey>& keys = legacy.keys;
    // 槽位数是键数的上界（旧表装载率 70%），记录数不少于键数。
    const size_t capacity = hash::slot_capacity(table->data, table->size);
    keys.reserve(capacity * 3 / 4 + 1);
    legacy.records.reserve(capacity * 3 / 4 + 1);
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
      if (!write_file(tmp.path, rewritten->blobs) || !rename_onto(tmp.path, blobs3)) {
        return UpgradeResult::Failed;
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

  if (result == UpgradeResult::Upgraded) {
    if (const std::optional<key_index::blobs_file> kind = current_key_index(dir)) {
      remove_superseded(dir, *kind);
    }
  }
  return result;
}

}  // namespace fushidicts

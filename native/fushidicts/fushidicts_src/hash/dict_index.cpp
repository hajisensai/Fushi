#include "dict_index.hpp"

#include <xxh3.h>

#include <algorithm>
#include <filesystem>
#include <system_error>

#include "../util/fs_utf8.hpp"

namespace hash {
namespace {

// 核对要读的最大字节数：[u8][u16][<=65535][u16][<=65535]。不到 1 MB，窗口映射下落在
// 同一个窗口里（memory::blob_file::view），整份映射下只是指针运算。
constexpr size_t kMaxKeyedPrefix = 1 + 2 + 65535 + 2 + 65535;

// 实际在用的索引文件的大小 + 修改时间 + 首页内容（4 KB），再加记录文件的大小。不对整个
// 文件求哈希：一套词典的索引合计几百 MB，装载期全读一遍是可感的冷启动 IO。内容没变而
// 身份变了（拷贝后 mtime 不同）只是联合过滤器多重建一次。
uint64_t file_identity(const std::string& index_path, const memory::mapped_file& index, uint64_t blobs_size) {
  std::error_code ec;
  const auto mtime = std::filesystem::last_write_time(fushi::fs_path(index_path), ec);
  const uint64_t fields[4] = {
      XXH3_64bits(index.data, std::min<size_t>(index.size, 4096)),
      static_cast<uint64_t>(index.size),
      ec ? 0 : static_cast<uint64_t>(mtime.time_since_epoch().count()),
      blobs_size,
  };
  return XXH3_64bits(fields, sizeof(fields));
}

}  // namespace

std::string dict_file(const std::string& dir, std::string_view name) {
  std::string path = dir;
  path += '/';
  path += name;
  return path;
}

bool record_has_key(const memory::blob_file& blobs, uint64_t record, std::string_view key) {
  const memory::blob_span rec = blobs.view(record, kMaxKeyedPrefix);
  if (rec.size < 3) {
    return false;
  }
  const uint8_t type = rec.data[0];
  uint16_t len = 0;
  std::memcpy(&len, rec.data + 1, sizeof(len));
  size_t pos = 3;
  if (rec.size - pos < len) {
    return false;
  }
  if (std::string_view(reinterpret_cast<const char*>(rec.data + pos), len) == key) {
    return true;
  }
  if (type != 0) {
    return false;
  }
  pos += len;
  if (rec.size - pos < sizeof(uint16_t)) {
    return false;
  }
  uint16_t reading_len = 0;
  std::memcpy(&reading_len, rec.data + pos, sizeof(reading_len));
  pos += sizeof(uint16_t);
  if (rec.size - pos < reading_len) {
    return false;
  }
  return std::string_view(reinterpret_cast<const char*>(rec.data + pos), reading_len) == key;
}

bool location_has_key(const memory::blob_file& blobs, location loc, std::string_view key) {
  bool match = false;
  for_each_record_offset(blobs, loc, [&](uint64_t record) -> bool {
    match = record_has_key(blobs, record, key);
    return false;  // 只看第一条
  });
  return match;
}

bool dict_index::open(const std::string& dir) {
  // 次序：key.index → 旧式 → 再看一次 key.index。存量升级（upgrade.cpp）可能正在别的
  // 线程 / 进程里对这个目录动手，而装载不拿它的锁：它先提交 key.index、后删旧式文件，
  // 所以「刚才还没有 key.index，转头旧式文件已经不在了」只可能是它在这两步之间提交了
  // ——这时 key.index 一定已经在，再看一次就能打开。
  return open_key_index(dir) || open_legacy(dir) || open_key_index(dir);
}

bool dict_index::open_key_index(const std::string& dir) {
  // 合法、且它指的记录文件打得开才用。不合法（截断 / 坏头 / 将来的版本）时由调用方
  // 退回旧式文件——它们若还在（升级后删不掉的 / 损坏前的）词典照常可查。
  const std::string path = dict_file(dir, kKeyIndexFile);
  memory::shared_mapping mapping = memory::map_rd_shared(path);
  key_index keys;
  if (!mapping || !keys.load(mapping->data, mapping->size)) {
    return false;
  }
  const std::string_view blobs_name =
      keys.blobs() == key_index::blobs_file::rewritten ? kRewrittenBlobsFile : kBlobsFile;
  memory::shared_blob_file blobs = memory::open_blob_file(dict_file(dir, blobs_name));
  if (!blobs) {
    return false;
  }
  identity_ = file_identity(path, *mapping, blobs->size());
  index_ = std::move(mapping);
  keys_ = keys;
  blobs_ = std::move(blobs);
  return true;
}

bool dict_index::open_legacy(const std::string& dir) {
  const std::string table_path = dict_file(dir, kHashTableFile);
  memory::shared_mapping table = memory::map_rd_shared(table_path);
  if (!table) {
    return false;
  }
  memory::shared_blob_file blobs = memory::open_blob_file(dict_file(dir, kBlobsFile));
  if (!blobs) {
    return false;
  }
  table_.load(table->data, table->size);
  // bloom.filter 缺失 / 损坏时保持置空（contains 恒真穿透），词典照常可查，只失去
  // bloom 加速（上游 d4183d4 删掉了现场重建）。
  bloom_ = memory::map_rd_shared(dict_file(dir, kBloomFilterFile));
  if (bloom_) {
    bloom_filter_.load(bloom_->data, bloom_->size);
  }
  table_.set_bloom(&bloom_filter_);
  identity_ = file_identity(table_path, *table, blobs->size());
  index_ = std::move(table);
  blobs_ = std::move(blobs);
  return true;
}

std::optional<location> dict_index::locate(uint64_t h, std::string_view key) const {
  if (!blobs_) {
    return std::nullopt;
  }
  if (keys_.loaded()) {
    const key_index::candidates first = keys_.primary(h);
    for (uint32_t i = 0; i < first.count; i++) {
      if (location_has_key(*blobs_, first.at[i], key)) {
        return first.at[i];
      }
    }
    if (!first.more) {
      return std::nullopt;
    }
    const key_index::candidates second = keys_.alternate(h);
    for (uint32_t i = 0; i < second.count; i++) {
      if (location_has_key(*blobs_, second.at[i], key)) {
        return second.at[i];
      }
    }
    return std::nullopt;
  }
  const uint64_t offset = table_.find(h);
  if (offset == 0) {
    return std::nullopt;
  }
  const location loc{.offset = offset, .single = false};
  if (!location_has_key(*blobs_, loc, key)) {
    return std::nullopt;
  }
  return loc;
}

union_filter::source dict_index::filter_source() const {
  if (keys_.loaded()) {
    return {.identity = identity_, .keys = &keys_};
  }
  return {.identity = identity_, .table = index_ ? index_->data : nullptr, .table_size = index_ ? index_->size : 0};
}

}  // namespace hash

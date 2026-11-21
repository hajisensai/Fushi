#pragma once

// 词典目录的「导入完成 + 磁盘格式版本」标记（单一真相源）。
//
// 标记文件名同时承担两层语义：目录是完整导入的词典（没有标记 = 导入未完成 / 损坏，不
// 加载），以及旧引擎能不能读它。版本阶梯：
//   .fushidicts_3 —— 索引是 key.index（不再有 hash.table / bloom.filter）。文件体是记录
//                    布局版本的一个 ASCII 数字："2"（v2 记录）或 "1"（v1 记录：
//                    write_simple_dict 产出的、或从 v1 存量升级上来的）。旧引擎只认
//                    下面三个名字，看到 .fushidicts_3 整目录不加载，而不是去开已经不在的
//                    hash.table（拍板台 pr3554：降级要重导，但不许静默坏掉）。
//   .fushidicts_2 —— v2 记录（kanji 带 stats 追加段、term 带 score、glossary 可能用
//                    dict.zstd），旧式 hash.table + bloom.filter 索引。
//   .fushidicts_1 / .hoshidicts_1 —— v1 记录、旧式索引（.hoshidicts_1 是改名前的存量，
//                    冻结，只读不写）。
// 写入端：索引写成 key.index 的一律写 .fushidicts_3；装不进 key.index（offset 超 32 位）
// 退回旧式索引的仍写 .fushidicts_2 / .fushidicts_1，旧引擎照读。

#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <iterator>
#include <optional>
#include <string>
#include <system_error>

#include "../memory/memory.hpp"
#include "fs_utf8.hpp"

namespace fushidicts::dict_marker {

inline constexpr const char* kKeyIndexMarker = ".fushidicts_3";
inline constexpr const char* kV2Marker = ".fushidicts_2";
inline constexpr const char* kV1Marker = ".fushidicts_1";
inline constexpr const char* kLegacyV1Marker = ".hoshidicts_1";

inline std::string marker_file(const std::string& dir, const char* name) {
  return dir + "/" + name;
}

inline bool is_file(const std::string& path) {
  std::error_code ec;
  return std::filesystem::is_regular_file(fushi::fs_path(path), ec);
}

// .fushidicts_3 文件体 → 记录布局版本；不认识的内容 = 0（不加载：比按错的布局读记录强）。
inline int key_index_marker_record_version(const std::string& marker) {
  std::ifstream in(fushi::fs_path(marker), std::ios::binary);
  if (!in) {
    return 0;
  }
  const std::string body((std::istreambuf_iterator<char>(in)), {});
  if (body == "2") return 2;
  if (body == "1") return 1;
  return 0;
}

// 旧式标记里记的记录布局版本（升级换标记时沿用）；没有旧式标记 = 0。
inline int legacy_record_version(const std::string& dir) {
  if (is_file(marker_file(dir, kV2Marker))) {
    return 2;
  }
  if (is_file(marker_file(dir, kV1Marker)) || is_file(marker_file(dir, kLegacyV1Marker))) {
    return 1;
  }
  return 0;
}

// 记录布局版本：2 / 1；0 = 没有可用标记，词典不加载。
inline int record_version(const std::string& dir) {
  const std::string v3 = marker_file(dir, kKeyIndexMarker);
  if (is_file(v3)) {
    return key_index_marker_record_version(v3);
  }
  return legacy_record_version(dir);
}

// 目录里的标记文件（.fushidicts_3 优先）；nullopt = 不是完整导入的词典目录。
inline std::optional<std::string> find(const std::string& dir) {
  for (const char* name : {kKeyIndexMarker, kV2Marker, kV1Marker, kLegacyV1Marker}) {
    const std::string path = marker_file(dir, name);
    if (is_file(path)) {
      return path;
    }
  }
  return std::nullopt;
}

// 写 .fushidicts_3（文件体 = [record_version]）：同目录临时文件写完、落盘，再改名成正式
// 名字——名字出现时文件体一定完整（读侧按文件体决定记录布局）。已存在且文件体相同时
// 不动。false = 没能写成 / 落盘（调用方不得因此删除旧标记）。
inline bool write_key_index_marker(const std::string& dir, int record_version) {
  const std::string final_path = marker_file(dir, kKeyIndexMarker);
  if (is_file(final_path) && key_index_marker_record_version(final_path) == record_version) {
    return true;
  }
  const std::string tmp = final_path + ".tmp";
  {
    std::ofstream out(fushi::fs_path(tmp), std::ios::binary | std::ios::trunc);
    out << record_version;
    out.close();
    if (!out) {
      std::error_code ignored;
      std::filesystem::remove(fushi::fs_path(tmp), ignored);
      return false;
    }
  }
  std::error_code ec;
  if (!memory::sync_file(tmp)) {
    std::filesystem::remove(fushi::fs_path(tmp), ec);
    return false;
  }
  std::filesystem::rename(fushi::fs_path(tmp), fushi::fs_path(final_path), ec);
  if (ec) {
    std::error_code ignored;
    std::filesystem::remove(fushi::fs_path(tmp), ignored);
    return false;
  }
  return true;
}

// 删掉旧式标记（尽力）。只在 .fushidicts_3 已落盘、目录项已落盘之后调：任何时刻目录里
// 至少有一个标记。
inline void remove_legacy_markers(const std::string& dir) {
  for (const char* name : {kV2Marker, kV1Marker, kLegacyV1Marker}) {
    (void)memory::remove_file(marker_file(dir, name));
  }
}

inline bool has_legacy_marker(const std::string& dir) {
  return legacy_record_version(dir) != 0;
}

}  // namespace fushidicts::dict_marker

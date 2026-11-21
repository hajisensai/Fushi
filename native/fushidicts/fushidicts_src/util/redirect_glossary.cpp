#include "redirect_glossary.hpp"

#include <zstd.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <glaze/glaze.hpp>
#include <memory>
#include <tuple>
#include <unordered_set>

#include "../hash/dict_index.hpp"
#include "../memory/memory.hpp"
#include "dict_marker.hpp"
#include "fs_utf8.hpp"

namespace fushi::redirect_glossary {

std::optional<std::vector<Redirect>> parse(const std::string& json) {
  // 廉价前置判据：必须以 `[[` 开头（容许空白），文本 / structured-content 都在这里出局。
  std::size_t i = json.find_first_not_of(" \t\r\n");
  if (i == std::string::npos || json[i] != '[') return std::nullopt;
  i = json.find_first_not_of(" \t\r\n", i + 1);
  if (i == std::string::npos || json[i] != '[') return std::nullopt;

  std::vector<std::tuple<std::string, std::vector<std::string>>> items;
  if (glz::read_json(items, json) || items.empty()) return std::nullopt;
  std::vector<Redirect> redirects;
  redirects.reserve(items.size());
  for (auto& [form_of, rules] : items) {
    if (form_of.empty()) return std::nullopt;
    redirects.push_back({.form_of = std::move(form_of), .rules = std::move(rules)});
  }
  return redirects;
}

bool is_redirect(std::string_view raw_glossary) {
  if (raw_glossary.size() > kMaxRawBytes) return false;
  // 前置判据先在视图上做，绝大多数 glossary 不用拷贝就出局；过了才拷成 std::string
  // 交给与查询期同一个 parse。
  const std::size_t i = raw_glossary.find_first_not_of(" \t\r\n");
  if (i == std::string_view::npos || raw_glossary[i] != '[') return false;
  return parse(std::string(raw_glossary)).has_value();
}

bool may_be_redirect(const uint8_t* compressed, uint32_t compressed_size) {
  if (compressed == nullptr || compressed_size == 0) return false;
  if (compressed_size > ZSTD_COMPRESSBOUND(kMaxRawBytes)) return false;
  const unsigned long long raw_size = ZSTD_getFrameContentSize(compressed, compressed_size);
  return raw_size != ZSTD_CONTENTSIZE_ERROR && raw_size != ZSTD_CONTENTSIZE_UNKNOWN && raw_size <= kMaxRawBytes;
}

std::optional<bool> read_flag(const std::string& dict_dir, uint64_t blobs_size) {
  std::ifstream in(fushi::fs_path(dict_dir + "/" + std::string(kFlagFilename)), std::ios::binary);
  if (!in) return std::nullopt;
  int flag = -1;
  uint64_t recorded_size = 0;
  in >> flag >> recorded_size;
  if (!in || (flag != 0 && flag != 1) || recorded_size != blobs_size) return std::nullopt;
  return flag == 1;
}

bool write_flag(const std::string& dict_dir, bool present, uint64_t blobs_size) {
  const std::string final_path = dict_dir + "/" + std::string(kFlagFilename);
  const std::string tmp_path = final_path + ".tmp";
  {
    std::ofstream out(fushi::fs_path(tmp_path), std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << (present ? '1' : '0') << ' ' << blobs_size << '\n';
    out.flush();
    if (!out) return false;
  }
  std::error_code ec;
  std::filesystem::rename(fushi::fs_path(tmp_path), fushi::fs_path(final_path), ec);
  if (ec) {
    std::filesystem::remove(fushi::fs_path(tmp_path), ec);
    return false;
  }
  return true;
}

namespace {

template <typename T>
bool read_at(const memory::blob_file& f, uint64_t pos, T& out) {
  const memory::blob_span span = f.view(pos, sizeof(T));
  if (span.size < sizeof(T)) return false;
  std::memcpy(&out, span.data, sizeof(T));
  return true;
}

}  // namespace

std::optional<bool> scan_dict_dir(const std::string& dict_dir) {
  // 索引 + 记录文件经 hash::dict_index（key.index 或旧式 hash.table，进程内按文件身份
  // 共享映射，BUG-4013）；记录文件经 blob_file：32 位进程按窗口映射，64 位整份映射。
  hash::dict_index index;
  if (!index.open(dict_dir)) return std::nullopt;

  // v2 记录（.fushidicts_2 / 文件体 "2" 的 .fushidicts_3）词典的 term glossary 可能用
  // dict.zstd 训练字典压缩；与 DictionaryQuery::add_dict 同样的挂载条件。
  std::unique_ptr<ZSTD_DDict, decltype(&ZSTD_freeDDict)> ddict(nullptr, ZSTD_freeDDict);
  if (fushidicts::dict_marker::record_version(dict_dir) >= 2) {
    std::ifstream f(fushi::fs_path(dict_dir + "/dict.zstd"), std::ios::binary);
    if (f) {
      const std::string blob((std::istreambuf_iterator<char>(f)), {});
      if (!blob.empty()) ddict.reset(ZSTD_createDDict(blob.data(), blob.size()));
    }
  }
  std::unique_ptr<ZSTD_DCtx, decltype(&ZSTD_freeDCtx)> dctx(ZSTD_createDCtx(), ZSTD_freeDCtx);
  if (!dctx) return std::nullopt;

  const memory::blob_file& bl = index.blobs();

  // 同一 glossary blob 被多条记录（表记 / 读音两个键、去重后的同释义）共享，只判一次。
  std::unordered_set<uint64_t> seen;
  std::string buf;
  bool found = false;
  index.for_each_location([&](hash::location loc) -> bool {
    hash::for_each_record_offset(bl, loc, [&](uint64_t rec) -> bool {
      // 与 query_raw 逐字段同布局：type, expr, reading, glossary offset/size。
      uint8_t type = 0xff;
      if (!read_at(bl, rec, type) || type != 0) return true;
      uint64_t pos = rec + 1;
      uint16_t expr_len = 0;
      if (!read_at(bl, pos, expr_len)) return true;
      pos += sizeof(uint16_t) + expr_len;
      uint16_t reading_len = 0;
      if (!read_at(bl, pos, reading_len)) return true;
      pos += sizeof(uint16_t) + reading_len;
      uint64_t glossary_offset = 0;
      uint32_t glossary_size = 0;
      if (!read_at(bl, pos, glossary_offset) || !read_at(bl, pos + sizeof(uint64_t), glossary_size)) return true;
      // query_raw 不校验 glossary 区间；这里越界的记录在查询期解压同样失败（判否），
      // 跳过即同口径。
      if (glossary_offset > bl.size() || bl.size() - glossary_offset < glossary_size) return true;
      if (!seen.insert(glossary_offset).second) return true;
      const memory::blob_span glossary = bl.view(glossary_offset, glossary_size);
      if (glossary.size < glossary_size) return true;
      const uint8_t* data = glossary.data;
      if (!may_be_redirect(data, glossary_size)) return true;
      const unsigned long long raw_size = ZSTD_getFrameContentSize(data, glossary_size);
      buf.resize(static_cast<size_t>(raw_size));
      const size_t n =
          ZSTD_decompress_usingDDict(dctx.get(), buf.data(), buf.size(), data, glossary_size, ddict.get());
      if (ZSTD_isError(n)) return true;
      buf.resize(n);
      if (parse(buf).has_value()) found = true;
      return !found;
    });
    return !found;
  });
  return found;
}

}  // namespace fushi::redirect_glossary

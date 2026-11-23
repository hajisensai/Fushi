#include "redirect_glossary.hpp"

#include <zstd.h>

#include <algorithm>
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

namespace {

// Jitendex 链接卡的标记：structured-content 根节点的 `data.content`。
constexpr std::string_view kJitendexRedirectMarker = "redirect-glossary";

const glz::generic* member(const glz::generic& v, std::string_view key) {
  if (!v.is_object()) return nullptr;
  const auto& obj = v.get_object();
  const auto it = obj.find(key);
  return it == obj.end() ? nullptr : &it->second;
}

bool string_member_equals(const glz::generic& v, std::string_view key, std::string_view expected) {
  const glz::generic* m = member(v, key);
  return m != nullptr && m->is_string() && m->get_string() == expected;
}

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// application/x-www-form-urlencoded 解码（与 Yomitan 用的 URLSearchParams 同口径：
// `+` 是空格，`%XX` 是字节）。坏的转义原样保留。
std::string form_decode(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '+') {
      out.push_back(' ');
    } else if (s[i] == '%' && i + 2 < s.size() && hex_value(s[i + 1]) >= 0 && hex_value(s[i + 2]) >= 0) {
      out.push_back(static_cast<char>(hex_value(s[i + 1]) * 16 + hex_value(s[i + 2])));
      i += 2;
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

// Yomitan 站内查询链接 `?query=<词>&...` 的查询词；不是站内查询链接返回空串。
std::string query_link_target(std::string_view href) {
  if (href.empty() || href.front() != '?') return {};
  href.remove_prefix(1);
  while (!href.empty()) {
    const std::size_t amp = href.find('&');
    const std::string_view pair = href.substr(0, amp);
    if (pair.starts_with("query=")) return form_decode(pair.substr(6));
    if (amp == std::string_view::npos) break;
    href.remove_prefix(amp + 1);
  }
  return {};
}

// 链接卡里所有站内查询链接的目标（按出现顺序）。
void collect_link_targets(const glz::generic& node, std::vector<std::string>& targets) {
  if (node.is_array()) {
    for (const glz::generic& child : node.get_array()) collect_link_targets(child, targets);
    return;
  }
  if (!node.is_object()) return;
  if (string_member_equals(node, "tag", "a")) {
    if (const glz::generic* href = member(node, "href"); href != nullptr && href->is_string()) {
      std::string target = query_link_target(href->get_string());
      if (!target.empty()) targets.push_back(std::move(target));
    }
  }
  if (const glz::generic* content = member(node, "content")) collect_link_targets(*content, targets);
}

// 一个 structured-content 根节点是不是 Jitendex 链接卡（`data.content` 是标记）。
bool is_redirect_card_node(const glz::generic& node) {
  const glz::generic* data = member(node, "data");
  return data != nullptr && string_member_equals(*data, "content", kJitendexRedirectMarker);
}

// glossary 里的一项是 Jitendex 链接卡时收集它的链接目标并返回 true；不是返回 false。
// 根内容可以是单个节点，也可以是节点数组（每个都得是链接卡）。
bool collect_redirect_card(const glz::generic& item, std::vector<std::string>& targets) {
  if (!string_member_equals(item, "type", "structured-content")) return false;
  const glz::generic* content = member(item, "content");
  if (content == nullptr) return false;
  if (content->is_array()) {
    const auto& nodes = content->get_array();
    if (nodes.empty()) return false;
    for (const glz::generic& node : nodes) {
      if (!is_redirect_card_node(node)) return false;
    }
  } else if (!is_redirect_card_node(*content)) {
    return false;
  }
  collect_link_targets(*content, targets);
  return true;
}

// `[formOf, [rule, ...]]` 项（Yomitan schema 的 deinflection 形态）。
std::optional<Redirect> form_of_item(const glz::generic& item) {
  if (!item.is_array()) return std::nullopt;
  const auto& pair = item.get_array();
  if (pair.size() != 2 || !pair[0].is_string() || pair[0].get_string().empty() || !pair[1].is_array()) {
    return std::nullopt;
  }
  Redirect redirect{.form_of = pair[0].get_string(), .rules = {}};
  for (const glz::generic& rule : pair[1].get_array()) {
    if (!rule.is_string()) return std::nullopt;
    redirect.rules.push_back(rule.get_string());
  }
  return redirect;
}

// 混有 structured-content 的形态（Jitendex）。调用方已确认文本里有标记。
std::optional<std::vector<Redirect>> parse_mixed(const std::string& json) {
  glz::generic root;
  if (glz::read_json(root, json) || !root.is_array() || root.get_array().empty()) return std::nullopt;
  std::vector<Redirect> redirects;
  std::vector<std::string> link_targets;
  for (const glz::generic& item : root.get_array()) {
    if (std::optional<Redirect> redirect = form_of_item(item)) {
      redirects.push_back(std::move(*redirect));
    } else if (!collect_redirect_card(item, link_targets)) {
      return std::nullopt;  // 混着释义（或认不得的项）：不是纯重定向。
    }
  }
  // 链接卡与 formOf 指向同一词头时留带 rule 的 formOf；只有链接卡的目标不带 rule。
  for (std::string& target : link_targets) {
    const bool known = std::ranges::any_of(redirects, [&](const Redirect& r) { return r.form_of == target; });
    if (!known) redirects.push_back({.form_of = std::move(target), .rules = {}});
  }
  if (redirects.empty()) return std::nullopt;  // 链接卡里没有可跟随的站内链接。
  return redirects;
}

}  // namespace

std::optional<std::vector<Redirect>> parse(const std::string& json) {
  // 廉价前置判据：必须以 `[` 开头（容许空白），文本 glossary 在这里出局。
  std::size_t i = json.find_first_not_of(" \t\r\n");
  if (i == std::string::npos || json[i] != '[') return std::nullopt;
  i = json.find_first_not_of(" \t\r\n", i + 1);
  if (i == std::string::npos) return std::nullopt;
  if (json[i] == '{') {
    // structured-content 开头：只有带 Jitendex 链接卡标记的才值得整体解析，普通
    // structured-content 释义在这一次子串查找上出局。
    if (json.find(kJitendexRedirectMarker) == std::string::npos) return std::nullopt;
    return parse_mixed(json);
  }
  if (json[i] != '[') return std::nullopt;

  // 纯 Yomitan formOf 形态：按固定形状直接读，不建通用 JSON 树。
  std::vector<std::tuple<std::string, std::vector<std::string>>> items;
  if (glz::read_json(items, json) || items.empty()) {
    // 首项是 formOf、后面跟着 Jitendex 链接卡的顺序也要认。
    if (json.find(kJitendexRedirectMarker) == std::string::npos) return std::nullopt;
    return parse_mixed(json);
  }
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
  int criterion = 0;
  in >> flag >> recorded_size >> criterion;
  // 旧判据写的 sidecar（v1 没有第三列）不采信：见 kFlagCriterion。
  if (!in || (flag != 0 && flag != 1) || recorded_size != blobs_size || criterion != kFlagCriterion) {
    return std::nullopt;
  }
  return flag == 1;
}

bool write_flag(const std::string& dict_dir, bool present, uint64_t blobs_size) {
  const std::string final_path = dict_dir + "/" + std::string(kFlagFilename);
  const std::string tmp_path = final_path + ".tmp";
  {
    std::ofstream out(fushi::fs_path(tmp_path), std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << (present ? '1' : '0') << ' ' << blobs_size << ' ' << kFlagCriterion << '\n';
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

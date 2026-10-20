#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// Yomitan「词典自带变形」（dictionary deinflection）的纯重定向 glossary：整条 glossary
// 都由 `[formOf, [rule, ...]]` 项组成（LDOCE5++ 的 `instead of` → `instead of
// somebody/something`）。Lookup::lookup 把它摘掉并改查 formOf（BUG-2853，语义见
// lookup.cpp）。
//
// 判据在这里只写一次，导入端（打标）、读侧迁移扫描、查询期检测三处共用同一份——
// 三处口径一旦分叉，sidecar 说「本词典没有重定向」而查询期认得出来，跳过检测就会
// 静默丢掉重定向（行为变化），所以不许各写一份。
namespace fushi::redirect_glossary {

// 纯重定向记录的 glossary 很短（目标词头 + 一两条 rule 文本）。原始大小超过它的
// glossary 一律不是重定向。
inline constexpr unsigned long long kMaxRawBytes = 1024;

struct Redirect {
  std::string form_of;
  std::vector<std::string> rules;
};

// 整条 glossary（解压后的 JSON 文本）都是 `[formOf, [rule, ...]]` 项时返回这些项，
// 否则 nullopt。只看文本，不看大小门槛。
std::optional<std::vector<Redirect>> parse(const std::string& json);

// 导入端：原始 glossary（压缩前的字节）是否是纯重定向。与查询期同一判据：原始大小
// ≤ kMaxRawBytes 且 parse 成功。
bool is_redirect(std::string_view raw_glossary);

// 查询期的廉价前置门槛：zstd 帧头里的原始大小 ≤ kMaxRawBytes 才可能是重定向。
// [compressed_size] 超过 ZSTD_COMPRESSBOUND(kMaxRawBytes) 时**不读帧头**直接判否：
// 导入端（Yomitan / MDX / StarDict / DSL 各路径）都以 ZSTD_compressBound(原始大小)
// 为输出容量压缩，压缩结果不会超过它，而 compressBound 随原始大小单调递增，所以
// 「压缩后 > bound(1024)」蕴含「原始 > 1024」。这一步不碰 glossary 所在的页，冷页
// 下省掉一次缺页（结论与读帧头完全相同）。
bool may_be_redirect(const uint8_t* compressed, uint32_t compressed_size);

// 词典目录旁的 sidecar：本词典是否含任何纯重定向 glossary。格式与
// term_rules.flag 相同：`<0|1> <blobs.bin 字节数>`，大小把 flag 钉在算出它的那份
// blobs.bin 上（覆盖式恢复留下的陈旧 sidecar 不被采信）。缺失 / 无效 = 未知，读侧
// 照旧逐条检测（行为不变，只是没有加速）。
inline constexpr std::string_view kFlagFilename = "redirect_glossary.flag";
std::optional<bool> read_flag(const std::string& dict_dir, uint64_t blobs_size);
// 先写临时文件再改名：读侧不会读到半截内容。
bool write_flag(const std::string& dict_dir, bool present, uint64_t blobs_size);

// 已导入词典的一次性迁移扫描：走 hash.table → offset-index → term 记录 → glossary
// （与 query_raw 同一条路径，所以覆盖面恰好是查询能看到的全部记录），发现第一条
// 纯重定向即返回 true。v2 词典按目录里的 dict.zstd 训练字典解压。读不了文件返回
// nullopt。整本扫描会读遍 blobs.bin（大词典百毫秒到秒级），只该在后台线程 / isolate
// 上跑，不要放进 add_*_dict。
std::optional<bool> scan_dict_dir(const std::string& dict_dir);

}  // namespace fushi::redirect_glossary

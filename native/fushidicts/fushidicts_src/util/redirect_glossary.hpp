#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// 纯重定向 glossary：整条 glossary 没有任何可显示的释义，只是「去查另一个词头」。
// Lookup::lookup 把它摘掉并改查目标（BUG-2853，语义见 lookup.cpp）。两种形态：
//
// 1. Yomitan「词典自带变形」（dictionary deinflection）：整条 glossary 都由
//    `[formOf, [rule, ...]]` 项组成（LDOCE5++ 的 `instead of` → `instead of
//    somebody/something`）。
// 2. Jitendex 的重定向词条（BUG-5272，拍板台 QkIs9sPRrB）：一条
//    `data.content == "redirect-glossary"` 的 structured-content（「⟶ 目标词」的
//    富文本链接卡，链接 href 是 Yomitan 站内查询 `?query=<目标>&...`），通常再跟一条
//    `[formOf, [rule]]`（`怖気つく` → `[怖気づく, ["redirected from 怖気つく"]]`）；
//    约 1% 只有链接卡、没有 formOf 项（`アッという間に` → `あっという間に`）。目标取
//    formOf 项，没有 formOf 的链接卡取 href 的 query 参数。整条 glossary 必须只由
//    这两种项组成——混着任何释义的记录（OALDPE10 自指标签 + 释义，BUG-2566）不动。
//
// 判据在这里只写一次，导入端（打标）、读侧迁移扫描、查询期检测三处共用同一份——
// 三处口径一旦分叉，sidecar 说「本词典没有重定向」而查询期认得出来，跳过检测就会
// 静默丢掉重定向（行为变化），所以不许各写一份。判据一改就要抬 kFlagCriterion，
// 让旧判据算出的 sidecar 全部失效重扫。
namespace fushi::redirect_glossary {

// 纯重定向记录的 glossary 很短（目标词头 + 一两条 rule 文本；Jitendex 的链接卡带
// 百分号编码的 href 与注音 ruby，实测 13.9 万条里最大 1950 字节、p99 1123 字节）。
// 原始大小超过它的 glossary 一律不是重定向。
inline constexpr unsigned long long kMaxRawBytes = 4096;

struct Redirect {
  std::string form_of;
  std::vector<std::string> rules;
};

// 整条 glossary（解压后的 JSON 文本）是纯重定向（上面两种形态）时返回重定向目标，
// 否则 nullopt。同一目标只出现一次：Jitendex 的链接卡与 formOf 项指向同一词头时
// 留带 rule 的 formOf 项。只看文本，不看大小门槛。
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

// 词典目录旁的 sidecar：本词典是否含任何纯重定向 glossary。格式
// `<0|1> <blobs.bin 字节数> <判据版本>`：大小把 flag 钉在算出它的那份 blobs.bin 上
//（覆盖式恢复留下的陈旧 sidecar 不被采信），判据版本把它钉在算出它的那版 parse 上
//（判据放宽后，旧版写的「0」可能漏掉新认得的重定向——v1 没有第三列、不认 Jitendex，
// 存量 Jitendex 全是「0」）。缺失 / 无效 = 未知，读侧照旧逐条检测（行为不变，只是
// 没有加速），启动后的迁移扫描（ensure_redirect_glossary_flag）按新判据重写。
inline constexpr std::string_view kFlagFilename = "redirect_glossary.flag";
inline constexpr int kFlagCriterion = 2;
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

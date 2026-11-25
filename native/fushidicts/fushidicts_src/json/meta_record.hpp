#pragma once
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

#include "yomitan_parser.hpp"

// meta 记录（freq / pitch / ipa）在 blobs 里的两种形态，写侧（导入、存量升级）与读侧
// （query.cpp 的 enrich_freq / enrich_pitch）共用这一份编解码。
//
// 两种记录的前缀相同——[u8 type][u16 expr_len][expr][u8 mode_len][mode]——之后：
//
//   type 1（原样）：[u32 data_len][data]，data 是 meta bank 里那一项的原始 JSON，查询期
//                  每次用 yomitan_parser 解析。存量词典全是这种。
//   type 3（预解析，上游 hoshidicts eb4e5dd 的布局）：导入期就解析好的二进制
//     freq ：[u16 reading_len][reading][i32 value][u16 display_len][display]
//     pitch：[u16 reading_len][reading][u16 n] n x {[i32 position][u16 pattern_len][pattern]
//            [u16 n_nasal][i32 x n_nasal][u16 n_devoice][i32 x n_devoice]}
//     ipa  ：[u16 reading_len][reading][u16 n] n x {[u16 len][transcription]}
//
// type 3 只是把查询期那次解析挪到导入期：字段就是 ParsedFrequency / ParsedPitch 的全部
// 内容，解码结果与「对 type 1 的 data 调同一个解析器」逐字段相同。解析失败、mode 不是
// 这三种、或某个长度 / 个数放不进 u16 的条目照旧写 type 1（不丢数据），读侧两种都认。
namespace meta_record {

inline constexpr uint8_t kRawType = 1;
inline constexpr uint8_t kParsedType = 3;

// 把一项 meta 追加到 [out]：能预解析就写 type 3，否则写 type 1。[allow_parsed] 为假时
// 一律写 type 1（旧式导入，测试与存量词典的造法）。返回写入的类型。
uint8_t append(std::vector<char>& out, std::string_view expr, std::string_view mode, std::string_view data,
               bool allow_parsed);

// 读侧：[p, end) 从 mode 之后开始（type 1 时是 u32 data_len，type 3 时是 reading_len）。
// 与 yomitan_parser::parse_* 同口径：false = 这条记录没有可用的数据（type 1 解析失败 /
// 记录截断）。out 里的 string_view 指向记录本身或其中的 JSON。
bool read_frequency(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedFrequency& out);
bool read_pitch(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedPitch& out);
bool read_ipa(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedPitch& out);

}  // namespace meta_record

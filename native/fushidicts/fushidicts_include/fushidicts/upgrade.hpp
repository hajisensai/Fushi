#pragma once

#include <cstdint>
#include <string>

namespace fushidicts {

// 存量词典的原地升级（fushidicts_src/upgrade.cpp）：把旧式索引 hash.table + bloom.filter
// 换成 key.index（hash/key_index.hpp），可选地把 meta 记录预解析成 type 3
// （json/meta_record.hpp）。
//
// 契约：
//   * 绝不修改、截断或覆盖任何在用的文件——同进程或别的进程里的引擎可能正映射着
//     hash.table / bloom.filter / blobs.bin 在查词。只创建新文件（唯一命名的 *.tmp），
//     写完、落盘（memory::sync_file）再改名成新名字；改名成 key.index 是提交点，之前
//     任何一步失败词典都还是原样。
//   * 同一本词典的升级跨进程、跨线程串行化（对导入标记文件加独占锁，阻塞等待）：
//     并发的调用里只有一个真的升级，其余拿到锁后看到「已是最新」。
//   * 提交之后删除不再需要的旧文件（hash.table、bloom.filter，重写过记录的还有
//     blobs.bin）——但只在确认新文件与目录项都已落盘之后；没能确认、或删不掉（Windows
//     上仍被映射）就留着，之后的调用（已是最新）再清。
//   * 幂等：已有合法 key.index 时只清理、返回 UpToDate。上一次中途失败留下的临时文件 /
//     没有 key.index 认领的 blobs3.bin 不影响这一次，并被清掉。
//   * 引擎装载（DictionaryQuery::add_*_dict）从不升级、不写盘；升级后的词典下一次装载
//     才用上 key.index。
enum class UpgradeResult : int32_t {
  Failed = -1,        // 读不了 / 写不了（目录不是完整导入的词典、IO 失败）；词典原样可用
  UpToDate = 0,       // 已有合法 key.index（顺带清理了遗留的旧文件）
  Upgraded = 1,       // 本次写出了 key.index
  NotApplicable = 2,  // key.index 装不下这本词典（offset 超 32 位）或它一个键都没有，保持旧式、照常可用
};

// [allow_meta_rewrite]：全部记录都是 type 1（纯 freq / pitch / ipa 词典）时把记录重写成
// type 3 写进 blobs3.bin。混有其它类型记录的词典只换索引。可能抛 std::exception
// （内存不足等），抛出时同样不留下半截的提交。
UpgradeResult upgrade_dictionary(const std::string& dict_dir, bool allow_meta_rewrite);

}  // namespace fushidicts

#ifndef FUSHI_VOICE_HOOK_KIRIKIRI_EXPORTER_SCAN_H_
#define FUSHI_VOICE_HOOK_KIRIKIRI_EXPORTER_SCAN_H_

// 从**已经 link 完**的 KiriKiri 插件反查 ITVPFunctionExporter 单例。
//
// 为什么需要第三条路径（BUG-2145）：
//   ① exe 直取 `TVPGetFunctionExporter` —— 要求 exe 导出该符号。
//   ② hook LoadLibrary → 截插件 `V2Link` —— 要求插件在我们装上 hook **之后**才 link。
// KiriKiri2 有整整一族 build 两条都不满足。真机实测（フタマタ恋愛 Ver1.00，
// KiriKiri2/BCB，ASProtect `.adata` 壳）：主模块**磁盘与运行期的导出目录 RVA 都是 0**
// ——不是"查早了"，是这个 build 根本没有导出表，① 永远不可能成立；而 19 个插件全部在
// boot 首帧 link 完，早于本 worker 装 LoadLibrary hook，② 也永远等不到。两条路径一起
// 静默返回，症状与"这个引擎不支持游戏内查词"同形。
//
// 判据：exporter 是**引擎单例**。引擎在 `Plugins.link` 里把同一个指针传进每个插件的
// `V2Link`，各插件的 tp_stub 把它存进自己的静态变量。于是"在所有已 link 插件的可写节里
// 都出现过的同一个指针值"就是它。真机实测：19 个插件 → 交集 28 个值 → 过下面的形状门后
// **唯一剩 1 个**（ptr=0x0104b6fc，虚表 0x00ff4548，探到的 8 个槽全部落在 exe 映像内）。
//
// 形状门只是收敛，不是判定：最后一道门必须是**真调用**——拿一个已知导出名去
// `QueryFunctionsByNarrowString` 查一次，成功才采用。形状对但不是 exporter 的候选在那里
// 被否掉，所以这套判据不会把随便一个对象当成 exporter 装上去。

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <vector>

#include "exact_lookup_signature.h"

namespace fushi_voice_hook::kirikiri_exporter {

// 少于三个插件时交集不够窄，直接放弃：两个插件之间的公共值里混着大量 CRT/编译器共有的
// 常量与同名全局，误报会把真调用门变成一串危险的盲试。
constexpr size_t kMinPlugins = 3u;
// 单节扫描字节上限，界定最坏耗时（wuvorbis.dll 一个节就有 9271 个不同值）。
constexpr size_t kMaxSectionBytes = 1u << 20;
// 交集规模上限。超过说明判据在这台机器上失效了——此时放弃，不截断后接着猜。
constexpr size_t kMaxCandidates = 4096u;
// 形状门探多少个虚表槽。ITVPFunctionExporter 的接口方法数远多于此。
constexpr size_t kVtableProbeEntries = 8u;

// 可读性探测注入点：真实实现走 VirtualQuery，测试喂一份合成内存模型。
using ReadableSpanFn = bool (*)(const void* address, size_t bytes);

inline bool DefaultReadableSpan(const void* address, size_t bytes) {
  return exact_lookup::IsReadableSpan(address, bytes);
}

// 形状门。候选值必须是可读指针；其首个机器字（虚表指针）可读；虚表前
// kVtableProbeEntries 个槽全部落在引擎主模块映像内 —— ITVPFunctionExporter 的实现体在
// exe 里，"虚表槽指向 exe"正是它与插件自有对象、字符串、句柄、CRT 常量的分水岭。
inline bool LooksLikeExporter(uintptr_t candidate, uintptr_t image_base,
                              uint32_t image_size, ReadableSpanFn readable) {
  if (candidate == 0u || image_base == 0u || image_size == 0u) return false;
  if (readable == nullptr) return false;
  const auto* object = reinterpret_cast<const void*>(candidate);
  if (!readable(object, sizeof(uintptr_t))) return false;
  uintptr_t vtable = 0u;
  std::memcpy(&vtable, object, sizeof(vtable));
  if (vtable == 0u) return false;
  const auto* slots = reinterpret_cast<const void*>(vtable);
  if (!readable(slots, sizeof(uintptr_t) * kVtableProbeEntries)) return false;
  for (size_t i = 0; i < kVtableProbeEntries; ++i) {
    uintptr_t entry = 0u;
    std::memcpy(&entry,
                reinterpret_cast<const uint8_t*>(slots) + i * sizeof(uintptr_t),
                sizeof(entry));
    if (entry < image_base || entry >= image_base + image_size) return false;
  }
  return true;
}

// 把一个模块可写节里的机器字收成去重后的有序表。
inline void CollectWritableWords(const uint8_t* bytes, size_t size,
                                 std::vector<uintptr_t>* out) {
  out->clear();
  if (bytes == nullptr) return;
  const size_t limit = (std::min)(size, kMaxSectionBytes);
  for (size_t offset = 0; offset + sizeof(uintptr_t) <= limit;
       offset += sizeof(uintptr_t)) {
    uintptr_t word = 0u;
    std::memcpy(&word, bytes + offset, sizeof(word));
    if (word != 0u) out->push_back(word);
  }
  std::sort(out->begin(), out->end());
  out->erase(std::unique(out->begin(), out->end()), out->end());
}

// 交集：只留在**每个**模块里都出现过的值。少于 kMinPlugins 个模块、或交集大于
// kMaxCandidates 时返回 false（判据失效，放弃，不猜）。
inline bool IntersectWritableWords(
    const std::vector<std::vector<uintptr_t>>& per_module,
    std::vector<uintptr_t>* out) {
  if (out == nullptr) return false;
  out->clear();
  if (per_module.size() < kMinPlugins) return false;
  std::vector<uintptr_t> accumulator = per_module.front();
  std::sort(accumulator.begin(), accumulator.end());
  accumulator.erase(std::unique(accumulator.begin(), accumulator.end()),
                    accumulator.end());
  for (size_t i = 1; i < per_module.size(); ++i) {
    std::vector<uintptr_t> other = per_module[i];
    std::sort(other.begin(), other.end());
    other.erase(std::unique(other.begin(), other.end()), other.end());
    std::vector<uintptr_t> merged;
    merged.reserve((std::min)(accumulator.size(), other.size()));
    std::set_intersection(accumulator.begin(), accumulator.end(), other.begin(),
                          other.end(), std::back_inserter(merged));
    accumulator.swap(merged);
    if (accumulator.empty()) return false;
  }
  if (accumulator.size() > kMaxCandidates) return false;
  out->swap(accumulator);
  return !out->empty();
}

}  // namespace fushi_voice_hook::kirikiri_exporter

#endif  // FUSHI_VOICE_HOOK_KIRIKIRI_EXPORTER_SCAN_H_

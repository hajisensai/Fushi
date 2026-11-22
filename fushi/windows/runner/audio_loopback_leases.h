#ifndef RUNNER_AUDIO_LOOPBACK_LEASES_H_
#define RUNNER_AUDIO_LOOPBACK_LEASES_H_

#include <cstdint>
#include <cwctype>
#include <map>
#include <string>

// loopback 采集的租约表（纯数据结构，不碰 WASAPI，随每次 Windows runner 构建跑单测）。
//
// 一路采集（一个来源：系统混音 / 某个 WebView2 进程树）可以同时被好几个使用方持有：
// galgame 会话的系统混音回退、galgame 补录的临时源、跨应用语音缓存（应用外查词制卡带
// 前一句语音，常驻），网页视频制卡的进程树。旧实现 `Start` 幂等、`Stop` 无条件停掉
// 唯一的那一路——跨应用缓存常驻之后，galgame 会话一结束（或一次失败的 start 之后的
// 兜底 stop）就会把它的环停掉。这里把「谁在用」显式化：每次 Start 发一张租约，Stop
// 只交回自己那张；某一路的最后一张租约交回时才真的停那一路。交回未知 / 已交回的
// 租约是无操作（重复 stop、失败 start 之后的兜底 stop 都不再误伤别人）。
namespace fushi {

// 一路采集的来源键：系统混音为空串；进程树模式为规范化的 user data folder 或 pid。
// [silent] 不进键：同一进程树一边压低音量一边不压低是互斥的（见 LoopbackSourcesConflict）。
inline std::wstring LoopbackSourceKey(const std::wstring& user_data_folder,
                                      uint32_t target_pid) {
  if (target_pid != 0) {
    return L"pid:" + std::to_wstring(target_pid);
  }
  if (user_data_folder.empty()) {
    return std::wstring();
  }
  std::wstring s = user_data_folder;
  for (wchar_t& c : s) {
    c = static_cast<wchar_t>(std::towlower(c));
    if (c == L'/') {
      c = L'\\';
    }
  }
  while (!s.empty() && s.back() == L'\\') {
    s.pop_back();
  }
  return L"udf:" + s;
}

// 租约 → 所属采集会话（会话 id 由采集层分配，0 表示「无」）。不加锁：调用方
// （AudioLoopbackCapture）在自己的注册表锁内使用。
class LoopbackLeaseTable {
 public:
  // 给会话 [session] 发一张新租约（永不为 0、永不复用）。
  uint64_t Acquire(uint32_t session) {
    const uint64_t lease = ++next_lease_;
    owners_[lease] = session;
    return lease;
  }

  // 交回租约。返回它原属的会话（未知 / 已交回返回 0，调用方什么都不做）；
  // [*last] 置为「该会话已没有任何租约」——调用方据此真的停掉那一路。
  uint32_t Release(uint64_t lease, bool* last) {
    if (last != nullptr) {
      *last = false;
    }
    const auto it = owners_.find(lease);
    if (it == owners_.end()) {
      return 0;
    }
    const uint32_t session = it->second;
    owners_.erase(it);
    if (last != nullptr) {
      *last = Count(session) == 0;
    }
    return session;
  }

  // 租约所属会话；未知返回 0。
  uint32_t SessionOf(uint64_t lease) const {
    const auto it = owners_.find(lease);
    return it == owners_.end() ? 0 : it->second;
  }

  // 会话 [session] 上还挂着几张租约。
  size_t Count(uint32_t session) const {
    size_t n = 0;
    for (const auto& entry : owners_) {
      if (entry.second == session) {
        ++n;
      }
    }
    return n;
  }

  // 同一来源的采集线程意外退出（例如默认输出设备被拔掉）后重起：旧会话上的租约
  // 整体迁到新会话，持有方不用重新 start 就能继续取环。
  void Rebind(uint32_t from, uint32_t to) {
    for (auto& entry : owners_) {
      if (entry.second == from) {
        entry.second = to;
      }
    }
  }

  // 进程退出兜底：清空全部租约。
  void Clear() { owners_.clear(); }

  bool empty() const { return owners_.empty(); }

 private:
  uint64_t next_lease_ = 0;
  std::map<uint64_t, uint32_t> owners_;
};

}  // namespace fushi

#endif  // RUNNER_AUDIO_LOOPBACK_LEASES_H_

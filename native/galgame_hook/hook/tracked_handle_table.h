#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// 「文件句柄 → 适配器附带数据」的小型定长表，**全程无锁**。
//
// 为什么不能用 g_cs（BUG-2046）：这些表的 Forget 一律从 kernel32!CloseHandle 的
// detour 里被调，而 CloseHandle 是 MinHook Freeze/Unfreeze 在**挂起了进程内其它所有
// 线程之后**还会调用的 API（关 OpenThread 拿到的线程句柄）。进程里不止我们一份
// MinHook——LunaHook32 装 hook 时同样 Freeze。只要被它挂起的线程正卡在
// EnterCriticalSection(&g_cs) 的「已被唤醒、尚未拿到锁」窗口（LockCount 低两位 = 01，
// OwningThread = 0），Freeze 线程再进同一把锁就永远等不到那个被自己挂起的线程去消费
// 唤醒：真机栈里主线程与 LunaHook 线程都停在 fushi_voice_hook 的同一个
// EnterCriticalSection 调用点，锁却无人持有。规则因此只有一条：**CloseHandle detour
// 可达的任何代码都不得阻塞**。Artemis / CatSystem2 / Malie 三张表早已是这套写法，本文件
// 把它抽成一份，其余表统一接入。
//
// 协议（与 CatSystem2 / Malie 相同的 reserved 占位 + 发布，再加一个 seq 防撕裂读）：
//   - handle 是槽位的唯一状态字：INVALID_HANDLE_VALUE = 空；kReserved = 写入中；其它 = 已发布。
//   - 写：CAS 抢到槽位 → seq 变奇数 → 写附带字段 → 发布 handle → seq 变偶数。
//   - 读：读 seq（奇数直接跳过）→ 比 handle → 拷贝字段 → 再读 seq，不等就当没读到。
//     读者拷进调用方缓冲区的东西只有返回 true 才算数。
//   - Forget：把**所有** handle 相等的槽位 CAS 回空。同一句柄值极端情况下可能占两个槽位
//     （两线程同时 Remember 同一值），清掉全部才不会留下匹配未来复用句柄值的僵尸条目。
//
// Slot 需要两个成员：`HANDLE handle`（初值 INVALID_HANDLE_VALUE）与 `volatile LONG seq`。

inline HANDLE TrackedHandleReserved() {
  return reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
}

// 空值、INVALID_HANDLE_VALUE 与占位值都不是可登记/可查找/可摘除的真实句柄；尤其占位值
// 若被当成真实句柄 Forget，会把别的线程写到一半的槽位清空。
inline bool IsTrackableHandleValue(HANDLE handle) {
  return handle != nullptr && handle != INVALID_HANDLE_VALUE &&
         handle != TrackedHandleReserved();
}

template <typename Slot>
inline HANDLE LoadTrackedHandle(Slot& slot) {
  return static_cast<HANDLE>(InterlockedCompareExchangePointer(
      reinterpret_cast<PVOID volatile*>(&slot.handle), nullptr, nullptr));
}

template <typename Slot, typename Write>
inline void PublishTrackedSlot(Slot& slot, HANDLE handle, Write&& write) {
  InterlockedIncrement(&slot.seq);  // 奇数：写入中，读者跳过
  write(slot);
  InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(&slot.handle),
                             handle);
  InterlockedIncrement(&slot.seq);  // 偶数：稳定
}

// 登记 [handle]（同值已在表里则原位重写附带字段——这是漏掉一次 Forget 时的安全网）。
// 表满返回 false。write(Slot&) 只能写附带字段，不得碰 handle / seq。
template <typename Slot, size_t N, typename Write>
inline bool RememberTrackedHandle(Slot (&slots)[N], HANDLE handle,
                                  Write&& write) {
  if (!IsTrackableHandleValue(handle)) return false;
  const HANDLE reserved = TrackedHandleReserved();
  for (Slot& slot : slots) {
    auto* cell = reinterpret_cast<PVOID volatile*>(&slot.handle);
    if (InterlockedCompareExchangePointer(cell, reserved, handle) == handle) {
      PublishTrackedSlot(slot, handle, write);
      return true;
    }
  }
  for (Slot& slot : slots) {
    auto* cell = reinterpret_cast<PVOID volatile*>(&slot.handle);
    if (InterlockedCompareExchangePointer(cell, reserved,
                                          INVALID_HANDLE_VALUE) ==
        INVALID_HANDLE_VALUE) {
      PublishTrackedSlot(slot, handle, write);
      return true;
    }
  }
  return false;
}

// 找到 [handle] 的槽位并用 read(const Slot&) 拷出附带字段；撕裂读（期间被重写）不算命中。
template <typename Slot, size_t N, typename Read>
inline bool ReadTrackedHandle(Slot (&slots)[N], HANDLE handle, Read&& read) {
  if (!IsTrackableHandleValue(handle)) return false;
  for (Slot& slot : slots) {
    const LONG before = InterlockedCompareExchange(&slot.seq, 0, 0);
    if ((before & 1) != 0) continue;
    if (LoadTrackedHandle(slot) != handle) continue;
    read(static_cast<const Slot&>(slot));
    const LONG after = InterlockedCompareExchange(&slot.seq, 0, 0);
    if (after != before) continue;
    return true;
  }
  return false;
}

template <typename Slot, size_t N>
inline bool IsTrackedHandle(Slot (&slots)[N], HANDLE handle) {
  return ReadTrackedHandle(slots, handle, [](const Slot&) {});
}

// 把 [handle] 从表里摘掉（全部匹配槽位）。返回是否摘到了至少一个。
template <typename Slot, size_t N>
inline bool ForgetTrackedHandle(Slot (&slots)[N], HANDLE handle) {
  if (!IsTrackableHandleValue(handle)) return false;
  bool forgotten = false;
  for (Slot& slot : slots) {
    auto* cell = reinterpret_cast<PVOID volatile*>(&slot.handle);
    if (InterlockedCompareExchangePointer(cell, INVALID_HANDLE_VALUE,
                                          handle) == handle) {
      forgotten = true;
    }
  }
  return forgotten;
}

}  // namespace fushi_voice_hook

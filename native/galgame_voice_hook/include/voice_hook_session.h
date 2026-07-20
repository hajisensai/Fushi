#ifndef HIBIKI_VOICE_HOOK_SESSION_H_
#define HIBIKI_VOICE_HOOK_SESSION_H_

#include <cstdint>

#include "voice_hook_ipc.h"

namespace hibiki_voice_hook {

// 同一游戏进程内，hook DLL 会持有共享内存直到游戏退出。host/injector 被 Hibiki 停掉后
// 再连接时，CreateFileMapping 会返回既有映射；此时绝不能 memset，否则 DLL 的工作线程
// 不会重新执行，hooked 会永久被清成 0。
enum class MappingSessionAction {
  kInitializeFresh,
  kReuseReady,
  kRejectStale,
};

// Unity 事件生产者先原子预留 write_count，再填槽并最后提交 seq。消费者若撞在这段极短
// 窗口内，必须保留游标重试；把未提交槽当成“已消费”会永久丢失该句资源音频。
inline bool AdvanceUnityEventCursorIfCommitted(
    uint64_t expected_seq, uint64_t observed_seq, uint64_t* next_event) {
  if (next_event == nullptr || observed_seq != expected_seq) {
    return false;
  }
  ++*next_event;
  return true;
}

inline MappingSessionAction InspectMappingSession(
    bool already_exists, const SharedHeader* header,
    uint32_t expected_ring_capacity, uint32_t expected_text_offset,
    uint32_t expected_clip_offset) {
  if (!already_exists) {
    return MappingSessionAction::kInitializeFresh;
  }
  if (header == nullptr || header->magic != kSharedMagic ||
      header->version != kSharedVersion ||
      header->ring_capacity != expected_ring_capacity ||
      header->text_region_offset != expected_text_offset ||
      header->clip_region_offset != expected_clip_offset ||
      header->hooked == 0) {
    return MappingSessionAction::kRejectStale;
  }
  return MappingSessionAction::kReuseReady;
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_VOICE_HOOK_SESSION_H_

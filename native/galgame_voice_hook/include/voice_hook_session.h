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

// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>

#include "voice_hook_session.h"

using fushi_voice_hook::InspectMappingSession;
using fushi_voice_hook::MappingSessionAction;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::kSharedMagic;
using fushi_voice_hook::kSharedVersion;

int main() {
  constexpr uint32_t kRing = 23040000;
  constexpr uint32_t kText = 23040120;
  constexpr uint32_t kClip = 23564408;

  SharedHeader header{};
  header.magic = kSharedMagic;
  header.version = kSharedVersion;
  header.ring_capacity = kRing;
  header.text_region_offset = kText;
  header.clip_region_offset = kClip;
  header.hooked = 1;
  const uint32_t deny_seq =
      fushi_voice_hook::PublishNativeLoopbackRequest(
          &header, fushi_voice_hook::kNativeLoopbackDeny);
  assert(deny_seq == 1);
  const auto deny = fushi_voice_hook::ReadNativeLoopbackRequest(&header);
  assert(fushi_voice_hook::PublishNativeLoopbackApplied(
      &header, deny, fushi_voice_hook::kNativeLoopbackStateStopped));

  assert(InspectMappingSession(false, &header, kRing, kText, kClip, false) ==
         MappingSessionAction::kInitializeFresh);
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, true) ==
         MappingSessionAction::kReuseReady);
  // ready 映射不代表本次请求的 DLL 已驻留。更新后的 injector 遇到旧 DLL 时必须
  // fail closed，不能沿用 hooked=1 跳过注入并伪装新能力已经生效。
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, false) ==
         MappingSessionAction::kRejectStale);

  // Reconnect must not memset a live mapping. A real policy edge advances the
  // request while preserving the old ack until the injected DLL applies it;
  // neither condition makes the audio/text session stale.
  const uint32_t allow_seq =
      fushi_voice_hook::PublishNativeLoopbackRequest(
          &header, fushi_voice_hook::kNativeLoopbackAllow);
  assert(allow_seq == 2);
  assert(fushi_voice_hook::AtomicLoadShared32(
             &header.native_loopback_applied_seq) == deny_seq);
  assert(fushi_voice_hook::AtomicLoadShared32(
             &header.native_loopback_state) ==
         fushi_voice_hook::kNativeLoopbackStateStopped);
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, true) ==
         MappingSessionAction::kReuseReady);

  header.hooked = 0;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, true) ==
         MappingSessionAction::kRejectStale);
  header.hooked = 1;
  header.version++;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, true) ==
         MappingSessionAction::kRejectStale);
  return 0;
}

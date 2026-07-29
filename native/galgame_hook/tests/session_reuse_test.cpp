#include <cassert>
#include <cstdint>

#include "voice_hook_session.h"

using hibiki_voice_hook::InspectMappingSession;
using hibiki_voice_hook::MappingSessionAction;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;

int main() {
  constexpr uint32_t kRing = 23040000;
  constexpr uint32_t kText = 23040120;
  constexpr uint32_t kClip = 23564408;
  constexpr uint32_t kPreview = 999999;
  constexpr uint32_t kPreviewCount =
      hibiki_voice_hook::kThreadPreviewCount;

  SharedHeader header{};
  header.magic = kSharedMagic;
  header.version = kSharedVersion;
  header.ipc_protocol_version = hibiki_voice_hook::kStableIpcVersion;
  header.luna_bridge_abi_version =
      hibiki_voice_hook::kLunaBridgeAbiVersion;
  header.luna_vendored_version = hibiki_voice_hook::kLunaVendoredVersion;
  header.ring_capacity = kRing;
  header.text_region_offset = kText;
  header.clip_region_offset = kClip;
  header.thread_preview_offset = kPreview;
  header.thread_preview_slot_count = kPreviewCount;
  header.hooked = 1;

  assert(InspectMappingSession(false, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kInitializeFresh);
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kReuseReady);

  header.hooked = 0;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kRejectStale);
  header.hooked = 1;
  header.version++;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kRejectStale);
  header.version = kSharedVersion;
  header.ipc_protocol_version--;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kRejectStale);
  header.ipc_protocol_version = hibiki_voice_hook::kStableIpcVersion;
  header.thread_preview_offset++;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip, kPreview,
                               kPreviewCount) ==
         MappingSessionAction::kRejectStale);
  return 0;
}

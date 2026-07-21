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

  SharedHeader header{};
  header.magic = kSharedMagic;
  header.version = kSharedVersion;
  header.ring_capacity = kRing;
  header.text_region_offset = kText;
  header.clip_region_offset = kClip;
  header.hooked = 1;

  assert(InspectMappingSession(false, &header, kRing, kText, kClip) ==
         MappingSessionAction::kInitializeFresh);
  assert(InspectMappingSession(true, &header, kRing, kText, kClip) ==
         MappingSessionAction::kReuseReady);

  header.hooked = 0;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip) ==
         MappingSessionAction::kRejectStale);
  header.hooked = 1;
  header.version++;
  assert(InspectMappingSession(true, &header, kRing, kText, kClip) ==
         MappingSessionAction::kRejectStale);
  return 0;
}

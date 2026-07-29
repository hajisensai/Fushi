#include "ipc_contract_descriptor.h"

#include <cstring>

#include "../../../hibiki/windows/runner/voice_hook_ipc.h"

namespace {
bool Accepts(const hibiki_voice_hook::SharedHeader* header) {
  using namespace hibiki_voice_hook;
  return header != nullptr && header->magic == kSharedMagic &&
         header->version == kSharedVersion &&
         header->ipc_protocol_version == kStableIpcVersion &&
         header->luna_bridge_abi_version == kLunaBridgeAbiVersion &&
         header->luna_vendored_version == kLunaVendoredVersion &&
         HasExpectedIpcLayout(header);
}
}  // namespace

extern "C" IpcContractDescriptor HostIpcDescriptor() {
  using namespace hibiki_voice_hook;
  return {
      kSharedVersion,
      kStableIpcVersion,
      sizeof(SharedHeader),
      alignof(SharedHeader),
      sizeof(TextSlot),
      sizeof(VoiceClip),
      sizeof(ThreadPreviewSlot),
      offsetof(SharedHeader, selected_text_thread_id),
      offsetof(SharedHeader, thread_preview_offset),
      offsetof(SharedHeader, thread_preview_slot_count),
      offsetof(SharedHeader, thread_preview_write_count),
      offsetof(SharedHeader, loopback_ring_offset),
      offsetof(SharedHeader, total_written),
  };
}

extern "C" bool HostAcceptsIpcFixture(const void* input, size_t size) {
  if (input == nullptr ||
      size < sizeof(hibiki_voice_hook::SharedHeader)) {
    return false;
  }
  hibiki_voice_hook::SharedHeader header{};
  std::memcpy(&header, input, sizeof(header));
  return Accepts(&header);
}

extern "C" uint64_t HostFixtureSelectedThread(const void* input, size_t size) {
  if (!HostAcceptsIpcFixture(input, size)) return 0;
  hibiki_voice_hook::SharedHeader header{};
  std::memcpy(&header, input, sizeof(header));
  return header.selected_text_thread_id;
}

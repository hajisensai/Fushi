#include "ipc_contract_descriptor.h"

#include <cstring>

#include "voice_hook_ipc.h"

extern "C" IpcContractDescriptor NativeIpcDescriptor() {
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

extern "C" size_t NativeBuildIpcFixture(void* output, size_t capacity) {
  using namespace hibiki_voice_hook;
  if (output == nullptr || capacity < sizeof(SharedHeader)) return 0;
  SharedHeader header{};
  header.magic = kSharedMagic;
  header.version = kSharedVersion;
  header.ipc_protocol_version = kStableIpcVersion;
  header.luna_bridge_abi_version = kLunaBridgeAbiVersion;
  header.luna_vendored_version = kLunaVendoredVersion;
  header.ring_capacity = 4096;
  header.loopback_ring_capacity = 8192;
  header.loopback_marker_slot_count = kLoopbackMarkerCount;
  header.thread_preview_slot_count = kThreadPreviewCount;
  header.text_region_offset =
      static_cast<uint32_t>(sizeof(SharedHeader) + header.ring_capacity);
  header.clip_region_offset =
      header.text_region_offset + kTextSlotCount * kTextSlotBytes;
  header.loopback_ring_offset =
      header.clip_region_offset + kClipCount * sizeof(VoiceClip);
  header.loopback_marker_offset =
      header.loopback_ring_offset + header.loopback_ring_capacity;
  header.thread_preview_offset =
      header.loopback_marker_offset +
      kLoopbackMarkerCount * sizeof(LoopbackMarker);
  header.selected_text_thread_id = 0x1122334455667788ull;
  header.thread_preview_write_count = 0x8877665544332211ull;
  std::memcpy(output, &header, sizeof(header));
  return sizeof(header);
}

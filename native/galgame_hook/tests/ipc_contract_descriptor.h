#ifndef HIBIKI_IPC_CONTRACT_DESCRIPTOR_H_
#define HIBIKI_IPC_CONTRACT_DESCRIPTOR_H_

#include <cstddef>
#include <cstdint>

struct IpcContractDescriptor {
  uint32_t shared_version;
  uint32_t stable_ipc_version;
  size_t shared_header_size;
  size_t shared_header_align;
  size_t text_slot_size;
  size_t voice_clip_size;
  size_t preview_slot_size;
  size_t selected_offset;
  size_t preview_offset_offset;
  size_t preview_count_offset;
  size_t preview_writes_offset;
  size_t loopback_offset;
  size_t total_written_offset;
};

extern "C" IpcContractDescriptor NativeIpcDescriptor();
extern "C" IpcContractDescriptor HostIpcDescriptor();
extern "C" size_t NativeBuildIpcFixture(void* output, size_t capacity);
extern "C" bool HostAcceptsIpcFixture(const void* input, size_t size);
extern "C" uint64_t HostFixtureSelectedThread(const void* input, size_t size);

#endif  // HIBIKI_IPC_CONTRACT_DESCRIPTOR_H_

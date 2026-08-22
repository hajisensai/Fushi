#ifndef FUSHI_VOICE_HOOK_SGRE_VOICE_ARCHIVE_H_
#define FUSHI_VOICE_HOOK_SGRE_VOICE_ARCHIVE_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>

#include "adapters/sgre_profile.h"

namespace fushi_voice_hook {

// Return the first exact byte-for-byte occurrence. SGRE stores character
// voices in voice_body.bin and BGM/SE in sound_body.bin, so archive membership
// is stronger role evidence than a duration or XAudio-format heuristic.
inline bool FindSgrePayloadOffsetInBytes(
    const uint8_t* archive, size_t archive_bytes, const uint8_t* payload,
    size_t payload_bytes, uint64_t* offset) {
  if (archive == nullptr || payload == nullptr || payload_bytes == 0 ||
      payload_bytes > archive_bytes || offset == nullptr) {
    return false;
  }
  const uint8_t* cursor = archive;
  const uint8_t* const last = archive + (archive_bytes - payload_bytes);
  while (cursor <= last) {
    const size_t remaining = static_cast<size_t>(last - cursor) + 1u;
    const void* found = std::memchr(cursor, payload[0], remaining);
    if (found == nullptr) return false;
    const auto* candidate = static_cast<const uint8_t*>(found);
    if (std::memcmp(candidate, payload, payload_bytes) == 0) {
      *offset = static_cast<uint64_t>(candidate - archive);
      return true;
    }
    cursor = candidate + 1;
  }
  return false;
}

struct SgreVoiceArchiveView {
  HANDLE file = INVALID_HANDLE_VALUE;
  HANDLE mapping = nullptr;
  const uint8_t* data = nullptr;
  size_t bytes = 0;
  bool attempted = false;
};

// HookWorker is the sole caller. Handles intentionally remain process-lifetime:
// the injected DLL has the same lifetime and Windows reclaims them on game exit.
inline SgreVoiceArchiveView g_sgre_voice_archive;

struct SgreVoiceArchiveResourceParts {
  const uint8_t* fmt = nullptr;
  uint32_t fmt_bytes = 0;
  const uint8_t* dpds = nullptr;
  uint32_t dpds_bytes = 0;
  uint64_t body_offset = 0;
};

// 只在 SGRE profile 已激活时映射。门控在 profile 而不是 exe 文件名——理由见
// adapters/sgre_profile.h。映射是一次性的（attempted 记住首次结果），失败不重试。
inline bool OpenSgreVoiceArchive() {
  SgreVoiceArchiveView& view = g_sgre_voice_archive;
  if (view.attempted) return view.data != nullptr;
  // profile 未激活时**不**记 attempted：adapter 安装与第一批音频作业之间没有顺序保证，
  // 提前记一次失败会把这条路径在本次会话里永久毒死。
  if (!SgreProfileActive()) return false;
  view.attempted = true;

  std::wstring path;
  if (!SgreVoiceArchivePath(&path)) return false;

  view.file = CreateFileW(path.c_str(), GENERIC_READ,
                          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (view.file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(view.file, &size) || size.QuadPart <= 0 ||
      static_cast<uint64_t>(size.QuadPart) >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    return false;
  }
  view.mapping =
      CreateFileMappingW(view.file, nullptr, PAGE_READONLY, 0, 0, nullptr);
  if (view.mapping == nullptr) return false;
  view.data = static_cast<const uint8_t*>(
      MapViewOfFile(view.mapping, FILE_MAP_READ, 0, 0, 0));
  if (view.data == nullptr) return false;
  view.bytes = static_cast<size_t>(size.QuadPart);
  return true;
}

inline bool FindSgreVoiceArchivePayload(const uint8_t* payload,
                                        size_t payload_bytes,
                                        uint64_t* body_offset) {
  // 归档实测 322 MiB，未命中一次全内存扫描约 30ms，跑在 HookWorker 上。调用方必须先用
  // 时长判据把 BGM/SE 挡掉（见 windows_audio_adapter.inc 的 kWmaudio2 分支），这里只留
  // 一条防畸形提交的下界。真正的角色资源证明是下面那次**全缓冲逐字节**比较，不是它。
  if (payload_bytes < 256 || !OpenSgreVoiceArchive()) return false;
  return FindSgrePayloadOffsetInBytes(
      g_sgre_voice_archive.data, g_sgre_voice_archive.bytes, payload,
      payload_bytes, body_offset);
}

// SGRE lays out every WMA resource as its exact 18-byte WAVEFORMATEX, two PSB
// padding bytes, the UINT32 dpds table, then the compressed payload.  Require
// both the full payload and the runtime table to match the mapped voice archive
// before treating the submission as character voice.
inline bool FindSgreVoiceArchiveResourceParts(
    const uint8_t* payload, size_t payload_bytes, const uint8_t* runtime_dpds,
    uint32_t packet_count, SgreVoiceArchiveResourceParts* parts) {
  if (runtime_dpds == nullptr || packet_count == 0 || parts == nullptr ||
      static_cast<uint64_t>(packet_count) * 4u >
          std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  uint64_t body_offset = 0;
  if (!FindSgreVoiceArchivePayload(payload, payload_bytes, &body_offset)) {
    return false;
  }
  constexpr uint32_t kFmtBytes = 18;
  constexpr uint32_t kPsbPaddingBytes = 2;
  const uint32_t dpds_bytes = packet_count * 4u;
  const uint64_t prefix_bytes =
      static_cast<uint64_t>(kFmtBytes) + kPsbPaddingBytes + dpds_bytes;
  if (body_offset < prefix_bytes) return false;
  const uint8_t* const dpds =
      g_sgre_voice_archive.data + body_offset - dpds_bytes;
  const uint8_t* const fmt = dpds - kPsbPaddingBytes - kFmtBytes;
  if (std::memcmp(dpds, runtime_dpds, dpds_bytes) != 0 ||
      fmt[0] != 0x61 || fmt[1] != 0x01 ||
      fmt[kFmtBytes] != 0 || fmt[kFmtBytes + 1] != 0) {
    return false;
  }
  parts->fmt = fmt;
  parts->fmt_bytes = kFmtBytes;
  parts->dpds = dpds;
  parts->dpds_bytes = dpds_bytes;
  parts->body_offset = body_offset;
  return true;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_SGRE_VOICE_ARCHIVE_H_

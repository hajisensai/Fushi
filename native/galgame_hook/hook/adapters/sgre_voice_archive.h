#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace fushi_voice_hook {

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
};

inline void CloseSgreVoiceArchive(SgreVoiceArchiveView* view) {
  if (view == nullptr) return;
  if (view->data != nullptr) UnmapViewOfFile(view->data);
  if (view->mapping != nullptr) CloseHandle(view->mapping);
  if (view->file != INVALID_HANDLE_VALUE) CloseHandle(view->file);
  *view = SgreVoiceArchiveView{};
}

inline bool OpenSgreVoiceArchive(const wchar_t* path,
                                 SgreVoiceArchiveView* view) {
  if (path == nullptr || path[0] == 0 || view == nullptr ||
      view->data != nullptr) {
    return false;
  }
  SgreVoiceArchiveView opened;
  opened.file = CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (opened.file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(opened.file, &size) || size.QuadPart <= 0 ||
      static_cast<uint64_t>(size.QuadPart) >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    CloseSgreVoiceArchive(&opened);
    return false;
  }
  opened.mapping =
      CreateFileMappingW(opened.file, nullptr, PAGE_READONLY, 0, 0, nullptr);
  if (opened.mapping == nullptr) {
    CloseSgreVoiceArchive(&opened);
    return false;
  }
  opened.data = static_cast<const uint8_t*>(
      MapViewOfFile(opened.mapping, FILE_MAP_READ, 0, 0, 0));
  if (opened.data == nullptr) {
    CloseSgreVoiceArchive(&opened);
    return false;
  }
  opened.bytes = static_cast<size_t>(size.QuadPart);
  *view = opened;
  return true;
}

struct SgreVoiceArchiveResourceParts {
  const uint8_t* fmt = nullptr;
  uint32_t fmt_bytes = 0;
  const uint8_t* dpds = nullptr;
  uint32_t dpds_bytes = 0;
  uint64_t body_offset = 0;
};

inline bool FindSgreVoiceArchiveResourceParts(
    const SgreVoiceArchiveView& archive, const uint8_t* payload,
    size_t payload_bytes, const uint8_t* runtime_dpds, uint32_t packet_count,
    SgreVoiceArchiveResourceParts* parts) {
  if (archive.data == nullptr || payload_bytes < 256 ||
      runtime_dpds == nullptr || packet_count == 0 || parts == nullptr ||
      static_cast<uint64_t>(packet_count) * 4u >
          std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  uint64_t body_offset = 0;
  if (!FindSgrePayloadOffsetInBytes(archive.data, archive.bytes, payload,
                                    payload_bytes, &body_offset)) {
    return false;
  }
  constexpr uint32_t kFmtBytes = 18;
  constexpr uint32_t kPsbPaddingBytes = 2;
  const uint32_t dpds_bytes = packet_count * 4u;
  const uint64_t prefix_bytes =
      static_cast<uint64_t>(kFmtBytes) + kPsbPaddingBytes + dpds_bytes;
  if (body_offset < prefix_bytes) return false;
  const uint8_t* const dpds = archive.data + body_offset - dpds_bytes;
  const uint8_t* const fmt = dpds - kPsbPaddingBytes - kFmtBytes;
  if (std::memcmp(dpds, runtime_dpds, dpds_bytes) != 0 || fmt[0] != 0x61 ||
      fmt[1] != 0x01 || fmt[kFmtBytes] != 0 || fmt[kFmtBytes + 1] != 0) {
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

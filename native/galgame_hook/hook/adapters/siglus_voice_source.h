#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "siglus_message_capture.h"

namespace fushi_voice_hook {

// Adapter queue policy, not a claimed engine path-length limit. Longer paths
// are rejected in full so a truncated path can never acquire resource identity.
inline constexpr uint32_t kSiglusVoiceSourcePathUnits = 520;
struct SiglusVoiceSourceTask {
  uint32_t key = 0;
  uint32_t offset = 0;
  uint32_t length = 0;
  wchar_t path[kSiglusVoiceSourcePathUnits] = {};
};
struct SiglusVoiceSourceLayout {
  uint32_t payload_return = 0;
  uint32_t ogg_vtable = 0;
  int32_t key_frame_offset = 0;
  int32_t key_copy_frame_displacement = 0;
  int32_t path_frame_displacement = 0;
  int32_t reader_frame_displacement = 0;
  uint32_t path_argument_offset = 0;
  uint32_t offset_argument_offset = 0;
  uint32_t length_argument_offset = 0;
};
struct SiglusVoiceSourceCall {
  uint32_t reader = 0;
  uint32_t entry_esp = 0;
  uint32_t caller_ebp = 0;
  uint32_t original_esi = 0;
  uint32_t original_ebx = 0;
};

// The worker opens this path after the callback has returned. Relative paths,
// including drive-relative and root-relative paths, could then name another
// archive if the game's CWD changes. Do not resolve them in the callback.
inline bool IsStableSiglusVoiceSourcePath(const wchar_t* path, uint32_t units) {
  if (path == nullptr || units < 4 || units >= kSiglusVoiceSourcePathUnits)
    return false;
  const auto separator = [](wchar_t c) { return c == L'\\' || c == L'/'; };
  if (separator(path[units - 1])) return false;
  const bool drive_letter = (path[0] >= L'A' && path[0] <= L'Z') ||
                            (path[0] >= L'a' && path[0] <= L'z');
  if (drive_letter && path[1] == L':' && separator(path[2])) return true;
  // Only ordinary UNC roots are admitted, not device/extended namespaces.
  if (path[0] != L'\\' || path[1] != L'\\') return false;
  uint32_t component = 2;
  for (uint32_t root_part = 0; root_part < 2; ++root_part) {
    uint32_t end = component;
    while (end < units && !separator(path[end])) {
      const wchar_t c = path[end];
      if (c < L' ' || c == L':' || c == L'*' || c == L'?' || c == L'"' ||
          c == L'<' || c == L'>' || c == L'|') return false;
      ++end;
    }
    if (end == component || end == units || path[end - 1] == L'.' ||
        path[end - 1] == L' ')
      return false;
    component = end + 1;
  }
  return component < units && !separator(path[component]);
}

inline bool SiglusVoiceSourceAddress(uint32_t base, int32_t displacement,
                                     uint32_t* out) {
  const int64_t address = static_cast<int64_t>(base) + displacement;
  if (base == 0 || out == nullptr || address <= 0 || address > UINT32_MAX)
    return false;
  *out = static_cast<uint32_t>(address);
  return true;
}

template <typename Reader>
bool ReadSiglusVoiceSourceWord(Reader& read, uint32_t base, int32_t displacement,
                               uint32_t* out) {
  uint32_t address = 0;
  return SiglusVoiceSourceAddress(base, displacement, &address) &&
         address <= UINT32_MAX - 3 && read(address, out, sizeof(*out));
}

// This consumes only bounded metadata from the proved Resource -> OggOpen call.
// It does not parse an archive or prove successful playback/decoding.
template <typename Reader>
bool CaptureSiglusVoiceSource(const SiglusVoiceSourceLayout& layout,
                              const SiglusVoiceSourceCall& call,
                              Reader& read, SiglusVoiceSourceTask* out) {
  static_assert(sizeof(wchar_t) == 2, "Windows UTF-16 paths required");
  if (out == nullptr || layout.payload_return == 0 || layout.ogg_vtable == 0 ||
      call.reader == 0 || call.entry_esp == 0 ||
      call.entry_esp >= call.caller_ebp ||
      ((call.entry_esp | call.caller_ebp) & 3u) != 0 ||
      layout.path_argument_offset > INT32_MAX ||
      layout.offset_argument_offset > INT32_MAX ||
      layout.length_argument_offset > INT32_MAX) return false;
  uint32_t caller = 0, frame_reader = 0, vtable = 0, key = 0, key_copy = 0;
  uint32_t path = 0, frame_path = 0, offset = 0, length = 0;
  if (!ReadSiglusVoiceSourceWord(read, call.entry_esp, 0, &caller) ||
      caller != layout.payload_return ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp,
                                layout.key_frame_offset, &key) || key > INT32_MAX ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp,
                                layout.key_copy_frame_displacement, &key_copy) ||
      key_copy != key ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp,
                                layout.reader_frame_displacement, &frame_reader) ||
      frame_reader != call.reader ||
      !ReadSiglusVoiceSourceWord(read, call.reader, 0, &vtable) ||
      vtable != layout.ogg_vtable ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp,
          static_cast<int32_t>(layout.path_argument_offset), &path) ||
      !SiglusVoiceSourceAddress(call.caller_ebp, layout.path_frame_displacement,
                                &frame_path) || path != frame_path ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp,
          static_cast<int32_t>(layout.offset_argument_offset), &offset) ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp,
          static_cast<int32_t>(layout.length_argument_offset), &length) ||
      offset != call.original_esi || length != call.original_ebx ||
      offset == 0 || length == 0 || length > UINT32_MAX - offset) return false;
  // The original path is an MSVC x86 TextUnion, including its size/capacity.
  uint32_t text_union[6] = {};
  if (path > UINT32_MAX - sizeof(text_union) ||
      !read(path, text_union, sizeof(text_union))) return false;
  const uint32_t units = text_union[4], capacity = text_union[5];
  if (units == 0 || units >= kSiglusVoiceSourcePathUnits || units > capacity)
    return false;
  const uint32_t characters = capacity < 8 ? path : text_union[0];
  const uint32_t bytes = (units + 1) * sizeof(wchar_t);
  if (characters == 0 || characters > UINT32_MAX - bytes) return false;
  SiglusVoiceSourceTask task;
  if (!read(characters, task.path, bytes) || task.path[units] != L'\0')
    return false;
  for (uint32_t i = 0; i < units; ++i) {
    if (task.path[i] == L'\0') return false;
  }
  if (!IsStableSiglusVoiceSourcePath(task.path, units)) return false;
  uint32_t final_union[6] = {};
  if (!read(path, final_union, sizeof(final_union)) ||
      std::memcmp(text_union, final_union, sizeof(text_union)) != 0)
    return false;
  task.key = key; task.offset = offset; task.length = length;
  *out = task;
  return true;
}

}  // namespace fushi_voice_hook

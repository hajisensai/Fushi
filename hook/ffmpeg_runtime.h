#pragma once

#include <cstddef>
#include <cstdint>
#include <cwchar>

namespace hibiki_voice_hook {

enum class FfmpegModuleKind : uint8_t {
  kNone = 0,
  kAvcodec = 1,
  kAvformat = 2,
};

struct FfmpegModule {
  FfmpegModuleKind kind = FfmpegModuleKind::kNone;
  uint32_t major = 0;
};

inline wchar_t AsciiLower(wchar_t value) {
  return value >= L'A' && value <= L'Z'
             ? static_cast<wchar_t>(value - L'A' + L'a')
             : value;
}

inline bool StartsWithAsciiInsensitive(const wchar_t* value,
                                       const wchar_t* prefix) {
  if (value == nullptr || prefix == nullptr) return false;
  while (*prefix != 0) {
    if (*value == 0 || AsciiLower(*value) != AsciiLower(*prefix)) return false;
    ++value;
    ++prefix;
  }
  return true;
}

inline bool FfmpegEqualsAsciiInsensitive(const wchar_t* value,
                                         const wchar_t* expected) {
  if (value == nullptr || expected == nullptr) return false;
  while (*value != 0 && *expected != 0) {
    if (AsciiLower(*value) != AsciiLower(*expected)) return false;
    ++value;
    ++expected;
  }
  return *value == 0 && *expected == 0;
}

// Chromium/NW.js ship one ffmpeg.dll containing both libavformat and
// libavcodec instead of the versioned avformat-XX/avcodec-XX split used by
// Ren'Py. Its ABI major cannot be inferred from the filename, so callers must
// capability-probe exports and treat the major as unknown (0).
inline bool IsMonolithicFfmpegModuleName(const wchar_t* module_name) {
  if (module_name == nullptr) return false;
  const wchar_t* base = module_name;
  for (const wchar_t* cursor = module_name; *cursor != 0; ++cursor) {
    if (*cursor == L'/' || *cursor == L'\\') base = cursor + 1;
  }
  return FfmpegEqualsAsciiInsensitive(base, L"ffmpeg.dll");
}

inline FfmpegModule ParseFfmpegModuleName(const wchar_t* module_name) {
  if (module_name == nullptr) return {};
  const wchar_t* base = module_name;
  for (const wchar_t* cursor = module_name; *cursor != 0; ++cursor) {
    if (*cursor == L'/' || *cursor == L'\\') base = cursor + 1;
  }
  if (StartsWithAsciiInsensitive(base, L"lib")) base += 3;
  FfmpegModuleKind kind = FfmpegModuleKind::kNone;
  const wchar_t* major_text = nullptr;
  if (StartsWithAsciiInsensitive(base, L"avcodec-")) {
    kind = FfmpegModuleKind::kAvcodec;
    major_text = base + 8;
  } else if (StartsWithAsciiInsensitive(base, L"avformat-")) {
    kind = FfmpegModuleKind::kAvformat;
    major_text = base + 9;
  } else {
    return {};
  }
  uint32_t major = 0;
  size_t digits = 0;
  while (major_text[digits] >= L'0' && major_text[digits] <= L'9') {
    major = major * 10u + static_cast<uint32_t>(major_text[digits] - L'0');
    ++digits;
  }
  if (digits == 0 || major == 0 || major > 999) return {};
  const wchar_t tail = major_text[digits];
  if (tail != 0 && tail != L'.' && tail != L'-') return {};
  return {kind, major};
}

enum class AudioResourceFormat : uint8_t {
  kUnknown = 0,
  kOgg = 1,
  kWave = 2,
  kOpus = 3,
  kFlac = 4,
  kM4a = 5,
};

inline bool BytesEqual(const uint8_t* bytes, size_t size, size_t offset,
                       const char* expected, size_t expected_size) {
  if (bytes == nullptr || offset > size || expected_size > size - offset) {
    return false;
  }
  for (size_t i = 0; i < expected_size; ++i) {
    if (bytes[offset + i] != static_cast<uint8_t>(expected[i])) return false;
  }
  return true;
}

inline AudioResourceFormat DetectAudioResourceFormat(const uint8_t* bytes,
                                                      size_t size) {
  if (BytesEqual(bytes, size, 0, "OggS", 4)) {
    return BytesEqual(bytes, size, 28, "OpusHead", 8)
               ? AudioResourceFormat::kOpus
               : AudioResourceFormat::kOgg;
  }
  if (BytesEqual(bytes, size, 0, "RIFF", 4) &&
      BytesEqual(bytes, size, 8, "WAVE", 4)) {
    return AudioResourceFormat::kWave;
  }
  if (BytesEqual(bytes, size, 0, "fLaC", 4)) {
    return AudioResourceFormat::kFlac;
  }
  if (BytesEqual(bytes, size, 4, "ftyp", 4)) {
    return AudioResourceFormat::kM4a;
  }
  return {};
}

inline const wchar_t* AudioResourceExtension(AudioResourceFormat format) {
  switch (format) {
    case AudioResourceFormat::kOgg:
      return L".ogg";
    case AudioResourceFormat::kWave:
      return L".wav";
    case AudioResourceFormat::kOpus:
      return L".opus";
    case AudioResourceFormat::kFlac:
      return L".flac";
    case AudioResourceFormat::kM4a:
      return L".m4a";
    default:
      return L"";
  }
}

}  // namespace hibiki_voice_hook

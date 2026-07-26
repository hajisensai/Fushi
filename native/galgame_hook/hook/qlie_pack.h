#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::qlie {

inline bool ContainsFilePackSignature(const uint8_t* bytes, size_t size) {
  if (bytes == nullptr) return false;
  static constexpr char kSignature[] = "FilePackVer";
  constexpr size_t kSignatureBytes = sizeof(kSignature) - 1;
  if (size < kSignatureBytes) return false;
  for (size_t offset = 0; offset + kSignatureBytes <= size; ++offset) {
    if (memcmp(bytes + offset, kSignature, kSignatureBytes) == 0) {
      return true;
    }
  }
  return false;
}

}  // namespace hibiki_voice_hook::qlie

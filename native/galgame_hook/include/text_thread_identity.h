#ifndef FUSHI_TEXT_THREAD_IDENTITY_H_
#define FUSHI_TEXT_THREAD_IDENTITY_H_

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>

namespace fushi_voice_hook {

// Native engine adapters and Luna share one selected_text_thread_id field.
// Reserve bit 62 for native sources while keeping bit 63 clear so ids survive
// Flutter's signed int64 platform channel as positive values.
constexpr uint64_t kNativeTextThreadNamespaceBit = 1ull << 62;
constexpr uint64_t kTextThreadIdentityPayloadMask =
    kNativeTextThreadNamespaceBit - 1;

inline uint64_t NormalizeLunaTextThreadId(uint64_t raw) {
  const uint64_t normalized = raw & kTextThreadIdentityPayloadMask;
  return normalized == 0 ? 1 : normalized;
}

inline uint64_t TextThreadFnv1a64(uint64_t hash, const void* data,
                                  size_t size) {
  const auto* bytes = static_cast<const unsigned char*>(data);
  for (size_t i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ull;
  }
  return hash;
}

inline uint64_t NativeTextThreadIdFrom(uint64_t component_identity,
                                       const wchar_t* hook_code,
                                       const char* hook_name) {
  uint64_t hash = 1469598103934665603ull;
  hash = TextThreadFnv1a64(hash, &component_identity,
                          sizeof(component_identity));
  if (hook_code != nullptr) {
    hash = TextThreadFnv1a64(
        hash, hook_code, std::wcslen(hook_code) * sizeof(wchar_t));
  }
  if (hook_name != nullptr) {
    hash = TextThreadFnv1a64(hash, hook_name, std::strlen(hook_name));
  }
  return (hash & kTextThreadIdentityPayloadMask) |
         kNativeTextThreadNamespaceBit;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_TEXT_THREAD_IDENTITY_H_

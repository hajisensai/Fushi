#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace fushi_voice_hook::hunex_lookup {

inline constexpr size_t kInvalidOffset = std::numeric_limits<size_t>::max();

// GetAsyncKeyState returns the complete 16-bit state.  Keep an out-of-band
// observed bit so zero remains distinguishable from an unseen (zero-initialized)
// slot in the injected DLL's fixed input-state table.
inline constexpr uint32_t kInputTraceObservedBit = 1u << 16u;

inline constexpr uint32_t EncodeInputTraceState(int16_t raw) {
  return kInputTraceObservedBit | static_cast<uint16_t>(raw);
}

inline constexpr bool IsInputTraceStateChange(uint32_t previous,
                                               int16_t raw) {
  return previous != EncodeInputTraceState(raw);
}

struct GlyphTraceCursor {
  uint32_t next_glyph_ordinal = 0u;
  uint32_t next_utf16_char_index = 0u;
  uint32_t last_first_utf16_char_index = 0u;
  bool has_unpaired_first = false;
};

struct GlyphTracePosition {
  bool valid = false;
  uint32_t glyph_ordinal = 0u;
  uint32_t utf16_char_index = 0u;
};

inline GlyphTracePosition ObserveGlyphTraceCall(GlyphTraceCursor* cursor,
                                                bool direct_first,
                                                uint32_t scalar_width) {
  GlyphTracePosition position;
  if (cursor == nullptr) return position;
  if (direct_first) {
    position.utf16_char_index = cursor->next_utf16_char_index;
    cursor->last_first_utf16_char_index = position.utf16_char_index;
    cursor->next_utf16_char_index += scalar_width == 2u ? 2u : 1u;
    cursor->has_unpaired_first = true;
  } else {
    if (!cursor->has_unpaired_first) return position;
    position.utf16_char_index = cursor->last_first_utf16_char_index;
    cursor->has_unpaired_first = false;
  }
  position.glyph_ordinal = cursor->next_glyph_ordinal++;
  position.valid = true;
  return position;
}

struct MaskedPattern {
  const uint8_t* bytes = nullptr;
  const uint8_t* mask = nullptr;
  size_t size = 0;
};

struct UniquePatternMatch {
  size_t offset = kInvalidOffset;
  uint32_t count = 0;
};

inline bool MatchesMaskedPattern(const uint8_t* candidate,
                                 const MaskedPattern& pattern) {
  if (candidate == nullptr || pattern.bytes == nullptr || pattern.mask == nullptr ||
      pattern.size == 0u) {
    return false;
  }
  for (size_t index = 0; index < pattern.size; ++index) {
    if (pattern.mask[index] != 0u && candidate[index] != pattern.bytes[index]) {
      return false;
    }
  }
  return true;
}

inline UniquePatternMatch FindUniqueMaskedPattern(const uint8_t* bytes,
                                                   size_t byte_count,
                                                   const MaskedPattern& pattern) {
  UniquePatternMatch result;
  if (bytes == nullptr || pattern.size == 0u || pattern.size > byte_count) {
    return result;
  }
  for (size_t offset = 0; offset <= byte_count - pattern.size; ++offset) {
    if (!MatchesMaskedPattern(bytes + offset, pattern)) continue;
    if (result.count == 0u) result.offset = offset;
    ++result.count;
  }
  if (result.count != 1u) result.offset = kInvalidOffset;
  return result;
}

inline bool DecodeRel32CallTarget(const uint8_t* call, uintptr_t* target,
                                  uintptr_t* return_address = nullptr) {
  if (call == nullptr || target == nullptr || call[0] != 0xe8u) return false;
  int32_t displacement = 0;
  std::memcpy(&displacement, call + 1u, sizeof(displacement));
  const uintptr_t after = reinterpret_cast<uintptr_t>(call) + 5u;
  *target = static_cast<uintptr_t>(
      static_cast<intptr_t>(after) + static_cast<intptr_t>(displacement));
  if (return_address != nullptr) *return_address = after;
  return true;
}

inline bool DecodeRipIndirectCallSlot(const uint8_t* call,
                                      uintptr_t* slot_address,
                                      uintptr_t* return_address = nullptr) {
  if (call == nullptr || slot_address == nullptr || call[0] != 0xffu ||
      call[1] != 0x15u) {
    return false;
  }
  int32_t displacement = 0;
  std::memcpy(&displacement, call + 2u, sizeof(displacement));
  const uintptr_t after = reinterpret_cast<uintptr_t>(call) + 6u;
  *slot_address = static_cast<uintptr_t>(
      static_cast<intptr_t>(after) + static_cast<intptr_t>(displacement));
  if (return_address != nullptr) *return_address = after;
  return true;
}

inline uint32_t FindRel32CallReturnsToTarget(
    const uint8_t* function, size_t function_bytes, uintptr_t target,
    uintptr_t* first_return, uintptr_t* second_return) {
  if (first_return != nullptr) *first_return = 0u;
  if (second_return != nullptr) *second_return = 0u;
  if (function == nullptr || function_bytes < 5u || target == 0u) return 0u;
  uint32_t count = 0u;
  for (size_t offset = 0u; offset <= function_bytes - 5u; ++offset) {
    if (function[offset] != 0xe8u) continue;
    uintptr_t candidate = 0u;
    uintptr_t after = 0u;
    if (!DecodeRel32CallTarget(function + offset, &candidate, &after) ||
        candidate != target) {
      continue;
    }
    if (count == 0u && first_return != nullptr) *first_return = after;
    if (count == 1u && second_return != nullptr) *second_return = after;
    ++count;
  }
  return count;
}

// Structural anchors measured from the HUNEX/GGE x64 renderer/input family.
// They contain no image hash and no virtual address.  Every runtime use also
// requires a unique executable-section match plus the call-graph invariants
// checked below; zero or multiple matches fail closed.
inline constexpr uint8_t kDrawEntryBytes[] = {
    0x48, 0x8b, 0xc4, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41,
    0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8d, 0xa8, 0x28,
    0xf8, 0xff, 0xff, 0x48, 0x81, 0xec, 0xa0, 0x08, 0x00, 0x00};
inline constexpr uint8_t kDrawEntryMask[sizeof(kDrawEntryBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr uint8_t kGlyphEntryBytes[] = {
    0x40, 0x53, 0x55, 0x56, 0x57, 0x48, 0x83, 0xec, 0x58, 0x49,
    0x8b, 0x01, 0x48, 0x8b, 0xf9, 0x49, 0x8b, 0xc9, 0x49, 0x8b,
    0xf1, 0x41, 0x8b, 0xe8, 0x48, 0x8b, 0xda, 0xff, 0x50, 0x10,
    0x85, 0xc0};
inline constexpr uint8_t kGlyphEntryMask[sizeof(kGlyphEntryBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr uint8_t kDrawFirstGlyphCallBytes[] = {
    0x4d, 0x8b, 0x4e, 0x30, 0x45, 0x8b, 0xc5, 0x48, 0x8d,
    0x95, 0x00, 0x06, 0x00, 0x00, 0x48, 0x8d, 0x4d, 0xc8,
    0xe8, 0x00, 0x00, 0x00, 0x00, 0x45, 0x85, 0xe4};
inline constexpr uint8_t
    kDrawFirstGlyphCallMask[sizeof(kDrawFirstGlyphCallBytes)] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff};

inline constexpr uint8_t kDrawSecondGlyphCallBytes[] = {
    0x4d, 0x8b, 0x4e, 0x30, 0x44, 0x8b, 0x45, 0x94, 0x48, 0x8d,
    0x95, 0x70, 0x06, 0x00, 0x00, 0x48, 0x8d, 0x4d, 0x00,
    0xe8, 0x00, 0x00, 0x00, 0x00, 0x83, 0x7c, 0x24, 0x5c, 0x00};
inline constexpr uint8_t
    kDrawSecondGlyphCallMask[sizeof(kDrawSecondGlyphCallBytes)] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr uint8_t kKeyPollerEntryBytes[] = {
    0x48, 0x8b, 0xc4, 0x48, 0x89, 0x48, 0x08, 0x55, 0x53, 0x56,
    0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48,
    0x8d, 0x68, 0xa1, 0x48, 0x81, 0xec, 0xa8, 0x00, 0x00, 0x00};
inline constexpr uint8_t kKeyPollerEntryMask[sizeof(kKeyPollerEntryBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr uint8_t kInputPumpEntryBytes[] = {
    0x48, 0x8b, 0xc4, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56,
    0x41, 0x57, 0x48, 0x8d, 0x68, 0xa1, 0x48, 0x81, 0xec, 0xa0,
    0x00, 0x00, 0x00, 0x48, 0xc7, 0x45, 0x07, 0xfe, 0xff, 0xff,
    0xff};
inline constexpr uint8_t kInputPumpEntryMask[sizeof(kInputPumpEntryBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff};

inline constexpr uint8_t kPumpCallsPollerBytes[] = {
    0x49, 0x8b, 0xcc, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0x4c, 0x8b, 0xe8, 0x48, 0x89, 0x45, 0xd7};
inline constexpr uint8_t kPumpCallsPollerMask[sizeof(kPumpCallsPollerBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr uint8_t kCursorPairBytes[] = {
    0x48, 0x8d, 0x4d, 0xcf, 0xff, 0x15, 0x00, 0x00, 0x00, 0x00,
    0x48, 0x8d, 0x55, 0xcf, 0x48, 0x8b, 0x0d, 0x00, 0x00, 0x00,
    0x00, 0xff, 0x15, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x4d, 0xcf};
inline constexpr uint8_t kCursorPairMask[sizeof(kCursorPairBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
    0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff};

inline constexpr uint8_t kGenericKeyPollBytes[] = {
    0x0f, 0xb7, 0x0e, 0x49, 0x8b, 0x5d, 0x18, 0x41, 0x8b,
    0xf8, 0x41, 0xff, 0xc0, 0x44, 0x89, 0x45, 0x7f, 0x48,
    0xc1, 0xe7, 0x05, 0xff, 0x15, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xbf, 0xc8};
inline constexpr uint8_t kGenericKeyPollMask[sizeof(kGenericKeyPollBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff};

inline constexpr uint8_t kLeftButtonPollBytes[] = {
    0xb9, 0x01, 0x00, 0x00, 0x00, 0xff, 0x15, 0x00, 0x00, 0x00,
    0x00, 0xb9, 0x00, 0x80, 0x00, 0x00, 0x66, 0x85, 0xc1};
inline constexpr uint8_t kLeftButtonPollMask[sizeof(kLeftButtonPollBytes)] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

inline constexpr MaskedPattern kDrawEntryPattern = {
    kDrawEntryBytes, kDrawEntryMask, sizeof(kDrawEntryBytes)};
inline constexpr MaskedPattern kGlyphEntryPattern = {
    kGlyphEntryBytes, kGlyphEntryMask, sizeof(kGlyphEntryBytes)};
inline constexpr MaskedPattern kDrawFirstGlyphCallPattern = {
    kDrawFirstGlyphCallBytes, kDrawFirstGlyphCallMask,
    sizeof(kDrawFirstGlyphCallBytes)};
inline constexpr MaskedPattern kDrawSecondGlyphCallPattern = {
    kDrawSecondGlyphCallBytes, kDrawSecondGlyphCallMask,
    sizeof(kDrawSecondGlyphCallBytes)};
inline constexpr MaskedPattern kKeyPollerEntryPattern = {
    kKeyPollerEntryBytes, kKeyPollerEntryMask,
    sizeof(kKeyPollerEntryBytes)};
inline constexpr MaskedPattern kInputPumpEntryPattern = {
    kInputPumpEntryBytes, kInputPumpEntryMask,
    sizeof(kInputPumpEntryBytes)};
inline constexpr MaskedPattern kPumpCallsPollerPattern = {
    kPumpCallsPollerBytes, kPumpCallsPollerMask,
    sizeof(kPumpCallsPollerBytes)};
inline constexpr MaskedPattern kCursorPairPattern = {
    kCursorPairBytes, kCursorPairMask, sizeof(kCursorPairBytes)};
inline constexpr MaskedPattern kGenericKeyPollPattern = {
    kGenericKeyPollBytes, kGenericKeyPollMask, sizeof(kGenericKeyPollBytes)};
inline constexpr MaskedPattern kLeftButtonPollPattern = {
    kLeftButtonPollBytes, kLeftButtonPollMask, sizeof(kLeftButtonPollBytes)};

inline constexpr size_t kDrawScanBytes = 0x900u;
inline constexpr size_t kDrawFirstGlyphCallOffset = 18u;
inline constexpr size_t kDrawSecondGlyphCallOffset = 19u;
inline constexpr size_t kKeyPollerScanBytes = 0x200u;
inline constexpr size_t kInputPumpScanBytes = 0x400u;
inline constexpr size_t kGenericKeyPollCallOffset = 21u;
inline constexpr size_t kLeftButtonPollCallOffset = 5u;
inline constexpr size_t kPumpCallsPollerCallOffset = 3u;
inline constexpr size_t kCursorGetPositionCallOffset = 4u;
inline constexpr size_t kCursorScreenToClientCallOffset = 21u;

}  // namespace fushi_voice_hook::hunex_lookup

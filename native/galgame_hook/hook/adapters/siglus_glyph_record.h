#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {

// Calling convention and object layout travel together. Neither the title
// nor a text-hook family establishes which glyph ABI is safe to call.
enum class SiglusGlyphLayoutAbi : uint8_t {
  kEcxTenArguments = 1,
  kStackSixteenArguments = 2,
};

inline constexpr size_t SiglusGlyphRecordBytes(SiglusGlyphLayoutAbi abi) {
  switch (abi) {
    case SiglusGlyphLayoutAbi::kEcxTenArguments: return 0x48u;
    case SiglusGlyphLayoutAbi::kStackSixteenArguments: return 0x3cu;
  }
  return 0;
}

struct SiglusGlyphRecord {
  uint16_t code_unit = 0;
  int32_t extent = 0;
  int32_t x = 0;
  int32_t y = 0;
};

// Decode only a bounded, already-copied record. Active glyphs may still be
// laid out behind a menu; this function does not assert scene visibility.
inline bool DecodeSiglusGlyphRecord(SiglusGlyphLayoutAbi abi,
                                    const uint8_t* bytes, size_t size,
                                    int32_t width, int32_t height,
                                    SiglusGlyphRecord* out) {
  if (out == nullptr) return false;
  *out = {};
  const size_t required = SiglusGlyphRecordBytes(abi);
  if (required == 0 || bytes == nullptr || size < required ||
      width <= 0 || height <= 0) return false;
  const size_t position = abi == SiglusGlyphLayoutAbi::kEcxTenArguments
                              ? 0x40u : 0x34u;
  uint32_t character = 0;
  int32_t extent = 0;
  float x = 0, y = 0;
  std::memcpy(&character, bytes + 4, sizeof(character));
  std::memcpy(&extent, bytes + 8, sizeof(extent));
  std::memcpy(&x, bytes + position, sizeof(x));
  std::memcpy(&y, bytes + position + 4, sizeof(y));
  if (character == 0 || character > 0xffffu || extent <= 0 || extent > 256 ||
      !std::isfinite(x) || !std::isfinite(y)) return false;
  // Bound in floating point before any integer conversion. Finite FLT_MAX
  // is not a valid lround input on Windows (where long is 32 bits).
  const double rounded_x = std::round(static_cast<double>(x));
  const double rounded_y = std::round(static_cast<double>(y));
  if (rounded_x < 0 || rounded_x >= width ||
      rounded_y < 0 || rounded_y >= height) return false;
  *out = {static_cast<uint16_t>(character), extent,
          static_cast<int32_t>(rounded_x), static_cast<int32_t>(rounded_y)};
  return true;
}

}  // namespace fushi_voice_hook

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
  kEcxEightArguments = 3,
};

inline constexpr size_t SiglusGlyphRecordBytes(SiglusGlyphLayoutAbi abi) {
  switch (abi) {
    case SiglusGlyphLayoutAbi::kEcxTenArguments: return 0x48u;
    case SiglusGlyphLayoutAbi::kEcxEightArguments: return 0x70u;
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
  if (abi == SiglusGlyphLayoutAbi::kEcxEightArguments) {
    // This family's writer copies the transformed logical position to 40/44,
    // accumulated float XYZ scale to 58/5c/60 and angles to 64/68/6c.
    // The font extent at 8 is still untransformed. Until transformed glyph
    // bounds are proved, admit only neutral scale/rotation; never approximate
    // an animated glyph with its old unscaled square or replay its transform.
    for (size_t axis = 0; axis < 3; ++axis) {
      float scale = 0, angle = 0;
      std::memcpy(&scale, bytes + 0x58 + axis * sizeof(float), sizeof(scale));
      std::memcpy(&angle, bytes + 0x64 + axis * sizeof(float), sizeof(angle));
      if (!std::isfinite(scale) || scale != 1.0f ||
          !std::isfinite(angle) || angle != 0.0f) return false;
    }
  }
  const size_t position = abi == SiglusGlyphLayoutAbi::kStackSixteenArguments
                              ? 0x34u : 0x40u;
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

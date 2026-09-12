#pragma once
#include <cmath>
#include "cmvs_presentation_reader.h"

namespace fushi_voice_hook::cmvs_layout {

struct PixelRect { int32_t x = 0, y = 0, width = 0, height = 0; };

inline bool IsUntransformed2d(const std::array<uint8_t, 0x70>& state) {
  return Field<int32_t>(state, 0) == 0 &&
      Field<int32_t>(state, 0x18) == 0 && Field<int32_t>(state, 0x1c) == 0 &&
      Field<int32_t>(state, 0x44) == 255 &&
      Field<float>(state, 0x48) == 1.0f && Field<float>(state, 0x4c) == 1.0f &&
      Field<int32_t>(state, 0x50) == 0 && Field<int32_t>(state, 0x54) == 256;
}

// Read the actual linked sprite quads, not inferred character advances. The
// current implementation intentionally declines rotation, fade, custom scale,
// missing/hidden sprites, cropped source quads, and ambiguous child ownership.
inline Result CaptureQuads(ReadMemory read, void* context, const Snapshot& line,
                           const Presentation& presentation,
                           std::array<PixelRect, kMaxGlyphs>* output) {
  if (output == nullptr) return Result::kInvalidArgument;
  *output = {};
  if (!read || line.count == 0 || line.count > kMaxGlyphs ||
      !Fits(presentation.source, line.design_width, line.design_height) ||
      !Fits(presentation.destination, presentation.client_width,
            presentation.client_height)) return Result::kInvalidArgument;
  std::array<uint8_t, 0x1880> parent{};
  std::array<uint8_t, 0x70> parent_state{};
  if (!ReadAt(read, context, line.sprite, parent.data(), parent.size()) ||
      !ReadAt(read, context, Field<uint64_t>(parent, 0x1830),
              parent_state.data(), parent_state.size())) return Result::kUnreadable;
  if (Field<uint64_t>(parent, 0) != 0 ||
      Field<int32_t>(parent, 0x1860) != 1 ||
      Field<int32_t>(parent, 0x1864) != 1 ||
      Field<float>(parent, 0x186c) != 1.0f ||
      !IsUntransformed2d(parent_state) ||
      Field<int32_t>(parent_state, 0x20) != line.origin_x ||
      Field<int32_t>(parent_state, 0x24) != line.origin_y)
    return Result::kInvalidNode;
  std::array<PixelRect, kMaxGlyphs> candidate{};
  std::array<uint64_t, kMaxGlyphs> seen{};
  std::array<bool, kMaxGlyphs> matched{};
  uint64_t item = Field<uint64_t>(parent, 0x1808);
  size_t count = 0;
  while (item) {
    if (count == line.count) return Result::kTooManyGlyphs;
    for (size_t i = 0; i < count; ++i) if (seen[i] == item) return Result::kCycle;
    seen[count++] = item;
    std::array<uint8_t, 0x18> link{};
    std::array<uint8_t, 0x1880> sprite{};
    std::array<uint8_t, 0x70> state{};
    if (!ReadAt(read, context, item, link.data(), link.size()) ||
        !ReadAt(read, context, Field<uint64_t>(link, 0x10), sprite.data(), sprite.size()) ||
        !ReadAt(read, context, Field<uint64_t>(sprite, 0x1830), state.data(), state.size()))
      return Result::kUnreadable;
    const int32_t id = Field<int32_t>(link, 8);
    size_t index = 0;
    while (index < line.count && line.glyphs[index].sprite_id != id) ++index;
    if (index == line.count || matched[index]) return Result::kInvalidNode;
    matched[index] = true;
    if (Field<uint64_t>(sprite, 0) != line.sprite ||
        Field<int32_t>(sprite, 0x1860) != 1 ||
        Field<int32_t>(sprite, 0x1864) != 1 ||
        (Field<uint32_t>(sprite, 0x1868) & 1) == 0 ||
        (Field<float>(sprite, 0x186c) != 0.0f &&
         Field<float>(sprite, 0x186c) != 1.0f) || !IsUntransformed2d(state))
      return Result::kInvalidNode;
    const int64_t left = static_cast<int64_t>(line.origin_x) + Field<int32_t>(state, 0x20);
    const int64_t top = static_cast<int64_t>(line.origin_y) + Field<int32_t>(state, 0x24);
    const int32_t width = Field<int32_t>(state, 0x10);
    const int32_t height = Field<int32_t>(state, 0x14);
    const auto& source = presentation.source;
    if (width <= 0 || height <= 0 || left < source.x || top < source.y ||
        left + width > static_cast<int64_t>(source.x) + source.width ||
        top + height > static_cast<int64_t>(source.y) + source.height)
      return Result::kInvalidNode;
    const auto& dest = presentation.destination;
    const double sx = static_cast<double>(dest.width) / source.width;
    const double sy = static_cast<double>(dest.height) / source.height;
    auto& rectangle = candidate[index];
    rectangle.x = static_cast<int32_t>(std::floor(dest.x + (left - source.x) * sx));
    rectangle.y = static_cast<int32_t>(std::floor(dest.y + (top - source.y) * sy));
    rectangle.width = static_cast<int32_t>(std::ceil(dest.x + (left + width - source.x) * sx)) - rectangle.x;
    rectangle.height = static_cast<int32_t>(std::ceil(dest.y + (top + height - source.y) * sy)) - rectangle.y;
    item = Field<uint64_t>(link, 0);
  }
  if (count != line.count) return Result::kInvalidNode;
  *output = candidate;
  return Result::kCaptured;
}
}  // namespace fushi_voice_hook::cmvs_layout

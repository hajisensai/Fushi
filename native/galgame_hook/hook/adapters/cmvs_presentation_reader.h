#pragma once
#include "cmvs_dialogue_layout_reader.h"

namespace fushi_voice_hook::cmvs_layout {

struct PresentationRect { int32_t x = 0, y = 0, width = 0, height = 0; };
struct Presentation {
  PresentationRect source{}, destination{};
  int32_t client_width = 0, client_height = 0;
};

inline bool Fits(const PresentationRect& rect, int32_t width, int32_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         static_cast<int64_t>(rect.x) + rect.width <= width &&
         static_cast<int64_t>(rect.y) + rect.height <= height;
}

// Exact final StretchRect contract (0x280f0), not aspect-ratio inference.
// In window mode the post object is destroyed, while surface+0x50 retains the
// old fullscreen rects. Its absence must select the verified identity path.
// client dimensions must come from a consistent, physical-pixel HWND context.
inline Result CapturePresentation(ReadMemory read, void* context,
                                  uint64_t module_base, uint64_t root,
                                  int32_t client_width, int32_t client_height,
                                  Presentation* output) {
  if (output == nullptr) return Result::kInvalidArgument;
  *output = {};
  if (read == nullptr || client_width <= 0 || client_height <= 0 ||
      client_width > 32768 || client_height > 32768 ||
      root > (std::numeric_limits<uint64_t>::max)() - 0x7b8 ||
      module_base > (std::numeric_limits<uint64_t>::max)() - 0xd6f78)
    return Result::kInvalidArgument;
  uint64_t vtable = 0, renderer = 0;
  if (!ReadAt(read, context, root, &vtable, 8) ||
      !ReadAt(read, context, root + 0x7b0, &renderer, 8))
    return Result::kUnreadable;
  if (vtable != module_base + kRootVtableRva) return Result::kWrongRoot;
  std::array<uint8_t, 16> renderer_bytes{}, renderer_after{};
  if (!ReadAt(read, context, renderer, renderer_bytes.data(), 16))
    return Result::kUnreadable;
  const uint64_t manager = Field<uint64_t>(renderer_bytes, 0);
  const uint64_t surface = Field<uint64_t>(renderer_bytes, 8);
  if (manager > (std::numeric_limits<uint64_t>::max)() - 0x128)
    return Result::kUnreadable;
  uint64_t post = 0;
  std::array<uint8_t, 0xd0> state{}, state_after{};
  if (!ReadAt(read, context, manager + 0x120, &post, 8) ||
      !ReadAt(read, context, surface, state.data(), state.size()))
    return Result::kUnreadable;
  const int32_t logical_width = Field<int32_t>(state, 0x18);
  const int32_t logical_height = Field<int32_t>(state, 0x1c);
  Presentation result{};
  result.client_width = client_width;
  result.client_height = client_height;
  std::array<uint8_t, 12> post_state{}, post_after{};
  if (post == 0) {
    if (Field<int32_t>(state, 0x98) != 0 || Field<int32_t>(state, 0xb8) != 0 ||
        logical_width != client_width || logical_height != client_height)
      return Result::kInvalidNode;
    result.source = result.destination = {0, 0, client_width, client_height};
  } else {
    if (!ReadAt(read, context, post, post_state.data(), post_state.size()))
      return Result::kUnreadable;
    if (Field<uint64_t>(post_state, 0) != module_base + 0xd6f78 ||
        Field<int32_t>(post_state, 8) != 1 ||
        Field<int32_t>(state, 0xb8) != 1 ||
        Field<int32_t>(state, 0xc8) != client_width ||
        Field<int32_t>(state, 0xcc) != client_height)
      return Result::kInvalidNode;
    result.source = {Field<int32_t>(state, 0x50), Field<int32_t>(state, 0x54),
                     Field<int32_t>(state, 0x58), Field<int32_t>(state, 0x5c)};
    result.destination = {Field<int32_t>(state, 0x60), Field<int32_t>(state, 0x64),
                          Field<int32_t>(state, 0x68), Field<int32_t>(state, 0x6c)};
    if (!Fits(result.source, logical_width, logical_height) ||
        !Fits(result.destination, client_width, client_height))
      return Result::kInvalidNode;
  }
  uint64_t renderer_now = 0, post_now = 0;
  if (!ReadAt(read, context, root + 0x7b0, &renderer_now, 8) ||
      !ReadAt(read, context, renderer, renderer_after.data(), 16) ||
      !ReadAt(read, context, manager + 0x120, &post_now, 8) ||
      !ReadAt(read, context, surface, state_after.data(), state_after.size()) ||
      (post && !ReadAt(read, context, post, post_after.data(), post_after.size())))
    return Result::kUnreadable;
  if (renderer_now != renderer || post_now != post ||
      renderer_bytes != renderer_after || state != state_after ||
      (post && post_state != post_after)) return Result::kChanged;
  *output = result;
  return Result::kCaptured;
}

}  // namespace fushi_voice_hook::cmvs_layout

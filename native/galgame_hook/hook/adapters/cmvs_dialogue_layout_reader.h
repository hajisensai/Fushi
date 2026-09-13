#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace fushi_voice_hook::cmvs_layout {

// ChronoClock trial v2 x64 only. This reader does not discover a process, choose
// a text thread, project to client pixels, or admit an IPC geometry provider.
// Its caller must verify the executable hash before supplying the root address.
inline constexpr char kExecutableSha256[] =
    "AA89205A61C7078A167F9E6668EEA2E4328BDD5C9CBCDD6F45B238CF475ACEA2";
inline constexpr uint64_t kRootVtableRva = 0xd53e8;
inline constexpr size_t kSlotCount = 12;
inline constexpr size_t kMaxGlyphs = 512;

using ReadMemory = bool (*)(void*, uint64_t, void*, size_t);

struct Glyph {
  uint64_t node = 0;
  int32_t sprite_id = -1;
  uint16_t cp932 = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t font_size = 0;
};

struct Snapshot {
  uint64_t owner = 0;
  uint64_t sprite = 0;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  int32_t design_width = 0;
  int32_t design_height = 0;
  size_t count = 0;
  std::array<Glyph, kMaxGlyphs> glyphs{};
};

enum class Result {
  kCaptured, kInvalidArgument, kUnreadable, kWrongRoot, kEmpty,
  kInvalidNode, kCycle, kTooManyGlyphs, kChanged,
};

template <typename T, size_t N>
inline T Field(const std::array<uint8_t, N>& data, size_t offset) {
  T value{};
  if (offset <= N && sizeof(T) <= N - offset)
    std::memcpy(&value, data.data() + offset, sizeof(T));
  return value;
}

inline bool IsCp932Code(uint16_t code) {
  if (code < 0x100)
    return (code >= 0x20 && code <= 0x7e) ||
           (code >= 0xa1 && code <= 0xdf);
  const auto lead = static_cast<uint8_t>(code >> 8);
  const auto trail = static_cast<uint8_t>(code);
  return ((lead >= 0x81 && lead <= 0x9f) ||
          (lead >= 0xe0 && lead <= 0xfc)) &&
         ((trail >= 0x40 && trail <= 0x7e) ||
          (trail >= 0x80 && trail <= 0xfc));
}

inline bool ReadAt(ReadMemory read, void* context, uint64_t address,
                   void* output, size_t size) {
  return address != 0 && size <= (std::numeric_limits<uint64_t>::max)() - address &&
         read(context, address, output, size);
}

// Worker-side bounded read of the *second* CMVS layout family (0x59740 /
// 0x58090), observed on real dialogue. root+0x10e8 belongs to a different,
// empty-on-dialogue family and must not be used as a fallback.
// Double reads reject observed changes; they are not an engine frame lock.
inline Result Capture(ReadMemory read, void* context, uint64_t module_base,
                      uint64_t root, size_t slot, Snapshot* output) {
  if (output == nullptr) return Result::kInvalidArgument;
  *output = {};
  if (read == nullptr || slot >= kSlotCount ||
      module_base > (std::numeric_limits<uint64_t>::max)() - kRootVtableRva ||
      root > (std::numeric_limits<uint64_t>::max)() - 0x1080)
    return Result::kInvalidArgument;
  uint64_t vtable = 0;
  uint64_t owner = 0;
  const uint64_t owner_slot = root + 0x1020 + slot * 8;
  if (!ReadAt(read, context, root, &vtable, sizeof(vtable)) ||
      !ReadAt(read, context, owner_slot, &owner, sizeof(owner)))
    return Result::kUnreadable;
  if (vtable != module_base + kRootVtableRva) return Result::kWrongRoot;
  if (owner == 0) return Result::kEmpty;
  std::array<uint8_t, 0x180> before{}, after{};
  if (!ReadAt(read, context, owner, before.data(), before.size()))
    return Result::kUnreadable;
  Snapshot candidate{};
  candidate.owner = owner;
  candidate.sprite = Field<uint64_t>(before, 0);
  candidate.origin_x = Field<int32_t>(before, 8);
  candidate.origin_y = Field<int32_t>(before, 0xc);
  candidate.design_width = Field<int32_t>(before, 0x158);
  candidate.design_height = Field<int32_t>(before, 0x15c);
  uint64_t node = Field<uint64_t>(before, 0xa8);
  if (node == 0) return Result::kEmpty;
  if (!candidate.sprite || candidate.design_width <= 0 ||
      candidate.design_height <= 0) return Result::kInvalidNode;
  std::array<std::array<uint8_t, 0x34>, kMaxGlyphs> raw{};
  while (node != 0) {
    for (size_t i = 0; i < candidate.count; ++i)
      if (candidate.glyphs[i].node == node) return Result::kCycle;
    if (candidate.count == kMaxGlyphs) return Result::kTooManyGlyphs;
    auto& bytes = raw[candidate.count];
    if (!ReadAt(read, context, node, bytes.data(), bytes.size()))
      return Result::kUnreadable;
    auto& glyph = candidate.glyphs[candidate.count];
    glyph.node = node;
    glyph.sprite_id = Field<int32_t>(bytes, 8);
    glyph.cp932 = Field<uint16_t>(bytes, 0xe);
    glyph.x = Field<int32_t>(bytes, 0x18);
    glyph.y = Field<int32_t>(bytes, 0x1c);
    glyph.font_size = Field<int32_t>(bytes, 0x20);
    if (Field<uint16_t>(bytes, 0xc) != 0x28 || glyph.sprite_id < 0 ||
        !IsCp932Code(glyph.cp932) || glyph.font_size <= 0 ||
        glyph.font_size > 4096) return Result::kInvalidNode;
    for (size_t i = 0; i < candidate.count; ++i)
      if (candidate.glyphs[i].sprite_id == glyph.sprite_id)
        return Result::kInvalidNode;
    ++candidate.count;
    node = Field<uint64_t>(bytes, 0);
  }
  for (size_t i = 0; i < candidate.count; ++i) {
    std::array<uint8_t, 0x34> verify{};
    if (!ReadAt(read, context, candidate.glyphs[i].node,
                verify.data(), verify.size())) return Result::kUnreadable;
    if (verify != raw[i]) return Result::kChanged;
  }
  uint64_t current_owner = 0;
  if (!ReadAt(read, context, owner, after.data(), after.size()) ||
      !ReadAt(read, context, owner_slot, &current_owner, sizeof(current_owner)))
    return Result::kUnreadable;
  if (current_owner != owner || before != after) return Result::kChanged;
  *output = candidate;
  return Result::kCaptured;
}

}  // namespace fushi_voice_hook::cmvs_layout

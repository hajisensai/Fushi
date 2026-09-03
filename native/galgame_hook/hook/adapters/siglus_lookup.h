#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "exact_lookup_signature.h"

namespace fushi_voice_hook {

inline constexpr uint16_t kSiglusLookupPeMachineI386 = 0x014cu;
inline constexpr size_t kSiglusLookupCaptureCapacity = 512u;
inline constexpr size_t kSiglusLookupMaxGlyphs = 256u;
inline constexpr uint16_t kSiglusLookupNoGlyph =
    std::numeric_limits<uint16_t>::max();

// Keep the text source and its ABI in the exact executable profile. A native
// TextUnion callback and a Luna Scenario lane have different ownership and
// caller-validation contracts even when the surrounding renderer is Siglus.
enum class SiglusLookupTextFeed : uint8_t {
  kNativeEcxTextUnion = 1,
  kLunaScenarioLane = 2,
};

// Each profile admits one measured executable only. The RVAs describe the
// Siglus per-visible-glyph layout boundary and the return address immediately
// after the engine's GetKeyState(VK_LBUTTON) call. They are unrelated to the
// SGRE renderer and DirectInput ABI.
struct SiglusLookupProfile {
  std::array<uint8_t, 32> executable_sha256 = {};
  // The shipped launcher virtualizes self-reads back to its same-size .org
  // image. Keep that exact runtime view in the same low-degree profile rather
  // than weakening admission to an engine-family or signature-only match.
  std::array<uint8_t, 32> runtime_view_sha256 = {};
  uint16_t pe_machine = 0;
  uint8_t pointer_bits = 0;
  SiglusLookupTextFeed text_feed = SiglusLookupTextFeed::kNativeEcxTextUnion;
  uintptr_t glyph_layout_rva = 0;
  uintptr_t dialogue_glyph_return_rva = 0;
  uintptr_t exact_text_rva = 0;
  uintptr_t exact_text_return_rva = 0;
  uintptr_t get_key_state_return_rva = 0;
  uintptr_t input_message_rva = 0;
  uintptr_t main_input_message_return_rva = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
};

inline constexpr SiglusLookupProfile kAnemoiSiglusLookupProfile = {
    {0xd9, 0x4c, 0x94, 0xeb, 0x13, 0x2f, 0xb1, 0xfc, 0xd6, 0xc2, 0x0f,
     0x35, 0xdd, 0x16, 0x55, 0x2e, 0xd1, 0x30, 0x17, 0x0b, 0x7a, 0x83,
     0xde, 0x07, 0xb2, 0x75, 0xad, 0x26, 0xc9, 0x7d, 0x05, 0x9d},
    {0x28, 0xfd, 0x4b, 0x91, 0x08, 0x46, 0xca, 0x5e, 0x2e, 0xca, 0x92,
     0x4c, 0xa3, 0xfc, 0xfc, 0x1e, 0x9e, 0x69, 0xc1, 0xb1, 0xad, 0x71,
     0x81, 0xd2, 0xe0, 0xc6, 0x6b, 0x85, 0xcc, 0x59, 0xa4, 0x86},
    kSiglusLookupPeMachineI386,
    32u,
    SiglusLookupTextFeed::kNativeEcxTextUnion,
    0x1EC1C0u,
    0x1EDC5Cu,
    0x25C880u,
    0x25A650u,
    0x2C16C3u,
    0x2C1AC0u,
    0x2B393Fu,
    1920,
    1080,
};

inline constexpr SiglusLookupProfile
    kSummerPocketsReflectionBlueSiglusLookupProfile = {
        {0x19, 0x0d, 0xf9, 0xa7, 0x29, 0x29, 0xbd, 0x6b, 0x63, 0x27, 0xe7,
         0x73, 0x95, 0x2b, 0x5c, 0x50, 0x7c, 0x69, 0x05, 0x2b, 0xc6, 0xd3,
         0xff, 0x16, 0xa4, 0x86, 0x8b, 0xd1, 0xff, 0x17, 0x91, 0xfd},
        {0x19, 0x0d, 0xf9, 0xa7, 0x29, 0x29, 0xbd, 0x6b, 0x63, 0x27, 0xe7,
         0x73, 0x95, 0x2b, 0x5c, 0x50, 0x7c, 0x69, 0x05, 0x2b, 0xc6, 0xd3,
         0xff, 0x16, 0xa4, 0x86, 0x8b, 0xd1, 0xff, 0x17, 0x91, 0xfd},
        kSiglusLookupPeMachineI386,
        32u,
        SiglusLookupTextFeed::kLunaScenarioLane,
        0x1DC690u,
        0x1DE25Cu,
        0x1DECF0u,
        0u,
        0x2B3D63u,
        0x2B3EE0u,
        0x2A8247u,
        1920,
        1080,
};

inline constexpr std::array<const SiglusLookupProfile *, 2>
    kSiglusLookupProfiles = {
        &kAnemoiSiglusLookupProfile,
        &kSummerPocketsReflectionBlueSiglusLookupProfile,
};

inline bool MatchesSiglusLookupDigest(const SiglusLookupProfile &profile,
                                      const uint8_t *observed_sha256,
                                      size_t digest_bytes) {
  if (observed_sha256 == nullptr ||
      digest_bytes != profile.executable_sha256.size()) {
    return false;
  }
  uint8_t executable_difference = 0;
  uint8_t runtime_view_difference = 0;
  for (size_t index = 0; index < digest_bytes; ++index) {
    executable_difference |= static_cast<uint8_t>(
        observed_sha256[index] ^ profile.executable_sha256[index]);
    runtime_view_difference |= static_cast<uint8_t>(
        observed_sha256[index] ^ profile.runtime_view_sha256[index]);
  }
  return executable_difference == 0 || runtime_view_difference == 0;
}

inline bool MatchesSiglusLookupProfile(const SiglusLookupProfile &profile,
                                       const uint8_t *executable_sha256,
                                       size_t digest_bytes,
                                       uint16_t pe_machine) {
  const bool valid_text_feed =
      (profile.text_feed == SiglusLookupTextFeed::kNativeEcxTextUnion &&
       profile.exact_text_rva != 0 && profile.exact_text_return_rva != 0) ||
      (profile.text_feed == SiglusLookupTextFeed::kLunaScenarioLane &&
       profile.exact_text_rva != 0);
  if (executable_sha256 == nullptr ||
      digest_bytes != profile.executable_sha256.size() ||
      pe_machine != profile.pe_machine || profile.pointer_bits != 32u ||
      profile.glyph_layout_rva == 0 || profile.dialogue_glyph_return_rva == 0 ||
      !valid_text_feed || profile.get_key_state_return_rva == 0 ||
      profile.input_message_rva == 0 ||
      profile.main_input_message_return_rva == 0 ||
      profile.viewport_width <= 0 || profile.viewport_height <= 0) {
    return false;
  }
  return MatchesSiglusLookupDigest(profile, executable_sha256, digest_bytes);
}

// Exact registry lookup deliberately rejects ambiguity. This preserves the
// fail-closed boundary if a future profile accidentally reuses another
// profile's executable or runtime-view digest.
inline const SiglusLookupProfile *
FindSiglusLookupProfile(const uint8_t *executable_sha256, size_t digest_bytes,
                        uint16_t pe_machine) {
  const SiglusLookupProfile *match = nullptr;
  for (const SiglusLookupProfile *candidate : kSiglusLookupProfiles) {
    if (candidate == nullptr ||
        !MatchesSiglusLookupProfile(*candidate, executable_sha256,
                                    digest_bytes, pe_machine)) {
      continue;
    }
    if (match != nullptr)
      return nullptr;
    match = candidate;
  }
  return match;
}

namespace siglus_exact {

// Both admitted builds share this hydrated glyph-layout prologue. The SEH
// handler and /GS cookie operands are loader-dependent, and the local stack
// size is 0xDC or 0xEC; only those measured differences are wildcarded. A
// runtime gate scans every executable section and requires the sole match to
// equal the exact profile RVA.
inline constexpr uint8_t kGlyphLayoutEntryBytes[] = {
    0x55, 0x8b, 0xec, 0x6a, 0xff, 0x68, 0x00, 0x00, 0x00, 0x00, 0x64,
    0xa1, 0x00, 0x00, 0x00, 0x00, 0x50, 0x81, 0xec, 0x00, 0x00, 0x00,
    0x00, 0x53, 0x56, 0x57, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x33, 0xc5,
    0x50, 0x8d, 0x45, 0xf4, 0x64, 0xa3, 0x00, 0x00, 0x00, 0x00, 0x8b,
    0xf1, 0x80, 0x7e, 0x20, 0x00, 0x75, 0x16,
};
inline constexpr auto kGlyphLayoutEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kGlyphLayoutEntryBytes)>(
        6u, 10u, 19u, 20u, 27u, 31u);
inline constexpr exact_lookup::MaskedPattern kGlyphLayoutEntryPattern = {
    kGlyphLayoutEntryBytes, kGlyphLayoutEntryMask.data(),
    sizeof(kGlyphLayoutEntryBytes)};
inline constexpr size_t kGlyphLayoutStackByteOffset = 19u;

inline constexpr uint8_t kAnemoiInputMessageEntryBytes[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x51, 0x8b, 0x45,
    0x08, 0x56, 0x8b, 0x35, 0x00, 0x00, 0x00, 0x00, 0x3d,
    0x01, 0x02, 0x00, 0x00, 0x77, 0x5c, 0x74, 0x45, 0x05,
    0x00, 0xff, 0xff, 0xff, 0x83, 0xf8, 0x05,
};
inline constexpr auto kAnemoiInputMessageEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kAnemoiInputMessageEntryBytes)>(
        13u, 17u);
inline constexpr exact_lookup::MaskedPattern kAnemoiInputMessageEntryPattern = {
    kAnemoiInputMessageEntryBytes, kAnemoiInputMessageEntryMask.data(),
    sizeof(kAnemoiInputMessageEntryBytes)};

inline constexpr uint8_t kSprbInputMessageEntryBytes[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x8b, 0x45, 0x08,
    0x83, 0xec, 0x08, 0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00,
    0x3d, 0x01, 0x02, 0x00, 0x00, 0x77, 0x59, 0x74, 0x43,
    0x05, 0x00, 0xff, 0xff, 0xff, 0x83, 0xf8, 0x05,
};
inline constexpr auto kSprbInputMessageEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kSprbInputMessageEntryBytes)>(
        14u, 18u);
inline constexpr exact_lookup::MaskedPattern kSprbInputMessageEntryPattern = {
    kSprbInputMessageEntryBytes, kSprbInputMessageEntryMask.data(),
    sizeof(kSprbInputMessageEntryBytes)};

inline const exact_lookup::MaskedPattern* InputMessagePatternForProfile(
    const SiglusLookupProfile& profile) {
  if (profile.input_message_rva ==
          kAnemoiSiglusLookupProfile.input_message_rva &&
      profile.text_feed == SiglusLookupTextFeed::kNativeEcxTextUnion) {
    return &kAnemoiInputMessageEntryPattern;
  }
  if (profile.input_message_rva ==
          kSummerPocketsReflectionBlueSiglusLookupProfile.input_message_rva &&
      profile.text_feed == SiglusLookupTextFeed::kLunaScenarioLane) {
    return &kSprbInputMessageEntryPattern;
  }
  return nullptr;
}

inline bool IsMeasuredGlyphStackSize(const uint8_t* entry) {
  return entry != nullptr &&
         (entry[kGlyphLayoutStackByteOffset] == 0xdcu ||
          entry[kGlyphLayoutStackByteOffset] == 0xecu);
}

}  // namespace siglus_exact

struct SiglusLookupGlyphCapture {
  char16_t code_unit = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t extent = 0;
};

// The injected callback may only append events after the exact executable and
// caller have already been admitted by the runtime profile. This type is only
// the fixed-capacity hand-off: it intentionally performs no caller guessing,
// allocation, IO, normalization, or engine-family detection.
struct SiglusLookupGlyphCaptureBuffer {
  std::array<SiglusLookupGlyphCapture, kSiglusLookupCaptureCapacity> entries =
      {};
  size_t first = 0;
  size_t count = 0;
};

inline void
ClearSiglusLookupGlyphCapture(SiglusLookupGlyphCaptureBuffer *buffer) {
  if (buffer == nullptr)
    return;
  buffer->first = 0;
  buffer->count = 0;
}

inline bool
AppendSiglusLookupGlyphCapture(char16_t code_unit, int32_t x, int32_t y,
                               int32_t extent,
                               SiglusLookupGlyphCaptureBuffer *buffer) {
  if (buffer == nullptr || code_unit == u'\0' || code_unit == u'\r' ||
      code_unit == u'\n' || extent <= 0) {
    return false;
  }
  size_t destination = 0;
  if (buffer->count < buffer->entries.size()) {
    destination = (buffer->first + buffer->count) % buffer->entries.size();
    ++buffer->count;
  } else {
    destination = buffer->first;
    buffer->first = (buffer->first + 1u) % buffer->entries.size();
  }
  buffer->entries[destination] = {code_unit, x, y, extent};
  return true;
}

inline const SiglusLookupGlyphCapture *
SiglusLookupGlyphCaptureAt(const SiglusLookupGlyphCaptureBuffer &buffer,
                           size_t logical_index) {
  if (logical_index >= buffer.count)
    return nullptr;
  return &buffer
              .entries[(buffer.first + logical_index) % buffer.entries.size()];
}

struct SiglusLookupRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct SiglusLookupGlyphRect {
  char16_t code_unit = 0;
  // Index into the original UTF-16 line, including any preceding CR/LF code
  // units that do not themselves have renderer glyphs.
  uint16_t char_index = 0;
  uint16_t visual_line = 0;
  SiglusLookupRect rect = {};
};

struct SiglusLookupGeometry {
  std::array<SiglusLookupGlyphRect, kSiglusLookupMaxGlyphs> glyphs = {};
  size_t glyph_count = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
};

struct SiglusLookupClientSnapshot {
  uintptr_t game_window = 0;
  int32_t screen_x = 0;
  int32_t screen_y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// Glyph callbacks are transport events and can replay an unchanged layout on
// every render. This counter identifies the combined UTF-16 sentence and
// derived geometry, so identical complete redraws retain one generation.
inline uint64_t NextSiglusLookupLogicalGeneration(uint64_t generation) {
  ++generation;
  return generation == 0 ? 1 : generation;
}

inline bool SameSiglusLookupGeometry(const SiglusLookupGeometry &lhs,
                                     const SiglusLookupGeometry &rhs) {
  if (lhs.glyph_count != rhs.glyph_count ||
      lhs.viewport_width != rhs.viewport_width ||
      lhs.viewport_height != rhs.viewport_height) {
    return false;
  }
  for (size_t index = 0; index < lhs.glyph_count; ++index) {
    const auto &left = lhs.glyphs[index];
    const auto &right = rhs.glyphs[index];
    if (left.code_unit != right.code_unit ||
        left.char_index != right.char_index ||
        left.visual_line != right.visual_line ||
        left.rect.x != right.rect.x || left.rect.y != right.rect.y ||
        left.rect.width != right.rect.width ||
        left.rect.height != right.rect.height) {
      return false;
    }
  }
  return true;
}

inline bool MatchesSiglusLookupGenerationAndClient(
    uint64_t payload_generation,
    const SiglusLookupClientSnapshot &payload_client,
    uint64_t active_generation,
    const SiglusLookupClientSnapshot &active_client) {
  return payload_generation != 0 && payload_generation == active_generation &&
         payload_client.game_window != 0 &&
         payload_client.game_window == active_client.game_window &&
         payload_client.screen_x == active_client.screen_x &&
         payload_client.screen_y == active_client.screen_y &&
         payload_client.width > 0 && payload_client.height > 0 &&
         payload_client.width == active_client.width &&
         payload_client.height == active_client.height;
}

inline bool IsSaneSiglusLookupAnchor(const SiglusLookupGlyphCapture &glyph,
                                     const SiglusLookupProfile &profile) {
  return glyph.code_unit != u'\0' && glyph.code_unit != u'\r' &&
         glyph.code_unit != u'\n' && glyph.x >= 0 && glyph.y >= 0 &&
         glyph.x < profile.viewport_width &&
         glyph.y < profile.viewport_height && glyph.extent > 0 &&
         glyph.extent <= 256;
}

template <size_t Capacity>
inline int32_t MedianSiglusLookupMetric(std::array<int32_t, Capacity> values,
                                        size_t count) {
  if (count == 0 || count > values.size())
    return 0;
  std::sort(values.begin(), values.begin() + count);
  const size_t middle = count / 2u;
  if ((count & 1u) != 0u)
    return values[middle];
  return static_cast<int32_t>(
      (static_cast<int64_t>(values[middle - 1u]) + values[middle]) / 2);
}

inline bool
IsNextSiglusLookupVisualLine(const SiglusLookupGlyphCapture &previous,
                             const SiglusLookupGlyphCapture &current,
                             bool explicit_line_break) {
  if (explicit_line_break || current.x < previous.x)
    return true;
  const int64_t y_delta = static_cast<int64_t>(current.y) - previous.y;
  return y_delta < -2 || y_delta > 2;
}

// Find the newest exact contiguous capture of the latest UTF-16 line, then
// infer non-overlapping hit cells directly from Siglus' virtual-layout
// anchors. CR/LF units are exact row boundaries but have no glyph. Automatic
// wrapping is detected from an x reset or a changed y anchor. Width comes from
// the next anchor on the same visual row (so half-width and full-width cells
// remain distinct); row-final cells use the engine's per-glyph extent. Height
// uses that same measured extent, bounded by the next row spacing. No SGRE
// dialogue origin is applied; the returned rectangles remain in Siglus'
// 1920x1080 design domain and must be scaled to the current client below.
inline bool
BuildSiglusLookupGeometry(const SiglusLookupProfile &profile,
                          const SiglusLookupGlyphCaptureBuffer &captures,
                          const char16_t *latest_line, size_t latest_line_units,
                          SiglusLookupGeometry *geometry,
                          size_t *matched_end = nullptr) {
  if (geometry == nullptr)
    return false;
  *geometry = {};
  if (matched_end != nullptr)
    *matched_end = 0;
  geometry->viewport_width = profile.viewport_width;
  geometry->viewport_height = profile.viewport_height;
  if (latest_line == nullptr || latest_line_units == 0 ||
      latest_line_units > std::numeric_limits<uint16_t>::max() ||
      profile.pointer_bits != 32u || profile.viewport_width <= 0 ||
      profile.viewport_height <= 0) {
    return false;
  }

  std::array<char16_t, kSiglusLookupMaxGlyphs> expected = {};
  std::array<uint16_t, kSiglusLookupMaxGlyphs> char_indices = {};
  std::array<uint16_t, kSiglusLookupMaxGlyphs> explicit_rows = {};
  size_t expected_count = 0;
  uint16_t explicit_row = 0;
  for (size_t index = 0; index < latest_line_units; ++index) {
    const char16_t code_unit = latest_line[index];
    if (code_unit == u'\r' || code_unit == u'\n') {
      // Treat CRLF as one explicit row boundary.
      if (code_unit == u'\r' && index + 1u < latest_line_units &&
          latest_line[index + 1u] == u'\n') {
        ++index;
      }
      if (explicit_row == std::numeric_limits<uint16_t>::max())
        return false;
      ++explicit_row;
      continue;
    }
    if (code_unit == u'\0' || expected_count == expected.size())
      return false;
    expected[expected_count] = code_unit;
    char_indices[expected_count] = static_cast<uint16_t>(index);
    explicit_rows[expected_count] = explicit_row;
    ++expected_count;
  }
  if (expected_count == 0 || expected_count > captures.count)
    return false;

  size_t matched_start = captures.count;
  size_t candidate = captures.count - expected_count + 1u;
  while (candidate != 0) {
    --candidate;
    bool matches = true;
    for (size_t index = 0; index < expected_count; ++index) {
      const auto *captured =
          SiglusLookupGlyphCaptureAt(captures, candidate + index);
      if (captured == nullptr || captured->code_unit != expected[index] ||
          !IsSaneSiglusLookupAnchor(*captured, profile)) {
        matches = false;
        break;
      }
    }
    if (matches) {
      matched_start = candidate;
      break;
    }
  }
  if (matched_start == captures.count)
    return false;

  std::array<const SiglusLookupGlyphCapture *, kSiglusLookupMaxGlyphs> matched =
      {};
  std::array<uint16_t, kSiglusLookupMaxGlyphs> visual_rows = {};
  size_t row_count = 1;
  matched[0] = SiglusLookupGlyphCaptureAt(captures, matched_start);
  for (size_t index = 1; index < expected_count; ++index) {
    matched[index] =
        SiglusLookupGlyphCaptureAt(captures, matched_start + index);
    const bool explicit_line_break =
        explicit_rows[index] != explicit_rows[index - 1u];
    if (IsNextSiglusLookupVisualLine(*matched[index - 1u], *matched[index],
                                     explicit_line_break)) {
      if (row_count == kSiglusLookupMaxGlyphs)
        return false;
      ++row_count;
    }
    visual_rows[index] = static_cast<uint16_t>(row_count - 1u);
  }

  std::array<int32_t, kSiglusLookupMaxGlyphs> all_advances = {};
  size_t all_advance_count = 0;
  std::array<int32_t, kSiglusLookupMaxGlyphs> row_median_advance = {};
  for (size_t row = 0; row < row_count; ++row) {
    std::array<int32_t, kSiglusLookupMaxGlyphs> row_advances = {};
    size_t row_advance_count = 0;
    for (size_t index = 0; index + 1u < expected_count; ++index) {
      if (visual_rows[index] != row || visual_rows[index + 1u] != row) {
        continue;
      }
      const int64_t advance =
          static_cast<int64_t>(matched[index + 1u]->x) - matched[index]->x;
      if (advance <= 0 || advance > profile.viewport_width)
        continue;
      row_advances[row_advance_count++] = static_cast<int32_t>(advance);
      all_advances[all_advance_count++] = static_cast<int32_t>(advance);
    }
    row_median_advance[row] =
        MedianSiglusLookupMetric(row_advances, row_advance_count);
  }
  const int32_t median_advance =
      MedianSiglusLookupMetric(all_advances, all_advance_count);

  std::array<int32_t, kSiglusLookupMaxGlyphs> extents = {};
  for (size_t index = 0; index < expected_count; ++index) {
    extents[index] = matched[index]->extent;
  }
  const int32_t median_extent =
      MedianSiglusLookupMetric(extents, expected_count);

  std::array<int32_t, kSiglusLookupMaxGlyphs> row_first_y = {};
  std::array<bool, kSiglusLookupMaxGlyphs> have_row_y = {};
  for (size_t index = 0; index < expected_count; ++index) {
    const size_t row = visual_rows[index];
    if (!have_row_y[row]) {
      have_row_y[row] = true;
      row_first_y[row] = matched[index]->y;
    }
  }
  std::array<int32_t, kSiglusLookupMaxGlyphs> row_spacings = {};
  size_t row_spacing_count = 0;
  for (size_t row = 1; row < row_count; ++row) {
    int64_t spacing =
        static_cast<int64_t>(row_first_y[row]) - row_first_y[row - 1u];
    if (spacing < 0)
      spacing = -spacing;
    if (spacing > 0 && spacing <= profile.viewport_height) {
      row_spacings[row_spacing_count++] = static_cast<int32_t>(spacing);
    }
  }
  const int32_t row_spacing =
      MedianSiglusLookupMetric(row_spacings, row_spacing_count);
  if (median_extent <= 0 || median_extent > profile.viewport_height) {
    return false;
  }

  for (size_t index = 0; index < expected_count; ++index) {
    const size_t row = visual_rows[index];
    int32_t width = 0;
    if (index + 1u < expected_count && visual_rows[index + 1u] == row) {
      const int64_t advance =
          static_cast<int64_t>(matched[index + 1u]->x) - matched[index]->x;
      if (advance > 0 && advance <= profile.viewport_width) {
        width = static_cast<int32_t>(advance);
      }
    }
    if (width <= 0)
      width = matched[index]->extent;
    if (width <= 0)
      width = row_median_advance[row];
    if (width <= 0)
      width = median_advance;
    if (width <= 0)
      width = median_extent;
    if (width <= 0 || width > profile.viewport_width)
      return false;

    int32_t glyph_height = matched[index]->extent;
    if (row_spacing > 0)
      glyph_height = std::min(glyph_height, row_spacing);
    if (glyph_height <= 0)
      glyph_height = median_extent;

    const int32_t clipped_width =
        std::min(width, profile.viewport_width - matched[index]->x);
    const int32_t clipped_height =
        std::min(glyph_height, profile.viewport_height - matched[index]->y);
    if (clipped_width <= 0 || clipped_height <= 0)
      return false;
    geometry->glyphs[index] = {
        matched[index]->code_unit,
        char_indices[index],
        visual_rows[index],
        {matched[index]->x, matched[index]->y, clipped_width, clipped_height},
    };
  }
  geometry->glyph_count = expected_count;
  if (matched_end != nullptr)
    *matched_end = matched_start + expected_count;
  return true;
}

// The admitted build lays out text in a 1920x1080 design surface even when
// the PMv2 HWND client is physically larger. Fit that surface into the real
// client with the same centered letterbox transform used by the renderer.
// This function must run inside the target process so GetClientRect is not
// affected by an external observer's DPI virtualization.
inline bool ScaleSiglusLookupRectToClient(const SiglusLookupProfile &profile,
                                          const SiglusLookupRect &design_rect,
                                          int32_t client_width,
                                          int32_t client_height,
                                          SiglusLookupRect *client_rect) {
  if (client_rect == nullptr || profile.viewport_width <= 0 ||
      profile.viewport_height <= 0 || client_width <= 0 || client_height <= 0 ||
      design_rect.width <= 0 || design_rect.height <= 0) {
    return false;
  }
  const double scale =
      std::min(static_cast<double>(client_width) / profile.viewport_width,
               static_cast<double>(client_height) / profile.viewport_height);
  if (!std::isfinite(scale) || scale <= 0.0)
    return false;
  const double offset_x = (client_width - profile.viewport_width * scale) * 0.5;
  const double offset_y =
      (client_height - profile.viewport_height * scale) * 0.5;
  client_rect->x =
      static_cast<int32_t>(std::lround(offset_x + design_rect.x * scale));
  client_rect->y =
      static_cast<int32_t>(std::lround(offset_y + design_rect.y * scale));
  client_rect->width = std::max<int32_t>(
      1, static_cast<int32_t>(std::lround(design_rect.width * scale)));
  client_rect->height = std::max<int32_t>(
      1, static_cast<int32_t>(std::lround(design_rect.height * scale)));
  return client_rect->x < client_width && client_rect->y < client_height &&
         client_rect->x + client_rect->width > 0 &&
         client_rect->y + client_rect->height > 0;
}

inline int FindSiglusLookupGlyph(const SiglusLookupGeometry &geometry,
                                 int32_t cursor_x, int32_t cursor_y,
                                 SiglusLookupGlyphRect *hit) {
  for (size_t index = 0; index < geometry.glyph_count; ++index) {
    const auto &glyph = geometry.glyphs[index];
    if (cursor_x >= glyph.rect.x && cursor_y >= glyph.rect.y &&
        cursor_x < glyph.rect.x + glyph.rect.width &&
        cursor_y < glyph.rect.y + glyph.rect.height) {
      if (hit != nullptr)
        *hit = glyph;
      return static_cast<int>(index);
    }
  }
  return -1;
}

enum class SiglusLookupClickOwner : uint8_t {
  kIdle = 0,
  kPassThrough = 1,
  kLookup = 2,
  kPopupShield = 3,
};

struct SiglusLookupClickSampleState {
  // Hook installation can race an already-held physical button. Do not consume
  // that half-transaction; one observed physical up arms the state machine.
  bool synchronized = false;
  SiglusLookupClickOwner owner = SiglusLookupClickOwner::kIdle;
  uint16_t glyph_index = kSiglusLookupNoGlyph;
};

struct SiglusLookupClickDecision {
  bool consume = false;
  bool begin = false;
  bool submit = false;
  bool popup_transaction = false;
  uint16_t glyph_index = kSiglusLookupNoGlyph;
};

// GetKeyState is an immediate sampled state, not a message stream. Ownership
// is therefore chosen only on a fresh physical down and latched through its
// matching up. A miss is passed through for the whole transaction. A lookup
// hit or popup shield consumes the complete down/hold/up transaction; only a
// lookup-owned up submits the glyph captured on its down.
inline SiglusLookupClickDecision
AdvanceSiglusLookupClickSample(bool button_down, bool popup_shield,
                               uint16_t hit_glyph_index,
                               SiglusLookupClickSampleState *state) {
  SiglusLookupClickDecision decision;
  if (state == nullptr)
    return decision;
  if (!state->synchronized) {
    if (!button_down)
      state->synchronized = true;
    state->owner = SiglusLookupClickOwner::kIdle;
    state->glyph_index = kSiglusLookupNoGlyph;
    return decision;
  }

  if (state->owner == SiglusLookupClickOwner::kIdle) {
    if (!button_down)
      return decision;
    decision.begin = true;
    if (popup_shield) {
      state->owner = SiglusLookupClickOwner::kPopupShield;
      decision.consume = true;
      decision.popup_transaction = true;
      return decision;
    }
    if (hit_glyph_index != kSiglusLookupNoGlyph) {
      state->owner = SiglusLookupClickOwner::kLookup;
      state->glyph_index = hit_glyph_index;
      decision.consume = true;
      decision.glyph_index = hit_glyph_index;
      return decision;
    }
    state->owner = SiglusLookupClickOwner::kPassThrough;
    decision.begin = false;
    return decision;
  }

  const SiglusLookupClickOwner owner = state->owner;
  const uint16_t owned_glyph = state->glyph_index;
  decision.consume = owner == SiglusLookupClickOwner::kLookup ||
                     owner == SiglusLookupClickOwner::kPopupShield;
  decision.popup_transaction = owner == SiglusLookupClickOwner::kPopupShield;
  decision.glyph_index = owner == SiglusLookupClickOwner::kLookup
                             ? owned_glyph
                             : kSiglusLookupNoGlyph;
  if (!button_down) {
    decision.submit = owner == SiglusLookupClickOwner::kLookup;
    state->owner = SiglusLookupClickOwner::kIdle;
    state->glyph_index = kSiglusLookupNoGlyph;
  }
  return decision;
}

inline int16_t FilterSiglusLookupGetKeyState(int16_t raw_state, bool consume) {
  if (!consume)
    return raw_state;
  return static_cast<int16_t>(static_cast<uint16_t>(raw_state) &
                              static_cast<uint16_t>(~0x8000u));
}

inline constexpr uint32_t kSiglusLookupWmLeftButtonDown = 0x0201u;
inline constexpr uint32_t kSiglusLookupWmLeftButtonUp = 0x0202u;
inline constexpr uint32_t kSiglusLookupWmLeftButtonDoubleClick = 0x0203u;

struct SiglusLookupMouseMessageDecision {
  bool consume = false;
  bool next_latched = false;
};

// Siglus writes its own dialogue-advance edges from WM_LBUTTONDOWN/UP before
// the lookup WebView exists. Keep the entire admitted transaction away from
// that engine sink. A double click is down-equivalent because Windows follows
// it with another button-up.
//
// Two invariants, both of which the engine depends on:
//
// (1) Down and up are consumed as a pair. `latched` means "this down was mine",
//     and it is the only input to the up decision. Deciding the up from
//     `popup_shield` instead lets a down reach the engine while its up is
//     swallowed (the popup opens between them on the async worker tick), and
//     Siglus is then stuck believing the left button is still held: skip, drag
//     and auto-mode all mis-fire.
//
// (2) `latched` must not survive a lost up. Its only clearing edge is an up
//     that reaches this admitted callsite, and alt-tab, WM_CANCELMODE, capture
//     loss or dragging out of the window route the up elsewhere. So a *down*
//     while latched is by construction a stale latch -- no second press can be
//     in flight -- and it is judged on its own merits instead of inheriting the
//     stale value. Without that, one lost up consumed every later down and the
//     player never got the left button back. This mirrors how the GetKeyState
//     filter latch heals from the physical `!button_down` sample; the message
//     path heals from the down edge, which is its equivalent ground truth.
inline SiglusLookupMouseMessageDecision
DecideSiglusLookupMouseMessage(uint32_t message, bool popup_shield,
                               bool glyph_hit, bool latched) {
  SiglusLookupMouseMessageDecision decision;
  if (message == kSiglusLookupWmLeftButtonDown ||
      message == kSiglusLookupWmLeftButtonDoubleClick) {
    decision.consume = popup_shield || glyph_hit;
    decision.next_latched = decision.consume;
    return decision;
  }
  if (message == kSiglusLookupWmLeftButtonUp) {
    decision.consume = latched;
    return decision;
  }
  decision.next_latched = latched;
  return decision;
}

// Preserve the held-key rising edge and GetAsyncKeyState's low-bit record of a
// complete press/release between two worker polls. Neither signal may emit a
// second lookup while Shift remains held.
inline bool ConsumeSiglusLookupShiftSample(uint16_t async_state,
                                           bool *last_down) {
  if (last_down == nullptr)
    return false;
  const bool down = (async_state & 0x8000u) != 0;
  const bool pressed_since_poll = (async_state & 0x0001u) != 0;
  const bool rising_edge =
      (down && !*last_down) || (!down && pressed_since_poll);
  *last_down = down;
  return rising_edge;
}

} // namespace fushi_voice_hook

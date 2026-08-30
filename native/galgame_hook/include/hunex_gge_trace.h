#pragma once

#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// Fixed, numeric-only telemetry for the structurally admitted HUNEX/GGE
// renderer and sampled-input paths.  Text bytes and Unicode scalar values are
// deliberately excluded: a one-way hash plus counts is sufficient to
// correlate a draw traversal with the selected exact Luna lane without
// exporting the user's game text.
inline constexpr char kHunexGgeTraceExportName[] = "FushiHunexGgeTraceV1";
inline constexpr uint32_t kHunexGgeTraceMagic = 0x31544748u;  // "HGT1"
inline constexpr uint32_t kHunexGgeTraceVersion = 1u;
inline constexpr uint32_t kHunexGgeTraceCapacity = 512u;

enum class HunexGgeTraceKind : uint32_t {
  kDraw = 1u,
  kGlyphDirectFirst = 2u,
  kGlyphDirectSecond = 3u,
  kInputGeneric = 4u,
  kInputLeftButton = 5u,
};

enum HunexGgeTraceScannerStatus : uint32_t {
  kHunexGgeTraceScannerProfileMatched = 0x00000001u,
  kHunexGgeTraceScannerPe64 = 0x00000002u,
  kHunexGgeTraceScannerDrawUnique = 0x00000004u,
  kHunexGgeTraceScannerGlyphUnique = 0x00000008u,
  kHunexGgeTraceScannerInputUnique = 0x00000010u,
  kHunexGgeTraceScannerDrawCallsValid = 0x00000020u,
  kHunexGgeTraceScannerInputCallsValid = 0x00000040u,
  kHunexGgeTraceScannerHooksReady = 0x00000080u,
};

struct alignas(8) HunexGgeTraceEvent {
  uint64_t sequence = 0;
  uint64_t timestamp_ms = 0;
  uint64_t draw_sequence = 0;
  uint64_t text_hash = 0;
  uint64_t draw_arg12_bits = 0;
  uint32_t kind = 0;
  uint32_t thread_id = 0;
  uint32_t caller_rva = 0;
  uint32_t text_units = 0;
  uint32_t visible_units = 0;
  uint32_t glyph_ordinal = 0;
  uint32_t utf16_char_index = 0;
  uint32_t scalar_width = 0;
  uint32_t arg7 = 0;
  uint32_t draw_arg13 = 0;
  int32_t draw_x = 0;
  int32_t draw_y = 0;
  int32_t draw_width = 0;
  int32_t result = 0;
  uint32_t descriptor_words[8] = {};
  uint32_t output_words[28] = {};
};

struct alignas(8) HunexGgeTraceSlot {
  int32_t writing = 0;
  uint32_t reserved = 0;
  HunexGgeTraceEvent event = {};
};

struct alignas(8) HunexGgeTraceBuffer {
  uint32_t magic = kHunexGgeTraceMagic;
  uint32_t version = kHunexGgeTraceVersion;
  uint32_t event_size = sizeof(HunexGgeTraceEvent);
  uint32_t slot_size = sizeof(HunexGgeTraceSlot);
  uint32_t capacity = kHunexGgeTraceCapacity;
  uint32_t scanner_status = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
  int64_t draw_calls = 0;
  int64_t glyph_calls = 0;
  int64_t input_calls = 0;
  uint32_t module_machine = 0;
  uint32_t draw_match_count = 0;
  uint32_t glyph_match_count = 0;
  uint32_t key_poller_match_count = 0;
  uint32_t input_pump_match_count = 0;
  uint32_t draw_rva = 0;
  uint32_t glyph_rva = 0;
  uint32_t key_poller_rva = 0;
  uint32_t input_pump_rva = 0;
  uint32_t generic_return_rva = 0;
  uint32_t left_button_return_rva = 0;
  uint32_t direct_first_glyph_return_rva = 0;
  uint32_t direct_second_glyph_return_rva = 0;
  uint32_t reserved = 0;
  HunexGgeTraceSlot slots[kHunexGgeTraceCapacity] = {};
};

static_assert(sizeof(HunexGgeTraceEvent) == 240,
              "HUNEX/GGE trace event ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, draw_arg12_bits) == 32,
              "HUNEX/GGE draw arg12 trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, caller_rva) == 48,
              "HUNEX/GGE caller trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, glyph_ordinal) == 60,
              "HUNEX/GGE glyph ordinal trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, utf16_char_index) == 64,
              "HUNEX/GGE UTF-16 index trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, draw_arg13) == 76,
              "HUNEX/GGE draw arg13 trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, descriptor_words) == 96,
              "HUNEX/GGE descriptor trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, output_words) == 128,
              "HUNEX/GGE output trace ABI drifted");
static_assert(sizeof(HunexGgeTraceSlot) == 248,
              "HUNEX/GGE trace slot ABI drifted");
static_assert(offsetof(HunexGgeTraceBuffer, slots) == 120,
              "HUNEX/GGE trace header ABI drifted");

}  // namespace fushi_voice_hook

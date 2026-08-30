#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "exact_lookup_signature.h"
#include "sgre_anchors.h"

namespace fushi_voice_hook {

// Engine-internal addresses (TextRender draw boundary, scenario text vtable,
// DirectInput mouse device slot) are build-specific and come from
// sgre_anchors.h: a measured row for known builds, a unique signature hit for
// unknown ones. The hook sites below read the resolved SgreAnchorSet and stay
// inert for any anchor that did not resolve.
//
// DirectInput ABI, which is not build-specific: SetDataFormat(c_dfDIMouse2),
// GetDeviceState(0x14, ...) via vtable slot 9 / byte offset 0x48.
inline constexpr size_t kSgreDirectInputGetDeviceStateVtableIndex = 9u;
inline constexpr size_t kSgreDirectInputMouseStateBytes = 20u;
inline constexpr size_t kSgreDirectInputMouseButtonsOffset = 12u;
inline constexpr size_t kSgreDirectInputMouseButtonCount = 8u;
inline constexpr size_t kSgreLookupPrimaryButtonIndex = 0u;
inline constexpr uint8_t kSgreLookupPrimaryButtonMask = 0x01u;

namespace sgre_exact {

// All four anchors were measured from the executable admitted by
// kSgreExecutableSha256. They are scanned as one candidate set across every
// hydrated IMAGE_SCN_MEM_EXECUTE section. RIP displacements are wildcarded
// only where the decoded module-relative target is checked below.
inline constexpr uint8_t kTextDrawEntryBytes[] = {
    0x48, 0x8b, 0xc4, 0x48, 0x89, 0x58, 0x08, 0x48, 0x89, 0x70, 0x10,
    0x48, 0x89, 0x78, 0x18, 0x55, 0x48, 0x8d, 0x68, 0xa1, 0x48, 0x81,
    0xec, 0xe0, 0x00, 0x00, 0x00, 0x0f, 0x29, 0x70, 0xe8, 0x0f, 0x29,
    0x78, 0xd8, 0x44, 0x0f, 0x29, 0x40, 0xc8, 0x44, 0x0f, 0x29, 0x48,
    0xb8, 0x44, 0x0f, 0x29, 0x50, 0xa8, 0x44, 0x0f, 0x29, 0x58, 0x98,
    0x44, 0x0f, 0x29, 0x60, 0x88, 0x48, 0x8b, 0xf9, 0x44, 0x0f, 0x10,
    0x91, 0xd8, 0x03, 0x00, 0x00, 0x32, 0xdb, 0x88, 0x5d, 0xd7,
};
inline constexpr exact_lookup::MaskedPattern kTextDrawEntryPattern = {
    kTextDrawEntryBytes, nullptr, sizeof(kTextDrawEntryBytes)};

inline constexpr uint8_t kScenarioVtableConstructorBytes[] = {
    0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83, 0xec, 0x20,
    0x48, 0x8d, 0x05, 0x00, 0x00, 0x00, 0x00, 0x8b, 0xda, 0x48,
    0x89, 0x01, 0x48, 0x8b, 0xf9, 0x48, 0x8d, 0x05, 0x00, 0x00,
    0x00, 0x00, 0x48, 0x89, 0x81, 0xb0, 0x00, 0x00, 0x00,
};
inline constexpr auto kScenarioVtableConstructorMask =
    exact_lookup::MaskExceptRanges<sizeof(kScenarioVtableConstructorBytes)>(
        13u, 17u, 28u, 32u);
inline constexpr exact_lookup::MaskedPattern kScenarioVtableConstructorPattern = {
    kScenarioVtableConstructorBytes, kScenarioVtableConstructorMask.data(),
    sizeof(kScenarioVtableConstructorBytes)};
inline constexpr size_t kScenarioVtableInstructionOffset = 10u;
inline constexpr size_t kScenarioVtableDisplacementOffset = 3u;
inline constexpr size_t kScenarioVtableInstructionBytes = 7u;

inline constexpr uint8_t kMouseCreateDeviceBytes[] = {
    // The preceding byte-store distinguishes the measured mouse creation
    // path from the otherwise identical keyboard CreateDevice sequence.
    0xc6, 0x05, 0x00, 0x00, 0x00, 0x00, 0x01, 0x48, 0x8b, 0x0d,
    0x00, 0x00, 0x00, 0x00, 0x4c, 0x8d, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x45, 0x33, 0xc9, 0x48, 0x8d, 0x15, 0x00, 0x00, 0x00,
    0x00, 0x48, 0x8b, 0x01, 0xff, 0x50, 0x18, 0x85, 0xc0,
};
inline constexpr auto kMouseCreateDeviceMask =
    exact_lookup::MaskExceptRanges<sizeof(kMouseCreateDeviceBytes)>(
        2u, 6u, 10u, 14u, 17u, 21u, 27u, 31u);
inline constexpr exact_lookup::MaskedPattern kMouseCreateDevicePattern = {
    kMouseCreateDeviceBytes, kMouseCreateDeviceMask.data(),
    sizeof(kMouseCreateDeviceBytes)};
inline constexpr size_t kMouseCreateDeviceOutputInstructionOffset = 14u;
inline constexpr size_t kMouseCreateDeviceOutputDisplacementOffset = 3u;
inline constexpr size_t kMouseCreateDeviceOutputInstructionBytes = 7u;

inline constexpr uint8_t kMouseImmediatePollBytes[] = {
    0x48, 0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x48, 0x85, 0xc9,
    0x0f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x01, 0x4c,
    0x8d, 0x44, 0x24, 0x30, 0xba, 0x14, 0x00, 0x00, 0x00, 0xff,
    0x50, 0x48,
};
inline constexpr auto kMouseImmediatePollMask =
    exact_lookup::MaskExceptRanges<sizeof(kMouseImmediatePollBytes)>(
        3u, 7u, 12u, 16u);
inline constexpr exact_lookup::MaskedPattern kMouseImmediatePollPattern = {
    kMouseImmediatePollBytes, kMouseImmediatePollMask.data(),
    sizeof(kMouseImmediatePollBytes)};
inline constexpr size_t kMouseImmediatePollLoadInstructionOffset = 0u;
inline constexpr size_t kMouseImmediatePollLoadDisplacementOffset = 3u;
inline constexpr size_t kMouseImmediatePollLoadInstructionBytes = 7u;

}  // namespace sgre_exact

// Clear only DIMOUSESTATE2::rgbButtons while a direct lookup popup is
// published. A local per-button latch survives popup teardown: once a down was
// hidden from the game, that button stays hidden until the real device state
// reports its matching up. Movement axes at bytes [0, 12) are never touched.
// Unsupported state layouts are rejected unchanged because this is an exact
// profile hook, not a best-effort DirectInput filter.
inline uint8_t FilterSgreDirectInputMouseButtons(bool shield_active,
                                                 uint8_t* state,
                                                 size_t state_bytes,
                                                 uint8_t latched_buttons) {
  if (state == nullptr || state_bytes != kSgreDirectInputMouseStateBytes) {
    return latched_buttons;
  }
  for (size_t index = 0; index < kSgreDirectInputMouseButtonCount; ++index) {
    const uint8_t bit = static_cast<uint8_t>(1u << index);
    const size_t offset = kSgreDirectInputMouseButtonsOffset + index;
    const bool down = (state[offset] & 0x80u) != 0;
    if (shield_active && down) latched_buttons |= bit;
    const bool suppress = shield_active || (latched_buttons & bit) != 0;
    if (suppress) state[offset] = 0;
    if (!down) latched_buttons &= static_cast<uint8_t>(~bit);
  }
  return latched_buttons;
}

enum class SgreLookupClickAction : uint8_t {
  kNone = 0,
  kBegin = 1,
  kSubmit = 2,
  kCancel = 3,
};

struct SgreLookupClickGestureState {
  // A hook can be installed while the physical button is already held. Do not
  // consume that half-transaction: wait for one observed up before accepting a
  // fresh lookup down.
  bool synchronized = false;
  bool last_down = false;
  bool active = false;
  bool cancelled = false;
};

// DirectInput exposes immediate button state rather than Win32 pointer
// messages, so reproduce the source-window single-click transaction explicitly:
// a fresh down over a glyph begins a pending lookup; physical screen movement
// past the same 6 px threshold used by the native text strip cancels it; only
// the matching up submits. The caller latches the physical button from kBegin
// through the matching release so SGRE never observes half of the consumed
// click.
// 命中即承诺：kBegin 那一刻 down 就已经从游戏的 DirectInput 采样里抹掉了，事后无法
// 补发（真让游戏看见 down，台词就推进了、这一行也没了）。所以**位移不是取消理由**——
// 曾经存在过一个 6px 拖动阈值，用户手抖越过它就走 kCancel：down 被吞、查词又被取消，
// 游戏和用户两头都拿不到任何结果，症状是「点台词偶尔完全没反应」且不可自解释。
// 消除这个特例，而不是给它配补发逻辑。
//
// 留下的两个取消理由都是「这次消费本来就不该成立」：查词权限/屏蔽在按住期间掉电，
// 或光标位置读不出来。两者下游本来就会吞掉这次点击，不构成额外损失。
inline SgreLookupClickAction AdvanceSgreLookupClickGesture(
    bool button_down, bool lookup_allowed, bool hit_on_press,
    bool pointer_valid, SgreLookupClickGestureState* state) {
  if (state == nullptr) return SgreLookupClickAction::kNone;
  if (!state->synchronized) {
    state->last_down = button_down;
    state->active = false;
    state->cancelled = false;
    if (!button_down) state->synchronized = true;
    return SgreLookupClickAction::kNone;
  }

  if (button_down && !state->last_down) {
    state->last_down = true;
    state->active = lookup_allowed && hit_on_press && pointer_valid;
    state->cancelled = false;
    return state->active ? SgreLookupClickAction::kBegin
                         : SgreLookupClickAction::kNone;
  }

  if (state->active && state->last_down &&
      (!lookup_allowed || !pointer_valid)) {
    state->cancelled = true;
  }

  if (button_down || !state->last_down) {
    return SgreLookupClickAction::kNone;
  }

  state->last_down = false;
  const bool submit = state->active && !state->cancelled && lookup_allowed &&
                      pointer_valid;
  const bool cancel = state->active && !submit;
  state->active = false;
  state->cancelled = false;
  if (submit) return SgreLookupClickAction::kSubmit;
  return cancel ? SgreLookupClickAction::kCancel
                : SgreLookupClickAction::kNone;
}

inline constexpr int32_t kSgreDesignWidth = 1920;
inline constexpr int32_t kSgreDesignHeight = 1080;
inline constexpr float kSgreDialogueOriginX = 320.0f;
inline constexpr float kSgreDialogueOriginY = 830.0f;
inline constexpr float kSgreScenarioLineHeight = 80.0f;

struct SgreLookupGlyphGeometry {
  float x = 0.0f;
  float y = 0.0f;
  float width = 0.0f;
  float height = 0.0f;
  uint16_t line = 0;
};

struct SgreLookupClientSnapshot {
  uintptr_t game_window = 0;
  int32_t screen_x = 0;
  int32_t screen_y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// Capture sequence is a transport detail: SGRE redraws an unchanged sentence
// every frame.  Lookup generations instead identify a logical text+geometry
// snapshot and only advance when that identity changes (or after invalidation).
inline uint64_t NextSgreLookupLogicalGeneration(uint64_t generation) {
  ++generation;
  return generation == 0 ? 1 : generation;
}

inline bool SameSgreLookupLogicalSnapshot(
    const char16_t* lhs_text, size_t lhs_text_units,
    const SgreLookupGlyphGeometry* lhs_glyphs, size_t lhs_glyph_count,
    float lhs_line_height, const char16_t* rhs_text, size_t rhs_text_units,
    const SgreLookupGlyphGeometry* rhs_glyphs, size_t rhs_glyph_count,
    float rhs_line_height) {
  if (lhs_text_units != rhs_text_units || lhs_glyph_count != rhs_glyph_count ||
      lhs_text_units != lhs_glyph_count || lhs_line_height != rhs_line_height ||
      (lhs_text_units != 0 && (lhs_text == nullptr || rhs_text == nullptr)) ||
      (lhs_glyph_count != 0 && (lhs_glyphs == nullptr || rhs_glyphs == nullptr))) {
    return false;
  }
  for (size_t index = 0; index < lhs_text_units; ++index) {
    if (lhs_text[index] != rhs_text[index]) return false;
  }
  for (size_t index = 0; index < lhs_glyph_count; ++index) {
    const auto& lhs = lhs_glyphs[index];
    const auto& rhs = rhs_glyphs[index];
    if (lhs.x != rhs.x || lhs.y != rhs.y || lhs.width != rhs.width ||
        lhs.height != rhs.height || lhs.line != rhs.line) {
      return false;
    }
  }
  return true;
}

inline bool MatchesSgreLookupGenerationAndClient(
    uint64_t payload_generation, const SgreLookupClientSnapshot& payload_client,
    uint64_t active_generation, const SgreLookupClientSnapshot& active_client) {
  return payload_generation != 0 && payload_generation == active_generation &&
         payload_client.game_window != 0 &&
         payload_client.game_window == active_client.game_window &&
         payload_client.screen_x == active_client.screen_x &&
         payload_client.screen_y == active_client.screen_y &&
         payload_client.width > 0 && payload_client.height > 0 &&
         payload_client.width == active_client.width &&
         payload_client.height == active_client.height;
}

struct SgreLookupRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// HookWorker samples input every 16 ms. A complete Shift press/release can
// happen between two samples, leaving the high bit clear even though Windows
// reports the transition in GetAsyncKeyState's low bit. Consume both signals:
// the high bit preserves the normal held-key edge, while the low bit recovers
// a tap that completed between polls. Never emit twice for one held press.
inline bool ConsumeSgreLookupShiftSample(uint16_t async_state,
                                         bool* last_down) {
  if (last_down == nullptr) return false;
  const bool down = (async_state & 0x8000u) != 0;
  const bool pressed_since_poll = (async_state & 0x0001u) != 0;
  const bool submit = (down && !*last_down) || (!down && pressed_since_poll);
  *last_down = down;
  return submit;
}

// The admitted renderer stores a flattened glyph list. A native line break
// resets the next glyph's x anchor instead of inserting a '\n' glyph. Derive
// the visual row from that reset so explicit and automatic game layout remain
// authoritative.
inline bool StartsNextSgreLookupLine(float previous_x, float current_x) {
  return std::isfinite(previous_x) && std::isfinite(current_x) &&
         current_x <= previous_x;
}

inline bool MatchesSgreScenarioDrawMetrics(float line_height,
                                           float glyph_height,
                                           bool has_horizontal_advance) {
  return std::isfinite(line_height) && std::isfinite(glyph_height) &&
         std::abs(line_height - kSgreScenarioLineHeight) <= 0.5f &&
         std::abs(glyph_height - kSgreScenarioLineHeight) <= 0.5f &&
         has_horizontal_advance;
}

inline bool IsSaneSgreLookupGlyph(const SgreLookupGlyphGeometry& glyph) {
  return std::isfinite(glyph.x) && std::isfinite(glyph.y) &&
         std::isfinite(glyph.width) && std::isfinite(glyph.height) &&
         glyph.x >= -64.0f && glyph.x <= 4096.0f && glyph.width > 0.0f &&
         glyph.width <= 256.0f && glyph.y >= -64.0f && glyph.y <= 2048.0f &&
         glyph.height > 0.0f && glyph.height <= 256.0f && glyph.line < 8;
}

inline bool SgreLookupRectForGlyph(const SgreLookupGlyphGeometry& glyph,
                                   int32_t client_width, int32_t client_height,
                                   SgreLookupRect* rect) {
  if (rect == nullptr || client_width <= 0 || client_height <= 0 ||
      !IsSaneSgreLookupGlyph(glyph)) {
    return false;
  }
  const float scale = std::min(
      static_cast<float>(client_width) / static_cast<float>(kSgreDesignWidth),
      static_cast<float>(client_height) /
          static_cast<float>(kSgreDesignHeight));
  const float offset_x =
      (static_cast<float>(client_width) - kSgreDesignWidth * scale) * 0.5f;
  const float offset_y =
      (static_cast<float>(client_height) - kSgreDesignHeight * scale) * 0.5f;
  // The admitted renderer mixes two domains exactly this way: the scenario
  // root is a 1920x1080 design anchor, while glyph+0x40/0x44 and the 80x80
  // texture cell are already physical draw units. The live 3840x2160 object
  // reports x=0,80,160 while its pre-draw layout field reports 0,25,50.
  rect->x = static_cast<int32_t>(
      std::lround(offset_x + kSgreDialogueOriginX * scale + glyph.x));
  rect->y = static_cast<int32_t>(
      std::lround(offset_y + kSgreDialogueOriginY * scale + glyph.y));
  rect->width =
      std::max<int32_t>(1, static_cast<int32_t>(std::lround(glyph.width)));
  rect->height =
      std::max<int32_t>(1, static_cast<int32_t>(std::lround(glyph.height)));
  return rect->x < client_width && rect->y < client_height &&
         rect->x + rect->width > 0 && rect->y + rect->height > 0;
}

// TextRender's glyph width is the font/texture box, not the horizontal
// advance. In the admitted SGRE build the real draw anchors normally advance
// 80 units, matching the 80-unit texture cell. Bound each hit cell by the next
// draw anchor anyway so punctuation and later font variants stay non-
// overlapping; for the row's last glyph reuse the previous advance. The raw
// box remains the fallback for a lone or malformed anchor sequence.
inline float SgreLookupHitWidth(const SgreLookupGlyphGeometry* glyphs,
                                size_t glyph_count, size_t glyph_index) {
  if (glyphs == nullptr || glyph_index >= glyph_count ||
      !IsSaneSgreLookupGlyph(glyphs[glyph_index])) {
    return 0.0f;
  }
  const auto& current = glyphs[glyph_index];
  if (glyph_index + 1 < glyph_count) {
    const auto& next = glyphs[glyph_index + 1];
    const float advance = next.x - current.x;
    if (next.line == current.line && std::isfinite(next.x) &&
        advance > 0.0f && advance <= 256.0f) {
      return std::min(current.width, advance);
    }
  }
  if (glyph_index != 0) {
    const auto& previous = glyphs[glyph_index - 1];
    const float advance = current.x - previous.x;
    if (previous.line == current.line && std::isfinite(previous.x) &&
        advance > 0.0f && advance <= 256.0f) {
      return std::min(current.width, advance);
    }
  }
  return current.width;
}

inline int FindSgreLookupGlyph(const SgreLookupGlyphGeometry* glyphs,
                               size_t glyph_count, int32_t client_width,
                               int32_t client_height, int32_t cursor_x,
                               int32_t cursor_y, SgreLookupRect* hit_rect) {
  if (glyphs == nullptr || glyph_count == 0) return -1;
  for (size_t i = 0; i < glyph_count; ++i) {
    SgreLookupGlyphGeometry hit_glyph = glyphs[i];
    hit_glyph.width = SgreLookupHitWidth(glyphs, glyph_count, i);
    SgreLookupRect rect;
    if (!SgreLookupRectForGlyph(hit_glyph, client_width, client_height,
                                &rect)) {
      continue;
    }
    if (cursor_x >= rect.x && cursor_y >= rect.y &&
        cursor_x < rect.x + rect.width && cursor_y < rect.y + rect.height) {
      if (hit_rect != nullptr) *hit_rect = rect;
      return static_cast<int>(i);
    }
  }
  return -1;
}

}  // namespace fushi_voice_hook

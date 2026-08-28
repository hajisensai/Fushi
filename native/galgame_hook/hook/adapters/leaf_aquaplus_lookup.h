#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

inline constexpr size_t kLeafAquaplusLookupMaxTextUnits = 512u;
inline constexpr uint16_t kLeafAquaplusAsyncPressedMask = 0x8001u;

struct LeafAquaplusLookupRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct LeafAquaplusLookupGlyph {
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
  uint32_t char_index = 0;
};

inline bool IsSaneLeafAquaplusLookupGlyph(const LeafAquaplusLookupGlyph &glyph,
                                          int32_t viewport_x,
                                          int32_t viewport_y,
                                          int32_t viewport_width,
                                          int32_t viewport_height) {
  return viewport_width > 0 && viewport_height > 0 &&
         std::isfinite(glyph.left) && std::isfinite(glyph.top) &&
         std::isfinite(glyph.right) && std::isfinite(glyph.bottom) &&
         glyph.left >= static_cast<float>(viewport_x) &&
         glyph.top >= static_cast<float>(viewport_y) &&
         glyph.right <= static_cast<float>(viewport_x + viewport_width) &&
         glyph.bottom <= static_cast<float>(viewport_y + viewport_height) &&
         glyph.right > glyph.left && glyph.bottom > glyph.top &&
         glyph.right - glyph.left <= 256.0f &&
         glyph.bottom - glyph.top <= 256.0f;
}

inline bool LeafAquaplusLookupRectForGlyph(
    const LeafAquaplusLookupGlyph &glyph, int32_t viewport_x,
    int32_t viewport_y, int32_t viewport_width, int32_t viewport_height,
    int32_t client_width, int32_t client_height, LeafAquaplusLookupRect *rect) {
  if (rect == nullptr || client_width <= 0 || client_height <= 0 ||
      !IsSaneLeafAquaplusLookupGlyph(glyph, viewport_x, viewport_y,
                                     viewport_width, viewport_height)) {
    return false;
  }
  const float scale_x =
      static_cast<float>(client_width) / static_cast<float>(viewport_width);
  const float scale_y =
      static_cast<float>(client_height) / static_cast<float>(viewport_height);
  rect->x =
      static_cast<int32_t>(std::lround((glyph.left - viewport_x) * scale_x));
  rect->y =
      static_cast<int32_t>(std::lround((glyph.top - viewport_y) * scale_y));
  rect->width = (std::max)(1, static_cast<int32_t>(std::lround(
                                  (glyph.right - glyph.left) * scale_x)));
  rect->height = (std::max)(1, static_cast<int32_t>(std::lround(
                                   (glyph.bottom - glyph.top) * scale_y)));
  return rect->x < client_width && rect->y < client_height &&
         rect->x + rect->width > 0 && rect->y + rect->height > 0;
}

inline int FindLeafAquaplusLookupGlyph(
    const LeafAquaplusLookupGlyph *glyphs, size_t glyph_count,
    int32_t viewport_x, int32_t viewport_y, int32_t viewport_width,
    int32_t viewport_height, int32_t client_width, int32_t client_height,
    int32_t cursor_x, int32_t cursor_y, LeafAquaplusLookupRect *hit_rect) {
  if (glyphs == nullptr || glyph_count == 0)
    return -1;
  // Later draw records sit visually above earlier ones. Walk backwards so
  // punctuation/ruby overlap follows the engine's own painter order.
  for (size_t reverse = glyph_count; reverse != 0; --reverse) {
    const size_t index = reverse - 1u;
    LeafAquaplusLookupRect rect;
    if (!LeafAquaplusLookupRectForGlyph(glyphs[index], viewport_x, viewport_y,
                                        viewport_width, viewport_height,
                                        client_width, client_height, &rect)) {
      continue;
    }
    if (cursor_x >= rect.x && cursor_y >= rect.y &&
        cursor_x < rect.x + rect.width && cursor_y < rect.y + rect.height) {
      if (hit_rect != nullptr)
        *hit_rect = rect;
      return static_cast<int>(index);
    }
  }
  return -1;
}

inline uint16_t FilterLeafAquaplusAsyncKeyState(uint16_t raw, bool consume) {
  return consume ? static_cast<uint16_t>(raw & ~kLeafAquaplusAsyncPressedMask)
                 : raw;
}

inline bool IsLeafAquaplusTraceForSentence(uint64_t event_sequence,
                                           uint64_t event_timestamp_ms,
                                           uint64_t sequence_floor,
                                           uint64_t sentence_timestamp_ms) {
  return event_sequence > sequence_floor &&
         event_timestamp_ms >= sentence_timestamp_ms;
}

inline uint64_t LeafAquaplusRecentTraceFloor(uint64_t committed_sequence,
                                             uint64_t capacity) {
  if (capacity == 0 || committed_sequence <= capacity)
    return 0;
  return committed_sequence - capacity;
}

inline bool LeafAquaplusTraceContinuesTraversal(uint64_t previous_sequence,
                                                uint32_t previous_glyph_index,
                                                uint64_t event_sequence,
                                                uint32_t event_glyph_index) {
  return previous_sequence != 0 && event_sequence == previous_sequence + 1u &&
         event_glyph_index > previous_glyph_index;
}

inline bool LeafAquaplusTargetSequenceIsNewer(uint64_t candidate_sequence,
                                              uint64_t consumed_sequence) {
  return candidate_sequence != 0 && candidate_sequence > consumed_sequence;
}

enum class LeafAquaplusSelectedLineEventDisposition : uint8_t {
  kIgnore = 0,
  kInvalidate = 1,
  kUseUtf16Payload = 2,
};

inline LeafAquaplusSelectedLineEventDisposition
ClassifyLeafAquaplusSelectedLineEvent(uint64_t event_sequence,
                                      uint64_t consumed_sequence,
                                      bool stable_selected_exact_line,
                                      bool is_utf8, uint32_t byte_len,
                                      uint32_t payload_capacity,
                                      size_t max_text_units) {
  if (!stable_selected_exact_line ||
      !LeafAquaplusTargetSequenceIsNewer(event_sequence, consumed_sequence)) {
    return LeafAquaplusSelectedLineEventDisposition::kIgnore;
  }
  if (is_utf8 || byte_len == 0 || (byte_len % sizeof(wchar_t)) != 0 ||
      byte_len > payload_capacity ||
      byte_len / sizeof(wchar_t) > max_text_units) {
    return LeafAquaplusSelectedLineEventDisposition::kInvalidate;
  }
  return LeafAquaplusSelectedLineEventDisposition::kUseUtf16Payload;
}

// A conflicting admitted poller must never touch the owner thread's mutable
// click/tail state. It only hides this button sample when a lookup transaction
// is actually live (or the sample itself hits the published glyph surface), so
// detecting an unsupported multi-threaded runtime does not permanently swallow
// otherwise-idle game input.
inline bool LeafAquaplusConflictingPollerMustConsume(
    bool popup_shield, bool requested_tail_button, bool latched_button,
    bool lookup_transaction_active, bool published_glyph_hit) {
  return popup_shield || requested_tail_button || latched_button ||
         lookup_transaction_active || published_glyph_hit;
}

inline bool LeafAquaplusTailRequestIsOrphaned(uint32_t request_token,
                                              bool valid_popup) {
  return request_token != 0 && !valid_popup;
}

struct LeafAquaplusPackedCp932Bytes {
  uint8_t bytes[2] = {};
  uint32_t count = 0;
};

inline uint16_t NormalizeLeafAquaplusPackedCp932(uint16_t packed) {
  const uint8_t low = static_cast<uint8_t>(packed & 0xffu);
  const uint8_t high = static_cast<uint8_t>(packed >> 8u);
  // 0x4460a0 sign-extends single-byte halfwidth katakana through one path.
  return high == 0xffu ? low : packed;
}

// 0x4460a0 receives the original bytes packed as the little-endian word read
// from the scenario stream.  Do not byte-swap it: CP932 byte order is low,
// then high.  Conversion to UTF-16 deliberately stays in the injected process.
inline bool UnpackLeafAquaplusCp932(uint16_t packed,
                                    LeafAquaplusPackedCp932Bytes *unpacked) {
  packed = NormalizeLeafAquaplusPackedCp932(packed);
  if (unpacked == nullptr || packed == 0)
    return false;
  *unpacked = {};
  unpacked->bytes[0] = static_cast<uint8_t>(packed & 0xffu);
  unpacked->bytes[1] = static_cast<uint8_t>(packed >> 8u);
  unpacked->count = unpacked->bytes[1] == 0 ? 1u : 2u;
  return unpacked->bytes[0] != 0;
}

// LeafFilter only removes literal line/control escapes.  Lookup must not send
// engine ruby markup to the WebView: <Rbase|ruby> contributes only `base`.
// Unknown/malformed angle markup fails closed instead of leaking raw controls.
inline bool NormalizeLeafAquaplusLookupText(const wchar_t *source,
                                            size_t source_units,
                                            wchar_t *normalized,
                                            size_t normalized_capacity,
                                            size_t *normalized_units) {
  if (normalized_units == nullptr)
    return false;
  *normalized_units = 0;
  if (source == nullptr || source_units == 0 || normalized == nullptr ||
      normalized_capacity == 0) {
    return false;
  }
  size_t output = 0;
  for (size_t index = 0; index < source_units;) {
    if (source[index] != L'<') {
      if (source[index] == L'>')
        return false;
      if (output >= normalized_capacity)
        return false;
      normalized[output++] = source[index++];
      continue;
    }
    if (index + 2u >= source_units || source[index + 1u] != L'R') {
      return false;
    }
    size_t separator = index + 2u;
    while (separator < source_units && source[separator] != L'|' &&
           source[separator] != L'>') {
      ++separator;
    }
    if (separator == index + 2u || separator >= source_units ||
        source[separator] != L'|') {
      return false;
    }
    size_t close = separator + 1u;
    while (close < source_units && source[close] != L'>')
      ++close;
    if (close == separator + 1u || close >= source_units)
      return false;
    for (size_t base = index + 2u; base < separator; ++base) {
      if (source[base] == L'<' || source[base] == L'>')
        return false;
      if (output >= normalized_capacity)
        return false;
      normalized[output++] = source[base];
    }
    index = close + 1u;
  }
  if (output == 0)
    return false;
  *normalized_units = output;
  return true;
}

inline bool IsLeafAquaplusVisibleTextUnit(wchar_t value) {
  return value != L' ' && value != L'\t' && value != L'\r' && value != L'\n' &&
         value != static_cast<wchar_t>(0x3000);
}

inline bool CollectLeafAquaplusVisibleCharMap(const wchar_t *text,
                                              size_t text_units,
                                              uint32_t *char_indices,
                                              size_t char_indices_capacity,
                                              size_t *visible_count) {
  if (visible_count == nullptr)
    return false;
  *visible_count = 0;
  if (text == nullptr || text_units == 0 || char_indices == nullptr) {
    return false;
  }
  size_t visible = 0;
  for (size_t index = 0; index < text_units; ++index) {
    if (!IsLeafAquaplusVisibleTextUnit(text[index]))
      continue;
    if (visible >= char_indices_capacity)
      return false;
    char_indices[visible++] = static_cast<uint32_t>(index);
  }
  *visible_count = visible;
  return visible != 0;
}

inline bool BuildLeafAquaplusVisibleCharMap(const wchar_t *text,
                                            size_t text_units,
                                            size_t glyph_count,
                                            uint32_t *char_indices,
                                            size_t char_indices_capacity) {
  if (glyph_count == 0 || glyph_count > char_indices_capacity)
    return false;
  size_t visible = 0;
  return CollectLeafAquaplusVisibleCharMap(text, text_units, char_indices,
                                           char_indices_capacity, &visible) &&
         visible == glyph_count;
}

inline bool LeafAquaplusDecodedGlyphMatchesText(wchar_t decoded,
                                                const wchar_t *text,
                                                size_t text_units,
                                                uint32_t char_index) {
  return text != nullptr && char_index < text_units && decoded != L'\0' &&
         decoded == text[char_index];
}

struct LeafAquaplusGlyphDrawIdentity {
  uint16_t draw_format = 0;
  uint32_t caller_rva = 0;
  uint32_t vertex_stride = 0;
  uint32_t fvf = 0;
};

inline bool IsLeafAquaplusPrimaryGlyphDraw(
    const LeafAquaplusGlyphDrawIdentity &draw, uint32_t primary_caller_rva,
    uint32_t primary_vertex_stride, uint32_t primary_fvf) {
  return draw.draw_format == 1u && draw.caller_rva == primary_caller_rva &&
         draw.vertex_stride == primary_vertex_stride && draw.fvf == primary_fvf;
}

inline bool AreLeafAquaplusMatchedGlyphDrawsPrimary(
    const LeafAquaplusGlyphDrawIdentity *draws, size_t draw_count,
    uint32_t primary_caller_rva, uint32_t primary_vertex_stride,
    uint32_t primary_fvf) {
  if (draws == nullptr || draw_count == 0)
    return false;
  for (size_t index = 0; index < draw_count; ++index) {
    if (!IsLeafAquaplusPrimaryGlyphDraw(draws[index], primary_caller_rva,
                                        primary_vertex_stride, primary_fvf)) {
      return false;
    }
  }
  return true;
}

// Text-object traversal order must agree with the horizontal layout.  A line
// may wrap down and restart at the left, but a glyph may not travel backwards
// within an overlapping line or jump upward into an earlier line.
inline bool IsLeafAquaplusGlyphSequenceSpatiallyMonotonic(
    const LeafAquaplusLookupGlyph *glyphs, size_t glyph_count) {
  if (glyphs == nullptr || glyph_count == 0)
    return false;
  for (size_t index = 1; index < glyph_count; ++index) {
    const auto &previous = glyphs[index - 1u];
    const auto &current = glyphs[index];
    const float previous_height = previous.bottom - previous.top;
    const float current_height = current.bottom - current.top;
    if (!(previous_height > 0.0f) || !(current_height > 0.0f))
      return false;
    const float overlap = (std::min)(previous.bottom, current.bottom) -
                          (std::max)(previous.top, current.top);
    const float same_line_threshold =
        (std::min)(previous_height, current_height) * 0.35f;
    if (overlap >= same_line_threshold) {
      const float backward_tolerance =
          (std::max)(2.0f, (std::min)(previous_height, current_height) * 0.25f);
      if (current.left + backward_tolerance < previous.left)
        return false;
    } else {
      const float previous_center = (previous.top + previous.bottom) * 0.5f;
      const float current_center = (current.top + current.bottom) * 0.5f;
      if (current_center <= previous_center)
        return false;
    }
  }
  return true;
}

struct LeafAquaplusSampledInputTailState {
  uint32_t token = 0;
  uint32_t drained_buttons = 0;
  uint32_t acknowledged_token = 0;
};

struct LeafAquaplusSampledInputTailDecision {
  bool consume = false;
  bool acknowledge = false;
  uint32_t token = 0;
};

// The host keeps request_token published after the physical up. A sampled
// engine can therefore consume a low-bit-only quick click even if the popup was
// hidden between two polls. Ack is emitted only after every requested button
// has first become inactive (raw high and low bits both clear).
inline LeafAquaplusSampledInputTailDecision AdvanceLeafAquaplusSampledInputTail(
    uint32_t request_token, uint32_t request_button_mask, uint32_t button_bit,
    uint16_t raw, LeafAquaplusSampledInputTailState *state) {
  LeafAquaplusSampledInputTailDecision decision;
  if (state == nullptr || request_token == 0 || request_button_mask == 0) {
    if (state != nullptr)
      *state = {};
    return decision;
  }
  if (state->token != request_token) {
    state->token = request_token;
    state->drained_buttons = 0;
    state->acknowledged_token = 0;
  }
  decision.token = request_token;
  if ((request_button_mask & button_bit) == 0)
    return decision;
  decision.consume = true;
  if ((raw & kLeafAquaplusAsyncPressedMask) != 0) {
    state->drained_buttons &= ~button_bit;
  } else {
    state->drained_buttons |= button_bit;
  }
  if ((state->drained_buttons & request_button_mask) == request_button_mask &&
      state->acknowledged_token != request_token) {
    state->acknowledged_token = request_token;
    decision.acknowledge = true;
  }
  return decision;
}

enum class LeafAquaplusLookupClickOwner : uint8_t {
  kIdle = 0,
  kLookup = 1,
  kPopup = 2,
};

struct LeafAquaplusLookupClickSampleState {
  bool synchronized = false;
  bool last_high_down = false;
  LeafAquaplusLookupClickOwner owner = LeafAquaplusLookupClickOwner::kIdle;
  uint64_t sentence_epoch = 0;
};

struct LeafAquaplusLookupClickDecision {
  bool begin = false;
  bool submit = false;
  bool consume = false;
  bool popup_transaction = false;
};

// WA2 tests GetAsyncKeyState with 0x8001, so both the physical high bit and
// the transition low bit are input. A low-bit-only tap is a complete click in
// one sample. A high-bit click freezes the sentence identity on down, submits
// only on its matching up, and remains consumed even when the sentence changes
// while held. Popup transactions use the same full down/up ownership.
inline LeafAquaplusLookupClickDecision AdvanceLeafAquaplusLookupClickSample(
    uint16_t raw, bool lookup_enabled, bool popup_visible, bool glyph_hit,
    uint64_t sentence_epoch, LeafAquaplusLookupClickSampleState *state) {
  LeafAquaplusLookupClickDecision decision;
  if (state == nullptr)
    return decision;
  const bool high_down = (raw & 0x8000u) != 0;
  const bool pressed_since_poll = (raw & 0x0001u) != 0;
  const bool active = high_down || pressed_since_poll;

  if (!state->synchronized) {
    state->last_high_down = high_down;
    if (!active)
      state->synchronized = true;
    if (popup_visible && active) {
      decision.consume = true;
      decision.popup_transaction = true;
    }
    return decision;
  }

  if (state->owner != LeafAquaplusLookupClickOwner::kIdle) {
    decision.consume = true;
    decision.popup_transaction =
        state->owner == LeafAquaplusLookupClickOwner::kPopup;
    if (!high_down) {
      decision.submit = state->owner == LeafAquaplusLookupClickOwner::kLookup &&
                        lookup_enabled &&
                        state->sentence_epoch == sentence_epoch;
      state->owner = LeafAquaplusLookupClickOwner::kIdle;
      state->sentence_epoch = 0;
    }
    state->last_high_down = high_down;
    return decision;
  }

  const bool fresh_press = (high_down && !state->last_high_down) ||
                           (!high_down && pressed_since_poll);
  if (fresh_press && popup_visible) {
    decision.begin = true;
    decision.consume = true;
    decision.popup_transaction = true;
    if (high_down)
      state->owner = LeafAquaplusLookupClickOwner::kPopup;
  } else if (fresh_press && lookup_enabled && glyph_hit) {
    decision.begin = true;
    decision.consume = true;
    state->sentence_epoch = sentence_epoch;
    if (high_down) {
      state->owner = LeafAquaplusLookupClickOwner::kLookup;
    } else {
      decision.submit = true;
      state->sentence_epoch = 0;
    }
  }
  state->last_high_down = high_down;
  return decision;
}

struct LeafAquaplusLookupShiftState {
  uint64_t activation_epoch = 0;
  bool synchronized = false;
  bool last_high_down = false;
};

inline bool
ConsumeLeafAquaplusLookupShiftSample(uint16_t async_state,
                                     uint64_t activation_epoch,
                                     LeafAquaplusLookupShiftState *state) {
  if (state == nullptr || activation_epoch == 0)
    return false;
  const bool down = (async_state & 0x8000u) != 0;
  if (!state->synchronized || state->activation_epoch != activation_epoch) {
    // GetAsyncKeyState has already drained the process-wide low bit.  Seed the
    // held state but never replay a tap/hold that happened while lookup was
    // disabled or while the sensor was being reinstalled.
    state->activation_epoch = activation_epoch;
    state->synchronized = true;
    state->last_high_down = down;
    return false;
  }
  const bool pressed_since_poll = (async_state & 0x0001u) != 0;
  const bool submit =
      (down && !state->last_high_down) || (!down && pressed_since_poll);
  state->last_high_down = down;
  return submit;
}

} // namespace fushi_voice_hook

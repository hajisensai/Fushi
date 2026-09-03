#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace fushi_voice_hook::hunex_lookup_core {

// These containers are the callback-to-worker hand-off only. They have fixed
// storage, never allocate, and deliberately know nothing about HUNEX addresses,
// callers, text-thread selection, IPC publication, or popup rendering.
inline constexpr size_t kCaptureCapacity = 8u;
inline constexpr size_t kTextCapacity = 512u;
inline constexpr size_t kGlyphCapacity = 512u;
inline constexpr uint16_t kNoUtf16Index =
    (std::numeric_limits<uint16_t>::max)();
inline constexpr uint16_t kAsyncPressedMask = 0x8001u;
inline constexpr uint16_t kAsyncLowMask = 0x0001u;

template <typename T, size_t Capacity> struct FixedRing {
  static_assert(Capacity != 0u);
  std::array<T, Capacity> entries = {};
  size_t first = 0u;
  size_t count = 0u;
};

template <typename T, size_t Capacity>
inline T *PushFixedRing(FixedRing<T, Capacity> *ring) {
  if (ring == nullptr)
    return nullptr;
  size_t destination = 0u;
  if (ring->count < Capacity) {
    destination = (ring->first + ring->count) % Capacity;
    ++ring->count;
  } else {
    destination = ring->first;
    ring->first = (ring->first + 1u) % Capacity;
  }
  ring->entries[destination] = T{};
  return &ring->entries[destination];
}

template <typename T, size_t Capacity>
inline T *FixedRingAt(FixedRing<T, Capacity> *ring, size_t logical_index) {
  if (ring == nullptr || logical_index >= ring->count)
    return nullptr;
  return &ring->entries[(ring->first + logical_index) % Capacity];
}

template <typename T, size_t Capacity>
inline const T *FixedRingAt(const FixedRing<T, Capacity> &ring,
                            size_t logical_index) {
  if (logical_index >= ring.count)
    return nullptr;
  return &ring.entries[(ring.first + logical_index) % Capacity];
}

struct Rect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

inline bool IsSaneRect(const Rect &rect) {
  if (rect.width <= 0 || rect.height <= 0)
    return false;
  const int64_t right = static_cast<int64_t>(rect.x) + rect.width;
  const int64_t bottom = static_cast<int64_t>(rect.y) + rect.height;
  return right <= (std::numeric_limits<int32_t>::max)() &&
         right >= (std::numeric_limits<int32_t>::min)() &&
         bottom <= (std::numeric_limits<int32_t>::max)() &&
         bottom >= (std::numeric_limits<int32_t>::min)();
}

inline bool ContainsPoint(const Rect &rect, int32_t x, int32_t y) {
  if (!IsSaneRect(rect))
    return false;
  const int64_t right = static_cast<int64_t>(rect.x) + rect.width;
  const int64_t bottom = static_cast<int64_t>(rect.y) + rect.height;
  return x >= rect.x && y >= rect.y && static_cast<int64_t>(x) < right &&
         static_cast<int64_t>(y) < bottom;
}

inline constexpr bool IsHighSurrogate(char16_t code_unit) {
  return code_unit >= 0xd800u && code_unit <= 0xdbffu;
}

inline constexpr bool IsLowSurrogate(char16_t code_unit) {
  return code_unit >= 0xdc00u && code_unit <= 0xdfffu;
}

inline bool DecodeUtf16ScalarAt(const char16_t *text, size_t text_count,
                                size_t index, uint32_t *scalar,
                                uint16_t *width) {
  if (text == nullptr || scalar == nullptr || width == nullptr ||
      index >= text_count) {
    return false;
  }
  const char16_t first = text[index];
  if (IsLowSurrogate(first))
    return false;
  if (!IsHighSurrogate(first)) {
    *scalar = static_cast<uint32_t>(first);
    *width = 1u;
    return true;
  }
  if (index + 1u >= text_count || !IsLowSurrogate(text[index + 1u]))
    return false;
  *scalar = 0x10000u + ((static_cast<uint32_t>(first) - 0xd800u) << 10u) +
            (static_cast<uint32_t>(text[index + 1u]) - 0xdc00u);
  *width = 2u;
  return true;
}

// HUNEX/TYPEMOON story text uses <rREADING>BASE</r>. The renderer glyphs
// address the raw UTF-16 string, while lookup publication must address the
// BASE-only string. Projection is deliberately exact: every visible scalar
// has one glyph, every glyph names that scalar's raw UTF-16 start, and hidden
// reading/tag code units never acquire a mapping.
struct RawGlyph {
  uint16_t raw_index = kNoUtf16Index;
  uint16_t width = 0u;
  uint32_t scalar = 0u;
  Rect logical_bounds = {};
};

struct ProjectedGlyph {
  uint16_t raw_index = kNoUtf16Index;
  // UTF-16 code-unit start in normalized_text, not a Unicode scalar ordinal.
  uint16_t normalized_index = kNoUtf16Index;
  uint16_t width = 0u;
  uint32_t scalar = 0u;
  Rect logical_bounds = {};
};

struct RubyTextProjection {
  std::array<char16_t, kTextCapacity> normalized_text = {};
  uint16_t normalized_text_count = 0u;
  // Visible raw code units map one-to-one to their normalized code units.
  // Ruby readings and every tag code unit remain kNoUtf16Index.
  std::array<uint16_t, kTextCapacity> raw_to_normalized = {};
  std::array<ProjectedGlyph, kGlyphCapacity> glyphs = {};
  uint16_t glyph_count = 0u;
  bool had_ruby_markup = false;
};

inline void ClearRubyTextProjection(RubyTextProjection *projection) {
  if (projection == nullptr)
    return;
  *projection = {};
  projection->raw_to_normalized.fill(kNoUtf16Index);
}

inline bool IsClosingRubyTagAt(const char16_t *raw, size_t raw_count,
                               size_t index) {
  return raw != nullptr && index <= raw_count && raw_count - index >= 4u &&
         raw[index] == u'<' && raw[index + 1u] == u'/' &&
         raw[index + 2u] == u'r' && raw[index + 3u] == u'>';
}

inline bool IsProjectableTextScalar(uint32_t scalar) {
  return scalar != 0u && scalar != static_cast<uint32_t>(u'\r') &&
         scalar != static_cast<uint32_t>(u'\n');
}

struct RawTextLayoutGlyph {
  uint16_t raw_index = kNoUtf16Index;
  uint16_t width = 0u;
  uint32_t scalar = 0u;
};

struct RawTextLayout {
  std::array<RawTextLayoutGlyph, kGlyphCapacity> visible_glyphs = {};
  uint16_t visible_glyph_count = 0u;
};

inline bool AppendRawTextLayoutGlyph(size_t raw_index, uint16_t width,
                                     uint32_t scalar,
                                     RawTextLayout *layout) {
  if (layout == nullptr || raw_index >= kNoUtf16Index || width == 0u ||
      layout->visible_glyph_count >= kGlyphCapacity)
    return false;
  RawTextLayoutGlyph &glyph =
      layout->visible_glyphs[layout->visible_glyph_count++];
  glyph.raw_index = static_cast<uint16_t>(raw_index);
  glyph.width = width;
  glyph.scalar = scalar;
  return true;
}

// Parse the complete HUNEX story-line grammar into the exact sequence expected
// from the body renderer. A terminal ruby base glyph can be followed by the
// hidden </r> suffix, so arithmetic end-of-string checks are insufficient.
// Unknown or malformed markup fails closed; callers can then reject a skipped,
// duplicated, exposed-reading, or otherwise partial renderer traversal.
inline bool AnalyzeRawTextLayout(const char16_t *raw, size_t raw_count,
                                 RawTextLayout *layout) {
  if (layout == nullptr)
    return false;
  *layout = {};
  if (raw == nullptr || raw_count == 0u || raw_count > kTextCapacity ||
      raw_count > static_cast<size_t>(kNoUtf16Index)) {
    return false;
  }

  RawTextLayout candidate;
  size_t raw_index = 0u;
  while (raw_index < raw_count) {
    if (raw[raw_index] == u'>')
      return false;
    if (raw[raw_index] != u'<') {
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, raw_index, &scalar, &width) ||
          !IsProjectableTextScalar(scalar) ||
          !AppendRawTextLayoutGlyph(raw_index, width, scalar, &candidate)) {
        return false;
      }
      raw_index += width;
      continue;
    }

    if (raw_count - raw_index < 3u || raw[raw_index + 1u] != u'r')
      return false;
    const size_t reading_start = raw_index + 2u;
    size_t reading_end = reading_start;
    size_t reading_scalars = 0u;
    while (reading_end < raw_count && raw[reading_end] != u'>') {
      if (raw[reading_end] == u'<')
        return false;
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, reading_end, &scalar, &width) ||
          !IsProjectableTextScalar(scalar)) {
        return false;
      }
      reading_end += width;
      ++reading_scalars;
    }
    if (reading_scalars == 0u || reading_end >= raw_count)
      return false;

    size_t base_index = reading_end + 1u;
    size_t base_scalars = 0u;
    while (base_index < raw_count &&
           !IsClosingRubyTagAt(raw, raw_count, base_index)) {
      if (raw[base_index] == u'<' || raw[base_index] == u'>')
        return false;
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, base_index, &scalar, &width) ||
          !IsProjectableTextScalar(scalar) ||
          !AppendRawTextLayoutGlyph(base_index, width, scalar, &candidate)) {
        return false;
      }
      base_index += width;
      ++base_scalars;
    }
    if (base_scalars == 0u || !IsClosingRubyTagAt(raw, raw_count, base_index))
      return false;
    raw_index = base_index + 4u;
  }

  if (candidate.visible_glyph_count == 0u)
    return false;
  *layout = candidate;
  return true;
}

inline bool
AppendProjectedRawScalar(const char16_t *raw, size_t raw_count,
                         size_t raw_index, RubyTextProjection *candidate,
                         std::array<uint16_t, kTextCapacity> *visible_widths,
                         size_t *normalized_count, size_t *visible_count) {
  if (candidate == nullptr || visible_widths == nullptr ||
      normalized_count == nullptr || visible_count == nullptr)
    return false;
  uint32_t scalar = 0u;
  uint16_t width = 0u;
  if (!DecodeUtf16ScalarAt(raw, raw_count, raw_index, &scalar, &width) ||
      !IsProjectableTextScalar(scalar) ||
      *normalized_count + width > kTextCapacity ||
      raw_index + width > raw_count || (*visible_widths)[raw_index] != 0u) {
    return false;
  }
  (*visible_widths)[raw_index] = width;
  for (uint16_t offset = 0u; offset < width; ++offset) {
    candidate->normalized_text[*normalized_count + offset] =
        raw[raw_index + offset];
    candidate->raw_to_normalized[raw_index + offset] =
        static_cast<uint16_t>(*normalized_count + offset);
  }
  *normalized_count += width;
  ++*visible_count;
  return true;
}

inline bool ProjectRubyText(const char16_t *raw, size_t raw_count,
                            const RawGlyph *glyphs, size_t glyph_count,
                            RubyTextProjection *projection) {
  if (projection == nullptr)
    return false;
  ClearRubyTextProjection(projection);
  if (raw == nullptr || raw_count == 0u || raw_count > kTextCapacity ||
      glyphs == nullptr || glyph_count == 0u || glyph_count > kGlyphCapacity) {
    return false;
  }

  RubyTextProjection candidate;
  ClearRubyTextProjection(&candidate);
  std::array<uint16_t, kTextCapacity> visible_widths = {};
  std::array<uint8_t, kTextCapacity> covered = {};
  size_t normalized_count = 0u;
  size_t visible_count = 0u;

  size_t raw_index = 0u;
  while (raw_index < raw_count) {
    if (raw[raw_index] == u'>')
      return false;
    if (raw[raw_index] != u'<') {
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, raw_index, &scalar, &width) ||
          !AppendProjectedRawScalar(raw, raw_count, raw_index, &candidate,
                                    &visible_widths, &normalized_count,
                                    &visible_count)) {
        return false;
      }
      raw_index += width;
      continue;
    }

    // Any '<' outside this exact lower-case ruby opener is an unknown tag.
    if (raw_count - raw_index < 3u || raw[raw_index + 1u] != u'r')
      return false;
    candidate.had_ruby_markup = true;
    const size_t reading_start = raw_index + 2u;
    size_t reading_end = reading_start;
    size_t reading_scalars = 0u;
    while (reading_end < raw_count && raw[reading_end] != u'>') {
      if (raw[reading_end] == u'<')
        return false;
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, reading_end, &scalar, &width) ||
          !IsProjectableTextScalar(scalar)) {
        return false;
      }
      reading_end += width;
      ++reading_scalars;
    }
    if (reading_scalars == 0u || reading_end >= raw_count)
      return false;

    size_t base_index = reading_end + 1u;
    size_t base_scalars = 0u;
    while (base_index < raw_count &&
           !IsClosingRubyTagAt(raw, raw_count, base_index)) {
      if (raw[base_index] == u'<' || raw[base_index] == u'>')
        return false;
      uint32_t scalar = 0u;
      uint16_t width = 0u;
      if (!DecodeUtf16ScalarAt(raw, raw_count, base_index, &scalar, &width) ||
          !AppendProjectedRawScalar(raw, raw_count, base_index, &candidate,
                                    &visible_widths, &normalized_count,
                                    &visible_count)) {
        return false;
      }
      base_index += width;
      ++base_scalars;
    }
    if (base_scalars == 0u || !IsClosingRubyTagAt(raw, raw_count, base_index)) {
      return false;
    }
    raw_index = base_index + 4u;
  }

  // Exact coverage prevents accepting a plausible prefix when the renderer
  // dropped, duplicated, or exposed a reading/tag glyph.
  if (normalized_count == 0u || visible_count == 0u ||
      glyph_count != visible_count) {
    return false;
  }
  for (size_t glyph_index = 0u; glyph_index < glyph_count; ++glyph_index) {
    const RawGlyph &glyph = glyphs[glyph_index];
    if (glyph.raw_index == kNoUtf16Index || glyph.raw_index >= raw_count ||
        visible_widths[glyph.raw_index] == 0u ||
        covered[glyph.raw_index] != 0u || !IsSaneRect(glyph.logical_bounds)) {
      return false;
    }
    uint32_t expected_scalar = 0u;
    uint16_t expected_width = 0u;
    if (!DecodeUtf16ScalarAt(raw, raw_count, glyph.raw_index, &expected_scalar,
                             &expected_width) ||
        glyph.width != expected_width ||
        glyph.width != visible_widths[glyph.raw_index] ||
        glyph.scalar != expected_scalar ||
        candidate.raw_to_normalized[glyph.raw_index] == kNoUtf16Index) {
      return false;
    }
    covered[glyph.raw_index] = 1u;
    ProjectedGlyph &projected = candidate.glyphs[glyph_index];
    projected.raw_index = glyph.raw_index;
    projected.normalized_index = candidate.raw_to_normalized[glyph.raw_index];
    projected.width = glyph.width;
    projected.scalar = glyph.scalar;
    projected.logical_bounds = glyph.logical_bounds;
  }
  for (size_t index = 0u; index < raw_count; ++index) {
    if (visible_widths[index] != 0u && covered[index] == 0u)
      return false;
  }

  candidate.normalized_text_count = static_cast<uint16_t>(normalized_count);
  candidate.glyph_count = static_cast<uint16_t>(glyph_count);
  *projection = candidate;
  return true;
}

struct Glyph {
  // Both fields are UTF-16 code-unit units. A non-BMP scalar therefore has a
  // width of two, while BMP characters and combining code units have one.
  uint16_t utf16_index = kNoUtf16Index;
  uint16_t utf16_width = 0u;
  Rect rect = {};
};

enum class CapturePhase : uint8_t {
  kEmpty = 0,
  kBuilding = 1,
  kSealed = 2,
  kInvalid = 3,
};

struct Capture {
  uint64_t epoch = 0u;
  uint32_t render_thread_id = 0u;
  CapturePhase phase = CapturePhase::kEmpty;
  std::array<char16_t, kTextCapacity> text = {};
  uint16_t text_count = 0u;
  FixedRing<Glyph, kGlyphCapacity> glyphs = {};
};

using CaptureRing = FixedRing<Capture, kCaptureCapacity>;

inline void InvalidateCapture(Capture *capture) {
  if (capture == nullptr)
    return;
  capture->phase = CapturePhase::kInvalid;
  capture->glyphs.first = 0u;
  capture->glyphs.count = 0u;
}

inline bool IsValidLine(const char16_t *text, size_t text_count) {
  if (text == nullptr || text_count == 0u || text_count > kTextCapacity ||
      text_count > (std::numeric_limits<uint16_t>::max)()) {
    return false;
  }
  for (size_t index = 0u; index < text_count; ++index) {
    if (text[index] == u'\0')
      return false;
  }
  return true;
}

inline Capture *BeginCapture(CaptureRing *captures, uint64_t epoch,
                             uint32_t render_thread_id, const char16_t *text,
                             size_t text_count) {
  if (captures == nullptr || epoch == 0u || render_thread_id == 0u ||
      !IsValidLine(text, text_count)) {
    return nullptr;
  }
  Capture *capture = PushFixedRing(captures);
  if (capture == nullptr)
    return nullptr;
  capture->epoch = epoch;
  capture->render_thread_id = render_thread_id;
  capture->phase = CapturePhase::kBuilding;
  capture->text_count = static_cast<uint16_t>(text_count);
  for (size_t index = 0u; index < text_count; ++index) {
    capture->text[index] = text[index];
  }
  return capture;
}

inline bool IsValidUtf16GlyphSpan(const Capture &capture, uint16_t utf16_index,
                                  uint16_t utf16_width) {
  if (capture.phase != CapturePhase::kBuilding || utf16_width == 0u ||
      utf16_width > 2u || utf16_index >= capture.text_count ||
      static_cast<size_t>(utf16_index) + utf16_width > capture.text_count) {
    return false;
  }
  const char16_t first = capture.text[utf16_index];
  if (first == u'\0' || first == u'\r' || first == u'\n')
    return false;
  if (utf16_width == 1u) {
    return !IsHighSurrogate(first) && !IsLowSurrogate(first);
  }
  return IsHighSurrogate(first) &&
         IsLowSurrogate(capture.text[utf16_index + 1u]);
}

// Any malformed glyph invalidates the whole in-progress capture. Keeping a
// plausible prefix would make a partially decoded renderer line look exact.
inline bool AppendGlyph(Capture *capture, uint32_t render_thread_id,
                        uint16_t utf16_index, uint16_t utf16_width,
                        const Rect &rect) {
  if (capture == nullptr)
    return false;
  if (render_thread_id == 0u || render_thread_id != capture->render_thread_id ||
      !IsValidUtf16GlyphSpan(*capture, utf16_index, utf16_width) ||
      !IsSaneRect(rect)) {
    InvalidateCapture(capture);
    return false;
  }
  Glyph *glyph = PushFixedRing(&capture->glyphs);
  if (glyph == nullptr) {
    InvalidateCapture(capture);
    return false;
  }
  glyph->utf16_index = utf16_index;
  glyph->utf16_width = utf16_width;
  glyph->rect = rect;
  return true;
}

inline bool SealCapture(Capture *capture, uint32_t render_thread_id) {
  if (capture == nullptr || capture->phase != CapturePhase::kBuilding ||
      render_thread_id == 0u || render_thread_id != capture->render_thread_id ||
      capture->glyphs.count == 0u) {
    InvalidateCapture(capture);
    return false;
  }
  capture->phase = CapturePhase::kSealed;
  return true;
}

inline const Capture *FindSealedCapture(const CaptureRing &captures,
                                        uint64_t epoch) {
  if (epoch == 0u)
    return nullptr;
  const Capture *match = nullptr;
  for (size_t index = 0u; index < captures.count; ++index) {
    const Capture *candidate = FixedRingAt(captures, index);
    if (candidate == nullptr || candidate->phase != CapturePhase::kSealed ||
        candidate->epoch != epoch) {
      continue;
    }
    // Epoch identity must be unique inside the live ring. Ambiguity is not
    // resolved by recency because the click transaction freezes this identity.
    if (match != nullptr)
      return nullptr;
    match = candidate;
  }
  return match;
}

enum class HitStatus : uint8_t {
  kInvalidCapture = 0,
  kMiss = 1,
  kHit = 2,
  kAmbiguous = 3,
};

struct Hit {
  bool valid = false;
  uint64_t capture_epoch = 0u;
  uint32_t render_thread_id = 0u;
  uint16_t utf16_index = kNoUtf16Index;
  uint16_t utf16_width = 0u;
  uint16_t line_utf16_count = 0u;
  Rect rect = {};
};

inline bool SameUtf16Span(const Hit &hit, const Glyph &glyph) {
  return hit.utf16_index == glyph.utf16_index &&
         hit.utf16_width == glyph.utf16_width;
}

inline HitStatus HitTest(const Capture &capture, int32_t cursor_x,
                         int32_t cursor_y, Hit *hit) {
  if (hit != nullptr)
    *hit = {};
  if (capture.phase != CapturePhase::kSealed || capture.epoch == 0u ||
      capture.render_thread_id == 0u || capture.text_count == 0u ||
      capture.glyphs.count == 0u) {
    return HitStatus::kInvalidCapture;
  }

  Hit candidate;
  bool found = false;
  for (size_t index = 0u; index < capture.glyphs.count; ++index) {
    const Glyph *glyph = FixedRingAt(capture.glyphs, index);
    if (glyph == nullptr || !ContainsPoint(glyph->rect, cursor_x, cursor_y)) {
      continue;
    }
    if (!found) {
      candidate.valid = true;
      candidate.capture_epoch = capture.epoch;
      candidate.render_thread_id = capture.render_thread_id;
      candidate.utf16_index = glyph->utf16_index;
      candidate.utf16_width = glyph->utf16_width;
      candidate.line_utf16_count = capture.text_count;
      candidate.rect = glyph->rect;
      found = true;
      continue;
    }
    if (!SameUtf16Span(candidate, *glyph)) {
      if (hit != nullptr)
        *hit = {};
      return HitStatus::kAmbiguous;
    }
  }
  if (!found)
    return HitStatus::kMiss;
  if (hit != nullptr)
    *hit = candidate;
  return HitStatus::kHit;
}

enum class ClickOwner : uint8_t {
  kIdle = 0,
  kPassThrough = 1,
  kLookup = 2,
  kPopup = 3,
};

struct ClickSampleState {
  // The exact admitted callsite may move between engine threads during a scene
  // transition. The atomic flag serializes its sampled transaction; the thread
  // id is diagnostic rather than a permanent owner latch.
  std::atomic_flag busy = ATOMIC_FLAG_INIT;
  std::atomic<uint32_t> bound_thread_id{0u};
  std::atomic<bool> thread_conflict{false};
  bool synchronized = false;
  bool last_high_down = false;
  ClickOwner owner = ClickOwner::kIdle;
  Hit frozen_hit = {};
};

struct ClickDecision {
  bool begin = false;
  bool submit = false;
  bool consume = false;
  bool popup_transaction = false;
  bool thread_conflict = false;
  Hit hit = {};
};

inline void ClearClickTransaction(ClickSampleState *state) {
  if (state == nullptr)
    return;
  state->owner = ClickOwner::kIdle;
  state->frozen_hit = {};
}

// Reset is a worker lifecycle operation. A callback already owns the state only
// delays recovery until the next worker tick; it is not a new sensor conflict.
inline bool ResetClickSampleState(ClickSampleState *state) {
  if (state == nullptr)
    return false;
  if (state->busy.test_and_set(std::memory_order_acquire)) {
    return false;
  }
  state->bound_thread_id.store(0u, std::memory_order_relaxed);
  state->thread_conflict.store(false, std::memory_order_relaxed);
  state->synchronized = false;
  state->last_high_down = false;
  ClearClickTransaction(state);
  state->busy.clear(std::memory_order_release);
  return true;
}

inline bool BindClickThreadLocked(uint32_t sample_thread_id,
                                  ClickSampleState *state) {
  if (state == nullptr || sample_thread_id == 0u ||
      state->thread_conflict.load(std::memory_order_acquire)) {
    return false;
  }
  state->bound_thread_id.store(sample_thread_id, std::memory_order_relaxed);
  return true;
}

inline bool IsUsableHit(const Hit *hit, uint64_t current_capture_epoch) {
  return hit != nullptr && hit->valid && hit->capture_epoch != 0u &&
         hit->capture_epoch == current_capture_epoch &&
         hit->utf16_index != kNoUtf16Index && hit->utf16_width != 0u &&
         static_cast<uint32_t>(hit->utf16_index) + hit->utf16_width <=
             hit->line_utf16_count &&
         IsSaneRect(hit->rect);
}

// This is a sampled GetAsyncKeyState transaction, not a message stream. A high
// bit owns down/hold/up; a low-bit-only sample is a complete quick tap. Misses
// remain pass-through for the whole physical transaction. Lookup/popup owners
// consume both 0x8000 and 0x0001, and only a lookup-owned matching up submits.
inline ClickDecision AdvanceClickSampleLocked(uint32_t sample_thread_id,
                                              uint16_t raw, bool lookup_enabled,
                                              bool popup_visible,
                                              const Hit *hit,
                                              uint64_t current_capture_epoch,
                                              ClickSampleState *state) {
  ClickDecision decision;
  if (!BindClickThreadLocked(sample_thread_id, state)) {
    if (state != nullptr) {
      decision.thread_conflict =
          state->thread_conflict.load(std::memory_order_acquire);
    }
    return decision;
  }

  const bool high_down = (raw & 0x8000u) != 0u;
  const bool pressed_since_poll = (raw & 0x0001u) != 0u;
  const bool active = high_down || pressed_since_poll;

  if (!state->synchronized) {
    state->last_high_down = high_down;
    if (!active)
      state->synchronized = true;
    // A popup already owns user input. Shield it even while waiting for the
    // first all-clear sample, but never synthesize a lookup from half a click.
    if (popup_visible && active) {
      decision.begin = true;
      decision.consume = true;
      decision.popup_transaction = true;
      if (high_down) {
        state->synchronized = true;
        state->owner = ClickOwner::kPopup;
      }
    }
    return decision;
  }

  // If an up was lost (capture loss/alt-tab), a later 0x8001 is a new press,
  // not a continuation of the stale latch. Re-evaluate that press below.
  const bool healed_stale_press = state->owner != ClickOwner::kIdle &&
                                  high_down && pressed_since_poll &&
                                  state->last_high_down;
  if (healed_stale_press) {
    ClearClickTransaction(state);
  }

  if (state->owner != ClickOwner::kIdle) {
    const ClickOwner owner = state->owner;
    const Hit frozen = state->frozen_hit;
    decision.consume =
        owner == ClickOwner::kLookup || owner == ClickOwner::kPopup;
    decision.popup_transaction = owner == ClickOwner::kPopup;
    if (owner == ClickOwner::kLookup)
      decision.hit = frozen;
    if (!high_down) {
      decision.submit = owner == ClickOwner::kLookup && lookup_enabled &&
                        frozen.valid &&
                        frozen.capture_epoch == current_capture_epoch;
      ClearClickTransaction(state);
    }
    state->last_high_down = high_down;
    return decision;
  }

  const bool fresh_press = healed_stale_press ||
                           (high_down && !state->last_high_down) ||
                           (!high_down && pressed_since_poll);
  if (!fresh_press) {
    state->last_high_down = high_down;
    return decision;
  }

  if (popup_visible) {
    decision.begin = true;
    decision.consume = true;
    decision.popup_transaction = true;
    if (high_down)
      state->owner = ClickOwner::kPopup;
  } else if (lookup_enabled && IsUsableHit(hit, current_capture_epoch)) {
    decision.begin = true;
    decision.consume = true;
    decision.hit = *hit;
    if (high_down) {
      state->owner = ClickOwner::kLookup;
      state->frozen_hit = *hit;
    } else {
      decision.submit = true;
    }
  } else if (high_down) {
    state->owner = ClickOwner::kPassThrough;
  }
  state->last_high_down = high_down;
  return decision;
}

inline ClickDecision AdvanceClickSample(uint32_t sample_thread_id, uint16_t raw,
                                        bool lookup_enabled, bool popup_visible,
                                        const Hit *hit,
                                        uint64_t current_capture_epoch,
                                        ClickSampleState *state) {
  ClickDecision decision;
  if (state == nullptr)
    return decision;
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    decision.thread_conflict = true;
    return decision;
  }
  // A detour callback must not wait on another engine thread. Contention is
  // itself proof that one sampled transaction cannot be reconstructed safely.
  if (state->busy.test_and_set(std::memory_order_acquire)) {
    state->thread_conflict.store(true, std::memory_order_release);
    decision.thread_conflict = true;
    return decision;
  }
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    ClearClickTransaction(state);
    state->synchronized = false;
    state->last_high_down = false;
    decision.thread_conflict = true;
  } else {
    decision = AdvanceClickSampleLocked(sample_thread_id, raw, lookup_enabled,
                                        popup_visible, hit,
                                        current_capture_epoch, state);
  }
  // A competing callback can poison the gate while this owner is evaluating.
  // Suppress that in-flight result too, so contention cannot leak one submit.
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    ClearClickTransaction(state);
    state->synchronized = false;
    state->last_high_down = false;
    decision = {};
    decision.thread_conflict = true;
  }
  state->busy.clear(std::memory_order_release);
  return decision;
}

inline uint16_t FilterAsyncKeyState(uint16_t raw, bool consume) {
  return consume ? static_cast<uint16_t>(raw & ~kAsyncPressedMask) : raw;
}

struct ShiftSampleState {
  std::atomic_flag busy = ATOMIC_FLAG_INIT;
  std::atomic<uint32_t> bound_thread_id{0u};
  std::atomic<bool> thread_conflict{false};
  uint64_t activation_epoch = 0u;
  bool synchronized = false;
  bool last_high_down = false;
};

struct ShiftDecision {
  bool submit = false;
  bool thread_conflict = false;
};

inline bool ResetShiftSampleState(ShiftSampleState *state) {
  if (state == nullptr)
    return false;
  if (state->busy.test_and_set(std::memory_order_acquire)) {
    return false;
  }
  state->bound_thread_id.store(0u, std::memory_order_relaxed);
  state->thread_conflict.store(false, std::memory_order_relaxed);
  state->activation_epoch = 0u;
  state->synchronized = false;
  state->last_high_down = false;
  state->busy.clear(std::memory_order_release);
  return true;
}

inline bool BindShiftThreadLocked(uint32_t sample_thread_id,
                                  ShiftSampleState *state) {
  if (state == nullptr || sample_thread_id == 0u ||
      state->thread_conflict.load(std::memory_order_acquire)) {
    return false;
  }
  state->bound_thread_id.store(sample_thread_id, std::memory_order_relaxed);
  return true;
}

// Activation epochs prevent replaying a Shift tap/hold that occurred while the
// feature was disabled or while the sensor was reinstalled. The low bit still
// preserves a complete press/release that happens between two active polls.
inline ShiftDecision AdvanceShiftSampleLocked(uint32_t sample_thread_id,
                                              uint16_t raw,
                                              uint64_t activation_epoch,
                                              ShiftSampleState *state) {
  ShiftDecision decision;
  if (!BindShiftThreadLocked(sample_thread_id, state)) {
    if (state != nullptr) {
      decision.thread_conflict =
          state->thread_conflict.load(std::memory_order_acquire);
    }
    return decision;
  }
  if (activation_epoch == 0u) {
    state->activation_epoch = 0u;
    state->synchronized = false;
    state->last_high_down = false;
    return decision;
  }
  const bool high_down = (raw & 0x8000u) != 0u;
  if (!state->synchronized || state->activation_epoch != activation_epoch) {
    state->activation_epoch = activation_epoch;
    state->synchronized = true;
    state->last_high_down = high_down;
    return decision;
  }
  const bool pressed_since_poll = (raw & 0x0001u) != 0u;
  decision.submit = (high_down && !state->last_high_down) ||
                    (!high_down && pressed_since_poll);
  state->last_high_down = high_down;
  return decision;
}

inline ShiftDecision AdvanceShiftSample(uint32_t sample_thread_id, uint16_t raw,
                                        uint64_t activation_epoch,
                                        ShiftSampleState *state) {
  ShiftDecision decision;
  if (state == nullptr)
    return decision;
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    decision.thread_conflict = true;
    return decision;
  }
  if (state->busy.test_and_set(std::memory_order_acquire)) {
    state->thread_conflict.store(true, std::memory_order_release);
    decision.thread_conflict = true;
    return decision;
  }
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    state->activation_epoch = 0u;
    state->synchronized = false;
    state->last_high_down = false;
    decision.thread_conflict = true;
  } else {
    decision = AdvanceShiftSampleLocked(sample_thread_id, raw, activation_epoch,
                                        state);
  }
  if (state->thread_conflict.load(std::memory_order_acquire)) {
    state->activation_epoch = 0u;
    state->synchronized = false;
    state->last_high_down = false;
    decision = {};
    decision.thread_conflict = true;
  }
  state->busy.clear(std::memory_order_release);
  return decision;
}

} // namespace fushi_voice_hook::hunex_lookup_core

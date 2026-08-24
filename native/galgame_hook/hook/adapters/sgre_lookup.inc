// SGRE in-game lookup sensor. The executable identity gate lives in
// sgre_profile.h. UserHook1 (0x328e0) is a pre-layout stream: it can run ahead
// of the visible dialogue and still contains MAGES controls. The sensor hooks
// the admitted draw boundary instead, copies the renderer's flattened visible
// glyph vector, and therefore receives both game-parsed text and live geometry.
// UTF-8 conversion, cursor polling and IPC publication stay on HookWorker.

constexpr size_t kSgreLookupCaptureSlots = 4;
constexpr size_t kSgreLookupMaxTextUnits = 512;
constexpr size_t kSgreLookupMaxGlyphs = 512;
constexpr size_t kSgreLookupMaxLines = 8;
constexpr size_t kSgreDrawLineHeightOffset = 0x208;
constexpr size_t kSgreDrawGlyphsBeginOffset = 0x2d0;
constexpr size_t kSgreDrawGlyphsEndOffset = 0x2d8;
constexpr size_t kSgreDrawVisibleGlyphsOffset = 0x3cc;
constexpr size_t kSgreGlyphCharacterOffset = 0x00;
// TextDraw +0x202/+0x22b forms the actual per-glyph draw point from 0x40/0x44.
// glyph+0x94 is only the pre-draw layout advance. It advances 25 units while
// the rendered Japanese cells advance 80, so it must never drive hit testing.
constexpr size_t kSgreGlyphDrawXOffset = 0x40;
constexpr size_t kSgreGlyphDrawYOffset = 0x44;
constexpr size_t kSgreGlyphWidthOffset = 0x48;
constexpr size_t kSgreGlyphHeightOffset = 0x4c;

struct SgreLookupCapture {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  uint32_t text_units = 0;
  uint32_t glyph_count = 0;
  float line_height = 0.0f;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
  fushi_voice_hook::SgreLookupGlyphGeometry glyphs[kSgreLookupMaxGlyphs] = {};
};

using SgreTextDrawFn = void(__fastcall*)(void*);

SgreTextDrawFn g_sgre_text_draw_original = nullptr;
const void* g_sgre_scenario_text_vtable = nullptr;
SgreLookupCapture g_sgre_lookup_captures[kSgreLookupCaptureSlots] = {};
volatile LONG64 g_sgre_lookup_capture_count = 0;
uint64_t g_sgre_lookup_processed_seq = 0;
bool g_sgre_lookup_last_shift_down = false;
SgreLookupCapture g_sgre_lookup_active_capture = {};
std::wstring g_sgre_lookup_active_line;
uint32_t g_sgre_lookup_active_char_indices[kSgreLookupMaxGlyphs] = {};
size_t g_sgre_lookup_active_mapped = 0;
bool g_sgre_lookup_active_valid = false;

enum class SgreLookupCaptureResult : uint32_t {
  kOk = 0,
  kNullInput = 1,
  kGlyphVectorPointer = 2,
  kGlyphVectorShape = 3,
  kVisibleGlyphCount = 4,
  kGlyphPointer = 5,
  kGlyphCharacter = 6,
  kGlyphX = 7,
  kGlyphWidth = 8,
  kGlyphHeight = 9,
  kLineCount = 10,
  kException = 11,
  kNoGlyphs = 12,
  kSurfaceClass = 13,
  kSurfaceMetrics = 14,
  kGlyphY = 15,
};

SgreLookupCaptureResult CopySgreLookupDrawState(void* text_surface,
                                                SgreLookupCapture* capture) {
  if (text_surface == nullptr || capture == nullptr) {
    return SgreLookupCaptureResult::kNullInput;
  }
  __try {
    const auto* object = static_cast<const uint8_t*>(text_surface);
    if (*reinterpret_cast<const void* const*>(object) !=
        g_sgre_scenario_text_vtable) {
      return SgreLookupCaptureResult::kSurfaceClass;
    }
    const float line_height =
        *reinterpret_cast<const float*>(object + kSgreDrawLineHeightOffset);
    const auto* glyphs_begin =
        *reinterpret_cast<const uint8_t* const*>(
            object + kSgreDrawGlyphsBeginOffset);
    const auto* glyphs_end =
        *reinterpret_cast<const uint8_t* const*>(
            object + kSgreDrawGlyphsEndOffset);
    const int32_t visible_glyphs =
        *reinterpret_cast<const int32_t*>(object +
                                         kSgreDrawVisibleGlyphsOffset);
    if (visible_glyphs <= 0) return SgreLookupCaptureResult::kNoGlyphs;
    if (glyphs_begin == nullptr || glyphs_end == nullptr ||
        glyphs_end < glyphs_begin) {
      return SgreLookupCaptureResult::kGlyphVectorPointer;
    }
    const size_t glyph_bytes =
        static_cast<size_t>(glyphs_end - glyphs_begin);
    if (glyph_bytes % sizeof(void*) != 0 ||
        glyph_bytes / sizeof(void*) > kSgreLookupMaxGlyphs) {
      return SgreLookupCaptureResult::kGlyphVectorShape;
    }
    const size_t glyph_count = glyph_bytes / sizeof(void*);
    if (static_cast<size_t>(visible_glyphs) > glyph_count ||
        visible_glyphs > static_cast<int32_t>(kSgreLookupMaxGlyphs)) {
      return SgreLookupCaptureResult::kVisibleGlyphCount;
    }

    uint16_t line = 0;
    float previous_x = 0.0f;
    bool has_horizontal_advance = false;
    float first_glyph_height = 0.0f;
    for (int32_t i = 0; i < visible_glyphs; ++i) {
      const auto* glyph = *reinterpret_cast<const uint8_t* const*>(
          glyphs_begin + static_cast<size_t>(i) * sizeof(void*));
      if (glyph == nullptr) return SgreLookupCaptureResult::kGlyphPointer;
      const wchar_t character =
          *reinterpret_cast<const wchar_t*>(glyph + kSgreGlyphCharacterOffset);
      if (character == L'\0') {
        return SgreLookupCaptureResult::kGlyphCharacter;
      }
      fushi_voice_hook::SgreLookupGlyphGeometry geometry;
      geometry.x =
          *reinterpret_cast<const float*>(glyph + kSgreGlyphDrawXOffset);
      geometry.y =
          *reinterpret_cast<const float*>(glyph + kSgreGlyphDrawYOffset);
      geometry.width =
          *reinterpret_cast<const float*>(glyph + kSgreGlyphWidthOffset);
      geometry.height =
          *reinterpret_cast<const float*>(glyph + kSgreGlyphHeightOffset);
      if (i == 0) first_glyph_height = geometry.height;
      if (i != 0 && std::isfinite(previous_x) &&
          std::isfinite(geometry.x) && geometry.x > previous_x) {
        has_horizontal_advance = true;
      }
      if (i != 0 && fushi_voice_hook::StartsNextSgreLookupLine(
                        previous_x, geometry.x)) {
        ++line;
      }
      if (line >= kSgreLookupMaxLines) {
        return SgreLookupCaptureResult::kLineCount;
      }
      geometry.line = line;
      if (!std::isfinite(geometry.x) || geometry.x < -64.0f ||
          geometry.x > 4096.0f) {
        return SgreLookupCaptureResult::kGlyphX;
      }
      if (!std::isfinite(geometry.y) || geometry.y < -64.0f ||
          geometry.y > 2048.0f) {
        return SgreLookupCaptureResult::kGlyphY;
      }
      if (!std::isfinite(geometry.width) || geometry.width <= 0.0f ||
          geometry.width > 256.0f) {
        return SgreLookupCaptureResult::kGlyphWidth;
      }
      if (!std::isfinite(geometry.height) || geometry.height <= 0.0f ||
          geometry.height > 256.0f) {
        return SgreLookupCaptureResult::kGlyphHeight;
      }
      capture->text[i] = character;
      capture->glyphs[i] = geometry;
      previous_x = geometry.x;
    }
    if (!fushi_voice_hook::MatchesSgreScenarioDrawMetrics(
            line_height, first_glyph_height, has_horizontal_advance)) {
      return SgreLookupCaptureResult::kSurfaceMetrics;
    }
    capture->text_units = static_cast<uint32_t>(visible_glyphs);
    capture->glyph_count = static_cast<uint32_t>(visible_glyphs);
    capture->line_height = line_height;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return SgreLookupCaptureResult::kException;
  }
  return SgreLookupCaptureResult::kOk;
}

bool IsSgreLookupCaptureFault(SgreLookupCaptureResult result) {
  switch (result) {
    case SgreLookupCaptureResult::kNullInput:
    case SgreLookupCaptureResult::kGlyphVectorPointer:
    case SgreLookupCaptureResult::kGlyphVectorShape:
    case SgreLookupCaptureResult::kVisibleGlyphCount:
    case SgreLookupCaptureResult::kGlyphPointer:
    case SgreLookupCaptureResult::kGlyphCharacter:
    case SgreLookupCaptureResult::kGlyphX:
    case SgreLookupCaptureResult::kGlyphY:
    case SgreLookupCaptureResult::kGlyphWidth:
    case SgreLookupCaptureResult::kGlyphHeight:
    case SgreLookupCaptureResult::kException:
      return true;
    default:
      return false;
  }
}

void CaptureSgreLookupDrawState(void* text_surface) {
  const bool capture_requested =
      !g_stop && g_header != nullptr &&
      fushi_voice_hook::HasLookupRegion(g_header) &&
      g_header->lookup_enabled != 0;
  if (!capture_requested) return;
  SgreLookupCapture snapshot;
  const SgreLookupCaptureResult capture_result =
      CopySgreLookupDrawState(text_surface, &snapshot);
  if (capture_result == SgreLookupCaptureResult::kOk) {
    snapshot.valid = 1;
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  } else {
    if (IsSgreLookupCaptureFault(capture_result)) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorFault;
    }
    return;
  }
  const uint64_t seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_capture_count)));
  SgreLookupCapture* capture =
      &g_sgre_lookup_captures[seq % kSgreLookupCaptureSlots];
  InterlockedExchange64(&capture->seq, 0);
  capture->valid = snapshot.valid;
  capture->text_units = snapshot.text_units;
  capture->glyph_count = snapshot.glyph_count;
  capture->line_height = snapshot.line_height;
  if (snapshot.text_units != 0) {
    memcpy(capture->text, snapshot.text,
           static_cast<size_t>(snapshot.text_units) * sizeof(wchar_t));
  }
  if (snapshot.glyph_count != 0) {
    memcpy(capture->glyphs, snapshot.glyphs,
           static_cast<size_t>(snapshot.glyph_count) *
               sizeof(capture->glyphs[0]));
  }
  InterlockedExchange64(&capture->seq, static_cast<LONG64>(seq));
}

void __fastcall SgreTextDrawDetour(void* text_surface) {
  CaptureSgreLookupDrawState(text_surface);
  if (g_sgre_text_draw_original != nullptr) {
    g_sgre_text_draw_original(text_surface);
  }
}

bool InstallSgreLookupSensor() {
  if (g_sgre_text_draw_original != nullptr) {
    if (g_header != nullptr) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorInstalled;
    }
    return true;
  }
  HMODULE executable = GetModuleHandleW(nullptr);
  if (executable == nullptr) return false;
  auto* target =
      reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(executable) +
                              fushi_voice_hook::kSgreTextDrawRva);
  g_sgre_scenario_text_vtable =
      reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(executable) +
                              fushi_voice_hook::kSgreScenarioTextVtableRva);
  const bool installed =
      HookFn(target, reinterpret_cast<void*>(&SgreTextDrawDetour),
             reinterpret_cast<void**>(&g_sgre_text_draw_original));
  if (installed && g_header != nullptr) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorInstalled;
  }
  return installed;
}

bool ReadLatestSgreLookupCapture(SgreLookupCapture* copy, uint64_t* seq) {
  if (copy == nullptr || seq == nullptr) return false;
  const uint64_t latest = static_cast<uint64_t>(InterlockedCompareExchange64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_capture_count), 0, 0));
  if (latest == 0 || latest == g_sgre_lookup_processed_seq) return false;
  SgreLookupCapture* source =
      &g_sgre_lookup_captures[latest % kSgreLookupCaptureSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != latest) return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0) return false;
  *seq = latest;
  return true;
}

void PublishSgreLookupHit(const std::wstring& line, uint32_t char_index,
                          const fushi_voice_hook::SgreLookupRect& rect,
                          int32_t client_width, int32_t client_height) {
  if (g_header == nullptr || char_index >= line.size()) return;
  fushi_voice_hook::LookupHitSlot* slot =
      fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr) return;
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, line.data(), static_cast<int>(line.size()), utf8,
      static_cast<int>(sizeof(utf8)), nullptr, nullptr);
  if (bytes <= 0) return;
  const uint64_t next =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64*>(&g_header->lookup_hit_count), 0,
          0)) +
      1u;
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&slot->seq), 0);
  slot->char_index = char_index;
  slot->char_count = static_cast<uint32_t>(line.size());
  slot->glyph_x = rect.x;
  slot->glyph_y = rect.y;
  slot->glyph_w = rect.width;
  slot->glyph_h = rect.height;
  slot->view_w = client_width;
  slot->view_h = client_height;
  slot->flags = fushi_voice_hook::kLookupHitFlagSubmit;
  memcpy(slot->line_utf8, utf8, static_cast<size_t>(bytes));
  slot->line_bytes = static_cast<uint32_t>(bytes);
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&slot->seq),
                        static_cast<LONG64>(next));
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&g_header->lookup_hit_count),
      static_cast<LONG64>(next));
  g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved |
                           fushi_voice_hook::kLookupDiagHitSubmitted;
}

void ProcessSgreLookupTick() {
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header)) {
    return;
  }
  if (g_header->lookup_enabled == 0) {
    g_sgre_lookup_last_shift_down = false;
    g_sgre_lookup_active_valid = false;
    g_sgre_lookup_active_line.clear();
    g_sgre_lookup_active_mapped = 0;
    return;
  }
  if (!InstallSgreLookupSensor()) return;

  SgreLookupCapture capture;
  uint64_t capture_seq = 0;
  if (ReadLatestSgreLookupCapture(&capture, &capture_seq)) {
    g_sgre_lookup_processed_seq = capture_seq;
    if (capture.valid == 1 && capture.text_units != 0 &&
        capture.text_units == capture.glyph_count) {
      memcpy(&g_sgre_lookup_active_capture, &capture, sizeof(capture));
      g_sgre_lookup_active_line.assign(
          capture.text, capture.text + capture.text_units);
      for (size_t i = 0; i < capture.glyph_count; ++i) {
        // Draw-state characters are already game-parsed and are exactly
        // one-to-one with the flattened visible glyph vector.
        g_sgre_lookup_active_char_indices[i] = static_cast<uint32_t>(i);
      }
      g_sgre_lookup_active_mapped = capture.glyph_count;
      g_sgre_lookup_active_valid = true;
    }
  }

  const uint16_t shift_state =
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT));
  const bool submit = fushi_voice_hook::ConsumeSgreLookupShiftSample(
      shift_state, &g_sgre_lookup_last_shift_down);
  if (!g_sgre_lookup_active_valid || g_sgre_lookup_active_mapped == 0) return;
  const SgreLookupCapture& active = g_sgre_lookup_active_capture;

  HWND game = FindGameMainWindow();
  RECT client = {};
  POINT cursor = {};
  if (game == nullptr || !GetClientRect(game, &client) ||
      !GetCursorPos(&cursor) || !ScreenToClient(game, &cursor)) {
    return;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  fushi_voice_hook::SgreLookupRect hit_rect;
  const int glyph_index = fushi_voice_hook::FindSgreLookupGlyph(
      active.glyphs, active.glyph_count, client_width, client_height, cursor.x,
      cursor.y, &hit_rect);

  if (submit && glyph_index >= 0) {
    PublishSgreLookupHit(g_sgre_lookup_active_line,
                         g_sgre_lookup_active_char_indices[glyph_index],
                         hit_rect, client_width, client_height);
  }
}

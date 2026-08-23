// SGRE in-game lookup sensor. The executable identity gate lives in
// sgre_profile.h; this file only knows the one admitted TextRender layout.
// The detour copies bounded POD snapshots after the original returns. UTF-8
// conversion, cursor polling and IPC publication stay on HookWorker.

constexpr size_t kSgreLookupCaptureSlots = 4;
constexpr size_t kSgreLookupMaxTextUnits = 512;
constexpr size_t kSgreLookupMaxGlyphs = 512;
constexpr size_t kSgreLookupMaxLines = 8;
constexpr size_t kSgreLookupLineStride = 0x48;

struct SgreLookupCapture {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  uint32_t text_units = 0;
  uint32_t glyph_count = 0;
  float line_height = 0.0f;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
  fushi_voice_hook::SgreLookupGlyphGeometry glyphs[kSgreLookupMaxGlyphs] = {};
};

struct SgreLookupEntryText {
  uint32_t text_units = 0;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
};

using SgreTextLayoutFn = bool(__fastcall*)(void*, const wchar_t*, int, int,
                                           int);

SgreTextLayoutFn g_sgre_text_layout_original = nullptr;
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
  kTextLength = 2,
  kLinesPointer = 3,
  kLinesShape = 4,
  kRingShape = 5,
  kGlyphPointer = 6,
  kGlyphX = 7,
  kGlyphWidth = 8,
  kGlyphHeight = 9,
  kException = 10,
  kNoGlyphs = 11,
};

SgreLookupCaptureResult CopySgreLookupEntryText(
    const wchar_t* text, SgreLookupEntryText* snapshot) {
  if (text == nullptr || snapshot == nullptr) {
    return SgreLookupCaptureResult::kNullInput;
  }
  uint32_t text_units = 0;
  __try {
    while (text_units < kSgreLookupMaxTextUnits && text[text_units] != L'\0') {
      snapshot->text[text_units] = text[text_units];
      ++text_units;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return SgreLookupCaptureResult::kException;
  }
  if (text_units == 0 || text_units == kSgreLookupMaxTextUnits) {
    return SgreLookupCaptureResult::kTextLength;
  }
  snapshot->text_units = text_units;
  return SgreLookupCaptureResult::kOk;
}

SgreLookupCaptureResult CopySgreLookupGeometry(void* text_render,
                                               SgreLookupCapture* capture) {
  if (text_render == nullptr || capture == nullptr) {
    return SgreLookupCaptureResult::kNullInput;
  }
  uint32_t glyph_count = 0;
  float line_height = 0.0f;
  __try {
    const auto* object = static_cast<const uint8_t*>(text_render);
    line_height = *reinterpret_cast<const float*>(object + 0x158);
    const auto* lines_begin =
        *reinterpret_cast<const uint8_t* const*>(object + 0x208);
    const auto* lines_end =
        *reinterpret_cast<const uint8_t* const*>(object + 0x210);
    if (lines_begin == nullptr || lines_end < lines_begin) {
      return SgreLookupCaptureResult::kLinesPointer;
    }
    const size_t lines_bytes = static_cast<size_t>(lines_end - lines_begin);
    if (lines_bytes == 0 || lines_bytes % kSgreLookupLineStride != 0 ||
        lines_bytes / kSgreLookupLineStride > kSgreLookupMaxLines) {
      return SgreLookupCaptureResult::kLinesShape;
    }

    const size_t line_count = lines_bytes / kSgreLookupLineStride;
    for (size_t line = 0; line < line_count; ++line) {
      const uint8_t* row = lines_begin + line * kSgreLookupLineStride;
      auto* glyph_ring = *reinterpret_cast<void* const* const*>(row + 0x08);
      const uint64_t ring_capacity =
          *reinterpret_cast<const uint64_t*>(row + 0x10);
      const uint64_t ring_begin =
          *reinterpret_cast<const uint64_t*>(row + 0x18);
      const uint64_t ring_size = *reinterpret_cast<const uint64_t*>(row + 0x20);
      if (ring_size == 0) continue;
      if (glyph_ring == nullptr || ring_capacity == 0 ||
          (ring_capacity & (ring_capacity - 1)) != 0 || ring_capacity > 4096 ||
          ring_size > ring_capacity ||
          glyph_count + ring_size > kSgreLookupMaxGlyphs) {
        return SgreLookupCaptureResult::kRingShape;
      }
      for (uint64_t i = 0; i < ring_size; ++i) {
        const uint64_t index = (ring_begin + i) & (ring_capacity - 1);
        const auto* glyph = static_cast<const uint8_t*>(glyph_ring[index]);
        if (glyph == nullptr) return SgreLookupCaptureResult::kGlyphPointer;
        fushi_voice_hook::SgreLookupGlyphGeometry geometry;
        geometry.x = *reinterpret_cast<const float*>(glyph + 0x94);
        geometry.width = *reinterpret_cast<const float*>(glyph + 0x48);
        geometry.height = *reinterpret_cast<const float*>(glyph + 0x4c);
        geometry.line = static_cast<uint16_t>(line);
        if (!std::isfinite(geometry.x) || geometry.x < -64.0f ||
            geometry.x > 2048.0f) {
          return SgreLookupCaptureResult::kGlyphX;
        }
        if (!std::isfinite(geometry.width) || geometry.width <= 0.0f ||
            geometry.width > 256.0f) {
          return SgreLookupCaptureResult::kGlyphWidth;
        }
        if (!std::isfinite(geometry.height) || geometry.height <= 0.0f ||
            geometry.height > 256.0f) {
          return SgreLookupCaptureResult::kGlyphHeight;
        }
        capture->glyphs[glyph_count++] = geometry;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return SgreLookupCaptureResult::kException;
  }
  if (glyph_count == 0) return SgreLookupCaptureResult::kNoGlyphs;
  capture->glyph_count = glyph_count;
  capture->line_height = line_height;
  return SgreLookupCaptureResult::kOk;
}

bool IsSgreLookupCaptureFault(SgreLookupCaptureResult result) {
  switch (result) {
    case SgreLookupCaptureResult::kNullInput:
    case SgreLookupCaptureResult::kRingShape:
    case SgreLookupCaptureResult::kGlyphPointer:
    case SgreLookupCaptureResult::kGlyphX:
    case SgreLookupCaptureResult::kGlyphWidth:
    case SgreLookupCaptureResult::kGlyphHeight:
    case SgreLookupCaptureResult::kException:
      return true;
    default:
      return false;
  }
}

bool __fastcall SgreTextLayoutDetour(void* text_render, const wchar_t* text,
                                     int flags, int width, int layout_mode) {
  const bool capture_requested =
      !g_stop && g_header != nullptr &&
      fushi_voice_hook::HasLookupRegion(g_header) &&
      g_header->lookup_enabled != 0;
  SgreLookupEntryText entry_text;
  const SgreLookupCaptureResult entry_text_result =
      capture_requested ? CopySgreLookupEntryText(text, &entry_text)
                        : SgreLookupCaptureResult::kNullInput;
  const bool result = g_sgre_text_layout_original != nullptr
                          ? g_sgre_text_layout_original(
                                text_render, text, flags, width, layout_mode)
                          : false;
  if (!capture_requested || g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      g_header->lookup_enabled == 0) {
    return result;
  }
  const uint64_t seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_capture_count)));
  SgreLookupCapture* capture =
      &g_sgre_lookup_captures[seq % kSgreLookupCaptureSlots];
  InterlockedExchange64(&capture->seq, 0);
  capture->valid = 0;
  capture->text_units = 0;
  capture->glyph_count = 0;
  SgreLookupCaptureResult capture_result = entry_text_result;
  if (entry_text_result == SgreLookupCaptureResult::kOk) {
    capture->text_units = entry_text.text_units;
    memcpy(capture->text, entry_text.text,
           static_cast<size_t>(entry_text.text_units) * sizeof(wchar_t));
    capture_result = CopySgreLookupGeometry(text_render, capture);
  }
  if (capture_result == SgreLookupCaptureResult::kOk) {
    capture->valid = 1;
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  } else if (IsSgreLookupCaptureFault(capture_result)) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorFault;
  }
  InterlockedExchange64(&capture->seq, static_cast<LONG64>(seq));
  return result;
}

bool InstallSgreLookupSensor() {
  if (g_sgre_text_layout_original != nullptr) {
    if (g_header != nullptr) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorInstalled;
    }
    return true;
  }
  HMODULE executable = GetModuleHandleW(nullptr);
  if (executable == nullptr) return false;
  auto* target =
      reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(executable) +
                              fushi_voice_hook::kSgreTextLayoutRva);
  const bool installed =
      HookFn(target, reinterpret_cast<void*>(&SgreTextLayoutDetour),
             reinterpret_cast<void**>(&g_sgre_text_layout_original));
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
    return;
  }
  if ((g_header->lookup_diag &
       fushi_voice_hook::kLookupDiagLunaKnownHookReady) == 0) {
    return;
  }
  if (!InstallSgreLookupSensor()) return;

  SgreLookupCapture capture;
  uint64_t capture_seq = 0;
  if (ReadLatestSgreLookupCapture(&capture, &capture_seq)) {
    g_sgre_lookup_processed_seq = capture_seq;
    if (capture.valid != 0) {
      std::wstring line = fushi_voice_hook::LunaNormalizeMagesControls(
          capture.text, static_cast<int>(capture.text_units), true);
      size_t mapped = 0;
      for (size_t i = 0; i < line.size() && mapped < capture.glyph_count; ++i) {
        if (line[i] == L'\r' || line[i] == L'\n') continue;
        g_sgre_lookup_active_char_indices[mapped++] = static_cast<uint32_t>(i);
      }
      const auto update = fushi_voice_hook::ResolveSgreLookupActiveUpdate(
          true, line.size(), mapped, capture.glyph_count);
      if (update == fushi_voice_hook::SgreLookupActiveUpdate::kReplace) {
        memcpy(&g_sgre_lookup_active_capture, &capture, sizeof(capture));
        g_sgre_lookup_active_line = std::move(line);
        g_sgre_lookup_active_mapped = mapped;
        g_sgre_lookup_active_valid = true;
      }
    }
  }

  const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool submit = shift_down && !g_sgre_lookup_last_shift_down;
  g_sgre_lookup_last_shift_down = shift_down;
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
      active.glyphs, active.glyph_count, active.line_height, client_width,
      client_height, cursor.x, cursor.y, &hit_rect);

  if (submit && glyph_index >= 0) {
    PublishSgreLookupHit(g_sgre_lookup_active_line,
                         g_sgre_lookup_active_char_indices[glyph_index],
                         hit_rect, client_width, client_height);
  }
}

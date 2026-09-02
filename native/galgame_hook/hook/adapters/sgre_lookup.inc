// SGRE in-game lookup sensor. Family identity is proven by the optional audio
// archive or by the structurally validated anchor set below. Build-specific
// addresses come only from intersected semantic signatures (see
// sgre_anchors.h); known hashes add consistency checks, not address shortcuts.
// UserHook1 (0x328e0 in the
// measured build) is a pre-layout stream: it can run ahead of the visible
// dialogue and still contains MAGES controls. The sensor hooks the draw
// boundary instead, copies the renderer's flattened visible glyph vector, and
// therefore receives both game-parsed text and live geometry. UTF-8 conversion
// and IPC publication stay on HookWorker. The DirectInput detour only copies a
// fixed snapshot and rechecks the physical point on a fresh click; it never
// allocates, encodes, logs, or touches shared-memory IPC.

// Resolved once by SgreAdapter::install(). Every hook site checks its own
// anchor: an unresolved anchor leaves that site inert, never guessed.
fushi_voice_hook::SgreAnchorSet g_sgre_anchors;
bool g_sgre_anchors_resolved = false;
std::array<uint8_t, 32> g_sgre_executable_sha256 = {};

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
constexpr size_t kSgreUiTextBytes = 768;
constexpr size_t kSgreUiMaxGlyphsPerRun = 96;
constexpr size_t kSgreUiMaxRunsPerLayer = 8;
constexpr size_t kSgreUiRawRunSlots = 128;
constexpr size_t kSgreUiLayerSlots = 24;
constexpr ULONGLONG kSgreUiRawRunMaxAgeMs = 1000;
constexpr ULONGLONG kSgreUiVisibleMaxAgeMs = 128;
constexpr uint8_t kSgreLookupGlyphSpaceScenario = 0;
constexpr uint8_t kSgreLookupGlyphSpaceClientPixels = 1;

struct SgreUiFloatRect {
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
};

struct SgreUiLayoutGlyph {
  uint32_t glyph_id = 0;
  float pen_x = 0.0f;
  float pen_y = 0.0f;
};

// Fixed POD only: raster/draw callbacks never allocate, encode, log or touch
// shared-memory IPC.  UTF-8 decoding and final capture composition stay on
// HookWorker.
struct SgreUiTextRun {
  uint32_t valid = 0;
  uint32_t utf8_bytes = 0;
  uint32_t glyph_count = 0;
  float line_height = 0.0f;
  ULONGLONG captured_tick = 0;
  char utf8[kSgreUiTextBytes] = {};
  fushi_voice_hook::SgreLookupGlyphGeometry
      local_glyphs[kSgreUiMaxGlyphsPerRun] = {};
};

struct SgreUiRawRunRecord {
  void* raw_image = nullptr;
  uint64_t sequence = 0;
  SgreUiTextRun run;
};

struct SgreUiLayerRun {
  SgreUiTextRun run;
  fushi_voice_hook::SgreLookupGlyphGeometry
      screen_glyphs[kSgreUiMaxGlyphsPerRun] = {};
};

struct SgreUiLayerRecord {
  void* layer = nullptr;
  uint64_t generation = 0;
  uint32_t run_count = 0;
  uint32_t screen_valid = 0;
  ULONGLONG last_seen_tick = 0;
  SgreUiLayerRun runs[kSgreUiMaxRunsPerLayer] = {};
};

struct SgreUiDrawContext {
  uint32_t active = 0;
  uint32_t utf8_bytes = 0;
  char utf8[kSgreUiTextBytes] = {};
};

struct SgreLookupCapture {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  uint32_t text_units = 0;
  uint32_t glyph_count = 0;
  float line_height = 0.0f;
  ULONGLONG captured_tick = 0;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
  fushi_voice_hook::SgreLookupGlyphGeometry glyphs[kSgreLookupMaxGlyphs] = {};
  uint8_t glyph_spaces[kSgreLookupMaxGlyphs] = {};
};

using SgreTextDrawFn = void(__fastcall*)(void*);
using SgreUiDrawTextFn = void(__fastcall*)(void*, void*, const char*, int32_t,
                                            int32_t, int32_t, int32_t);
using SgreUiRasterTextFn = void(__fastcall*)(
    void*, void*, int32_t, int32_t, int32_t, int32_t, void*, float, float,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
using SgreUiRawImageUploadFn = void(__fastcall*)(void*, void*);
using SgreUiLayerRawTexDrawFn = void(__fastcall*)(void*);
using SgreUiComputeScreenAabbFn = SgreUiFloatRect*(__fastcall*)(
    void*, SgreUiFloatRect*, const SgreUiFloatRect*);
using SgreGetDeviceStateFn =
    HRESULT(STDMETHODCALLTYPE*)(void*, DWORD, LPVOID);

SgreTextDrawFn g_sgre_text_draw_original = nullptr;
SgreUiDrawTextFn g_sgre_ui_draw_text_original = nullptr;
SgreUiRasterTextFn g_sgre_ui_raster_text_original = nullptr;
SgreUiRawImageUploadFn g_sgre_ui_raw_image_upload_original = nullptr;
SgreUiLayerRawTexDrawFn g_sgre_ui_layer_raw_tex_draw_original = nullptr;
SgreUiComputeScreenAabbFn g_sgre_ui_compute_screen_aabb = nullptr;
void** g_sgre_ui_renderer_context_slot = nullptr;
const void* g_sgre_scenario_text_vtable = nullptr;
SgreLookupCapture g_sgre_lookup_captures[kSgreLookupCaptureSlots] = {};
volatile LONG64 g_sgre_lookup_capture_count = 0;
std::atomic<void*> g_sgre_lookup_scenario_surface{nullptr};
std::atomic<void*> g_sgre_text_scenario_surface{nullptr};
uint64_t g_sgre_lookup_processed_seq = 0;
bool g_sgre_lookup_last_shift_down = false;
SgreLookupCapture g_sgre_lookup_active_capture = {};
SgreLookupCapture g_sgre_lookup_scenario_capture = {};
bool g_sgre_lookup_scenario_capture_valid = false;
std::wstring g_sgre_lookup_active_line;
uint32_t g_sgre_lookup_active_char_indices[kSgreLookupMaxGlyphs] = {};
size_t g_sgre_lookup_active_mapped = 0;
bool g_sgre_lookup_active_valid = false;
uint64_t g_sgre_lookup_active_generation = 0;
uint64_t g_sgre_lookup_generation_counter = 0;
ULONGLONG g_sgre_lookup_active_capture_tick = 0;
uint32_t g_sgre_last_text_units = 0;
wchar_t g_sgre_last_text[kSgreLookupMaxTextUnits] = {};
volatile LONG g_sgre_lookup_structure_state = 0;
volatile LONG g_sgre_direct_input_structure_state = 0;
volatile LONG g_sgre_lookup_structure_attempts = 0;
volatile LONG g_sgre_direct_input_structure_attempts = 0;
alignas(8) volatile LONG64 g_sgre_lookup_structure_next_retry_tick = 0;
alignas(8) volatile LONG64 g_sgre_direct_input_structure_next_retry_tick = 0;
SRWLOCK g_sgre_ui_metadata_lock = SRWLOCK_INIT;
SgreUiRawRunRecord g_sgre_ui_raw_runs[kSgreUiRawRunSlots] = {};
SgreUiLayerRecord g_sgre_ui_layers[kSgreUiLayerSlots] = {};
uint64_t g_sgre_ui_raw_run_sequence = 0;
uint64_t g_sgre_ui_layer_generation = 0;
volatile LONG g_sgre_ui_hook_install_state = 0;
thread_local SgreUiDrawContext g_sgre_ui_draw_context;
thread_local bool g_sgre_ui_layer_draw_reentrant = false;
thread_local SgreUiLayerRecord g_sgre_ui_layer_snapshot;

constexpr LONG kSgreStructureUnknown = 0;
constexpr LONG kSgreStructureMatched = 1;
constexpr LONG kSgreStructureChecking = 2;
constexpr LONG kSgreStructureRetryPending = 3;
constexpr LONG kSgreStructureFault = -1;
constexpr LONG kSgreStructureRetryLimit = 3;
constexpr ULONGLONG kSgreStructureRetryDelayMs = 250;

bool IsSgreResolvedStructureMatched(volatile LONG* cached_state,
                                     volatile LONG* attempts,
                                     volatile LONG64* next_retry_tick,
                                     bool lookup_sensor) {
  LONG cached = InterlockedCompareExchange(cached_state, 0, 0);
  if (cached == kSgreStructureMatched) return true;
  if (cached == kSgreStructureFault || cached == kSgreStructureChecking) {
    return false;
  }
  const ULONGLONG now = GetTickCount64();
  LONG expected = kSgreStructureUnknown;
  if (cached == kSgreStructureRetryPending) {
    const ULONGLONG retry_at = static_cast<ULONGLONG>(
        InterlockedCompareExchange64(next_retry_tick, 0, 0));
    if (now < retry_at) return false;
    expected = kSgreStructureRetryPending;
  } else if (cached != kSgreStructureUnknown) {
    return false;
  }
  if (InterlockedCompareExchange(cached_state, kSgreStructureChecking,
                                 expected) != expected) {
    return false;
  }

  bool matched = false;
  bool transient_failure = false;
#if defined(_M_X64)
  // Anchor resolution already requires unique, mutually corroborated
  // signatures. Re-read the live mapped image here and validate those exact
  // resolved RVAs; never substitute the measured-build constants. This makes
  // the known-hash row and a hash-miss candidate build pass the same ABI
  // proof, while a stale row, patched image, or changed object layout remains
  // fail-closed.
  fushi_voice_hook::SgreImageView image;
  HMODULE module = GetModuleHandleW(nullptr);
  if (!g_sgre_anchors_resolved || module == nullptr) {
    transient_failure = true;
  } else if (!fushi_voice_hook::ReadSgreImageSections(module, &image)) {
    transient_failure = true;
  } else {
    fushi_voice_hook::SgreAnchorSet live_anchors;
    const bool reparsed = fushi_voice_hook::ResolveSgreAnchorsGuarded(
        g_sgre_executable_sha256.data(), g_sgre_executable_sha256.size(),
        &image, &live_anchors);
    if (!reparsed) {
      transient_failure = true;
    } else {
      matched = lookup_sensor
                    ? live_anchors.lookup_sensor_available() &&
                          live_anchors.text_draw.rva ==
                              g_sgre_anchors.text_draw.rva &&
                          live_anchors.scenario_text_vtable.rva ==
                              g_sgre_anchors.scenario_text_vtable.rva &&
                          fushi_voice_hook::ValidateSgreLookupAnchorStructure(
                              live_anchors, image)
                    : live_anchors.direct_input_shield_available() &&
                          live_anchors.direct_input_mouse_device.rva ==
                              g_sgre_anchors.direct_input_mouse_device.rva &&
                          fushi_voice_hook::
                              ValidateSgreDirectInputAnchorStructure(
                                  live_anchors, image);
    }
  }
#endif
  if (matched) {
    InterlockedExchange(attempts, 0);
    InterlockedExchange(cached_state, kSgreStructureMatched);
    return true;
  }
  if (transient_failure) {
    const LONG attempt = InterlockedIncrement(attempts);
    if (attempt < kSgreStructureRetryLimit) {
      InterlockedExchange64(
          next_retry_tick,
          static_cast<LONG64>(now + kSgreStructureRetryDelayMs));
      InterlockedExchange(cached_state, kSgreStructureRetryPending);
      return false;
    }
  }
  InterlockedExchange(cached_state, kSgreStructureFault);
  return matched;
}

bool IsSgreLookupStructureMatched() {
  return IsSgreResolvedStructureMatched(
      &g_sgre_lookup_structure_state, &g_sgre_lookup_structure_attempts,
      &g_sgre_lookup_structure_next_retry_tick, true);
}

bool IsSgreDirectInputStructureMatched() {
  return IsSgreResolvedStructureMatched(
      &g_sgre_direct_input_structure_state,
      &g_sgre_direct_input_structure_attempts,
      &g_sgre_direct_input_structure_next_retry_tick, false);
}

bool IsSgreLookupStructureFaulted() {
  return InterlockedCompareExchange(&g_sgre_lookup_structure_state, 0, 0) ==
         kSgreStructureFault;
}

bool IsSgreDirectInputStructureFaulted() {
  return InterlockedCompareExchange(&g_sgre_direct_input_structure_state, 0,
                                    0) == kSgreStructureFault;
}

constexpr size_t kSgreLookupClickEventSlots = 4;
constexpr ULONGLONG kSgreLookupClickTargetMaxAgeMs = 64;
constexpr ULONGLONG kSgreLookupActiveCaptureMaxAgeMs = 128;
constexpr ULONGLONG kSgreLookupDuplicateHitWindowMs = 250;

struct SgreLookupClickPayload {
  uint64_t logical_generation = 0;
  uint32_t text_units = 0;
  uint32_t char_index = 0;
  fushi_voice_hook::SgreLookupRect rect;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
};

struct SgreLookupClickTarget {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  ULONGLONG published_tick = 0;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  uint64_t logical_generation = 0;
  SgreLookupCapture capture;
};

struct SgreLookupClickEvent {
  volatile LONG64 seq = 0;
  SgreLookupClickPayload payload;
};

SgreLookupClickTarget g_sgre_lookup_click_target = {};
volatile LONG64 g_sgre_lookup_click_target_count = 0;
SgreLookupClickEvent
    g_sgre_lookup_click_events[kSgreLookupClickEventSlots] = {};
volatile LONG64 g_sgre_lookup_click_event_count = 0;
uint64_t g_sgre_lookup_click_processed_seq = 0;
std::atomic<bool> g_sgre_lookup_click_runtime_enabled{false};
uint64_t g_sgre_lookup_last_hit_identity = 0;
ULONGLONG g_sgre_lookup_last_hit_tick = 0;

// The admitted SGRE GetDeviceState callsite is single-threaded. Keep the
// gesture itself on that exact poller; cross-thread handoff is only the fixed
// target/event publications below, both protected by a sequence barrier.
fushi_voice_hook::SgreLookupClickGestureState g_sgre_lookup_click_gesture;
void* g_sgre_lookup_click_observed_device = nullptr;
SgreLookupClickTarget g_sgre_lookup_click_read_target = {};
SgreLookupClickPayload g_sgre_lookup_pending_click = {};
bool g_sgre_lookup_pending_click_valid = false;

void FillSgreLookupClickPayload(
    SgreLookupClickPayload* payload, const SgreLookupCapture& capture,
    uint64_t logical_generation, uint32_t char_index,
    const fushi_voice_hook::SgreLookupRect& rect, HWND game,
    const POINT& client_origin, int32_t client_width, int32_t client_height) {
  if (payload == nullptr) return;
  *payload = SgreLookupClickPayload();
  payload->logical_generation = logical_generation;
  payload->text_units = capture.text_units;
  payload->char_index = char_index;
  payload->rect = rect;
  payload->game_window = reinterpret_cast<uintptr_t>(game);
  payload->client_screen_x = client_origin.x;
  payload->client_screen_y = client_origin.y;
  payload->client_width = client_width;
  payload->client_height = client_height;
  if (capture.text_units != 0) {
    memcpy(payload->text, capture.text,
           static_cast<size_t>(capture.text_units) * sizeof(wchar_t));
  }
}

void PublishSgreLookupClickTarget(
    const SgreLookupCapture& capture, uint64_t logical_generation,
    HWND game, const POINT& client_origin, int32_t client_width,
    int32_t client_height) {
  if (game == nullptr || logical_generation == 0 || capture.valid != 1 ||
      capture.text_units == 0 ||
      capture.text_units != capture.glyph_count ||
      capture.glyph_count > kSgreLookupMaxGlyphs) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_click_target_count)));
  InterlockedExchange64(&g_sgre_lookup_click_target.seq, 0);
  g_sgre_lookup_click_target.valid = 1;
  g_sgre_lookup_click_target.published_tick = GetTickCount64();
  g_sgre_lookup_click_target.game_window =
      reinterpret_cast<uintptr_t>(game);
  g_sgre_lookup_click_target.client_screen_x = client_origin.x;
  g_sgre_lookup_click_target.client_screen_y = client_origin.y;
  g_sgre_lookup_click_target.client_width = client_width;
  g_sgre_lookup_click_target.client_height = client_height;
  g_sgre_lookup_click_target.logical_generation = logical_generation;
  memcpy(&g_sgre_lookup_click_target.capture, &capture, sizeof(capture));
  InterlockedExchange64(&g_sgre_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

void InvalidateSgreLookupClickTarget() {
  const uint64_t next = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_click_target_count)));
  InterlockedExchange64(&g_sgre_lookup_click_target.seq, 0);
  g_sgre_lookup_click_target.valid = 0;
  g_sgre_lookup_click_target.published_tick = GetTickCount64();
  g_sgre_lookup_click_target.game_window = 0;
  g_sgre_lookup_click_target.client_screen_x = 0;
  g_sgre_lookup_click_target.client_screen_y = 0;
  g_sgre_lookup_click_target.client_width = 0;
  g_sgre_lookup_click_target.client_height = 0;
  g_sgre_lookup_click_target.logical_generation = 0;
  memset(&g_sgre_lookup_click_target.capture, 0,
         sizeof(g_sgre_lookup_click_target.capture));
  InterlockedExchange64(&g_sgre_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

bool ReadSgreLookupClickTarget(SgreLookupClickTarget* copy) {
  if (copy == nullptr) return false;
  const uint64_t before = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_sgre_lookup_click_target.seq, 0, 0));
  if (before == 0) return false;
  memcpy(copy, &g_sgre_lookup_click_target, sizeof(*copy));
  const uint64_t after = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_sgre_lookup_click_target.seq, 0, 0));
  if (after != before || after == 0 || copy->valid != 1) return false;
  const ULONGLONG now = GetTickCount64();
  return now >= copy->published_tick &&
         now - copy->published_tick <= kSgreLookupClickTargetMaxAgeMs &&
         copy->game_window != 0 && copy->client_width > 0 &&
         copy->client_height > 0 && copy->capture.valid == 1 &&
         copy->capture.text_units != 0 &&
          copy->capture.text_units <= kSgreLookupMaxTextUnits &&
          copy->capture.text_units == copy->capture.glyph_count &&
          copy->capture.glyph_count <= kSgreLookupMaxGlyphs &&
         copy->logical_generation != 0;
}

bool SgreLookupRectForCapturedGlyph(const SgreLookupCapture& capture,
                                    size_t glyph_index,
                                    int32_t client_width,
                                    int32_t client_height,
                                    fushi_voice_hook::SgreLookupRect* rect) {
  if (rect == nullptr || glyph_index >= capture.glyph_count) return false;
  auto glyph = capture.glyphs[glyph_index];
  if (capture.glyph_spaces[glyph_index] ==
      kSgreLookupGlyphSpaceClientPixels) {
    if (!std::isfinite(glyph.x) || !std::isfinite(glyph.y) ||
        !std::isfinite(glyph.width) || !std::isfinite(glyph.height) ||
        glyph.width <= 0.0f || glyph.height <= 0.0f) {
      return false;
    }
    if (glyph_index + 1 < capture.glyph_count &&
        capture.glyph_spaces[glyph_index + 1] ==
            kSgreLookupGlyphSpaceClientPixels &&
        capture.glyphs[glyph_index + 1].line == glyph.line) {
      const float advance = capture.glyphs[glyph_index + 1].x - glyph.x;
      if (std::isfinite(advance) && advance > 0.0f) {
        glyph.width = std::min(glyph.width, advance);
      }
    }
    rect->x = static_cast<int32_t>(std::lround(glyph.x));
    rect->y = static_cast<int32_t>(std::lround(glyph.y));
    rect->width = std::max<int32_t>(
        1, static_cast<int32_t>(std::lround(glyph.width)));
    rect->height = std::max<int32_t>(
        1, static_cast<int32_t>(std::lround(glyph.height)));
    // Runner and Dart both require a glyph rectangle to be fully contained in
    // the advertised client viewport. Accepting a merely intersecting edge
    // glyph here lets DirectInput consume the click before the host rejects the
    // same payload. Subtraction avoids signed overflow in x + width.
    return client_width > 0 && client_height > 0 && rect->x >= 0 &&
           rect->y >= 0 && rect->width <= client_width &&
           rect->height <= client_height &&
           rect->x <= client_width - rect->width &&
           rect->y <= client_height - rect->height;
  }
  glyph.width = fushi_voice_hook::SgreLookupHitWidth(
      capture.glyphs, capture.glyph_count, glyph_index);
  return fushi_voice_hook::SgreLookupRectForGlyph(
      glyph, client_width, client_height, rect);
}

int FindSgreCapturedLookupGlyph(const SgreLookupCapture& capture,
                                int32_t client_width,
                                int32_t client_height, int32_t cursor_x,
                                int32_t cursor_y,
                                fushi_voice_hook::SgreLookupRect* hit_rect) {
  for (size_t i = 0; i < capture.glyph_count; ++i) {
    fushi_voice_hook::SgreLookupRect rect;
    if (!SgreLookupRectForCapturedGlyph(capture, i, client_width,
                                        client_height, &rect)) {
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

bool BuildSgreLookupClickPayloadAtPress(const SgreLookupClickTarget& target,
                                        HWND game, const POINT& screen_point,
                                        SgreLookupClickPayload* payload) {
  if (payload == nullptr || target.valid != 1 || game == nullptr ||
      reinterpret_cast<HWND>(target.game_window) != game ||
      !IsWindow(game) || GetForegroundWindow() != game) {
    return false;
  }
  const HWND point_window = WindowFromPoint(screen_point);
  if (point_window == nullptr ||
      (point_window != game && !IsChild(game, point_window))) {
    return false;
  }
  RECT client = {};
  POINT client_origin = {0, 0};
  if (!GetClientRect(game, &client) ||
      !ClientToScreen(game, &client_origin)) {
    return false;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  if (client_width != target.client_width ||
      client_height != target.client_height ||
      client_origin.x != target.client_screen_x ||
      client_origin.y != target.client_screen_y) {
    return false;
  }
  const int32_t client_x = screen_point.x - client_origin.x;
  const int32_t client_y = screen_point.y - client_origin.y;
  fushi_voice_hook::SgreLookupRect rect;
  const int glyph_index = FindSgreCapturedLookupGlyph(
      target.capture, client_width, client_height, client_x, client_y, &rect);
  if (glyph_index < 0 ||
      static_cast<uint32_t>(glyph_index) >= target.capture.text_units) {
    return false;
  }
  FillSgreLookupClickPayload(
      payload, target.capture, target.logical_generation,
      static_cast<uint32_t>(glyph_index), rect, game, client_origin,
      client_width, client_height);
  return true;
}

fushi_voice_hook::SgreLookupClientSnapshot SgreLookupPayloadClientSnapshot(
    const SgreLookupClickPayload& payload) {
  return {payload.game_window, payload.client_screen_x,
          payload.client_screen_y, payload.client_width,
          payload.client_height};
}

fushi_voice_hook::SgreLookupClientSnapshot SgreLookupTargetClientSnapshot(
    const SgreLookupClickTarget& target) {
  return {target.game_window, target.client_screen_x,
          target.client_screen_y, target.client_width,
          target.client_height};
}

bool SgreLookupPayloadMatchesPublishedTarget(
    const SgreLookupClickPayload& payload) {
  SgreLookupClickTarget target;
  return ReadSgreLookupClickTarget(&target) &&
         fushi_voice_hook::MatchesSgreLookupGenerationAndClient(
             payload.logical_generation,
             SgreLookupPayloadClientSnapshot(payload),
             target.logical_generation, SgreLookupTargetClientSnapshot(target));
}

void QueueSgreLookupClickSubmit(const SgreLookupClickPayload& payload) {
  if (payload.text_units == 0 || payload.text_units > kSgreLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_click_event_count)));
  SgreLookupClickEvent* event =
      &g_sgre_lookup_click_events[next % kSgreLookupClickEventSlots];
  InterlockedExchange64(&event->seq, 0);
  event->payload = payload;
  InterlockedExchange64(&event->seq, static_cast<LONG64>(next));
}

bool ReadLatestSgreLookupClickSubmit(SgreLookupClickEvent* copy,
                                     uint64_t* seq) {
  if (copy == nullptr || seq == nullptr) return false;
  const uint64_t latest = static_cast<uint64_t>(InterlockedCompareExchange64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_click_event_count), 0,
      0));
  if (latest == 0 || latest == g_sgre_lookup_click_processed_seq) return false;
  SgreLookupClickEvent* source =
      &g_sgre_lookup_click_events[latest % kSgreLookupClickEventSlots];
  const uint64_t before = static_cast<uint64_t>(
      InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != latest) return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after = static_cast<uint64_t>(
      InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0) return false;
  *seq = latest;
  return true;
}

void DiscardPendingSgreLookupClickSubmits() {
  g_sgre_lookup_click_processed_seq = static_cast<uint64_t>(
      InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_click_event_count),
          0, 0));
}

// BUG-1882 — SGRE does not advance from WM_LBUTTONDOWN. It polls the
// GUID_SysMouse IDirectInputDevice8 immediate state every frame. The popup HWND
// published on the game window is the host-owned liveness token; the button
// latch is injected-side state so teardown cannot expose the held half of a
// click after its down was already hidden.
SgreGetDeviceStateFn g_sgre_get_device_state_original = nullptr;
void* g_sgre_get_device_state_target = nullptr;
std::atomic<void*> g_sgre_mouse_device{nullptr};
std::atomic<uint8_t> g_sgre_direct_input_latched_buttons{0};
std::atomic<HWND> g_sgre_direct_input_game_window{nullptr};
HWND g_sgre_direct_input_property_window = nullptr;
ULONGLONG g_sgre_direct_input_last_health_tick = 0;
constexpr ULONGLONG kSgreDirectInputHealthIntervalMs = 1000;

HWND GetValidPublishedSgreDirectInputShieldPopup(HWND game) {
  if (game == nullptr) return nullptr;
  const HWND popup = reinterpret_cast<HWND>(GetPropW(
      game, fushi_voice_hook::kSgreDirectInputShieldWindowProperty));
  // Idle GetDeviceState hot path stops at the single null property read.  Pay
  // HWND/owner/class validation only while a host actually published a card.
  if (popup == nullptr || !IsWindow(game) || !IsWindow(popup) ||
      GetWindow(popup, GW_OWNER) != game) {
    return nullptr;
  }
  wchar_t class_name[64] = {};
  if (GetClassNameW(popup, class_name,
                    static_cast<int>(sizeof(class_name) /
                                     sizeof(class_name[0]))) <= 0 ||
      lstrcmpW(class_name, L"FushiGlobalLookupWindow") != 0) {
    return nullptr;
  }
  return popup;
}

// Ready 是注入侧对 host 的握手：detour 真的装上了，host 才被允许发布 popup HWND；
// health worker 在契约失效时会撤回它。屏蔽一旦生效就是把游戏的鼠标键整片清零，
// 必须由完整契约背书，不能只看「Window 属性在不在」。
//
// 这里只留「读 ready」这一个原语，不再提供 popup+ready 的复合判据：detour 的热路径
// 已经单独取过 popup HWND（卡外关闭要用它），复合判据会把 owner/class 校验做第二遍，
// 而且它一旦没人调用就会变成守卫护着的死代码——那正是本次要修掉的形态。
bool IsSgreDirectInputShieldReadyPublished(HWND game) {
  return reinterpret_cast<uintptr_t>(GetPropW(
             game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty)) ==
         fushi_voice_hook::kSgreDirectInputShieldReadyValue;
}

bool IsSgreDirectInputShieldOperational() {
  const HWND game =
      g_sgre_direct_input_game_window.load(std::memory_order_acquire);
  return g_sgre_get_device_state_target != nullptr &&
         g_sgre_get_device_state_original != nullptr &&
         g_sgre_mouse_device.load(std::memory_order_acquire) != nullptr &&
         game != nullptr && IsWindow(game) &&
         IsSgreDirectInputShieldReadyPublished(game);
}

HRESULT STDMETHODCALLTYPE SgreGetDeviceStateDetour(void* device,
                                                    DWORD state_bytes,
                                                    LPVOID state) {
  const SgreGetDeviceStateFn original = g_sgre_get_device_state_original;
  if (original == nullptr) return E_FAIL;
  const HRESULT result = original(device, state_bytes, state);
  const void* current_device =
      g_sgre_mouse_device.load(std::memory_order_acquire);
  if (FAILED(result)) {
    // A missing sample cannot complete a click safely. Keep the injected-side
    // button latch until a later successful raw up drains it, but make the
    // pending lookup non-submittable now.
    if (device == current_device && g_sgre_lookup_click_gesture.active) {
      g_sgre_lookup_click_gesture.cancelled = true;
    }
    return result;
  }
  if (state == nullptr ||
      device != g_sgre_mouse_device.load(std::memory_order_acquire) ||
      state_bytes != fushi_voice_hook::kSgreDirectInputMouseStateBytes) {
    return result;
  }

  if (g_sgre_lookup_click_observed_device != device) {
    // Synchronize to a full up before the first accepted down on a newly
    // admitted device. Otherwise injection while physically held would hide
    // only the latter half of a click that SGRE already observed.
    g_sgre_lookup_click_observed_device = device;
    g_sgre_lookup_click_gesture =
        fushi_voice_hook::SgreLookupClickGestureState();
    g_sgre_lookup_pending_click = SgreLookupClickPayload();
    g_sgre_lookup_pending_click_valid = false;
  }

  auto* bytes = static_cast<uint8_t*>(state);
  const size_t primary_offset =
      fushi_voice_hook::kSgreDirectInputMouseButtonsOffset +
      fushi_voice_hook::kSgreLookupPrimaryButtonIndex;
  const bool primary_down = (bytes[primary_offset] & 0x80u) != 0;
  const HWND game =
      g_sgre_direct_input_game_window.load(std::memory_order_acquire);
  const HWND direct_popup =
      GetValidPublishedSgreDirectInputShieldPopup(game);
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  // direct route 必须过 Ready 握手；bitmap route 是注入侧自己画的卡，进程内可见性
  // 就是全部真相，没有 host 侧握手可言。两者语义不同，不能折成「有没有卡」一问。
  const bool direct_shield =
      direct_popup != nullptr && IsSgreDirectInputShieldReadyPublished(game);
  const bool shield_active = direct_shield || bitmap_popup_visible;
  const bool lookup_allowed =
      g_sgre_lookup_click_runtime_enabled.load(std::memory_order_acquire) &&
      fushi_voice_hook::g_geometry_provider_registry.OwnsReadyProvider(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSgre) &&
      !shield_active && game != nullptr;
  const bool fresh_down = primary_down &&
                          g_sgre_lookup_click_gesture.synchronized &&
                          !g_sgre_lookup_click_gesture.last_down;
  POINT pointer = {};
  bool pointer_valid = false;
  if (fresh_down || g_sgre_lookup_click_gesture.active) {
    pointer_valid = GetCursorPos(&pointer) != FALSE;
  }
  if (fresh_down && direct_popup == nullptr && bitmap_popup_visible &&
      game != nullptr && pointer_valid && GetForegroundWindow() == game) {
    const HWND point_window = WindowFromPoint(pointer);
    if (point_window != nullptr &&
        (point_window == game || IsChild(game, point_window))) {
      RequestLookupOverlayOutsideDismiss();
    }
  }

  SgreLookupClickPayload pressed_payload;
  bool hit_on_press = false;
  if (fresh_down && lookup_allowed && pointer_valid &&
      ReadSgreLookupClickTarget(&g_sgre_lookup_click_read_target)) {
    hit_on_press = BuildSgreLookupClickPayloadAtPress(
        g_sgre_lookup_click_read_target, game, pointer, &pressed_payload);
  }
  const fushi_voice_hook::SgreLookupClickAction click_action =
      fushi_voice_hook::AdvanceSgreLookupClickGesture(
          primary_down, lookup_allowed, hit_on_press, pointer_valid,
          &g_sgre_lookup_click_gesture);
  if (click_action == fushi_voice_hook::SgreLookupClickAction::kBegin) {
    g_sgre_lookup_pending_click = pressed_payload;
    g_sgre_lookup_pending_click_valid = true;
    g_sgre_direct_input_latched_buttons.fetch_or(
        fushi_voice_hook::kSgreLookupPrimaryButtonMask,
        std::memory_order_acq_rel);
  } else if (click_action ==
             fushi_voice_hook::SgreLookupClickAction::kSubmit) {
    // The down payload is immutable, but the renderer may replace the
    // sentence or client transform while the button is held.  Re-read the
    // worker-published logical target before queueing the up transaction.
    if (g_sgre_lookup_pending_click_valid && lookup_allowed &&
        SgreLookupPayloadMatchesPublishedTarget(
            g_sgre_lookup_pending_click)) {
      QueueSgreLookupClickSubmit(g_sgre_lookup_pending_click);
    }
    g_sgre_lookup_pending_click_valid = false;
  } else if (click_action ==
             fushi_voice_hook::SgreLookupClickAction::kCancel) {
    g_sgre_lookup_pending_click_valid = false;
  }

  const uint8_t initial_latch =
      g_sgre_direct_input_latched_buttons.load(std::memory_order_acquire);
  if (!shield_active && initial_latch == 0) return result;

  uint8_t raw_buttons[fushi_voice_hook::kSgreDirectInputMouseButtonCount] = {};
  for (size_t index = 0;
       index < fushi_voice_hook::kSgreDirectInputMouseButtonCount; ++index) {
    raw_buttons[index] =
        bytes[fushi_voice_hook::kSgreDirectInputMouseButtonsOffset + index];
  }
  // The admitted callsite is single-threaded, but make the latch linearizable
  // anyway: a future second poller must not lose another button's bit through a
  // load -> filter -> store last-writer-wins race.
  uint8_t observed = initial_latch;
  for (;;) {
    for (size_t index = 0;
         index < fushi_voice_hook::kSgreDirectInputMouseButtonCount; ++index) {
      bytes[fushi_voice_hook::kSgreDirectInputMouseButtonsOffset + index] =
          raw_buttons[index];
    }
    const uint8_t next = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
        shield_active, bytes, state_bytes, observed);
    if (g_sgre_direct_input_latched_buttons.compare_exchange_weak(
            observed, next, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      break;
    }
  }
  return result;
}

void RevokeSgreDirectInputShieldReady(HWND game) {
  if (game != nullptr && IsWindow(game)) {
    RemovePropW(game,
                fushi_voice_hook::kSgreDirectInputShieldWindowProperty);
    RemovePropW(game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty);
  }
  if (g_header != nullptr) {
    InterlockedAnd(
        reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
        static_cast<LONG>(
            ~fushi_voice_hook::kLookupDiagSgreDirectInputShieldReady));
  }
}

HWND ResolveSgreDirectInputPropertyWindow() {
  if (g_sgre_direct_input_property_window != nullptr &&
      IsWindow(g_sgre_direct_input_property_window)) {
    DWORD pid = 0;
    GetWindowThreadProcessId(g_sgre_direct_input_property_window, &pid);
    if (pid == GetCurrentProcessId()) {
      return g_sgre_direct_input_property_window;
    }
  }
  g_sgre_direct_input_property_window = FindGameMainWindow();
  return g_sgre_direct_input_property_window;
}

bool RefreshSgreDirectInputPropertyWindow() {
  const HWND previous = g_sgre_direct_input_property_window;
  const HWND current = FindGameMainWindow();
  if (current == nullptr) {
    // Minimize/restore can temporarily leave no visible owner candidate.  Keep
    // an otherwise live cached HWND; the next health tick will rediscover it or
    // migrate when a replacement main window appears.
    if (previous != nullptr && IsWindow(previous)) return true;
    RevokeSgreDirectInputShieldReady(previous);
    g_sgre_direct_input_property_window = nullptr;
    g_sgre_direct_input_game_window.store(nullptr,
                                           std::memory_order_release);
    return false;
  }
  if (current == previous) return true;

  if (GetValidPublishedSgreDirectInputShieldPopup(previous) != nullptr) {
    // Never tear down a live host publication underneath an on-screen lookup.
    // Its owner remains the previous HWND; after host Hide removes Window, the
    // next 1s health pass can safely migrate Required -> Ready to |current|.
    return true;
  }

  // SGRE may replace its visible top-level window while retaining the old HWND
  // (fullscreen / mode transitions).  Move the whole Required -> Ready contract
  // instead of leaving Fushi to misclassify the new main window as a generic
  // HHOOK-only game.
  RevokeSgreDirectInputShieldReady(previous);
  if (previous != nullptr && IsWindow(previous)) {
    RemovePropW(previous,
                fushi_voice_hook::kSgreDirectInputShieldRequiredProperty);
  }
  g_sgre_direct_input_property_window = current;
  g_sgre_direct_input_game_window.store(nullptr, std::memory_order_release);
  g_sgre_direct_input_last_health_tick = 0;
  return true;
}

bool PublishSgreDirectInputShieldRequired() {
  const HWND game = ResolveSgreDirectInputPropertyWindow();
  if (game == nullptr) return false;
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kSgreDirectInputShieldRequiredProperty)) ==
      fushi_voice_hook::kSgreDirectInputShieldRequiredValue) {
    return true;
  }
  return SetPropW(
             game,
             fushi_voice_hook::kSgreDirectInputShieldRequiredProperty,
             reinterpret_cast<HANDLE>(
                 fushi_voice_hook::kSgreDirectInputShieldRequiredValue)) !=
         FALSE;
}

void MarkSgreDirectInputShieldNotReady() {
  RevokeSgreDirectInputShieldReady(g_sgre_direct_input_property_window);
  g_sgre_direct_input_game_window.store(nullptr, std::memory_order_release);
  // A hidden down remains suppressed through its raw up even if the health
  // contract is revoked mid-click.  Preserve the hooked self while the latch is
  // non-zero; the detour's inactive path drains it on the matching raw release.
  if (g_sgre_direct_input_latched_buttons.load(std::memory_order_acquire) == 0) {
    g_sgre_mouse_device.store(nullptr, std::memory_order_release);
  }
  g_sgre_direct_input_last_health_tick = 0;
}

bool PublishSgreDirectInputShieldReady() {
  const HWND game = ResolveSgreDirectInputPropertyWindow();
  if (game == nullptr) return false;
  // Injected-side cache first, Ready property last. Ready is the cross-process
  // commit observed by Fushi; publishing it earlier leaves a first-frame window
  // where host shows the popup while the detour still reads game == nullptr.
  g_sgre_direct_input_game_window.store(game, std::memory_order_release);
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty)) !=
          fushi_voice_hook::kSgreDirectInputShieldReadyValue &&
      !SetPropW(game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty,
                reinterpret_cast<HANDLE>(
                    fushi_voice_hook::kSgreDirectInputShieldReadyValue))) {
    g_sgre_direct_input_game_window.store(nullptr, std::memory_order_release);
    return false;
  }
  if (g_header != nullptr) {
    InterlockedOr(
        reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
        static_cast<LONG>(
            fushi_voice_hook::kLookupDiagSgreDirectInputShieldReady));
  }
  g_sgre_direct_input_last_health_tick = GetTickCount64();
  return true;
}

bool InstallSgreDirectInputShield() {
  if (!IsSgreDirectInputStructureMatched()) {
    PublishSgreDirectInputShieldRequired();
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  HMODULE executable = GetModuleHandleW(nullptr);
  // Required is the family statement "this runtime polls DirectInput, fail
  // closed without a working detour". It is published even when the device
  // slot anchor is unresolved: a host must never treat an SGRE build as a
  // plain HHOOK game just because this build has not been measured yet.
  if (executable == nullptr ||
      !g_sgre_anchors.direct_input_shield_available()) {
    PublishSgreDirectInputShieldRequired();
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  void* mouse_device = nullptr;
  void* target = nullptr;
  __try {
    mouse_device = *reinterpret_cast<void**>(
        reinterpret_cast<uintptr_t>(executable) +
        g_sgre_anchors.direct_input_mouse_device.rva);
    if (mouse_device != nullptr) {
      target = VtableSlot(
          mouse_device,
          fushi_voice_hook::kSgreDirectInputGetDeviceStateVtableIndex);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    mouse_device = nullptr;
    target = nullptr;
  }
  const ULONGLONG now = GetTickCount64();
  const HWND cached_game =
      g_sgre_direct_input_game_window.load(std::memory_order_acquire);
  void** device_vtable = nullptr;
  if (mouse_device != nullptr &&
      reinterpret_cast<uintptr_t>(mouse_device) % alignof(void*) == 0 &&
      fushi_voice_hook::exact_lookup::IsReadableSpan(mouse_device,
                                                     sizeof(void*))) {
    memcpy(&device_vtable, mouse_device, sizeof(device_vtable));
  }
  const bool device_abi_valid =
      device_vtable != nullptr &&
      reinterpret_cast<uintptr_t>(device_vtable) % alignof(void*) == 0 &&
      fushi_voice_hook::exact_lookup::IsReadableSpan(
          device_vtable,
          (fushi_voice_hook::kSgreDirectInputGetDeviceStateVtableIndex + 1u) *
              sizeof(void*)) &&
      target == device_vtable
                     [fushi_voice_hook::
                          kSgreDirectInputGetDeviceStateVtableIndex] &&
      fushi_voice_hook::exact_lookup::IsExecutableAddress(target);
  if (mouse_device != nullptr && target != nullptr && device_abi_valid &&
      target == g_sgre_get_device_state_target &&
      mouse_device == g_sgre_mouse_device.load(std::memory_order_acquire) &&
      cached_game != nullptr &&
      cached_game == g_sgre_direct_input_property_window &&
      IsWindow(cached_game) &&
      g_sgre_direct_input_last_health_tick != 0 &&
      now - g_sgre_direct_input_last_health_tick <
          kSgreDirectInputHealthIntervalMs) {
    // Steady-state worker tick: in-process device/method reads plus a cheap HWND
    // liveness check prove the admitted binding is unchanged. Avoid EnumWindows
    // and property traffic at the 16 ms lookup polling cadence; do the full
    // main-window selection and cross-process contract refresh once per second.
    return true;
  }
  if (!RefreshSgreDirectInputPropertyWindow()) {
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  if (!PublishSgreDirectInputShieldRequired()) {
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  if (mouse_device == nullptr || target == nullptr || !device_abi_valid) {
    if (g_sgre_get_device_state_target != nullptr &&
        g_sgre_mouse_device.load(std::memory_order_acquire) != nullptr &&
        GetValidPublishedSgreDirectInputShieldPopup(
            g_sgre_direct_input_property_window) != nullptr) {
      // Exact SGRE initializes/releases this global outside the admitted
      // per-frame callsite.  A transient null health sample must not revoke a
      // live popup contract; the already-hooked self keeps filtering and the
      // next health pass retries the slot.
      return PublishSgreDirectInputShieldReady();
    }
    MarkSgreDirectInputShieldNotReady();
    return false;
  }

  // The implementation address is normally shared by every DirectInput mouse
  // instance. Refuse a surprising target change instead of repointing one
  // global trampoline while an older detour may still be executing.
  if (g_sgre_get_device_state_target != nullptr &&
      g_sgre_get_device_state_target != target) {
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  if (g_sgre_get_device_state_target == nullptr) {
    if (!HookFn(target, reinterpret_cast<void*>(&SgreGetDeviceStateDetour),
                reinterpret_cast<void**>(
                    &g_sgre_get_device_state_original)) ||
        g_sgre_get_device_state_original == nullptr) {
      MarkSgreDirectInputShieldNotReady();
      return false;
    }
    g_sgre_get_device_state_target = target;
  }
  g_sgre_mouse_device.store(mouse_device, std::memory_order_release);
  return PublishSgreDirectInputShieldReady();
}

void ShutdownSgreDirectInputShield() {
  g_sgre_lookup_click_runtime_enabled.store(false,
                                            std::memory_order_release);
  InvalidateSgreLookupClickTarget();
  DiscardPendingSgreLookupClickSubmits();
  g_sgre_lookup_scenario_surface.store(nullptr, std::memory_order_release);
  // Keep Required on an exact SGRE process after helper teardown: any later
  // host must fail closed until a working detour republishes Ready. Removing it
  // would misclassify this known DirectInput game as a generic HHOOK game.
  MarkSgreDirectInputShieldNotReady();
  g_sgre_direct_input_last_health_tick = 0;
}

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

void PublishSgreLookupCaptureSnapshot(const SgreLookupCapture& snapshot) {
  const uint64_t seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&g_sgre_lookup_capture_count)));
  SgreLookupCapture* capture =
      &g_sgre_lookup_captures[seq % kSgreLookupCaptureSlots];
  InterlockedExchange64(&capture->seq, 0);
  capture->valid = snapshot.valid;
  capture->text_units = snapshot.text_units;
  capture->glyph_count = snapshot.glyph_count;
  capture->line_height = snapshot.line_height;
  capture->captured_tick = snapshot.captured_tick;
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

void ResetSgreExactTextDedup() {
  if (!g_text_cs_ready) return;
  EnterCriticalSection(&g_text_cs);
  g_sgre_last_text_units = 0;
  memset(g_sgre_last_text, 0, sizeof(g_sgre_last_text));
  LeaveCriticalSection(&g_text_cs);
}

void PublishSgreExactText(const SgreLookupCapture& snapshot,
                          void* text_surface) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || snapshot.text_units == 0 ||
      snapshot.text_units > kSgreLookupMaxTextUnits) {
    return;
  }

  // This identity describes the SGRE/wind3d11 scenario renderer ABI, not a
  // measured RVA or executable hash. It does not encode the install path,
  // ASLR base or resolved RVA either. Candidate builds still have to pass the
  // complete anchor/ABI proof.
  constexpr uint64_t kSgreTextComponentIdentity = 0x5347524554455854ull;
  constexpr wchar_t kSgreTextHookCode[] = L"ENGINE:SGRE:wind3d11";
  constexpr char kSgreTextHookName[] = "SGRE exact";
  const uint64_t thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      kSgreTextComponentIdentity, kSgreTextHookCode, kSgreTextHookName);

  EnterCriticalSection(&g_text_cs);
  const size_t bytes = static_cast<size_t>(snapshot.text_units) *
                       sizeof(snapshot.text[0]);
  const bool duplicate =
      g_sgre_last_text_units == snapshot.text_units &&
      memcmp(g_sgre_last_text, snapshot.text, bytes) == 0;
  if (!duplicate) {
    fushi_voice_hook::TextLaneWrite write;
    write.thread_id = thread_id;
    write.thread_address = g_sgre_anchors.text_draw.rva;
    write.process_id = GetCurrentProcessId();
    write.source_kind = fushi_voice_hook::kTextSourceSgre;
    write.is_utf8 = 0;
    write.text = snapshot.text;
    write.byte_len = static_cast<uint32_t>(bytes);
    write.hook_name = kSgreTextHookName;
    write.hook_code = kSgreTextHookCode;
    const uint64_t published = fushi_voice_hook::WriteTextLaneEvent(
        g_header, fushi_voice_hook::kNativeThreadPreviewStart,
        fushi_voice_hook::kTextLaneCount, write);
    if (published != 0) {
      memcpy(g_sgre_last_text, snapshot.text, bytes);
      g_sgre_last_text_units = snapshot.text_units;
    }
  }
  LeaveCriticalSection(&g_text_cs);

  g_sgre_text_scenario_surface.store(text_surface,
                                     std::memory_order_release);
  // Exact engine text is cleaner than the GDI glyph fallback.  The historical
  // field name says Luna, but its contract is simply "an exact text producer
  // is active" (Siglus uses it the same way).
  g_header->luna_active = 1;
}

void CaptureSgreLookupDrawState(void* text_surface) {
  const bool text_requested =
      !g_stop && g_capture_enabled && g_header != nullptr &&
      g_text_base != nullptr && g_text_cs_ready;
  const bool lookup_requested =
      !g_stop && g_header != nullptr &&
      fushi_voice_hook::HasLookupRegion(g_header) &&
      g_header->lookup_enabled != 0;
  if (!text_requested && !lookup_requested) return;
  SgreLookupCapture snapshot;
  const SgreLookupCaptureResult capture_result =
      CopySgreLookupDrawState(text_surface, &snapshot);
  if (capture_result == SgreLookupCaptureResult::kOk) {
    if (text_requested) PublishSgreExactText(snapshot, text_surface);
    if (!lookup_requested) return;
    snapshot.valid = 1;
    snapshot.captured_tick = GetTickCount64();
    g_sgre_lookup_scenario_surface.store(text_surface,
                                         std::memory_order_release);
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  } else if (capture_result == SgreLookupCaptureResult::kNoGlyphs) {
    void* expected_text_surface = text_surface;
    if (text_requested &&
        g_sgre_text_scenario_surface.compare_exchange_strong(
            expected_text_surface, nullptr, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      ResetSgreExactTextDedup();
    }
    if (!lookup_requested) return;
    // kNoGlyphs is reached only after the exact scenario-surface vtable gate.
    // Publish a tombstone only for the same surface that last produced the
    // dialogue. Other idle instances of the same renderer class must not erase
    // a live line drawn earlier in this frame.
    if (g_sgre_lookup_scenario_surface.load(std::memory_order_acquire) !=
        text_surface) {
      return;
    }
    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.captured_tick = GetTickCount64();
  } else {
    if (lookup_requested && IsSgreLookupCaptureFault(capture_result)) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorFault;
    }
    return;
  }
  PublishSgreLookupCaptureSnapshot(snapshot);
}

bool CopySgreUiDrawContext(const char* utf8_text,
                           SgreUiDrawContext* context) {
  if (utf8_text == nullptr || context == nullptr) return false;
  *context = SgreUiDrawContext();
  __try {
    while (context->utf8_bytes + 1 < kSgreUiTextBytes &&
           utf8_text[context->utf8_bytes] != '\0') {
      ++context->utf8_bytes;
    }
    if (context->utf8_bytes == 0 ||
        context->utf8_bytes + 1 >= kSgreUiTextBytes ||
        utf8_text[context->utf8_bytes] != '\0') {
      return false;
    }
    memcpy(context->utf8, utf8_text, context->utf8_bytes);
    context->utf8[context->utf8_bytes] = '\0';
    context->active = 1;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    *context = SgreUiDrawContext();
    return false;
  }
}

bool CaptureSgreUiRasterRun(void* vector_font, void* raw_image,
                            int32_t dst_x, int32_t dst_y, void* layout,
                            float origin_x, float origin_y,
                            SgreUiTextRun* run) {
  if (run == nullptr || vector_font == nullptr || raw_image == nullptr ||
      layout == nullptr || g_sgre_ui_draw_context.active != 1) {
    return false;
  }
  *run = SgreUiTextRun();
  __try {
    const auto* font = reinterpret_cast<const uint8_t*>(vector_font);
    const auto* raw = reinterpret_cast<const uint8_t*>(raw_image);
    const auto* layout_bytes = reinterpret_cast<const uint8_t*>(layout);
    const int32_t line_height_i =
        *reinterpret_cast<const int32_t*>(font + 0x50);
    const int32_t raw_width = *reinterpret_cast<const int32_t*>(raw + 0x18);
    const int32_t raw_height = *reinterpret_cast<const int32_t*>(raw + 0x1c);
    auto* begin = *reinterpret_cast<SgreUiLayoutGlyph* const*>(layout_bytes);
    auto* end =
        *reinterpret_cast<SgreUiLayoutGlyph* const*>(layout_bytes + 0x08);
    if (line_height_i <= 0 || line_height_i > 512 || raw_width <= 0 ||
        raw_height <= 0 || raw_width > 16384 || raw_height > 16384 ||
        begin == nullptr || end == nullptr || end < begin) {
      return false;
    }
    const size_t count = static_cast<size_t>(end - begin);
    if (count == 0 || count > kSgreUiMaxGlyphsPerRun) return false;
    uint16_t line = 0;
    for (size_t i = 0; i < count; ++i) {
      const float pen_x = begin[i].pen_x;
      const float pen_y = begin[i].pen_y;
      if (!std::isfinite(pen_x) || !std::isfinite(pen_y)) return false;
      if (i != 0 &&
          (pen_y > begin[i - 1].pen_y + 0.5f ||
           pen_x <= begin[i - 1].pen_x)) {
        if (++line >= kSgreLookupMaxLines) return false;
      }
      float width = static_cast<float>(line_height_i);
      if (i + 1 < count &&
          std::abs(begin[i + 1].pen_y - pen_y) <= 0.5f) {
        const float advance = begin[i + 1].pen_x - pen_x;
        if (std::isfinite(advance) && advance > 0.0f && advance <= 512.0f) {
          width = advance;
        }
      }
      auto& glyph = run->local_glyphs[i];
      glyph.x = static_cast<float>(dst_x) + origin_x + pen_x;
      glyph.y = static_cast<float>(dst_y) + origin_y + pen_y;
      glyph.width = width;
      glyph.height = static_cast<float>(line_height_i);
      glyph.line = line;
      if (!std::isfinite(glyph.x) || !std::isfinite(glyph.y) ||
          glyph.x < -512.0f || glyph.y < -512.0f ||
          glyph.x > raw_width + 512.0f ||
          glyph.y > raw_height + 512.0f) {
        return false;
      }
    }
    run->utf8_bytes = g_sgre_ui_draw_context.utf8_bytes;
    memcpy(run->utf8, g_sgre_ui_draw_context.utf8,
           run->utf8_bytes + 1);
    run->glyph_count = static_cast<uint32_t>(count);
    run->line_height = static_cast<float>(line_height_i);
    run->captured_tick = GetTickCount64();
    run->valid = 1;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    *run = SgreUiTextRun();
    return false;
  }
}

void StoreSgreUiRawRun(void* raw_image, const SgreUiTextRun& run) {
  if (raw_image == nullptr || run.valid != 1) return;
  AcquireSRWLockExclusive(&g_sgre_ui_metadata_lock);
  size_t selected = 0;
  ULONGLONG oldest = UINT64_MAX;
  for (size_t i = 0; i < kSgreUiRawRunSlots; ++i) {
    if (g_sgre_ui_raw_runs[i].raw_image == nullptr) {
      selected = i;
      oldest = 0;
      break;
    }
    if (g_sgre_ui_raw_runs[i].run.captured_tick < oldest) {
      oldest = g_sgre_ui_raw_runs[i].run.captured_tick;
      selected = i;
    }
  }
  auto& slot = g_sgre_ui_raw_runs[selected];
  slot.raw_image = raw_image;
  slot.sequence = ++g_sgre_ui_raw_run_sequence;
  slot.run = run;
  ReleaseSRWLockExclusive(&g_sgre_ui_metadata_lock);
}

void __fastcall SgreUiDrawTextTraceDetour(
    void* raw_image_ex, void* font_descriptor, const char* utf8_text,
    int32_t x, int32_t y, int32_t horizontal_align,
    int32_t vertical_align) {
  const SgreUiDrawContext previous = g_sgre_ui_draw_context;
  CopySgreUiDrawContext(utf8_text, &g_sgre_ui_draw_context);
  if (g_sgre_ui_draw_text_original != nullptr) {
    g_sgre_ui_draw_text_original(raw_image_ex, font_descriptor, utf8_text, x,
                                 y, horizontal_align, vertical_align);
  }
  g_sgre_ui_draw_context = previous;
}

void __fastcall SgreUiRasterTextDetour(
    void* vector_font, void* raw_image, int32_t dst_x, int32_t dst_y,
    int32_t canvas_width, int32_t canvas_height, void* layout,
    float origin_x, float origin_y, int32_t style_70,
    int32_t style_74, int32_t style_78, int32_t style_7c, int32_t style_80,
    int32_t style_84) {
  SgreUiTextRun run;
  const bool captured = CaptureSgreUiRasterRun(
      vector_font, raw_image, dst_x, dst_y, layout, origin_x, origin_y, &run);
  if (g_sgre_ui_raster_text_original != nullptr) {
    g_sgre_ui_raster_text_original(
        vector_font, raw_image, dst_x, dst_y, canvas_width, canvas_height,
        layout, origin_x, origin_y, style_70, style_74, style_78,
        style_7c, style_80, style_84);
  }
  if (captured) StoreSgreUiRawRun(raw_image, run);
}

SgreUiLayerRecord* FindOrAllocateSgreUiLayerLocked(void* layer) {
  size_t selected = 0;
  ULONGLONG oldest = UINT64_MAX;
  for (size_t i = 0; i < kSgreUiLayerSlots; ++i) {
    if (g_sgre_ui_layers[i].layer == layer) return &g_sgre_ui_layers[i];
    if (g_sgre_ui_layers[i].layer == nullptr) return &g_sgre_ui_layers[i];
    if (g_sgre_ui_layers[i].last_seen_tick < oldest) {
      oldest = g_sgre_ui_layers[i].last_seen_tick;
      selected = i;
    }
  }
  return &g_sgre_ui_layers[selected];
}

void __fastcall SgreUiRawImageUploadDetour(void* layer, void* raw_image) {
  if (g_sgre_ui_raw_image_upload_original != nullptr) {
    g_sgre_ui_raw_image_upload_original(layer, raw_image);
  }
  if (layer == nullptr) return;
  const ULONGLONG now = GetTickCount64();
  AcquireSRWLockExclusive(&g_sgre_ui_metadata_lock);
  SgreUiLayerRecord* destination = FindOrAllocateSgreUiLayerLocked(layer);
  *destination = SgreUiLayerRecord();
  destination->layer = layer;
  destination->generation = ++g_sgre_ui_layer_generation;
  for (size_t pass = 0; pass < kSgreUiMaxRunsPerLayer; ++pass) {
    size_t selected = kSgreUiRawRunSlots;
    uint64_t sequence = UINT64_MAX;
    for (size_t i = 0; i < kSgreUiRawRunSlots; ++i) {
      const auto& source = g_sgre_ui_raw_runs[i];
      if (source.raw_image == raw_image && source.sequence < sequence &&
          source.run.valid == 1 && now >= source.run.captured_tick &&
          now - source.run.captured_tick <= kSgreUiRawRunMaxAgeMs) {
        selected = i;
        sequence = source.sequence;
      }
    }
    if (selected == kSgreUiRawRunSlots) break;
    destination->runs[destination->run_count++].run =
        g_sgre_ui_raw_runs[selected].run;
    g_sgre_ui_raw_runs[selected] = SgreUiRawRunRecord();
  }
  // An upload is authoritative replacement.  Any unmatched or excess raw
  // runs are invalidated rather than leaking hitboxes into a reused texture.
  for (auto& source : g_sgre_ui_raw_runs) {
    if (source.raw_image == raw_image) source = SgreUiRawRunRecord();
  }
  ReleaseSRWLockExclusive(&g_sgre_ui_metadata_lock);
}

bool TransformSgreUiLayerSnapshot(void* layer, SgreUiLayerRecord* snapshot) {
  if (layer == nullptr || snapshot == nullptr ||
      g_sgre_ui_compute_screen_aabb == nullptr ||
      g_sgre_ui_renderer_context_slot == nullptr) {
    return false;
  }
  __try {
    const auto* bytes = reinterpret_cast<const uint8_t*>(layer);
    const uint32_t lifecycle =
        *reinterpret_cast<const uint32_t*>(bytes + 0x18);
    const uint32_t hidden = *reinterpret_cast<const uint32_t*>(bytes + 0x1c);
    if (lifecycle == 2 || hidden != 0) return false;
    const float layer_x = *reinterpret_cast<const float*>(bytes + 0xb8);
    const float layer_y = *reinterpret_cast<const float*>(bytes + 0xbc);
    void* renderer_context = *g_sgre_ui_renderer_context_slot;
    if (!std::isfinite(layer_x) || !std::isfinite(layer_y) ||
        renderer_context == nullptr) {
      return false;
    }
    for (uint32_t r = 0; r < snapshot->run_count; ++r) {
      auto& layer_run = snapshot->runs[r];
      for (uint32_t g = 0; g < layer_run.run.glyph_count; ++g) {
        const auto& local = layer_run.run.local_glyphs[g];
        SgreUiFloatRect input{layer_x + local.x, layer_y + local.y,
                              layer_x + local.x + local.width,
                              layer_y + local.y + local.height};
        SgreUiFloatRect output;
        if (g_sgre_ui_compute_screen_aabb(renderer_context, &output, &input) !=
            &output) {
          return false;
        }
        const float output_width = output.right - output.left;
        const float output_height = output.bottom - output.top;
        if (!std::isfinite(output.left) || !std::isfinite(output.top) ||
            !std::isfinite(output.right) || !std::isfinite(output.bottom) ||
            !std::isfinite(output_width) || !std::isfinite(output_height) ||
            output_width <= 0.0f || output_height <= 0.0f ||
            output_width > 2048.0f || output_height > 2048.0f ||
            output.left < -2048.0f || output.top < -2048.0f ||
            output.left > 16384.0f || output.top > 16384.0f) {
          return false;
        }
        auto& screen = layer_run.screen_glyphs[g];
        screen.x = output.left;
        screen.y = output.top;
        screen.width = output_width;
        screen.height = output_height;
        screen.line = static_cast<uint16_t>(r % kSgreLookupMaxLines);
      }
    }
    return snapshot->run_count != 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void __fastcall SgreUiLayerRawTexDrawDetour(void* layer) {
  bool transformed = false;
  bool owns_guard = false;
  uint64_t generation = 0;
  if (!g_sgre_ui_layer_draw_reentrant && layer != nullptr) {
    g_sgre_ui_layer_draw_reentrant = true;
    owns_guard = true;
    AcquireSRWLockShared(&g_sgre_ui_metadata_lock);
    bool found = false;
    for (const auto& candidate : g_sgre_ui_layers) {
      if (candidate.layer == layer && candidate.run_count != 0) {
        g_sgre_ui_layer_snapshot = candidate;
        generation = candidate.generation;
        found = true;
        break;
      }
    }
    ReleaseSRWLockShared(&g_sgre_ui_metadata_lock);
    if (found) {
      transformed = TransformSgreUiLayerSnapshot(
          layer, &g_sgre_ui_layer_snapshot);
    }
  }
  if (g_sgre_ui_layer_raw_tex_draw_original != nullptr) {
    g_sgre_ui_layer_raw_tex_draw_original(layer);
  }
  if (owns_guard) {
    AcquireSRWLockExclusive(&g_sgre_ui_metadata_lock);
    for (auto& candidate : g_sgre_ui_layers) {
      if (candidate.layer == layer && candidate.generation == generation) {
        if (transformed) {
          candidate = g_sgre_ui_layer_snapshot;
          candidate.screen_valid = 1;
          candidate.last_seen_tick = GetTickCount64();
        } else {
          candidate.screen_valid = 0;
          candidate.last_seen_tick = 0;
        }
        break;
      }
    }
    ReleaseSRWLockExclusive(&g_sgre_ui_metadata_lock);
    g_sgre_ui_layer_draw_reentrant = false;
  }
}

bool InstallSgreUiDrawTextTrace() {
  if (InterlockedCompareExchange(&g_sgre_ui_hook_install_state, 0, 0) == 1) {
    return true;
  }
  if (!g_sgre_anchors.ui_lookup_chain_available()) return false;
  if (InterlockedCompareExchange(&g_sgre_ui_hook_install_state, 2, 0) != 0) {
    return false;
  }
  HMODULE executable = GetModuleHandleW(nullptr);
  if (executable == nullptr) {
    InterlockedExchange(&g_sgre_ui_hook_install_state, -1);
    return false;
  }
  const uintptr_t base = reinterpret_cast<uintptr_t>(executable);
  g_sgre_ui_compute_screen_aabb = reinterpret_cast<SgreUiComputeScreenAabbFn>(
      base + g_sgre_anchors.ui_compute_screen_aabb.rva);
  g_sgre_ui_renderer_context_slot = reinterpret_cast<void**>(
      base + g_sgre_anchors.ui_renderer_context.rva);
  const bool raster = HookFn(
      reinterpret_cast<void*>(base + g_sgre_anchors.ui_raster_text.rva),
      reinterpret_cast<void*>(&SgreUiRasterTextDetour),
      reinterpret_cast<void**>(&g_sgre_ui_raster_text_original));
  const bool upload = raster && HookFn(
      reinterpret_cast<void*>(base + g_sgre_anchors.ui_raw_image_upload.rva),
      reinterpret_cast<void*>(&SgreUiRawImageUploadDetour),
      reinterpret_cast<void**>(&g_sgre_ui_raw_image_upload_original));
  const bool draw = upload && HookFn(
      reinterpret_cast<void*>(base + g_sgre_anchors.ui_layer_raw_tex_draw.rva),
      reinterpret_cast<void*>(&SgreUiLayerRawTexDrawDetour),
      reinterpret_cast<void**>(&g_sgre_ui_layer_raw_tex_draw_original));
  const bool common = draw && HookFn(
      reinterpret_cast<void*>(base + g_sgre_anchors.ui_draw_text.rva),
      reinterpret_cast<void*>(&SgreUiDrawTextTraceDetour),
      reinterpret_cast<void**>(&g_sgre_ui_draw_text_original));
  InterlockedExchange(&g_sgre_ui_hook_install_state, common ? 1 : -1);
  return common;
}

void __fastcall SgreTextDrawDetour(void* text_surface) {
  CaptureSgreLookupDrawState(text_surface);
  if (g_sgre_text_draw_original != nullptr) {
    g_sgre_text_draw_original(text_surface);
  }
}

bool InstallSgreLookupSensor() {
  if (!IsSgreLookupStructureMatched()) return false;
  if (g_sgre_text_draw_original != nullptr) {
    InstallSgreUiDrawTextTrace();
    if (g_header != nullptr) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorInstalled;
    }
    return true;
  }
  HMODULE executable = GetModuleHandleW(nullptr);
  if (executable == nullptr || !g_sgre_anchors.lookup_sensor_available()) {
    return false;
  }
  auto* target =
      reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(executable) +
                              g_sgre_anchors.text_draw.rva);
  g_sgre_scenario_text_vtable =
      reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(executable) +
                              g_sgre_anchors.scenario_text_vtable.rva);
  const bool installed =
      HookFn(target, reinterpret_cast<void*>(&SgreTextDrawDetour),
             reinterpret_cast<void**>(&g_sgre_text_draw_original));
  if (installed) InstallSgreUiDrawTextTrace();
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

bool AppendSgreLookupSeparator(SgreLookupCapture* capture) {
  if (capture == nullptr || capture->text_units == 0 ||
      capture->text_units >= kSgreLookupMaxTextUnits ||
      capture->glyph_count >= kSgreLookupMaxGlyphs) {
    return capture != nullptr && capture->text_units == 0;
  }
  const size_t index = capture->text_units++;
  capture->glyph_count++;
  capture->text[index] = L'\n';
  capture->glyphs[index] = {};
  capture->glyphs[index].x = -10000.0f;
  capture->glyph_spaces[index] = kSgreLookupGlyphSpaceClientPixels;
  return true;
}

bool AppendSgreUiRunToCapture(const SgreUiLayerRun& layer_run,
                              SgreLookupCapture* capture) {
  if (capture == nullptr || layer_run.run.valid != 1 ||
      layer_run.run.glyph_count == 0 ||
      layer_run.run.glyph_count > kSgreUiMaxGlyphsPerRun) {
    return false;
  }
  wchar_t decoded[kSgreUiMaxGlyphsPerRun] = {};
  const int units = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, layer_run.run.utf8,
      static_cast<int>(layer_run.run.utf8_bytes), decoded,
      static_cast<int>(kSgreUiMaxGlyphsPerRun));
  if (units <= 0 || static_cast<uint32_t>(units) != layer_run.run.glyph_count) {
    return false;
  }
  for (int i = 0; i < units; ++i) {
    if (decoded[i] == L'\0' ||
        (decoded[i] >= 0xd800 && decoded[i] <= 0xdfff)) {
      return false;
    }
    const auto& geometry = layer_run.screen_glyphs[i];
    if (!std::isfinite(geometry.x) || !std::isfinite(geometry.y) ||
        !std::isfinite(geometry.width) || !std::isfinite(geometry.height) ||
        geometry.width <= 0.0f || geometry.height <= 0.0f) {
      return false;
    }
  }
  const size_t separator = capture->text_units == 0 ? 0 : 1;
  if (capture->text_units + separator + static_cast<size_t>(units) >
          kSgreLookupMaxTextUnits ||
      capture->glyph_count + separator + static_cast<size_t>(units) >
          kSgreLookupMaxGlyphs ||
      (separator != 0 && !AppendSgreLookupSeparator(capture))) {
    return false;
  }
  const size_t at = capture->text_units;
  memcpy(capture->text + at, decoded,
         static_cast<size_t>(units) * sizeof(wchar_t));
  memcpy(capture->glyphs + at, layer_run.screen_glyphs,
         static_cast<size_t>(units) * sizeof(layer_run.screen_glyphs[0]));
  memset(capture->glyph_spaces + at, kSgreLookupGlyphSpaceClientPixels,
         static_cast<size_t>(units));
  capture->text_units += static_cast<uint32_t>(units);
  capture->glyph_count += static_cast<uint32_t>(units);
  capture->line_height = std::max(capture->line_height,
                                  layer_run.run.line_height);
  capture->captured_tick =
      std::max(capture->captured_tick, layer_run.run.captured_tick);
  return true;
}

bool BuildSgreUiLookupCapture(ULONGLONG now, SgreLookupCapture* capture) {
  if (capture == nullptr) return false;
  *capture = SgreLookupCapture();
  AcquireSRWLockShared(&g_sgre_ui_metadata_lock);
  for (const auto& layer : g_sgre_ui_layers) {
    if (layer.layer == nullptr || layer.screen_valid != 1 ||
        layer.run_count == 0 || layer.last_seen_tick == 0 ||
        now < layer.last_seen_tick ||
        now - layer.last_seen_tick > kSgreUiVisibleMaxAgeMs) {
      continue;
    }
    for (uint32_t run = 0; run < layer.run_count; ++run) {
      AppendSgreUiRunToCapture(layer.runs[run], capture);
    }
    capture->captured_tick =
        std::max(capture->captured_tick, layer.last_seen_tick);
  }
  ReleaseSRWLockShared(&g_sgre_ui_metadata_lock);
  capture->valid = capture->text_units != 0 &&
                           capture->text_units == capture->glyph_count
                       ? 1u
                       : 0u;
  return capture->valid == 1;
}

bool AppendSgreLookupCapture(const SgreLookupCapture& source,
                             SgreLookupCapture* destination) {
  if (destination == nullptr || source.valid != 1 || source.text_units == 0 ||
      source.text_units != source.glyph_count) {
    return false;
  }
  const size_t separator = destination->text_units == 0 ? 0 : 1;
  if (destination->text_units + separator + source.text_units >
          kSgreLookupMaxTextUnits ||
      destination->glyph_count + separator + source.glyph_count >
          kSgreLookupMaxGlyphs ||
      (separator != 0 && !AppendSgreLookupSeparator(destination))) {
    return false;
  }
  const size_t at = destination->text_units;
  memcpy(destination->text + at, source.text,
         static_cast<size_t>(source.text_units) * sizeof(wchar_t));
  memcpy(destination->glyphs + at, source.glyphs,
         static_cast<size_t>(source.glyph_count) * sizeof(source.glyphs[0]));
  memcpy(destination->glyph_spaces + at, source.glyph_spaces,
         static_cast<size_t>(source.glyph_count));
  destination->text_units += source.text_units;
  destination->glyph_count += source.glyph_count;
  destination->line_height =
      std::max(destination->line_height, source.line_height);
  destination->captured_tick =
      std::max(destination->captured_tick, source.captured_tick);
  destination->valid = 1;
  return true;
}

bool PublishSgreLookupHit(uint64_t capture_generation,
                          const std::wstring& line, uint32_t char_index,
                          const fushi_voice_hook::SgreLookupRect& rect,
                          int32_t client_width, int32_t client_height) {
  if (g_header == nullptr || capture_generation == 0 ||
      char_index >= line.size()) return false;
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, line.data(), static_cast<int>(line.size()), utf8,
      static_cast<int>(sizeof(utf8)), nullptr, nullptr);
  if (bytes <= 0) return false;
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdSgre;
  publication.char_index = char_index;
  publication.source_length = fushi_voice_hook::LookupUtf16SourceLength(
      line.data(), static_cast<uint32_t>(line.size()), char_index);
  publication.char_count = static_cast<uint32_t>(line.size());
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = capture_generation;
  publication.geometry_generation = capture_generation;
  publication.glyph_x = rect.x;
  publication.glyph_y = rect.y;
  publication.glyph_w = rect.width;
  publication.glyph_h = rect.height;
  publication.view_w = client_width;
  publication.view_h = client_height;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(bytes);
  return fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header, publication);
}

void ClearSgreLookupActiveCapture() {
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSgre);
  }
  g_sgre_lookup_active_valid = false;
  g_sgre_lookup_active_line.clear();
  g_sgre_lookup_active_mapped = 0;
  g_sgre_lookup_active_generation = 0;
  g_sgre_lookup_active_capture_tick = 0;
  InvalidateSgreLookupClickTarget();
}

bool IsSgreLookupPayloadCurrent(const SgreLookupClickPayload& payload) {
  // capture_count/processed_seq are transport cursors, not content identity.
  // SGRE redraws an unchanged line every frame, so requiring those cursors to
  // remain equal across mouse-down, mouse-up and the worker drain races the
  // renderer and silently drops otherwise valid lookup submits.  The stable
  // logical generation, text, client transform and glyph rectangle checks
  // below still reject genuinely stale clicks.
  if (!g_sgre_lookup_active_valid || g_sgre_lookup_active_generation == 0 ||
      payload.text_units == 0 ||
      payload.text_units != g_sgre_lookup_active_line.size() ||
      payload.char_index >= payload.text_units ||
      payload.char_index >= g_sgre_lookup_active_capture.glyph_count ||
      memcmp(payload.text, g_sgre_lookup_active_line.data(),
             static_cast<size_t>(payload.text_units) * sizeof(wchar_t)) != 0) {
    return false;
  }

  const HWND game = reinterpret_cast<HWND>(payload.game_window);
  RECT client = {};
  POINT origin = {0, 0};
  if (game == nullptr || !IsWindow(game) || GetForegroundWindow() != game ||
      g_sgre_direct_input_game_window.load(std::memory_order_acquire) != game ||
      !GetClientRect(game, &client) || !ClientToScreen(game, &origin)) {
    return false;
  }
  const fushi_voice_hook::SgreLookupClientSnapshot active_client = {
      reinterpret_cast<uintptr_t>(game), origin.x, origin.y,
      client.right - client.left, client.bottom - client.top};
  if (!fushi_voice_hook::MatchesSgreLookupGenerationAndClient(
          payload.logical_generation, SgreLookupPayloadClientSnapshot(payload),
          g_sgre_lookup_active_generation, active_client)) {
    return false;
  }

  fushi_voice_hook::SgreLookupRect expected;
  if (!SgreLookupRectForCapturedGlyph(
          g_sgre_lookup_active_capture, payload.char_index,
          active_client.width, active_client.height, &expected)) {
    return false;
  }
  return payload.rect.x == expected.x && payload.rect.y == expected.y &&
         payload.rect.width == expected.width &&
         payload.rect.height == expected.height;
}

bool PublishSgreLookupClickPayload(const SgreLookupClickPayload& payload) {
  if (payload.text_units == 0 || payload.text_units > kSgreLookupMaxTextUnits ||
      payload.char_index >= payload.text_units ||
      !IsSgreLookupPayloadCurrent(payload)) {
    return false;
  }
  const ULONGLONG now = GetTickCount64();
  // The renderer republishes the same line with a new capture sequence every
  // frame. De-duplicate Shift+click by stable visible content and geometry,
  // never by that volatile sequence.
  uint64_t identity = 1469598103934665603ull;
  const auto hash_value = [&identity](uint64_t value) {
    identity ^= value;
    identity *= 1099511628211ull;
  };
  hash_value(payload.text_units);
  for (uint32_t index = 0; index < payload.text_units; ++index) {
    hash_value(static_cast<uint32_t>(payload.text[index]));
  }
  hash_value(payload.char_index);
  hash_value(static_cast<uint32_t>(payload.rect.x));
  hash_value(static_cast<uint32_t>(payload.rect.y));
  hash_value(static_cast<uint32_t>(payload.rect.width));
  hash_value(static_cast<uint32_t>(payload.rect.height));
  if (identity == g_sgre_lookup_last_hit_identity &&
      now >= g_sgre_lookup_last_hit_tick &&
      now - g_sgre_lookup_last_hit_tick <=
          kSgreLookupDuplicateHitWindowMs) {
    return false;
  }
  const std::wstring line(payload.text, payload.text + payload.text_units);
  if (!IsSgreLookupPayloadCurrent(payload) ||
      !PublishSgreLookupHit(payload.logical_generation, line,
                            payload.char_index,
                            payload.rect, payload.client_width,
                            payload.client_height)) {
    return false;
  }
  g_sgre_lookup_last_hit_identity = identity;
  g_sgre_lookup_last_hit_tick = now;
  return true;
}

void ProcessSgreLookupTick() {
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header)) {
    if (g_header != nullptr) {
      fushi_voice_hook::g_geometry_provider_registry.Retire(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSgre);
    }
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    InvalidateSgreLookupClickTarget();
    DiscardPendingSgreLookupClickSubmits();
    return;
  }
  // Install the structurally admitted draw hook for the engine-text lane even
  // when the optional in-game lookup preference is off. Hash-miss candidate
  // builds do not have a SHA-keyed Luna profile, so coupling installation to
  // lookup_enabled would make their normal hook text disappear as well.
  if (!InstallSgreLookupSensor()) {
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    ClearSgreLookupActiveCapture();
    return;
  }
  if (g_header->lookup_enabled == 0) {
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    g_sgre_lookup_last_shift_down = false;
    ClearSgreLookupActiveCapture();
    DiscardPendingSgreLookupClickSubmits();
    return;
  }
  if (!IsSgreDirectInputShieldOperational()) {
    // The draw hook remains active for the exact engine-text lane, but no
    // clickable geometry or click submit is admitted until the DirectInput
    // detour has committed its Ready property. This prevents a stale host
    // preference from re-enabling click-through while the shield is pending.
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    g_sgre_lookup_last_shift_down = false;
    ClearSgreLookupActiveCapture();
    DiscardPendingSgreLookupClickSubmits();
    return;
  }
  const ULONGLONG now = GetTickCount64();
  SgreLookupCapture scenario;
  uint64_t capture_seq = 0;
  if (ReadLatestSgreLookupCapture(&scenario, &capture_seq)) {
    g_sgre_lookup_processed_seq = capture_seq;
    if (scenario.valid == 1 && scenario.text_units != 0 &&
        scenario.text_units == scenario.glyph_count &&
        scenario.text_units <= kSgreLookupMaxTextUnits &&
        scenario.captured_tick != 0 && now >= scenario.captured_tick &&
        now - scenario.captured_tick <= kSgreLookupActiveCaptureMaxAgeMs) {
      g_sgre_lookup_scenario_capture = scenario;
      g_sgre_lookup_scenario_capture_valid = true;
    } else {
      g_sgre_lookup_scenario_capture_valid = false;
    }
  }
  if (g_sgre_lookup_scenario_capture_valid &&
      (now < g_sgre_lookup_scenario_capture.captured_tick ||
       now - g_sgre_lookup_scenario_capture.captured_tick >
           kSgreLookupActiveCaptureMaxAgeMs)) {
    g_sgre_lookup_scenario_capture_valid = false;
  }

  SgreLookupCapture candidate;
  SgreLookupCapture ui_capture;
  if (g_sgre_lookup_scenario_capture_valid) {
    AppendSgreLookupCapture(g_sgre_lookup_scenario_capture, &candidate);
  }
  if (BuildSgreUiLookupCapture(now, &ui_capture)) {
    AppendSgreLookupCapture(ui_capture, &candidate);
  }
  if (candidate.valid == 1 && candidate.text_units != 0 &&
      candidate.text_units == candidate.glyph_count) {
    const bool same_logical_snapshot =
        g_sgre_lookup_active_valid &&
        fushi_voice_hook::SameSgreLookupLogicalSnapshot(
            reinterpret_cast<const char16_t*>(
                g_sgre_lookup_active_capture.text),
            g_sgre_lookup_active_capture.text_units,
            g_sgre_lookup_active_capture.glyphs,
            g_sgre_lookup_active_capture.glyph_count,
            g_sgre_lookup_active_capture.line_height,
            reinterpret_cast<const char16_t*>(candidate.text),
            candidate.text_units, candidate.glyphs, candidate.glyph_count,
            candidate.line_height) &&
        memcmp(g_sgre_lookup_active_capture.glyph_spaces,
               candidate.glyph_spaces, candidate.glyph_count) == 0;
    if (!same_logical_snapshot) {
      g_sgre_lookup_generation_counter =
          fushi_voice_hook::NextSgreLookupLogicalGeneration(
              g_sgre_lookup_generation_counter);
    }
    g_sgre_lookup_active_capture = candidate;
    g_sgre_lookup_active_line.assign(
        candidate.text, candidate.text + candidate.text_units);
    for (size_t i = 0; i < candidate.glyph_count; ++i) {
      g_sgre_lookup_active_char_indices[i] = static_cast<uint32_t>(i);
    }
    g_sgre_lookup_active_mapped = candidate.glyph_count;
    g_sgre_lookup_active_valid = true;
    g_sgre_lookup_active_generation = g_sgre_lookup_generation_counter;
    g_sgre_lookup_active_capture_tick = candidate.captured_tick;
  } else {
    ClearSgreLookupActiveCapture();
  }

  // Publish the provider's current readiness before draining an up event.
  // PublishHit is deliberately fail-closed unless the registry already owns
  // a ready offer; doing this afterwards could consume the queued click while
  // an admission/owner handoff rejects its immutable payload.
  bool owns_geometry = false;
  if (g_sgre_lookup_active_valid && g_sgre_lookup_active_mapped != 0) {
    fushi_voice_hook::g_geometry_provider_registry.OfferReady(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSgre);
    owns_geometry =
        fushi_voice_hook::g_geometry_provider_registry.OwnsReadyProvider(
            g_header,
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSgre);
  } else {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSgre);
  }
  g_sgre_lookup_click_runtime_enabled.store(owns_geometry,
                                             std::memory_order_release);
  if (!owns_geometry) {
    g_sgre_lookup_last_shift_down = false;
    InvalidateSgreLookupClickTarget();
    DiscardPendingSgreLookupClickSubmits();
    return;
  }

  // Drain queued ups only after consuming the latest renderer snapshot and
  // publishing its readiness.  The final publication gate then compares the
  // down epoch and client transform against this active logical generation.
  bool click_submitted = false;
  SgreLookupClickEvent click_event;
  uint64_t click_event_seq = 0;
  if (ReadLatestSgreLookupClickSubmit(&click_event, &click_event_seq)) {
    g_sgre_lookup_click_processed_seq = click_event_seq;
    const HWND click_game =
        g_sgre_direct_input_game_window.load(std::memory_order_acquire);
    if (GetValidPublishedSgreDirectInputShieldPopup(click_game) == nullptr &&
        !IsLookupOverlayInputShieldVisible()) {
      click_submitted = PublishSgreLookupClickPayload(click_event.payload);
    }
  }

  const uint16_t shift_state =
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT));
  const bool submit = fushi_voice_hook::ConsumeSgreLookupShiftSample(
      shift_state, &g_sgre_lookup_last_shift_down);
  if (!g_sgre_lookup_active_valid || g_sgre_lookup_active_mapped == 0) {
    InvalidateSgreLookupClickTarget();
    return;
  }
  const SgreLookupCapture& active = g_sgre_lookup_active_capture;

  HWND game = FindGameMainWindow();
  RECT client = {};
  POINT cursor = {};
  POINT client_origin = {0, 0};
  if (game == nullptr || !GetClientRect(game, &client) ||
      !ClientToScreen(game, &client_origin) || !GetCursorPos(&cursor)) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSgre);
    InvalidateSgreLookupClickTarget();
    return;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  const HWND click_game =
      g_sgre_direct_input_game_window.load(std::memory_order_acquire);
  const bool popup_visible =
      GetValidPublishedSgreDirectInputShieldPopup(click_game) != nullptr ||
      IsLookupOverlayInputShieldVisible();
  if (click_game == game && !popup_visible) {
    PublishSgreLookupClickTarget(active, g_sgre_lookup_active_generation, game,
                                 client_origin, client_width, client_height);
  } else {
    InvalidateSgreLookupClickTarget();
  }

  const HWND point_window = WindowFromPoint(cursor);
  const bool game_point =
      GetForegroundWindow() == game && point_window != nullptr &&
      (point_window == game || IsChild(game, point_window));
  cursor.x -= client_origin.x;
  cursor.y -= client_origin.y;
  fushi_voice_hook::SgreLookupRect hit_rect;
  const int glyph_index = FindSgreCapturedLookupGlyph(
      active, client_width, client_height, cursor.x, cursor.y, &hit_rect);

  if (submit && glyph_index >= 0 && !click_submitted && !popup_visible &&
      game_point) {
    SgreLookupClickPayload shift_payload;
    FillSgreLookupClickPayload(
        &shift_payload, active, g_sgre_lookup_active_generation,
        g_sgre_lookup_active_char_indices[glyph_index], hit_rect, game,
        client_origin, client_width, client_height);
    PublishSgreLookupClickPayload(shift_payload);
  }
}

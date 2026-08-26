// SGRE in-game lookup sensor. The executable identity gate lives in
// sgre_profile.h. UserHook1 (0x328e0) is a pre-layout stream: it can run ahead
// of the visible dialogue and still contains MAGES controls. The sensor hooks
// the admitted draw boundary instead, copies the renderer's flattened visible
// glyph vector, and therefore receives both game-parsed text and live geometry.
// UTF-8 conversion and IPC publication stay on HookWorker. The DirectInput
// detour only copies a fixed snapshot and rechecks the physical point on a
// fresh click; it never allocates, encodes, logs, or touches shared-memory IPC.

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
  ULONGLONG captured_tick = 0;
  wchar_t text[kSgreLookupMaxTextUnits] = {};
  fushi_voice_hook::SgreLookupGlyphGeometry glyphs[kSgreLookupMaxGlyphs] = {};
};

using SgreTextDrawFn = void(__fastcall*)(void*);
using SgreGetDeviceStateFn =
    HRESULT(STDMETHODCALLTYPE*)(void*, DWORD, LPVOID);

SgreTextDrawFn g_sgre_text_draw_original = nullptr;
const void* g_sgre_scenario_text_vtable = nullptr;
SgreLookupCapture g_sgre_lookup_captures[kSgreLookupCaptureSlots] = {};
volatile LONG64 g_sgre_lookup_capture_count = 0;
std::atomic<void*> g_sgre_lookup_scenario_surface{nullptr};
uint64_t g_sgre_lookup_processed_seq = 0;
bool g_sgre_lookup_last_shift_down = false;
SgreLookupCapture g_sgre_lookup_active_capture = {};
std::wstring g_sgre_lookup_active_line;
uint32_t g_sgre_lookup_active_char_indices[kSgreLookupMaxGlyphs] = {};
size_t g_sgre_lookup_active_mapped = 0;
bool g_sgre_lookup_active_valid = false;
uint64_t g_sgre_lookup_active_capture_seq = 0;
ULONGLONG g_sgre_lookup_active_capture_tick = 0;

constexpr size_t kSgreLookupClickEventSlots = 4;
constexpr ULONGLONG kSgreLookupClickTargetMaxAgeMs = 64;
constexpr ULONGLONG kSgreLookupActiveCaptureMaxAgeMs = 128;
constexpr ULONGLONG kSgreLookupDuplicateHitWindowMs = 250;

struct SgreLookupClickPayload {
  uint64_t capture_seq = 0;
  uint32_t text_units = 0;
  uint32_t char_index = 0;
  fushi_voice_hook::SgreLookupRect rect;
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
  uint64_t capture_seq = 0;
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
    uint64_t capture_seq, uint32_t char_index,
    const fushi_voice_hook::SgreLookupRect& rect, int32_t client_width,
    int32_t client_height) {
  if (payload == nullptr) return;
  *payload = SgreLookupClickPayload();
  payload->capture_seq = capture_seq;
  payload->text_units = capture.text_units;
  payload->char_index = char_index;
  payload->rect = rect;
  payload->client_width = client_width;
  payload->client_height = client_height;
  if (capture.text_units != 0) {
    memcpy(payload->text, capture.text,
           static_cast<size_t>(capture.text_units) * sizeof(wchar_t));
  }
}

void PublishSgreLookupClickTarget(
    const SgreLookupCapture& capture, uint64_t capture_seq,
    HWND game, const POINT& client_origin, int32_t client_width,
    int32_t client_height) {
  if (game == nullptr || capture.valid != 1 || capture.text_units == 0 ||
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
  g_sgre_lookup_click_target.capture_seq = capture_seq;
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
  g_sgre_lookup_click_target.capture_seq = 0;
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
         copy->capture.glyph_count <= kSgreLookupMaxGlyphs;
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
  const int glyph_index = fushi_voice_hook::FindSgreLookupGlyph(
      target.capture.glyphs, target.capture.glyph_count, client_width,
      client_height, client_x, client_y, &rect);
  if (glyph_index < 0 ||
      static_cast<uint32_t>(glyph_index) >= target.capture.text_units) {
    return false;
  }
  FillSgreLookupClickPayload(payload, target.capture, target.capture_seq,
                             static_cast<uint32_t>(glyph_index), rect,
                             client_width, client_height);
  return true;
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

bool IsPublishedSgreDirectInputShieldActive(HWND game) {
  if (GetValidPublishedSgreDirectInputShieldPopup(game) == nullptr) {
    return false;
  }
  return reinterpret_cast<uintptr_t>(GetPropW(
             game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty)) ==
         fushi_voice_hook::kSgreDirectInputShieldReadyValue;
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
  const bool shield_active = direct_popup != nullptr || bitmap_popup_visible;
  const bool lookup_allowed =
      g_sgre_lookup_click_runtime_enabled.load(std::memory_order_acquire) &&
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
          primary_down, lookup_allowed, hit_on_press, pointer_valid, pointer.x,
          pointer.y, fushi_voice_hook::kSgreLookupClickDragThreshold,
          &g_sgre_lookup_click_gesture);
  if (click_action == fushi_voice_hook::SgreLookupClickAction::kBegin) {
    g_sgre_lookup_pending_click = pressed_payload;
    g_sgre_lookup_pending_click_valid = true;
    g_sgre_direct_input_latched_buttons.fetch_or(
        fushi_voice_hook::kSgreLookupPrimaryButtonMask,
        std::memory_order_acq_rel);
  } else if (click_action ==
             fushi_voice_hook::SgreLookupClickAction::kSubmit) {
    if (g_sgre_lookup_pending_click_valid && lookup_allowed) {
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
  HMODULE executable = GetModuleHandleW(nullptr);
  if (executable == nullptr) {
    PublishSgreDirectInputShieldRequired();
    MarkSgreDirectInputShieldNotReady();
    return false;
  }
  void* mouse_device = nullptr;
  void* target = nullptr;
  __try {
    mouse_device = *reinterpret_cast<void**>(
        reinterpret_cast<uintptr_t>(executable) +
        fushi_voice_hook::kSgreDirectInputMouseDeviceRva);
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
  if (mouse_device != nullptr && target != nullptr &&
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
  if (mouse_device == nullptr || target == nullptr) {
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
    snapshot.captured_tick = GetTickCount64();
    g_sgre_lookup_scenario_surface.store(text_surface,
                                         std::memory_order_release);
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagGeometryObserved;
  } else if (capture_result == SgreLookupCaptureResult::kNoGlyphs) {
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
    if (IsSgreLookupCaptureFault(capture_result)) {
      g_header->lookup_diag |= fushi_voice_hook::kLookupDiagSensorFault;
    }
    return;
  }
  PublishSgreLookupCaptureSnapshot(snapshot);
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

void ClearSgreLookupActiveCapture() {
  g_sgre_lookup_active_valid = false;
  g_sgre_lookup_active_line.clear();
  g_sgre_lookup_active_mapped = 0;
  g_sgre_lookup_active_capture_seq = 0;
  g_sgre_lookup_active_capture_tick = 0;
  InvalidateSgreLookupClickTarget();
}

bool PublishSgreLookupClickPayload(const SgreLookupClickPayload& payload) {
  if (payload.text_units == 0 || payload.text_units > kSgreLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
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
  PublishSgreLookupHit(line, payload.char_index, payload.rect,
                       payload.client_width, payload.client_height);
  g_sgre_lookup_last_hit_identity = identity;
  g_sgre_lookup_last_hit_tick = now;
  return true;
}

void ProcessSgreLookupTick() {
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header)) {
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    InvalidateSgreLookupClickTarget();
    DiscardPendingSgreLookupClickSubmits();
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
  if (!InstallSgreLookupSensor()) {
    g_sgre_lookup_click_runtime_enabled.store(false,
                                              std::memory_order_release);
    ClearSgreLookupActiveCapture();
    return;
  }
  g_sgre_lookup_click_runtime_enabled.store(true, std::memory_order_release);

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

  SgreLookupCapture capture;
  uint64_t capture_seq = 0;
  const ULONGLONG now = GetTickCount64();
  if (ReadLatestSgreLookupCapture(&capture, &capture_seq)) {
    g_sgre_lookup_processed_seq = capture_seq;
    if (capture.valid == 1 && capture.text_units != 0 &&
        capture.text_units == capture.glyph_count &&
        capture.text_units <= kSgreLookupMaxTextUnits &&
        capture.glyph_count <= kSgreLookupMaxGlyphs &&
        capture.captured_tick != 0 && now >= capture.captured_tick &&
        now - capture.captured_tick <= kSgreLookupActiveCaptureMaxAgeMs) {
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
      g_sgre_lookup_active_capture_seq = capture_seq;
      g_sgre_lookup_active_capture_tick = capture.captured_tick;
    } else {
      ClearSgreLookupActiveCapture();
    }
  }
  if (g_sgre_lookup_active_valid &&
      (now < g_sgre_lookup_active_capture_tick ||
       now - g_sgre_lookup_active_capture_tick >
           kSgreLookupActiveCaptureMaxAgeMs)) {
    ClearSgreLookupActiveCapture();
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
    PublishSgreLookupClickTarget(active, g_sgre_lookup_active_capture_seq, game,
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
  const int glyph_index = fushi_voice_hook::FindSgreLookupGlyph(
      active.glyphs, active.glyph_count, client_width, client_height, cursor.x,
      cursor.y, &hit_rect);

  if (submit && glyph_index >= 0 && !click_submitted && !popup_visible &&
      game_point) {
    SgreLookupClickPayload shift_payload;
    FillSgreLookupClickPayload(
        &shift_payload, active, g_sgre_lookup_active_capture_seq,
        g_sgre_lookup_active_char_indices[glyph_index], hit_rect, client_width,
        client_height);
    PublishSgreLookupClickPayload(shift_payload);
  }
}

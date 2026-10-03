// YU-RIS message text lane + in-game lookup runtime
// (EngineExactLayout / kLookupGeometryProviderIdYuris).  Engine facts,
// signatures and every decision rule live in yuris_lookup_core.h and are
// unit-tested; this file binds them to MinHook, Win32, the text lanes and the
// v19 registry.
//
// Threads:
//   * game thread — DRAW entry stub: every character the engine draws (its
//     own typewriter and the script-level string command alike) is copied
//     with its layer, pen and font size from DRAW's own arguments into a
//     fixed glyph ring.  When the engine's message text (S+T) changed since
//     the previous draw, the new text (bounded CP932) is copied into a text
//     ring first, which opens a new page.  No allocation, no IO, no
//     conversion.
//   * game thread — mouse-button loop stub (once per frame, before the engine
//     reads its GetKeyboardState table): a fresh left press on exactly one
//     mapped glyph of the current model is claimed and VK_LBUTTON's high bit
//     is masked until the button is released, so the engine sees no click.
//   * game thread — main window procedure detour: a touch tap is promoted by
//     the system to a WM_LBUTTONDOWN/UP pair at lift, both within one frame,
//     so the engine's per-frame key table never shows it (a tap neither
//     advances the game nor reaches the claim above).  A promoted touch press
//     on a mapped glyph is claimed here instead and its UP swallowed; the key
//     loop is told the button is owned so it masks any sample in between.
//   * HookWorker — ProcessYurisLookupTick: converts and publishes the message
//     text lane, rebuilds the page from the glyph ring, matches the selected
//     line, projects to physical client pixels, offers / retires the provider,
//     publishes the model for the game thread and turns claimed presses into
//     registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing; a text
// that is not clean CP932, a glyph whose character differs from the text at
// its offset, an unknown layer placement, a client with another aspect than
// the design screen or a missing native-input admission retires the provider
// or refuses the click, and the click then reaches the game unchanged.

#if defined(_M_IX86)

namespace yuris_lookup = fushi_voice_hook::yuris_lookup;

constexpr uint32_t kYurisGlyphSlots = 512u;
constexpr uint32_t kYurisTextSlots = 8u;
constexpr uint32_t kYurisModelSlots = 2u;
constexpr uint32_t kYurisSubmitSlots = 8u;
constexpr uint32_t kYurisLogBudget = 4096u;
constexpr uint64_t kYurisTextDedupeMs = 500u;
constexpr uint64_t kYurisWindowRetryMs = 500u;

struct YurisGlyphEvent {
  uint64_t page = 0u;          // message sequence the glyph belongs to
  uintptr_t layer = 0u;        // the layer object DRAW renders into
  int32_t x = 0;
  int32_t y = 0;
  int32_t size = 0;
  uint8_t bytes[2] = {};
  uint8_t length = 0u;
};

struct YurisTextEvent {
  uint64_t page = 0u;
  uint64_t sequence = 0u;  // text ring sequence (voice clips order against it)
  uint64_t tick = 0u;
  uintptr_t state = 0u;
  uintptr_t layer = 0u;
  uint32_t text_bytes = 0u;
  bool clean = false;
  uint8_t text[yuris_lookup::kMaxTextBytes + 1u] = {};
};

struct YurisModelGlyph {
  yuris_lookup::LineGlyph line;
  yuris_lookup::PixelRect rect;  // physical client pixels
};

struct YurisModel {
  uint64_t generation = 0u;
  uint64_t page = 0u;
  uintptr_t layer = 0u;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  uint64_t glyph_seq = 0u;  // glyphs captured when the model was built
  uintptr_t window = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<YurisModelGlyph, yuris_lookup::kMaxCells> glyphs{};
};

struct YurisSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
  yuris_lookup::LineGlyph line;
  yuris_lookup::PixelRect rect;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
};

constexpr uint32_t kYurisPageGlyphs = 512u;
constexpr uint32_t kYurisPageLayers = 8u;

struct YurisPage {
  bool valid = false;
  uint64_t id = 0u;
  uint64_t text_event = 0u;
  uintptr_t state = 0u;
  std::wstring text;
  bool has_ruby = false;  // ruby readings are drawn smaller than the base
  uint32_t count = 0u;
  bool overflow = false;
  std::array<YurisGlyphEvent, kYurisPageGlyphs> glyphs{};
};

struct YurisLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  yuris_lookup::SiteResult site_result = yuris_lookup::SiteResult::kNoImports;
  bool provider_offered = false;
  HWND window = nullptr;
  bool window_hooked = false;
  bool window_rejected = false;
  uint64_t window_retry_tick = 0u;
  uint64_t processed_glyph_seq = 0u;
  uint64_t processed_text_seq = 0u;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint32_t logged = 0u;
  YurisTextEvent text_copy;
  YurisPage page;
  YurisModel model;
  YurisModel candidate;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  yuris_lookup::PublishedLines published_lines;
  uint64_t logged_claims = 0u;
  std::array<yuris_lookup::LineGlyph, yuris_lookup::kMaxCells> scratch{};
  std::array<yuris_lookup::Cell, yuris_lookup::kMaxCells> cells{};
  std::array<uint32_t, yuris_lookup::kMaxCells> codepoints{};
  std::array<uint16_t, yuris_lookup::kMaxCells> sources{};
  std::array<uintptr_t, kYurisPageLayers> logged_layers{};
  uint32_t logged_layer_count = 0u;
  std::wstring last_text;
  uint64_t last_text_thread = 0u;
  uint64_t last_text_tick = 0u;
  uint64_t last_text_event = 0u;

  // ── resolved once, read everywhere ──
  yuris_lookup::Sites sites;
  uintptr_t image_base = 0u;

  // ── game-thread-owned ──
  // "Game thread" is the thread that owns the main window: the key loop reads
  // the table GetKeyboardState filled, and that table is per-thread input
  // state, so the loop only sees clicks at all because it runs on the thread
  // that receives the window's mouse messages — the same thread the window
  // procedure detour runs on.  claim and touch_up_pending are shared between
  // the two on that one thread and need no synchronisation.
  bool touch_up_pending = false;  // swallow the UP of a claimed touch press
                                  // (dropped at the next DOWN if it never came)
  uint64_t current_page = 0u;  // page of the last message-text change
  uint64_t text_signature = 0u;
  yuris_lookup::ClaimState claim;
  YurisModel input_model;
  std::array<yuris_lookup::LineGlyph, yuris_lookup::kMaxCells> input_lines{};

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> glyph_count{0u};
  std::array<std::atomic<uint64_t>, kYurisGlyphSlots> glyph_seq = {};
  std::array<YurisGlyphEvent, kYurisGlyphSlots> glyphs = {};
  std::atomic<uint64_t> text_count{0u};
  std::array<std::atomic<uint64_t>, kYurisTextSlots> text_seq = {};
  std::array<YurisTextEvent, kYurisTextSlots> texts = {};
  std::array<std::atomic<uint32_t>, kYurisModelSlots> model_seq = {};
  std::array<YurisModel, kYurisModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kYurisSubmitSlots> submit_seq = {};
  std::array<YurisSubmit, kYurisSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  std::atomic<uint32_t> draw_hits{0u};
  std::atomic<uint32_t> key_polls{0u};
};

YurisLookupRuntime g_yuris_lookup;
void BindYurisPendingVoice(uint64_t text_event, uint64_t text_order,
                           uint64_t text_tick);
bool ReadYurisLayerOrigin(uintptr_t layer, int32_t* origin_x,
                          int32_t* origin_y);
void* g_yuris_draw_original = nullptr;
void* g_yuris_key_loop_original = nullptr;

bool ReadYurisBytes(uintptr_t address, void* out, size_t bytes) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), bytes);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

template <typename T>
bool ReadYurisValue(uintptr_t address, T* out) {
  return ReadYurisBytes(address, out, sizeof(T));
}

// ── two-slot seqlock (model) ───────────────────────────────────────────────

size_t YurisModelBytes(uint32_t count) {
  return offsetof(YurisModel, glyphs) +
         static_cast<size_t>(count) * sizeof(YurisModelGlyph);
}

void PublishYurisModel(const YurisModel& value) {
  auto& rt = g_yuris_lookup;
  const uint32_t current = rt.published_model.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= kYurisModelSlots ? 0u : (current + 1u) % kYurisModelSlots;
  const uint32_t seq = rt.model_seq[slot].load(std::memory_order_relaxed);
  rt.model_seq[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&rt.models[slot], &value, YurisModelBytes(value.count));
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_seq[slot].store((seq | 1u) + 1u, std::memory_order_release);
  rt.published_model.store(slot, std::memory_order_release);
}

bool ReadYurisModelBytes(YurisModel* out, size_t bytes) {
  auto& rt = g_yuris_lookup;
  const uint32_t slot = rt.published_model.load(std::memory_order_acquire);
  if (out == nullptr || slot >= kYurisModelSlots) return false;
  const uint32_t before = rt.model_seq[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &rt.models[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_seq[slot].load(std::memory_order_acquire) == before &&
         rt.published_model.load(std::memory_order_acquire) == slot;
}

bool ReadYurisModel(YurisModel* out) {
  if (!ReadYurisModelBytes(out, offsetof(YurisModel, glyphs))) return false;
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(yuris_lookup::kMaxCells));
  return ReadYurisModelBytes(out, YurisModelBytes(count)) &&
         out->count == count;
}

void InvalidateYurisModel() {
  g_yuris_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

// ── game thread: DRAW entry ────────────────────────────────────────────────

void PushYurisText(uintptr_t state, uintptr_t layer, uint64_t page,
                   const uint8_t* text, uint32_t length, bool clean) {
  auto& rt = g_yuris_lookup;
  const uint64_t sequence =
      rt.text_count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.text_seq[sequence % kYurisTextSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  YurisTextEvent& event = rt.texts[sequence % kYurisTextSlots];
  event.page = page;
  event.sequence = sequence;
  event.tick = GetTickCount64();
  event.state = state;
  event.layer = layer;
  event.text_bytes = length;
  event.clean = clean;
  std::memcpy(event.text, text, length);
  event.text[length] = 0u;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
}

// The engine's message text (S+T): signature over its bytes, so a change
// (a new message) is seen at the first draw after it.
void TrackYurisMessage(uintptr_t layer) {
  auto& rt = g_yuris_lookup;
  const uintptr_t state = *reinterpret_cast<const uintptr_t*>(
      rt.image_base + rt.sites.state_global);
  if (state == 0u) return;
  const auto* text = *reinterpret_cast<const uint8_t* const*>(
      state + rt.sites.text_ptr);
  if (text == nullptr) return;
  uint64_t signature = 1469598103934665603ull ^ reinterpret_cast<uintptr_t>(text);
  uint32_t length = 0u;
  while (length < yuris_lookup::kMaxTextBytes && text[length] != 0u) {
    signature = (signature ^ text[length]) * 1099511628211ull;
    ++length;
  }
  if (signature == rt.text_signature) return;
  rt.text_signature = signature;
  rt.current_page = rt.text_count.load(std::memory_order_relaxed) + 1u;
  const size_t clean_length = yuris_lookup::MessageTextLength(
      text, length < yuris_lookup::kMaxTextBytes ? length + 1u
                                                 : yuris_lookup::kMaxTextBytes);
  PushYurisText(state, layer, rt.current_page, text, length,
                clean_length == length && length != 0u);
}

// `entry_esp` is esp at DRAW's first instruction ([esp] = return address),
// `character` its first register argument (the character to draw).
void __cdecl YurisDrawObserve(const uint8_t* entry_esp, uint32_t character) {
  auto& rt = g_yuris_lookup;
  rt.draw_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire)) return;
  __try {
    const uintptr_t layer = *reinterpret_cast<const uintptr_t*>(
        entry_esp + rt.sites.arg_layer);
    TrackYurisMessage(layer);
    const auto* bytes = reinterpret_cast<const uint8_t*>(
        static_cast<uintptr_t>(character));
    const uint64_t sequence =
        rt.glyph_count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
    auto& slot_seq = rt.glyph_seq[sequence % kYurisGlyphSlots];
    slot_seq.store(0u, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_release);
    YurisGlyphEvent& event = rt.glyphs[sequence % kYurisGlyphSlots];
    event.page = rt.current_page;
    event.layer = layer;
    event.x = *reinterpret_cast<const int32_t*>(entry_esp + rt.sites.arg_x);
    event.y = *reinterpret_cast<const int32_t*>(entry_esp + rt.sites.arg_y);
    event.size =
        *reinterpret_cast<const int32_t*>(entry_esp + rt.sites.arg_size);
    event.bytes[0] = bytes[0];
    event.bytes[1] = yuris_lookup::IsCp932Lead(bytes[0]) ? bytes[1] : 0u;
    event.length = yuris_lookup::IsCp932Lead(bytes[0]) ? 2u : 1u;
    std::atomic_thread_fence(std::memory_order_release);
    slot_seq.store(sequence, std::memory_order_release);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

__declspec(naked) void YurisDrawStub() {
  __asm {
    pushfd
    pushad
    push eax
    lea eax, [esp + 0x28]
    push eax
    call YurisDrawObserve
    add esp, 8
    popad
    popfd
    jmp dword ptr [g_yuris_draw_original]
  }
}

// ── game thread: mouse-button loop ─────────────────────────────────────────

void QueueYurisSubmit(const YurisSubmit& submit) {
  auto& rt = g_yuris_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kYurisSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kYurisSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool YurisShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A fresh engine-sampled press: may it become a lookup?  Only a bare left
// press on exactly one mapped glyph of the current model, in the foreground
// game window, with the host's native-input admission applied, no card
// shielding the game and no newer glyph drawn since the model was built.
// Why the last fresh press was not claimed (0 = claimed); read and logged by
// the worker.  Game thread writes only an integer.
std::atomic<uint32_t> g_yuris_press_reject{0u};
std::atomic<uint32_t> g_yuris_press_count{0u};

bool RejectYurisPress(uint32_t reason) {
  g_yuris_press_reject.store(reason, std::memory_order_relaxed);
  return false;
}

bool YurisPressEligible(YurisSubmit* submit) {
  auto& rt = g_yuris_lookup;
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RejectYurisPress(1u);
  }
  YurisModel& model = rt.input_model;
  if (!ReadYurisModel(&model) || model.generation == 0u || model.count == 0u) {
    return RejectYurisPress(2u);
  }
  const HWND game = reinterpret_cast<HWND>(model.window);
  if (game == nullptr ||
      rt.glyph_count.load(std::memory_order_acquire) != model.glyph_seq ||
      !fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdYuris) ||
      YurisShieldActive(game) || GetForegroundWindow() != game ||
      (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RejectYurisPress(3u);
  }
  // The layer is still where the model put it.
  int32_t origin_x = 0, origin_y = 0;
  if (!ReadYurisLayerOrigin(model.layer, &origin_x, &origin_y) ||
      origin_x != model.origin_x || origin_y != model.origin_y) {
    return RejectYurisPress(4u);
  }
  // The window's own thread: cursor and client in its logical pixels.
  POINT cursor = {};
  RECT client = {};
  if (!GetCursorPos(&cursor)) return RejectYurisPress(5u);
  const HWND under = WindowFromPoint(cursor);
  if ((under != game && !IsChild(game, under)) ||
      !ScreenToClient(game, &cursor) || !GetClientRect(game, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return RejectYurisPress(6u);
  }
  int32_t x = 0, y = 0;
  if (!yuris_lookup::ClientToDesign(cursor.x, cursor.y, model.logical_w,
                                    model.logical_h, model.design_w,
                                    model.design_h, &x, &y)) {
    return RejectYurisPress(7u);
  }
  auto& lines = rt.input_lines;
  for (uint32_t i = 0u; i < model.count; ++i) lines[i] = model.glyphs[i].line;
  size_t hit = 0u;
  if (!yuris_lookup::HitTestLine(lines.data(), model.count, x, y, &hit)) {
    return RejectYurisPress(8u);
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  submit->line = model.glyphs[hit].line;
  submit->rect = model.glyphs[hit].rect;
  submit->physical_w = model.physical_w;
  submit->physical_h = model.physical_h;
  return true;
}

void __cdecl YurisKeyLoopObserve() {
  auto& rt = g_yuris_lookup;
  rt.key_polls.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire)) return;
  __try {
    uint8_t* key = reinterpret_cast<uint8_t*>(
        rt.image_base + rt.sites.key_table + static_cast<uintptr_t>(VK_LBUTTON));
    const uint8_t raw = *key;
    YurisSubmit submit;
    const bool fresh = yuris_lookup::IsFreshPress(raw, rt.claim);
    if (fresh) g_yuris_press_count.fetch_add(1u, std::memory_order_relaxed);
    const bool eligible = fresh && YurisPressEligible(&submit);
    if (eligible) RejectYurisPress(0u);
    const auto decision =
        yuris_lookup::DecideLeftButton(raw, eligible, &rt.claim);
    if (decision.submit) {
      QueueYurisSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.mask) {
      *key = static_cast<uint8_t>(raw & ~yuris_lookup::kKeyDownBit);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

__declspec(naked) void YurisKeyLoopStub() {
  __asm {
    pushfd
    pushad
    call YurisKeyLoopObserve
    popad
    popfd
    jmp dword ptr [g_yuris_key_loop_original]
  }
}

WNDPROC g_yuris_wndproc_original = nullptr;

LRESULT CALLBACK YurisWndProcDetour(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  auto& rt = g_yuris_lookup;
  if (rt.live.load(std::memory_order_acquire)) {
    bool swallow = false;
    __try {
      const auto kind =
          message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK
              ? yuris_lookup::LeftButtonMessage::kDown
          : message == WM_LBUTTONUP ? yuris_lookup::LeftButtonMessage::kUp
                                    : yuris_lookup::LeftButtonMessage::kOther;
      const bool promoted =
          kind == yuris_lookup::LeftButtonMessage::kDown &&
          yuris_lookup::IsPromotedTouch(GetMessageExtraInfo());
      const yuris_lookup::TouchDecision decision =
          yuris_lookup::DecideTouchMessage(kind, promoted, rt.claim.owned,
                                           &rt.touch_up_pending);
      swallow = decision.swallow;
      YurisSubmit submit;
      if (decision.evaluate) {
        g_yuris_press_count.fetch_add(1u, std::memory_order_relaxed);
      }
      if (decision.evaluate && YurisPressEligible(&submit)) {
        RejectYurisPress(0u);
        QueueYurisSubmit(submit);
        rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
        rt.claim.owned = true;
        rt.claim.was_down = true;
        rt.touch_up_pending = true;
        swallow = true;
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      swallow = false;
    }
    if (swallow) return 0;
  }
  return g_yuris_wndproc_original(hwnd, message, wparam, lparam);
}

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void YurisLookupLog(const wchar_t* format, ...) {
  auto& rt = g_yuris_lookup;
  if (rt.logged >= kYurisLogBudget) return;
  ++rt.logged;
  wchar_t line[1024] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = g_orig_CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                   nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[1200] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[3600] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

// Both detours in one MinHook transaction; all or nothing.  A target someone
// else already hooked installs none.
bool InstallYurisHooks(void* draw, void* key_loop) {
  if (!g_cs_ready || draw == nullptr || key_loop == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 2 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != draw && g_hooked_fns[i] != key_loop;
  }
  bool draw_created = false, key_created = false;
  if (ok) {
    draw_created = MH_CreateHook(draw, reinterpret_cast<void*>(&YurisDrawStub),
                                 &g_yuris_draw_original) == MH_OK;
    key_created = draw_created &&
                  MH_CreateHook(key_loop,
                                reinterpret_cast<void*>(&YurisKeyLoopStub),
                                &g_yuris_key_loop_original) == MH_OK;
    ok = key_created && MH_QueueEnableHook(draw) == MH_OK &&
         MH_QueueEnableHook(key_loop) == MH_OK && MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = draw;
    g_hooked_fns[g_hooked_count++] = key_loop;
  } else {
    if (key_created) MH_RemoveHook(key_loop);
    if (draw_created) MH_RemoveHook(draw);
    g_yuris_draw_original = nullptr;
    g_yuris_key_loop_original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

// The executable as it is on disk, laid out by section (no loader, no
// relocation).  Sites are resolved on this copy: other in-process hookers
// (LunaHook's YU-RIS text hooks patch the rasteriser's TextOutA call) rewrite
// the live code, and a signature must not depend on who got there first.
// Only the two hook targets are then required to be byte-identical live.
std::vector<uint8_t> g_yuris_pristine;
yuris_lookup::ImageView g_yuris_pristine_view;

bool LoadYurisPristineView(yuris_lookup::ImageView* view,
                           uint32_t* preferred_base) {
  wchar_t path[MAX_PATH] = {};
  const DWORD chars = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (chars == 0u || chars >= MAX_PATH) return false;
  HANDLE file = g_orig_CreateFileW(path, GENERIC_READ,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE |
                                       FILE_SHARE_DELETE,
                                   nullptr, OPEN_EXISTING,
                                   FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  std::vector<uint8_t> raw;
  bool ok = GetFileSizeEx(file, &size) && size.QuadPart > 0x400 &&
            size.QuadPart < (64ll << 20);
  if (ok) {
    raw.resize(static_cast<size_t>(size.QuadPart));
    ok = ReadExact(file, raw.data(), static_cast<uint32_t>(raw.size()));
  }
  g_orig_CloseHandle(file);
  if (!ok) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(raw.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          raw.size()) {
    return false;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(raw.data() + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.SizeOfImage < 0x1000u ||
      nt->OptionalHeader.SizeOfImage > (256u << 20) ||
      nt->OptionalHeader.SizeOfHeaders > raw.size()) {
    return false;
  }
  g_yuris_pristine.assign(nt->OptionalHeader.SizeOfImage, 0u);
  std::memcpy(g_yuris_pristine.data(), raw.data(),
              nt->OptionalHeader.SizeOfHeaders);
  const auto* sections = IMAGE_FIRST_SECTION(nt);
  view->code_count = 0u;
  for (uint32_t i = 0u; i < nt->FileHeader.NumberOfSections; ++i) {
    const IMAGE_SECTION_HEADER& section = sections[i];
    if (reinterpret_cast<const uint8_t*>(&section + 1) >
        raw.data() + raw.size()) {
      return false;
    }
    const uint32_t bytes = (std::min)(section.SizeOfRawData,
                                      section.Misc.VirtualSize != 0u
                                          ? section.Misc.VirtualSize
                                          : section.SizeOfRawData);
    if (section.VirtualAddress > g_yuris_pristine.size() ||
        bytes > g_yuris_pristine.size() - section.VirtualAddress ||
        section.PointerToRawData > raw.size() ||
        bytes > raw.size() - section.PointerToRawData) {
      return false;
    }
    std::memcpy(g_yuris_pristine.data() + section.VirtualAddress,
                raw.data() + section.PointerToRawData, bytes);
    if ((section.Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u) {
      if (view->code_count >= view->code.size()) return false;
      view->code[view->code_count++] = {section.VirtualAddress,
                                        section.VirtualAddress + bytes};
    }
  }
  view->bytes = g_yuris_pristine.data();
  view->size = g_yuris_pristine.size();
  view->va_base = nt->OptionalHeader.ImageBase;
  *preferred_base = nt->OptionalHeader.ImageBase;
  return view->code_count != 0u;
}

// IAT slot RVA of dll!symbol in the pristine copy (by name).
uint32_t YurisImportSlot(const yuris_lookup::ImageView& view, const char* dll,
                         const char* symbol) {
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  image.base = view.bytes;
  image.size = view.size;
  image.absolute_base = view.va_base;
  return static_cast<uint32_t>(
      fushi_voice_hook::reallive_lookup::FindImportSlotRva(image, dll, symbol));
}

// The live bytes at a hook target still equal the pristine ones.
bool YurisLiveMatches(uintptr_t live_base, uint32_t rva, size_t bytes) {
  if (rva > g_yuris_pristine.size() || bytes > g_yuris_pristine.size() - rva) {
    return false;
  }
  uint8_t live[16] = {};
  return bytes <= sizeof(live) && ReadYurisBytes(live_base + rva, live, bytes) &&
         std::memcmp(live, g_yuris_pristine.data() + rva, bytes) == 0;
}

bool InstallYurisLookup() {
  auto& rt = g_yuris_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    if (!rt.hooks_installed) return false;
    rt.claim = yuris_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  yuris_lookup::ImageView view;
  uint32_t preferred_base = 0u;
  const uintptr_t live_base =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (!LoadYurisPristineView(&view, &preferred_base) ||
      preferred_base != live_base) {
    // A relocated image would need every absolute operand rebased; YU-RIS
    // executables load at their preferred base, anything else fails closed.
    rt.site_result = yuris_lookup::SiteResult::kNoImports;
  } else {
    g_yuris_pristine_view = view;
    yuris_lookup::ImportSlots imports;
    imports.text_out = YurisImportSlot(view, "gdi32.dll", "TextOutA");
    imports.get_keyboard_state =
        YurisImportSlot(view, "user32.dll", "GetKeyboardState");
    imports.screen_to_client =
        YurisImportSlot(view, "user32.dll", "ScreenToClient");
    rt.site_result = yuris_lookup::ResolveSites(view, imports, &rt.sites);
    // Both hook targets must still be the engine's own bytes.
    if (rt.site_result == yuris_lookup::SiteResult::kResolved &&
        (!YurisLiveMatches(live_base, rt.sites.draw, 8u) ||
         !YurisLiveMatches(live_base, rt.sites.key_loop, 8u))) {
      rt.site_result = yuris_lookup::SiteResult::kHookTargetPatched;
    }
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  if (rt.site_result != yuris_lookup::SiteResult::kResolved) {
    YurisLookupLog(L"yuris-lookup: sites unresolved result=%u scan=%.1fms",
                   static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  rt.image_base = live_base;
  rt.claim = yuris_lookup::ClaimState();
  rt.live.store(true, std::memory_order_release);
  const bool hooked = InstallYurisHooks(
      reinterpret_cast<void*>(rt.image_base + rt.sites.draw),
      reinterpret_cast<void*>(rt.image_base + rt.sites.key_loop));
  rt.hooks_installed = hooked;
  rt.installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  YurisLookupLog(
      L"yuris-lookup: sites draw=+0x%lx raster=+0x%lx S=+0x%lx buf=+0x%lx "
      L"pen=0x%x text=0x%x ti=0x%x op=0x%x size=0x%x K=+0x%lx loop=+0x%lx "
      L"sites=%u hooks=%d scan=%.1fms",
      static_cast<unsigned long>(rt.sites.draw),
      static_cast<unsigned long>(rt.sites.raster),
      static_cast<unsigned long>(rt.sites.state_global),
      static_cast<unsigned long>(rt.sites.char_buffer), rt.sites.pen_x,
      rt.sites.text_ptr, rt.sites.text_index, rt.sites.op_index,
      rt.sites.size_array, static_cast<unsigned long>(rt.sites.key_table),
      static_cast<unsigned long>(rt.sites.key_loop), rt.sites.return_count,
      hooked ? 1 : 0, scan_ms);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

// Returns the text event the line is published under (0 = not published).
// *fresh is true only when this call wrote a new event; a repeat of the last
// line inside the dedupe window returns that line's event with *fresh false.
uint64_t PublishYurisTextLine(const std::wstring& text, uint64_t identity,
                              uintptr_t address, uint64_t tick, bool* fresh) {
  auto& rt = g_yuris_lookup;
  *fresh = false;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  constexpr wchar_t kHookCode[] = L"ENGINE:YURIS:message_draw";
  constexpr char kHookName[] = "YU-RIS exact";
  const uint64_t thread_id =
      fushi_voice_hook::NativeTextThreadIdFrom(identity, kHookCode, kHookName);
  if (thread_id == rt.last_text_thread && text == rt.last_text &&
      tick - rt.last_text_tick <= kYurisTextDedupeMs) {
    return rt.last_text_event;
  }
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.thread_address = address;
  write.thread_context = address;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceYuris;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kHookName;
  write.hook_code = kHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields (YU-RIS
  // rasterises every glyph through TextOutA into a scratch DIB at 0,0).
  g_header->luna_active = 1;
  rt.last_text = text;
  rt.last_text_thread = thread_id;
  rt.last_text_tick = tick;
  rt.last_text_event = event;
  *fresh = true;
  return event;
}

// Decode and publish a message and make it the current page.  Returns the
// text event when this message became a new published line, else 0.
uint64_t PublishYurisMessage(const YurisTextEvent& event) {
  auto& rt = g_yuris_lookup;
  YurisPage& page = rt.page;
  page.valid = false;
  page.count = 0u;
  page.overflow = false;
  if (!event.clean || event.text_bytes == 0u) {
    YurisLookupLog(L"yuris-lookup: message %llu text rejected bytes=%u",
                   static_cast<unsigned long long>(event.page),
                   event.text_bytes);
    return 0u;
  }
  bool had_ruby = false;
  const std::wstring text = yuris_lookup::PublishedMessageText(
      yuris_lookup::DecodeMessageText(event.text, event.text_bytes),
      &had_ruby);
  if (text.empty()) {
    YurisLookupLog(L"yuris-lookup: message %llu not convertible",
                   static_cast<unsigned long long>(event.page));
    return 0u;
  }
  // Lane identity: the engine's message state global (one message system per
  // process), stable across runs, unlike the heap address of the state.
  bool fresh = false;
  const uint64_t text_event = PublishYurisTextLine(
      text, (static_cast<uint64_t>(rt.sites.state_global) << 8) ^
                rt.sites.text_ptr,
      event.state, event.tick, &fresh);
  YurisLookupLog(L"yuris-lookup: message %llu bytes=%u units=%u event=%llu "
                 L"fresh=%d",
                 static_cast<unsigned long long>(event.page), event.text_bytes,
                 static_cast<unsigned>(text.size()),
                 static_cast<unsigned long long>(text_event), fresh ? 1 : 0);
  if (text_event == 0u) return 0u;
  page.valid = true;
  page.has_ruby = had_ruby;
  page.id = event.page;
  page.text_event = text_event;
  page.state = event.state;
  page.text = text;
  return fresh ? text_event : 0u;
}

// Every message settles the voice clips opened before it, whether or not it
// was published (BindYurisPendingVoice).
void ProcessYurisTextEvent(const YurisTextEvent& event) {
  const uint64_t text_event = PublishYurisMessage(event);
  BindYurisPendingVoice(text_event, event.sequence, event.tick);
}

void ProcessYurisGlyphEvent(const YurisGlyphEvent& event) {
  auto& rt = g_yuris_lookup;
  YurisPage& page = rt.page;
  bool seen = false;
  for (uint32_t i = 0u; i < rt.logged_layer_count; ++i) {
    seen = seen || rt.logged_layers[i] == event.layer;
  }
  if (!seen && rt.logged_layer_count < kYurisPageLayers) {
    rt.logged_layers[rt.logged_layer_count++] = event.layer;
    int32_t x = 0, y = 0;
    const bool placed = ReadYurisLayerOrigin(event.layer, &x, &y);
    YurisLookupLog(L"yuris-lookup: layer %u first glyph pen=%d,%d size=%d "
                   L"origin=%d,%d placed=%d",
                   rt.logged_layer_count, event.x, event.y, event.size, x, y,
                   placed ? 1 : 0);
  }
  if (!page.valid || event.page != page.id) return;
  if (page.count >= kYurisPageGlyphs) {
    page.overflow = true;
    return;
  }
  page.glyphs[page.count++] = event;
}

template <typename Event, size_t Slots>
void DrainYurisRing(std::atomic<uint64_t>& count,
                    std::array<std::atomic<uint64_t>, Slots>& seqs,
                    std::array<Event, Slots>& events, uint64_t* processed,
                    Event* copy, void (*handle)(const Event&)) {
  const uint64_t latest = count.load(std::memory_order_acquire);
  if (latest == *processed) return;
  uint64_t next = *processed + 1u;
  if (latest - *processed > Slots) next = latest - Slots + 1u;
  for (; next <= latest; ++next) {
    auto& slot_seq = seqs[next % Slots];
    if (slot_seq.load(std::memory_order_acquire) != next) break;  // in flight
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(copy, &events[next % Slots], sizeof(Event));
    std::atomic_thread_fence(std::memory_order_acquire);
    *processed = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;  // torn
    handle(*copy);
  }
}

void DrainYurisEvents() {
  auto& rt = g_yuris_lookup;
  // Texts first: a page must exist before its glyphs are attached.  Both
  // rings are drained in capture order because a text event is pushed by the
  // same draw as its page's first glyph.
  static YurisGlyphEvent glyph_copy;
  DrainYurisRing(rt.text_count, rt.text_seq, rt.texts, &rt.processed_text_seq,
                 &rt.text_copy, &ProcessYurisTextEvent);
  DrainYurisRing(rt.glyph_count, rt.glyph_seq, rt.glyphs,
                 &rt.processed_glyph_seq, &glyph_copy, &ProcessYurisGlyphEvent);
}

// The main window: the one visible top-level window of this process whose
// (ANSI) window procedure lies in the game image's code.
void FindYurisWindow() {
  auto& rt = g_yuris_lookup;
  if (rt.window != nullptr && IsWindow(rt.window)) return;
  rt.window = nullptr;
  const uint64_t now = GetTickCount64();
  if (rt.window_retry_tick != 0u &&
      now - rt.window_retry_tick < kYurisWindowRetryMs) {
    return;
  }
  rt.window_retry_tick = now;
  struct Search {
    uintptr_t base = 0u;
    size_t size = 0u;
    HWND window = nullptr;
    uint32_t matches = 0u;
  } search;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          reinterpret_cast<HMODULE>(rt.image_base), &image)) {
    return;
  }
  search.base = rt.image_base;
  search.size = image.size;
  EnumWindows(
      [](HWND hwnd, LPARAM context) -> BOOL {
        auto* s = reinterpret_cast<Search*>(context);
        DWORD pid = 0u;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) ||
            IsWindowUnicode(hwnd)) {
          return TRUE;
        }
        const uintptr_t procedure =
            static_cast<uintptr_t>(GetWindowLongPtrA(hwnd, GWLP_WNDPROC));
        if (procedure < s->base || procedure - s->base >= s->size) return TRUE;
        ++s->matches;
        s->window = hwnd;
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  if (search.matches != 1u) return;
  rt.window = search.window;
  if (rt.window_hooked || rt.window_rejected) return;
  // The window procedure is hooked once (MinHook on its code, like the other
  // detours; the window class keeps pointing at it).
  void* procedure = reinterpret_cast<void*>(
      GetWindowLongPtrA(rt.window, GWLP_WNDPROC));
  bool ok = false;
  if (g_cs_ready && procedure != nullptr) {
    EnterCriticalSection(&g_cs);
    ok = g_hooked_count + 1 <= 64;
    for (int i = 0; ok && i < g_hooked_count; ++i) {
      ok = g_hooked_fns[i] != procedure;
    }
    bool created = false;
    if (ok) {
      created = MH_CreateHook(procedure,
                              reinterpret_cast<void*>(&YurisWndProcDetour),
                              reinterpret_cast<void**>(
                                  &g_yuris_wndproc_original)) == MH_OK;
      ok = created && MH_QueueEnableHook(procedure) == MH_OK &&
           MH_ApplyQueued() == MH_OK;
    }
    if (ok) {
      g_hooked_fns[g_hooked_count++] = procedure;
    } else if (created) {
      MH_RemoveHook(procedure);
    }
    LeaveCriticalSection(&g_cs);
  }
  rt.window_hooked = ok;
  rt.window_rejected = !ok;
  YurisLookupLog(L"yuris-lookup: window procedure +0x%lx hooked=%d",
                 static_cast<unsigned long>(
                     reinterpret_cast<uintptr_t>(procedure) - rt.image_base),
                 ok ? 1 : 0);
}

void RetireYurisLookup() {
  auto& rt = g_yuris_lookup;
  InvalidateYurisModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdYuris);
  }
}

struct YurisDpiScope {
  explicit YurisDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~YurisDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

constexpr uint32_t kYurisMaxChain = 16u;

// Where a text layer sits on the design screen: the sum of its sprite
// positions up the parent chain, exactly as the engine's own sprite hit test
// composes it.  A chain that does not terminate within the bound, or a
// sprite that cannot be read, fails closed.
bool ReadYurisLayerOrigin(uintptr_t layer, int32_t* origin_x,
                          int32_t* origin_y) {
  auto& rt = g_yuris_lookup;
  int64_t x = 0, y = 0;
  uintptr_t node = layer;
  for (uint32_t depth = 0u; depth < kYurisMaxChain; ++depth) {
    if (node == 0u) break;
    uint32_t live = 0u;
    if (!ReadYurisValue(node + rt.sites.chain_live, &live)) return false;
    if (live == 0u) break;
    uintptr_t sprite = 0u;
    int32_t sx = 0, sy = 0;
    if (!ReadYurisValue(node + rt.sites.chain_sprite, &sprite) ||
        sprite == 0u || !ReadYurisValue(sprite + rt.sites.sprite_x, &sx) ||
        !ReadYurisValue(sprite + rt.sites.sprite_y, &sy) ||
        !ReadYurisValue(node + rt.sites.chain_parent, &node)) {
      return false;
    }
    x += sx;
    y += sy;
    if (depth + 1u == kYurisMaxChain) return false;
  }
  if (x < -yuris_lookup::kMaxDesignSide || x > yuris_lookup::kMaxDesignSide ||
      y < -yuris_lookup::kMaxDesignSide || y > yuris_lookup::kMaxDesignSide) {
    return false;
  }
  *origin_x = static_cast<int32_t>(x);
  *origin_y = static_cast<int32_t>(y);
  return true;
}

// The design screen of the main window record, which must be the window the
// model is built for.
bool ReadYurisDesign(HWND game, int32_t* design_w, int32_t* design_h) {
  auto& rt = g_yuris_lookup;
  uintptr_t record = 0u;
  uintptr_t hwnd = 0u;
  return ReadYurisValue(rt.image_base + rt.sites.window_table, &record) &&
         record != 0u && ReadYurisValue(record + rt.sites.window_hwnd, &hwnd) &&
         hwnd == reinterpret_cast<uintptr_t>(game) &&
         ReadYurisValue(record + rt.sites.design_w, design_w) &&
         ReadYurisValue(record + rt.sites.design_h, design_h) &&
         yuris_lookup::DesignPlausible(*design_w, *design_h);
}

bool ReadYurisLayerPlacement(uintptr_t layer, HWND game, int32_t* origin_x,
                             int32_t* origin_y, int32_t* design_w,
                             int32_t* design_h) {
  return ReadYurisLayerOrigin(layer, origin_x, origin_y) &&
         ReadYurisDesign(game, design_w, design_h);
}

uint32_t g_yuris_model_failure = 0u;

bool FailYurisModel(uint32_t step) {
  g_yuris_model_failure = step;
  return false;
}

// The page's glyphs on one layer, in draw order, as cells.  A character drawn
// again over its own cell (the engine draws an outline / shadow copy first,
// then the face) replaces the earlier draw: the later one is on top.
uint32_t CollectYurisLayerCells(const YurisPage& page, uintptr_t layer) {
  auto& rt = g_yuris_lookup;
  // With ruby on the page, only glyphs of the line's own (largest) font size
  // are the line; the readings are not part of the published text.
  int32_t line_size = 0;
  if (page.has_ruby) {
    for (uint32_t i = 0u; i < page.count; ++i) {
      if (page.glyphs[i].layer == layer && page.glyphs[i].size > line_size) {
        line_size = page.glyphs[i].size;
      }
    }
  }
  uint32_t count = 0u;
  for (uint32_t i = 0u; i < page.count; ++i) {
    const YurisGlyphEvent& g = page.glyphs[i];
    if (g.layer != layer || g.size < line_size) continue;
    yuris_lookup::Cell cell;
    cell.bytes[0] = g.bytes[0];
    cell.bytes[1] = g.bytes[1];
    cell.length = g.length;
    cell.x = g.x;
    cell.y = g.y;
    cell.size = g.size;
    const size_t at = yuris_lookup::OverdrawTarget(rt.cells.data(), count, cell);
    if (at < count) {
      rt.cells[at] = cell;
      continue;
    }
    if (count >= rt.cells.size()) return 0u;
    rt.cells[count++] = cell;
  }
  for (uint32_t i = 0u; i < count; ++i) {
    wchar_t wide[4] = {};
    if (MultiByteToWideChar(932, MB_ERR_INVALID_CHARS,
                            reinterpret_cast<const char*>(rt.cells[i].bytes),
                            rt.cells[i].length, wide, 4) != 1) {
      return 0u;
    }
    rt.codepoints[i] = wide[0];
    rt.sources[i] = yuris_lookup::kNoSource;
  }
  return count;
}

bool BuildYurisModel(const YurisPage& page, const std::wstring& line,
                     YurisModel* model, uint32_t* first_glyph) {
  auto& rt = g_yuris_lookup;
  const HWND game = rt.window;
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game)) {
    return FailYurisModel(1u);
  }
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT window_context =
        GetWindowDpiAwarenessContext(game);
    if (window_context == nullptr) return FailYurisModel(2u);
    YurisDpiScope own(window_context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailYurisModel(2u);
    }
  }
  {
    YurisDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailYurisModel(2u);
    }
  }
  // The selected line must be the render-order suffix of exactly one layer.
  std::array<uintptr_t, kYurisPageLayers> layers{};
  uint32_t layer_count = 0u;
  for (uint32_t i = 0u; i < page.count; ++i) {
    bool seen = false;
    for (uint32_t k = 0u; k < layer_count; ++k) {
      seen = seen || layers[k] == page.glyphs[i].layer;
    }
    if (seen) continue;
    if (layer_count >= layers.size()) return FailYurisModel(3u);
    layers[layer_count++] = page.glyphs[i].layer;
  }
  // A `NAME「…」` message is matched across two layers only when the engine
  // drew exactly NAME on a layer of its own (yuris_lookup::ChooseLineLayer).
  const size_t speaker =
      yuris_lookup::SpeakerPrefixCandidate(line.data(), line.size());
  std::array<yuris_lookup::LayerFit, kYurisPageLayers> fits{};
  for (uint32_t k = 0u; k < layer_count; ++k) {
    const uint32_t count = CollectYurisLayerCells(page, layers[k]);
    if (count == 0u) continue;
    const size_t built = yuris_lookup::BuildPageGlyphs(
        rt.cells.data(), count, rt.codepoints.data(), rt.sources.data(), 0, 0,
        rt.scratch.data(), rt.scratch.size());
    if (built == 0u) continue;
    fits[k].line = yuris_lookup::MapSelectedSuffix(
                       rt.scratch.data(), built, line.data(), line.size()) <
                   built;
    if (speaker == 0u) continue;
    fits[k].quote =
        yuris_lookup::MapSelectedSuffix(rt.scratch.data(), built,
                                        line.data() + speaker,
                                        line.size() - speaker) < built;
    fits[k].name = yuris_lookup::GlyphRunIs(rt.scratch.data(), built,
                                            line.data(), speaker);
  }
  const yuris_lookup::LineLayerChoice choice =
      yuris_lookup::ChooseLineLayer(fits.data(), layer_count, speaker);
  if (choice.ambiguous) return FailYurisModel(4u);
  if (choice.layer >= layer_count) return FailYurisModel(5u);
  const uintptr_t matched_layer = layers[choice.layer];
  const wchar_t* const matched_text = line.data() + choice.source_offset;
  const size_t matched_units = line.size() - choice.source_offset;
  int32_t origin_x = 0, origin_y = 0, design_w = 0, design_h = 0;
  if (!ReadYurisLayerPlacement(matched_layer, game, &origin_x, &origin_y,
                               &design_w, &design_h)) {
    return FailYurisModel(6u);
  }
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  if (!yuris_lookup::ClientMatchesDesign(logical_w, logical_h, design_w,
                                         design_h) ||
      !yuris_lookup::ClientMatchesDesign(physical_w, physical_h, design_w,
                                         design_h)) {
    return FailYurisModel(7u);
  }
  // Rebuild the matched layer's glyphs at the layer's design origin.
  const uint32_t count = CollectYurisLayerCells(page, matched_layer);
  const size_t built = yuris_lookup::BuildPageGlyphs(
      rt.cells.data(), count, rt.codepoints.data(), rt.sources.data(),
      origin_x, origin_y, rt.scratch.data(), rt.scratch.size());
  const size_t first = yuris_lookup::MapSelectedSuffix(
      rt.scratch.data(), built, matched_text, matched_units);
  if (built == 0u || first >= built ||
      !yuris_lookup::ShiftSources(rt.scratch.data(), built,
                                  choice.source_offset)) {
    return FailYurisModel(5u);
  }
  model->page = page.id;
  model->layer = matched_layer;
  model->origin_x = origin_x;
  model->origin_y = origin_y;
  model->glyph_seq = rt.processed_glyph_seq;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->design_w = design_w;
  model->design_h = design_h;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = 0u;
  for (size_t i = first; i < built; ++i) {
    const auto& glyph = rt.scratch[i];
    if (glyph.source_index == yuris_lookup::kNoSource) continue;
    YurisModelGlyph& out = model->glyphs[model->count];
    if (!yuris_lookup::ProjectGlyph(glyph, design_w, design_h, physical_w,
                                    physical_h, &out.rect)) {
      return FailYurisModel(8u);
    }
    out.line = glyph;
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(first);
  return model->count != 0u;
}

bool SameYurisModelGeometry(const YurisModel& left, const YurisModel& right) {
  if (left.page != right.page || left.glyph_seq != right.glyph_seq ||
      left.layer != right.layer || left.origin_x != right.origin_x ||
      left.origin_y != right.origin_y ||
      left.window != right.window || left.design_w != right.design_w ||
      left.design_h != right.design_h || left.logical_w != right.logical_w ||
      left.logical_h != right.logical_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t i = 0u; i < left.count; ++i) {
    const auto& a = left.glyphs[i];
    const auto& b = right.glyphs[i];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.line.source_index != b.line.source_index) {
      return false;
    }
  }
  return true;
}

bool FailYurisHit(const YurisSubmit& submit, const wchar_t* reason) {
  YurisLookupLog(L"yuris-lookup: hit dropped gen=%llu glyph=%u reason=%s",
                 static_cast<unsigned long long>(submit.generation),
                 submit.glyph, reason);
  return false;
}

bool PublishYurisLookupHit(const YurisSubmit& submit) {
  auto& rt = g_yuris_lookup;
  if (g_header == nullptr || submit.generation == 0u) {
    return FailYurisHit(submit, L"no-header");
  }
  const yuris_lookup::PublishedLine* record =
      rt.published_lines.Find(submit.generation);
  if (record == nullptr) return FailYurisHit(submit, L"model-gone");
  const std::wstring& model_line = record->line;
  const size_t units = model_line.size();
  if (submit.line.source_index == yuris_lookup::kNoSource ||
      submit.line.source_length == 0u || submit.line.source_index >= units ||
      submit.line.source_length > units - submit.line.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          model_line.data(), static_cast<uint32_t>(units),
          submit.line.source_index) != submit.line.source_length) {
    return FailYurisHit(submit, L"source-range");
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, model_line.data(),
      static_cast<int>(units), nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return FailYurisHit(submit, L"line-bytes");
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, model_line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return FailYurisHit(submit, L"utf8");
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdYuris;
  publication.char_index = submit.line.source_index;
  publication.source_length = submit.line.source_length;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = record->text_event;
  publication.geometry_generation = submit.generation;
  publication.glyph_x = submit.rect.x;
  publication.glyph_y = submit.rect.y;
  publication.glyph_w = submit.rect.w;
  publication.glyph_h = submit.rect.h;
  publication.view_w = submit.physical_w;
  publication.view_h = submit.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  YurisLookupLog(
      L"yuris-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"design=%d,%d %dx%d view=%dx%d published=%d",
      static_cast<unsigned long long>(submit.generation), submit.glyph,
      submit.line.source_index, submit.line.source_length, submit.rect.x,
      submit.rect.y, submit.rect.w, submit.rect.h, submit.line.x,
      submit.line.y, submit.line.w, submit.line.h, submit.physical_w,
      submit.physical_h, published ? 1 : 0);
  return published;
}

bool ReadLatestYurisSubmit(YurisSubmit* out) {
  auto& rt = g_yuris_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kYurisSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kYurisSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Why the last tick retired (0 = offered); logged once per change.
void NoteYurisRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  const uint32_t key = reason == 4u ? 100u + g_yuris_model_failure : reason;
  if (key == last) return;
  last = key;
  static const wchar_t* const kNames[] = {
      L"offered",          L"lookup-disabled", L"no-page",
      L"no-selected-text", L"model-unbuilt",   L"offer-rejected",
      L"no-window"};
  if (reason == 4u) {
    YurisLookupLog(L"yuris-lookup: gate=model-unbuilt step=%u draws=%u keys=%u",
                   g_yuris_model_failure,
                   g_yuris_lookup.draw_hits.load(std::memory_order_relaxed),
                   g_yuris_lookup.key_polls.load(std::memory_order_relaxed));
    return;
  }
  YurisLookupLog(L"yuris-lookup: gate=%s draws=%u glyphs=%llu texts=%llu keys=%u",
                 reason < 7u ? kNames[reason] : L"?",
                 g_yuris_lookup.draw_hits.load(std::memory_order_relaxed),
                 static_cast<unsigned long long>(
                     g_yuris_lookup.glyph_count.load(std::memory_order_relaxed)),
                 static_cast<unsigned long long>(
                     g_yuris_lookup.text_count.load(std::memory_order_relaxed)),
                 g_yuris_lookup.key_polls.load(std::memory_order_relaxed));
}

void ProcessYurisLookupTick() {
  auto& rt = g_yuris_lookup;
  if (!rt.installed) return;
  // The text lane does not depend on the lookup switch.
  DrainYurisEvents();
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteYurisRetire(1u);
    RetireYurisLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  const uint64_t claims = rt.claimed_presses.load(std::memory_order_acquire);
  if (claims != rt.logged_claims) {
    rt.logged_claims = claims;
    YurisLookupLog(L"yuris-lookup: press claimed total=%llu",
                   static_cast<unsigned long long>(claims));
  }
  YurisSubmit submit;
  if (ReadLatestYurisSubmit(&submit)) (void)PublishYurisLookupHit(submit);
  {
    static uint32_t logged_presses = 0u;
    const uint32_t presses = g_yuris_press_count.load(std::memory_order_relaxed);
    if (presses != logged_presses) {
      logged_presses = presses;
      YurisLookupLog(L"yuris-lookup: fresh press %u reject=%u", presses,
                     g_yuris_press_reject.load(std::memory_order_relaxed));
    }
  }
  FindYurisWindow();
  if (rt.window == nullptr) {
    NoteYurisRetire(6u);
    RetireYurisLookup();
    return;
  }
  if (!rt.page.valid || rt.page.overflow || rt.page.count == 0u) {
    NoteYurisRetire(2u);
    RetireYurisLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, yuris_lookup::kMaxCells)) {
    NoteYurisRetire(3u);
    RetireYurisLookup();
    return;
  }
  YurisModel& built = rt.candidate;
  uint32_t first_glyph = 0u;
  if (!BuildYurisModel(rt.page, line, &built, &first_glyph)) {
    NoteYurisRetire(4u);
    RetireYurisLookup();
    return;
  }
  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameYurisModelGeometry(rt.model, built);
  if (!same) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    rt.published_lines.Record(rt.model.generation, event, line);
    PublishYurisModel(rt.model);
    const auto& first = rt.model.glyphs[0];
    const auto& last = rt.model.glyphs[rt.model.count - 1u];
    YurisLookupLog(
        L"yuris-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
        L"skipped=%u first=%d,%d %dx%d (design %d,%d) last=%d,%d %dx%d "
        L"view=%dx%d client=%dx%d design=%dx%d",
        static_cast<unsigned long long>(rt.model.generation),
        static_cast<unsigned long long>(event),
        static_cast<unsigned>(line.size()), rt.model.count, first_glyph,
        first.rect.x, first.rect.y, first.rect.w, first.rect.h, first.line.x,
        first.line.y, last.rect.x, last.rect.y, last.rect.w, last.rect.h,
        rt.model.physical_w, rt.model.physical_h, rt.model.logical_w,
        rt.model.logical_h, rt.model.design_w, rt.model.design_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdYuris)) {
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteYurisRetire(0u);
  } else {
    NoteYurisRetire(5u);
    RetireYurisLookup();
  }
}

void ShutdownYurisLookup() {
  auto& rt = g_yuris_lookup;
  rt.live.store(false, std::memory_order_release);
  rt.claim = yuris_lookup::ClaimState();
  rt.page.valid = false;
  RetireYurisLookup();
  rt.installed = false;
}

bool YurisLookupSensorInstalled() { return g_yuris_lookup.installed; }
bool YurisLookupSitesRejected() {
  return g_yuris_lookup.resolved && !g_yuris_lookup.hooks_installed;
}

#else  // !_M_IX86

bool InstallYurisLookup() { return false; }
void ProcessYurisLookupTick() {}
void ShutdownYurisLookup() {}
bool YurisLookupSensorInstalled() { return false; }
bool YurisLookupSitesRejected() { return false; }

#endif  // _M_IX86

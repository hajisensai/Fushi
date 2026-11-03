// SoftPal in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdSoftpal).  Every decision rule lives in
// softpal_core.h and is unit-tested; this file binds them to Win32, the
// published text lane, the v19 registry and the highlight window.
//
// Threads:
//   * HookWorker — ProcessSoftpalLookupTick: keeps the pages the text lane
//     published, finds the page of the host's selected line, places its
//     glyphs (the text sprite's last placement on the design screen, the
//     design screen on the client), offers / retires the provider, publishes
//     the model for the input side, turns claimed presses into registry hits
//     and keeps the hover / looked-up term highlight on the glyphs.
//   * game thread — Pal samples the left button every frame through its own
//     imports of GetAsyncKeyState / GetKeyState: those two import slots of
//     the Pal module (only that module) are pointed at our wrappers.  The
//     window procedure of the Pal window is subclassed for the button
//     messages.  The first of the two to see a press decides it
//     (softpal::DecideSample / DecideMessage); a press on a glyph of the
//     current model is hidden from the engine as a whole and queued for the
//     worker, any other press reaches the engine unchanged.
//
// Fail closed everywhere: a page that is not on its sprite any more, a hidden
// or moved sprite, an implausible design screen or a missing native-input
// admission retires the provider or refuses the press.

#if defined(_M_IX86)

constexpr uint32_t kSoftpalLookupPageSlots = 4u;
constexpr uint32_t kSoftpalSubmitSlots = 8u;
constexpr uint32_t kSoftpalParameterBytes = 0x400u;

struct SoftpalLookupPage {
  uint64_t text_event = 0u;
  SoftpalPage page;
};

struct SoftpalModel {
  uint64_t generation = 0u;
  uint64_t page_seq = 0u;
  uintptr_t sprite = 0u;
  uintptr_t window = 0u;  // HWND
  uint32_t origin_x_bits = 0u;  // float design pixels, as placed
  uint32_t origin_y_bits = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  bool keep_aspect = false;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<softpal::PageGlyph, softpal::kMaxPageGlyphs> glyphs{};
};

struct SoftpalSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct SoftpalLookupRuntime {
  // ── HookWorker-owned ──
  bool installed = false;
  bool provider_offered = false;
  HWND window = nullptr;
  HWND failed_window = nullptr;
  uint64_t next_generation = 0u;
  uint64_t processed_submit = 0u;
  std::array<SoftpalLookupPage, kSoftpalLookupPageSlots> pages{};
  uint32_t next_page_slot = 0u;
  SoftpalModel model;  // the offered model
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  uint32_t last_retire = UINT32_MAX;
  uint32_t last_view = UINT32_MAX;
  uintptr_t* async_slot = nullptr;
  uintptr_t* keystate_slot = nullptr;

  // ── input side (game / window thread), under input_lock ──
  SRWLOCK input_lock = SRWLOCK_INIT;
  softpal::PressState press;
  softpal::TouchState touch;  // WM_TOUCH contacts (touch-registered windows)
  // GetTickCount() of the last engine frame that saw a card up over the game
  // (0: none yet).  The host takes a card down as soon as a press lands
  // outside it, before the engine dispatches that contact's WM_TOUCH.
  std::atomic<uint32_t> card_seen_at{0u};
  SoftpalModel input_model;

  // ── shared ──
  std::atomic<HWND> bound_window{nullptr};
  std::atomic<uint32_t> model_version{0u};  // seqlock: odd while writing
  SoftpalModel shared_model;
  std::array<std::atomic<uint64_t>, kSoftpalSubmitSlots> submit_seq = {};
  std::array<SoftpalSubmit, kSoftpalSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint32_t> claimed{0u};
  std::atomic<uint32_t> presses{0u};
  std::atomic<uint32_t> press_reject{0u};
};

SoftpalLookupRuntime g_softpal_lookup;

// Chained-to originals; published before each replacement is visible and
// never cleared (a call in flight may still chain through them).
std::atomic<uintptr_t> g_softpal_async_original{0u};
std::atomic<uintptr_t> g_softpal_keystate_original{0u};
std::atomic<WNDPROC> g_softpal_previous_proc{nullptr};
std::atomic<bool> g_softpal_window_unicode{false};

float SoftpalFloat(uint32_t bits) {
  float value = 0.0f;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

// ── HookWorker: pages and the model ────────────────────────────────────────

// Called by the text lane for every published page (softpal_text.inc).
void NoteSoftpalPublishedPage(const SoftpalPage& page, uint64_t text_event) {
  auto& rt = g_softpal_lookup;
  if (!rt.installed) return;
  for (auto& slot : rt.pages) {
    if (slot.text_event == text_event) {
      slot.page = page;  // a redraw of the same page
      return;
    }
  }
  SoftpalLookupPage& slot =
      rt.pages[rt.next_page_slot++ % kSoftpalLookupPageSlots];
  slot.text_event = text_event;
  slot.page = page;
}

void PublishSoftpalModel(const SoftpalModel& model) {
  auto& rt = g_softpal_lookup;
  const uint32_t version = rt.model_version.load(std::memory_order_relaxed);
  rt.model_version.store(version + 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.shared_model = model;
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_version.store(version + 2u, std::memory_order_release);
}

bool ReadSoftpalModel(SoftpalModel* out) {
  auto& rt = g_softpal_lookup;
  const uint32_t before = rt.model_version.load(std::memory_order_acquire);
  if ((before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.shared_model;
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_version.load(std::memory_order_acquire) == before;
}

void RetireSoftpalLookup(uint32_t reason) {
  auto& rt = g_softpal_lookup;
  if (reason != rt.last_retire) {
    rt.last_retire = reason;
    SoftpalLog(L"softpal-lookup: gate=%u pages=%u presses=%u claimed=%u "
               L"reject=%u",
               reason, g_softpal.page_hits.load(std::memory_order_relaxed),
               rt.presses.load(std::memory_order_relaxed),
               rt.claimed.load(std::memory_order_relaxed),
               rt.press_reject.load(std::memory_order_relaxed));
  }
  if (rt.model.generation != 0u) {
    rt.model.generation = 0u;
    rt.model.count = 0u;
    PublishSoftpalModel(rt.model);
  }
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSoftpal);
  }
}

struct SoftpalDpiScope {
  explicit SoftpalDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~SoftpalDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Logical (the window's own DPI context, what its messages carry) and
// physical client sizes.
bool ReadSoftpalClient(HWND game, int32_t* logical_w, int32_t* logical_h,
                       int32_t* physical_w, int32_t* physical_h) {
  RECT logical = {}, physical = {};
  {
    const DPI_AWARENESS_CONTEXT context = GetWindowDpiAwarenessContext(game);
    if (context == nullptr) return false;
    SoftpalDpiScope own(context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) return false;
  }
  {
    SoftpalDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return false;
    }
  }
  *logical_w = logical.right - logical.left;
  *logical_h = logical.bottom - logical.top;
  *physical_w = physical.right - physical.left;
  *physical_h = physical.bottom - physical.top;
  return *logical_w > 0 && *logical_h > 0 && *physical_w > 0 &&
         *physical_h > 0;
}

// The design screen and the keep-aspect flag from the Pal system block.
bool ReadSoftpalDesign(int32_t* w, int32_t* h, bool* keep_aspect) {
  if (g_softpal.get_parameters == 0u) return false;
  alignas(8) uint32_t block[kSoftpalParameterBytes / 4u] = {};
  __try {
    reinterpret_cast<void(__cdecl*)(void*)>(g_softpal.get_parameters)(block);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  *keep_aspect = block[0x04 / 4] != 0u;
  *w = static_cast<int32_t>(block[0x38 / 4]);
  *h = static_cast<int32_t>(block[0x3c / 4]);
  return softpal::DesignPlausible(*w, *h);
}

bool ReplaceSoftpalWindowProcedure(HWND window);

// The Pal window, subclassed once per HWND.
void BindSoftpalWindow() {
  auto& rt = g_softpal_lookup;
  if (rt.window != nullptr && IsWindow(rt.window)) return;
  rt.window = nullptr;
  rt.bound_window.store(nullptr, std::memory_order_release);
  if (rt.failed_window != nullptr && !IsWindow(rt.failed_window)) {
    rt.failed_window = nullptr;
  }
  if (g_softpal.get_window == 0u) return;
  HWND window = nullptr;
  __try {
    window = reinterpret_cast<HWND(__cdecl*)()>(g_softpal.get_window)();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  DWORD pid = 0u;
  if (window == nullptr || !IsWindow(window) || window == rt.failed_window ||
      GetWindowThreadProcessId(window, &pid) == 0u ||
      pid != GetCurrentProcessId()) {
    return;
  }
  if (!ReplaceSoftpalWindowProcedure(window)) {
    rt.failed_window = window;
    return;
  }
  rt.window = window;
  rt.bound_window.store(window, std::memory_order_release);
}

const SoftpalSpriteSlot* SoftpalPlacement(uintptr_t sprite,
                                          uint64_t page_seq) {
  const SoftpalSpriteSlot* slot = FindSoftpalSprite(sprite);
  if (slot == nullptr ||
      slot->page_seq.load(std::memory_order_acquire) != page_seq ||
      slot->placed.load(std::memory_order_acquire) == 0u ||
      slot->view.load(std::memory_order_acquire) == 0u) {
    return nullptr;
  }
  return slot;
}

// Returns 0 when built, else the gate that failed.
uint32_t BuildSoftpalModel(const SoftpalLookupPage& entry,
                           SoftpalModel* model) {
  auto& rt = g_softpal_lookup;
  const HWND game = rt.window;
  if (game == nullptr || !IsWindow(game) || IsIconic(game)) return 10u;
  int32_t logical_w = 0, logical_h = 0, physical_w = 0, physical_h = 0;
  if (!ReadSoftpalClient(game, &logical_w, &logical_h, &physical_w,
                         &physical_h)) {
    return 11u;
  }
  int32_t design_w = 0, design_h = 0;
  bool keep_aspect = false;
  if (!ReadSoftpalDesign(&design_w, &design_h, &keep_aspect)) return 12u;
  const SoftpalPage& page = entry.page;
  const SoftpalSpriteSlot* slot =
      SoftpalPlacement(page.sprite, page.page_seq);
  if (slot == nullptr) return 13u;
  const uint32_t view = slot->view.load(std::memory_order_acquire);
  if (view != rt.last_view) {
    rt.last_view = view;
    SoftpalLog(L"softpal-lookup: text sprite view=%u", view);
  }
  if (page.glyphs.empty() || page.glyphs.size() > softpal::kMaxPageGlyphs) {
    return 14u;
  }
  model->page_seq = page.page_seq;
  model->sprite = page.sprite;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->origin_x_bits = slot->x_bits.load(std::memory_order_acquire);
  model->origin_y_bits = slot->y_bits.load(std::memory_order_acquire);
  model->design_w = design_w;
  model->design_h = design_h;
  model->keep_aspect = keep_aspect;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = static_cast<uint32_t>(page.glyphs.size());
  std::copy(page.glyphs.begin(), page.glyphs.end(), model->glyphs.begin());
  const float ox = SoftpalFloat(model->origin_x_bits);
  const float oy = SoftpalFloat(model->origin_y_bits);
  if (!(ox > -design_w && ox < design_w * 2.0f && oy > -design_h &&
        oy < design_h * 2.0f)) {
    return 15u;
  }
  return 0u;
}

bool SameSoftpalGeometry(const SoftpalModel& a, const SoftpalModel& b) {
  return a.page_seq == b.page_seq && a.sprite == b.sprite &&
         a.window == b.window && a.origin_x_bits == b.origin_x_bits &&
         a.origin_y_bits == b.origin_y_bits && a.design_w == b.design_w &&
         a.design_h == b.design_h && a.keep_aspect == b.keep_aspect &&
         a.logical_w == b.logical_w && a.logical_h == b.logical_h &&
         a.physical_w == b.physical_w && a.physical_h == b.physical_h &&
         a.count == b.count;
}

bool SoftpalViewport(const SoftpalModel& model, bool physical,
                     softpal::Viewport* viewport) {
  return softpal::ComputeViewport(
      model.design_w, model.design_h,
      physical ? model.physical_w : model.logical_w,
      physical ? model.physical_h : model.logical_h, model.keep_aspect,
      viewport);
}

// A glyph's client rectangle (logical or physical pixels).
bool SoftpalGlyphClientRect(const SoftpalModel& model, double x, double y,
                            double w, double h, bool physical,
                            softpal::PixelRect* rect) {
  softpal::Viewport viewport;
  return SoftpalViewport(model, physical, &viewport) &&
         softpal::DesignRectToClient(
             viewport, SoftpalFloat(model.origin_x_bits) + x,
             SoftpalFloat(model.origin_y_bits) + y, w, h, rect);
}

void PublishSoftpalHit(const SoftpalSubmit& submit) {
  auto& rt = g_softpal_lookup;
  const SoftpalModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count) {
    SoftpalLog(L"softpal-lookup: hit dropped gen=%llu model=%llu",
               static_cast<unsigned long long>(submit.generation),
               static_cast<unsigned long long>(model.generation));
    return;
  }
  const softpal::PageGlyph& glyph = model.glyphs[submit.glyph];
  const std::wstring& line = rt.model_line;
  const size_t units = line.size();
  if (glyph.source_index >= units ||
      fushi_voice_hook::LookupUtf16SourceLength(
          line.data(), static_cast<uint32_t>(units), glyph.source_index) !=
          1u) {
    SoftpalLog(L"softpal-lookup: hit dropped source=%u",
               static_cast<unsigned>(glyph.source_index));
    return;
  }
  softpal::PixelRect rect;
  if (!SoftpalGlyphClientRect(model, glyph.x, glyph.y, glyph.w, glyph.h, true,
                              &rect)) {
    return;
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, line.data(), static_cast<int>(units),
      nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdSoftpal;
  publication.char_index = glyph.source_index;
  publication.source_length = 1u;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = rt.model_text_event;
  publication.geometry_generation = model.generation;
  publication.glyph_x = rect.x;
  publication.glyph_y = rect.y;
  publication.glyph_w = rect.w;
  publication.glyph_h = rect.h;
  publication.view_w = model.physical_w;
  publication.view_h = model.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  SoftpalLog(L"softpal-lookup: hit gen=%llu char=%u rect=%d,%d %dx%d "
             L"view=%dx%d published=%d",
             static_cast<unsigned long long>(model.generation),
             static_cast<unsigned>(glyph.source_index), rect.x, rect.y, rect.w,
             rect.h, model.physical_w, model.physical_h, published ? 1 : 0);
}

bool SoftpalCardVisible(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A card is up over the game: the host shields a press for it, or it shows a
// looked-up term (present frames set the term, the dismiss frame clears it).
bool SoftpalCardShown(HWND game) {
  return SoftpalCardVisible(game) || ReadLookupTermHighlight(nullptr, nullptr);
}

// The highlight over the glyphs: the looked-up term while its card is up,
// else the glyph under the cursor.  Logical pixels, the process's own DPI
// context, which the highlight window shares.
bool UpdateSoftpalHighlight(const SoftpalModel& model) {
  auto& rt = g_softpal_lookup;
  const HWND game = rt.window;
  if (game == nullptr || model.generation == 0u ||
      GetForegroundWindow() != game) {
    return false;
  }
  POINT origin = {0, 0};
  if (!ClientToScreen(game, &origin)) return false;
  softpal::PixelRect rect;
  uint32_t start = 0u, length = 0u;
  if (ReadLookupTermHighlight(&start, &length)) {
    int32_t x = 0, y = 0, w = 0, h = 0;
    if (!softpal::TermRect(model.glyphs.data(), model.count, start, length, &x,
                           &y, &w, &h) ||
        !SoftpalGlyphClientRect(model, x, y, w, h, false, &rect)) {
      return false;
    }
  } else {
    if (SoftpalCardVisible(game)) return false;
    POINT cursor = {};
    if (!GetCursorPos(&cursor) || WindowFromPoint(cursor) != game) {
      return false;
    }
    softpal::Viewport viewport;
    double dx = 0.0, dy = 0.0;
    size_t hit = 0u;
    if (!SoftpalViewport(model, false, &viewport) ||
        !softpal::ClientPointToDesign(viewport, cursor.x - origin.x,
                                      cursor.y - origin.y, &dx, &dy) ||
        !softpal::HitTestPage(model.glyphs.data(), model.count,
                              SoftpalFloat(model.origin_x_bits),
                              SoftpalFloat(model.origin_y_bits), dx, dy,
                              &hit)) {
      return false;
    }
    const softpal::PageGlyph& g = model.glyphs[hit];
    if (!SoftpalGlyphClientRect(model, g.x, g.y, g.w, g.h, false, &rect)) {
      return false;
    }
  }
  RequestLookupHoverHighlight(
      fushi_voice_hook::kLookupGeometryProviderIdSoftpal,
      origin.x + rect.x, origin.y + rect.y, rect.w,
                              rect.h);
  return true;
}

struct SoftpalHighlightScope {
  bool keep = false;
  ~SoftpalHighlightScope() {
    if (!keep) ClearLookupHoverHighlight(
        fushi_voice_hook::kLookupGeometryProviderIdSoftpal);
  }
};

void ProcessSoftpalLookupTick() {
  auto& rt = g_softpal_lookup;
  if (!rt.installed) return;
  SoftpalHighlightScope highlight;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    RetireSoftpalLookup(1u);
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  // Claimed presses first: they refer to the model offered so far.
  const uint64_t latest = rt.submit_count.load(std::memory_order_acquire);
  if (latest != rt.processed_submit) {
    rt.processed_submit = latest;
    auto& slot_seq = rt.submit_seq[latest % kSoftpalSubmitSlots];
    if (slot_seq.load(std::memory_order_acquire) == latest) {
      std::atomic_thread_fence(std::memory_order_acquire);
      const SoftpalSubmit submit = rt.submits[latest % kSoftpalSubmitSlots];
      std::atomic_thread_fence(std::memory_order_acquire);
      if (slot_seq.load(std::memory_order_acquire) == latest) {
        PublishSoftpalHit(submit);
      }
    }
  }
  BindSoftpalWindow();
  if (rt.window == nullptr) {
    RetireSoftpalLookup(2u);
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(g_header, &line, &event,
                                                &thread,
                                                softpal::kMaxPageGlyphs * 2u)) {
    RetireSoftpalLookup(3u);
    return;
  }
  // The selected line is the latest published page with that text.
  const SoftpalLookupPage* entry = nullptr;
  for (const SoftpalLookupPage& candidate : rt.pages) {
    if (candidate.text_event == 0u || candidate.page.text != line) continue;
    if (entry == nullptr || candidate.text_event > entry->text_event) {
      entry = &candidate;
    }
  }
  if (entry == nullptr) {
    RetireSoftpalLookup(4u);
    return;
  }
  SoftpalModel built;
  const uint32_t failed = BuildSoftpalModel(*entry, &built);
  if (failed != 0u) {
    RetireSoftpalLookup(failed);
    return;
  }
  if (rt.model.generation == 0u || rt.model_line != line ||
      rt.model_text_event != event || !SameSoftpalGeometry(rt.model, built)) {
    const uint32_t why =
        (rt.model.generation == 0u ? 1u : 0u) |
        (rt.model_line != line ? 2u : 0u) |
        (rt.model_text_event != event ? 4u : 0u) |
        (rt.model.page_seq != built.page_seq ? 8u : 0u) |
        (!SameSoftpalGeometry(rt.model, built) ? 16u : 0u);
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishSoftpalModel(rt.model);
    SoftpalLog(L"softpal-lookup: model why=%u gen=%llu glyphs=%u origin=%.1f,%.1f "
               L"design=%dx%d aspect=%d client=%dx%d view=%dx%d",
               why, static_cast<unsigned long long>(rt.model.generation),
               rt.model.count, SoftpalFloat(rt.model.origin_x_bits),
               SoftpalFloat(rt.model.origin_y_bits), rt.model.design_w,
               rt.model.design_h, rt.model.keep_aspect ? 1 : 0,
               rt.model.logical_w, rt.model.logical_h, rt.model.physical_w,
               rt.model.physical_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSoftpal)) {
    if (!rt.provider_offered) rt.last_retire = UINT32_MAX;
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
  } else {
    RetireSoftpalLookup(5u);
    return;
  }
  highlight.keep = UpdateSoftpalHighlight(rt.model);
}

// ── input side ─────────────────────────────────────────────────────────────

bool RejectSoftpalPress(uint32_t reason) {
  g_softpal_lookup.press_reject.store(reason, std::memory_order_relaxed);
  return false;
}

// May a press at client (logical) x,y of `hwnd` become a lookup?  Runs under
// input_lock.
bool EvaluateSoftpalPress(HWND hwnd, int32_t x, int32_t y,
                          SoftpalSubmit* submit) {
  auto& rt = g_softpal_lookup;
  rt.presses.fetch_add(1u, std::memory_order_relaxed);
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RejectSoftpalPress(1u);
  }
  SoftpalModel& model = rt.input_model;
  if (!ReadSoftpalModel(&model) || model.generation == 0u ||
      model.count == 0u || hwnd == nullptr ||
      model.window != reinterpret_cast<uintptr_t>(hwnd)) {
    return RejectSoftpalPress(2u);
  }
  // The modelled page is still the one on its sprite, shown, where it was.
  const SoftpalSpriteSlot* slot =
      SoftpalPlacement(model.sprite, model.page_seq);
  if (slot == nullptr ||
      slot->x_bits.load(std::memory_order_acquire) != model.origin_x_bits ||
      slot->y_bits.load(std::memory_order_acquire) != model.origin_y_bits) {
    return RejectSoftpalPress(3u);
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSoftpal)) {
    return RejectSoftpalPress(4u);
  }
  if (SoftpalCardVisible(hwnd)) return RejectSoftpalPress(7u);
  if (GetForegroundWindow() != hwnd) return RejectSoftpalPress(8u);
  if ((GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RejectSoftpalPress(9u);
  }
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return RejectSoftpalPress(5u);
  }
  softpal::Viewport viewport;
  double dx = 0.0, dy = 0.0;
  size_t hit = 0u;
  if (!SoftpalViewport(model, false, &viewport) ||
      !softpal::ClientPointToDesign(viewport, x, y, &dx, &dy) ||
      !softpal::HitTestPage(model.glyphs.data(), model.count,
                            SoftpalFloat(model.origin_x_bits),
                            SoftpalFloat(model.origin_y_bits), dx, dy, &hit)) {
    return RejectSoftpalPress(6u);
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

void QueueSoftpalSubmit(const SoftpalSubmit& submit) {
  auto& rt = g_softpal_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kSoftpalSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kSoftpalSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
  rt.claimed.fetch_add(1u, std::memory_order_relaxed);
}

// Pal's own sample of a key, through its import slot.
SHORT WINAPI SoftpalGetAsyncKeyState(int key) {
  const auto original = reinterpret_cast<SHORT(WINAPI*)(int)>(
      g_softpal_async_original.load(std::memory_order_acquire));
  const SHORT real = original != nullptr ? original(key) : 0;
  auto& rt = g_softpal_lookup;
  if (key != VK_LBUTTON || !g_softpal.live.load(std::memory_order_acquire)) {
    return real;
  }
  const HWND bound = rt.bound_window.load(std::memory_order_acquire);
  if (bound != nullptr && SoftpalCardShown(bound)) {
    rt.card_seen_at.store((std::max)(GetTickCount(), 1ul),
                          std::memory_order_release);
  }
  bool mask = false;
  {
    AcquireSRWLockExclusive(&rt.input_lock);
    softpal::SampleAction action =
        softpal::DecideSample(&rt.press, (real & 0x8000) != 0);
    if (action == softpal::SampleAction::kEvaluate) {
      const HWND hwnd = rt.bound_window.load(std::memory_order_acquire);
      POINT cursor = {};
      SoftpalSubmit submit;
      const bool claimed =
          hwnd != nullptr && GetCursorPos(&cursor) &&
          ScreenToClient(hwnd, &cursor) &&
          EvaluateSoftpalPress(hwnd, cursor.x, cursor.y, &submit);
      softpal::ResolvePress(&rt.press, claimed);
      if (claimed) {
        RejectSoftpalPress(0u);
        QueueSoftpalSubmit(submit);
      }
      action = claimed ? softpal::SampleAction::kMask
                       : softpal::SampleAction::kPass;
    }
    mask = action == softpal::SampleAction::kMask;
    ReleaseSRWLockExclusive(&rt.input_lock);
  }
  return mask ? 0 : real;
}

SHORT WINAPI SoftpalGetKeyState(int key) {
  const auto original = reinterpret_cast<SHORT(WINAPI*)(int)>(
      g_softpal_keystate_original.load(std::memory_order_acquire));
  const SHORT real = original != nullptr ? original(key) : 0;
  auto& rt = g_softpal_lookup;
  if (key != VK_LBUTTON || !g_softpal.live.load(std::memory_order_acquire)) {
    return real;
  }
  AcquireSRWLockShared(&rt.input_lock);
  const bool hidden = rt.press.claimed || rt.press.up_pending;
  ReleaseSRWLockShared(&rt.input_lock);
  return hidden ? static_cast<SHORT>(real & ~0x8000) : real;
}

// Physical screen point (WM_TOUCH reports hundredths of physical pixels) to
// `hwnd`'s client coordinates in its own DPI context.
bool SoftpalTouchToClient(HWND hwnd, const TOUCHINPUT& input, POINT* point) {
  using PhysicalToLogicalFn = BOOL(WINAPI*)(HWND, LPPOINT);
  static const auto physical_to_logical = reinterpret_cast<PhysicalToLogicalFn>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"),
                     "PhysicalToLogicalPointForPerMonitorDPI"));
  point->x = TOUCH_COORD_TO_PIXEL(input.x);
  point->y = TOUCH_COORD_TO_PIXEL(input.y);
  if (physical_to_logical != nullptr) physical_to_logical(hwnd, point);
  return ScreenToClient(hwnd, point) != FALSE;
}

// WM_TOUCH of a touch-registered Pal window: true when the message is hidden
// from the engine (its touch input handle is then closed here).
bool HandleSoftpalTouch(HWND hwnd, WPARAM wparam, LPARAM lparam) {
  auto& rt = g_softpal_lookup;
  TOUCHINPUT inputs[16] = {};
  const UINT count = (std::min)(static_cast<UINT>(LOWORD(wparam)),
                                static_cast<UINT>(std::size(inputs)));
  if (count == 0u ||
      !GetTouchInputInfo(reinterpret_cast<HTOUCHINPUT>(lparam), count, inputs,
                         sizeof(TOUCHINPUT))) {
    return false;
  }
  bool swallow = false;
  AcquireSRWLockExclusive(&rt.input_lock);
  for (UINT i = 0; i < count; ++i) {
    const TOUCHINPUT& input = inputs[i];
    const softpal::TouchEvent event =
        (input.dwFlags & TOUCHEVENTF_DOWN) != 0 ? softpal::TouchEvent::kDown
        : (input.dwFlags & TOUCHEVENTF_UP) != 0 ? softpal::TouchEvent::kUp
                                                : softpal::TouchEvent::kMove;
    const softpal::TouchDecision decision =
        softpal::DecideTouch(&rt.touch, input.dwID, event);
    swallow = swallow || decision.swallow;
    const uint32_t card_seen_at =
        rt.card_seen_at.load(std::memory_order_acquire);
    if (decision.evaluate &&
        (SoftpalCardShown(hwnd) ||
         (card_seen_at != 0u && input.dwTime != 0u &&
          static_cast<int32_t>(card_seen_at - input.dwTime) >= 0))) {
      // The host's card shield hides mouse presses outside the card from
      // the game; a contact taken from WM_TOUCH would get past it.  A card
      // an engine frame saw up at or after the contact's own input time was
      // up when it landed, even if the host has taken it down since.
      softpal::ResolveTouch(&rt.touch, &rt.press, true);
      swallow = true;
    } else if (decision.evaluate) {
      POINT point = {};
      SoftpalSubmit submit;
      const bool claimed =
          SoftpalTouchToClient(hwnd, input, &point) &&
          EvaluateSoftpalPress(hwnd, point.x, point.y, &submit);
      if (softpal::ResolveTouch(&rt.touch, &rt.press, claimed)) {
        RejectSoftpalPress(0u);
        QueueSoftpalSubmit(submit);
        swallow = true;
      }
    }
  }
  ReleaseSRWLockExclusive(&rt.input_lock);
  if (swallow) CloseTouchInputHandle(reinterpret_cast<HTOUCHINPUT>(lparam));
  return swallow;
}

LRESULT CALLBACK SoftpalWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  auto& rt = g_softpal_lookup;
  if (message == WM_TOUCH && g_softpal.live.load(std::memory_order_acquire) &&
      HandleSoftpalTouch(hwnd, wparam, lparam)) {
    return 0;
  }
  const auto kind =
      message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK
          ? softpal::ButtonMessage::kDown
      : message == WM_LBUTTONUP ? softpal::ButtonMessage::kUp
                                : softpal::ButtonMessage::kOther;
  if (kind != softpal::ButtonMessage::kOther &&
      g_softpal.live.load(std::memory_order_acquire)) {
    bool swallow = false;
    {
      AcquireSRWLockExclusive(&rt.input_lock);
      // The press Windows promotes from a contact WM_TOUCH already decided.
      const bool followed =
          kind == softpal::ButtonMessage::kDown &&
          softpal::IsPromotedPointerMessage(
              static_cast<uintptr_t>(GetMessageExtraInfo())) &&
          softpal::TakeTouchPromotion(&rt.touch, &rt.press, &swallow);
      const softpal::MessageDecision decision =
          followed ? softpal::MessageDecision{}
                   : softpal::DecideMessage(&rt.press, kind);
      swallow = swallow || decision.swallow;
      if (decision.evaluate) {
        SoftpalSubmit submit;
        const bool claimed = EvaluateSoftpalPress(
            hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), &submit);
        if (softpal::ResolveMessagePress(&rt.press, claimed)) {
          RejectSoftpalPress(0u);
          QueueSoftpalSubmit(submit);
          swallow = true;
        }
      }
      ReleaseSRWLockExclusive(&rt.input_lock);
    }
    if (swallow) return 0;
  }
  const WNDPROC previous =
      g_softpal_previous_proc.load(std::memory_order_acquire);
  const bool unicode = g_softpal_window_unicode.load(std::memory_order_acquire);
  if (previous == nullptr) {
    return unicode ? DefWindowProcW(hwnd, message, wparam, lparam)
                   : DefWindowProcA(hwnd, message, wparam, lparam);
  }
  return unicode ? CallWindowProcW(previous, hwnd, message, wparam, lparam)
                 : CallWindowProcA(previous, hwnd, message, wparam, lparam);
}

LONG_PTR ReadSoftpalWindowProcedure(HWND window, bool unicode) {
  return unicode ? GetWindowLongPtrW(window, GWLP_WNDPROC)
                 : GetWindowLongPtrA(window, GWLP_WNDPROC);
}

LONG_PTR WriteSoftpalWindowProcedure(HWND window, bool unicode,
                                     LONG_PTR procedure) {
  return unicode ? SetWindowLongPtrW(window, GWLP_WNDPROC, procedure)
                 : SetWindowLongPtrA(window, GWLP_WNDPROC, procedure);
}

// Worker: put our procedure into a newly bound window's chain, chaining to
// whatever was there.  Called once per HWND; false leaves it untouched.
bool ReplaceSoftpalWindowProcedure(HWND window) {
  if (window == nullptr) return false;
  const bool unicode = IsWindowUnicode(window) != FALSE;
  const LONG_PTR ours = reinterpret_cast<LONG_PTR>(&SoftpalWindowProc);
  const LONG_PTR current = ReadSoftpalWindowProcedure(window, unicode);
  if (current == 0 || current == ours) return false;
  g_softpal_window_unicode.store(unicode, std::memory_order_release);
  g_softpal_previous_proc.store(reinterpret_cast<WNDPROC>(current),
                                std::memory_order_release);
  SetLastError(0);
  const LONG_PTR replaced = WriteSoftpalWindowProcedure(window, unicode, ours);
  const bool ok = replaced != 0 || GetLastError() == 0;
  if (ok && replaced != 0 && replaced != current) {
    g_softpal_previous_proc.store(reinterpret_cast<WNDPROC>(replaced),
                                  std::memory_order_release);
  }
  SoftpalLog(L"softpal-lookup: window=%p procedure replaced=%d unicode=%d",
             window, ok ? 1 : 0, unicode ? 1 : 0);
  return ok;
}

// Worker, shutdown: give the window its previous procedure back while ours
// is still the head of its chain (a later subclass chaining to ours keeps
// ours, which then passes everything through).
void RestoreSoftpalWindowProcedure() {
  auto& rt = g_softpal_lookup;
  const HWND window = rt.window;
  rt.window = nullptr;
  rt.bound_window.store(nullptr, std::memory_order_release);
  if (window == nullptr || !IsWindow(window)) return;
  const bool unicode = g_softpal_window_unicode.load(std::memory_order_acquire);
  const WNDPROC previous =
      g_softpal_previous_proc.load(std::memory_order_acquire);
  if (previous == nullptr ||
      ReadSoftpalWindowProcedure(window, unicode) !=
          reinterpret_cast<LONG_PTR>(&SoftpalWindowProc)) {
    return;
  }
  WriteSoftpalWindowProcedure(window, unicode,
                              reinterpret_cast<LONG_PTR>(previous));
}

// The import slot of `symbol` from `dll` in a loaded module, nullptr when
// the module does not import it by name.
uintptr_t* FindSoftpalImportSlot(HMODULE module, const char* dll,
                                 const char* symbol) {
  const auto* base = reinterpret_cast<const uint8_t*>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT) {
    return nullptr;
  }
  const uint32_t directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
          .VirtualAddress;
  const uint32_t image_size = nt->OptionalHeader.SizeOfImage;
  if (directory == 0u || directory >= image_size) return nullptr;
  for (const auto* desc =
           reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(base + directory);
       desc->Name != 0u || desc->FirstThunk != 0u; ++desc) {
    if (desc->Name >= image_size ||
        _stricmp(reinterpret_cast<const char*>(base + desc->Name), dll) != 0) {
      continue;
    }
    const uint32_t lookup = desc->OriginalFirstThunk != 0u
                                ? desc->OriginalFirstThunk
                                : desc->FirstThunk;
    if (lookup == 0u || lookup >= image_size || desc->FirstThunk == 0u ||
        desc->FirstThunk >= image_size) {
      return nullptr;
    }
    const auto* names = reinterpret_cast<const uint32_t*>(base + lookup);
    for (uint32_t i = 0u; names[i] != 0u; ++i) {
      if ((names[i] & IMAGE_ORDINAL_FLAG32) != 0u ||
          names[i] + 2u >= image_size) {
        continue;
      }
      if (std::strcmp(reinterpret_cast<const char*>(base + names[i] + 2u),
                      symbol) == 0) {
        return reinterpret_cast<uintptr_t*>(
            const_cast<uint8_t*>(base) + desc->FirstThunk + i * 4u);
      }
    }
  }
  return nullptr;
}

bool WriteSoftpalImportSlot(uintptr_t* slot, uintptr_t value) {
  DWORD old = 0u;
  if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old)) return false;
  InterlockedExchange(reinterpret_cast<volatile LONG*>(slot),
                      static_cast<LONG>(value));
  VirtualProtect(slot, sizeof(*slot), old, &old);
  return true;
}

// Point one of Pal's import slots at `ours`, publishing the original first.
// `*patched` is the slot only when the result is kPatched.
softpal::ImportPatch PatchSoftpalImport(const char* symbol, uintptr_t ours,
                                        std::atomic<uintptr_t>* original,
                                        uintptr_t** patched) {
  *patched = nullptr;
  uintptr_t* slot = nullptr;
  bool faulted = false;
  __try {
    slot = FindSoftpalImportSlot(g_softpal.module, "USER32.dll", symbol);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    faulted = true;
  }
  // An import table we could not read may import it: not provably absent.
  if (faulted) return softpal::ImportPatch::kFailed;
  if (slot == nullptr) return softpal::ImportPatch::kNotImported;
  if (*slot == 0u || *slot == ours) return softpal::ImportPatch::kFailed;
  original->store(*slot, std::memory_order_release);
  if (!WriteSoftpalImportSlot(slot, ours)) return softpal::ImportPatch::kFailed;
  *patched = slot;
  return softpal::ImportPatch::kPatched;
}

void RestoreSoftpalImport(uintptr_t** slot, uintptr_t ours,
                          const std::atomic<uintptr_t>& original) {
  if (*slot != nullptr && **slot == ours) {
    WriteSoftpalImportSlot(*slot, original.load(std::memory_order_acquire));
  }
  *slot = nullptr;
}

bool InstallSoftpalLookup() {
  auto& rt = g_softpal_lookup;
  if (rt.installed) return true;
  if (!g_softpal.installed || g_softpal.module == nullptr ||
      g_softpal.get_window == 0u || g_softpal.get_parameters == 0u) {
    return false;
  }
  const softpal::ImportPatch async_state = PatchSoftpalImport(
      "GetAsyncKeyState", reinterpret_cast<uintptr_t>(&SoftpalGetAsyncKeyState),
      &g_softpal_async_original, &rt.async_slot);
  const softpal::ImportPatch key_state = PatchSoftpalImport(
      "GetKeyState", reinterpret_cast<uintptr_t>(&SoftpalGetKeyState),
      &g_softpal_keystate_original, &rt.keystate_slot);
  SoftpalLog(L"softpal-lookup: imports async=%u keystate=%u view=%d "
             L"release=%d",
             static_cast<unsigned>(async_state),
             static_cast<unsigned>(key_state), g_softpal.view_hooked ? 1 : 0,
             g_softpal.release_hooked ? 1 : 0);
  // Fail closed: an unwrapped sampler would leak a claimed press to the
  // engine, an untracked hide / release would leave a gone page clickable.
  rt.installed = softpal::LookupAdmissible(async_state, key_state,
                                           g_softpal.view_hooked,
                                           g_softpal.release_hooked);
  if (!rt.installed) {
    RestoreSoftpalImport(&rt.async_slot,
                         reinterpret_cast<uintptr_t>(&SoftpalGetAsyncKeyState),
                         g_softpal_async_original);
    RestoreSoftpalImport(&rt.keystate_slot,
                         reinterpret_cast<uintptr_t>(&SoftpalGetKeyState),
                         g_softpal_keystate_original);
  }
  return rt.installed;
}

void ShutdownSoftpalLookup() {
  auto& rt = g_softpal_lookup;
  RetireSoftpalLookup(0u);
  ClearLookupHoverHighlight(fushi_voice_hook::kLookupGeometryProviderIdSoftpal);
  RestoreSoftpalWindowProcedure();
  RestoreSoftpalImport(&rt.async_slot,
                       reinterpret_cast<uintptr_t>(&SoftpalGetAsyncKeyState),
                       g_softpal_async_original);
  RestoreSoftpalImport(&rt.keystate_slot,
                       reinterpret_cast<uintptr_t>(&SoftpalGetKeyState),
                       g_softpal_keystate_original);
  rt.failed_window = nullptr;
  rt.installed = false;
}

bool SoftpalLookupSensorInstalled() { return g_softpal_lookup.installed; }

#else  // !_M_IX86

bool InstallSoftpalLookup() { return false; }
void ProcessSoftpalLookupTick() {}
void ShutdownSoftpalLookup() {}
bool SoftpalLookupSensorInstalled() { return false; }

#endif  // _M_IX86

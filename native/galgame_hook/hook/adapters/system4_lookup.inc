// AliceSoft System 4 in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdSystem4).  Every decision rule lives in
// system4_core.h and is unit-tested; this file binds them to Win32, the
// published text lane, the registry and the highlight window.
//
// Threads:
//   * HookWorker — ProcessSystem4LookupTick: keeps the pages the text lane
//     published with complete geometry, finds the page of the host's selected
//     line, places its glyphs (the sprite on the design screen, the design
//     screen stretched over the client), offers / retires the provider,
//     publishes the model for the input side, turns claimed presses into
//     registry hits and keeps the hover / looked-up term highlight.
//   * window thread — the game window's procedure is subclassed: the engine
//     sees the left button through those messages only (system4_core.h), so
//     a press on a glyph of the current model is hidden from it as a whole
//     (down and its up) and queued for the worker; any other press reaches
//     the engine unchanged.  A touch tap arrives as the promoted mouse
//     messages and is decided the same way.
//
// Fail closed everywhere: a page that is not on its sprite any more, a hidden
// or moved sprite, a client of another aspect ratio than the design screen or
// a missing native-input admission retires the provider or refuses the press.

#if defined(_M_IX86)

constexpr uint32_t kSystem4LookupPageSlots = 4u;
constexpr uint32_t kSystem4SubmitSlots = 8u;

struct System4LookupPage {
  uint64_t text_event = 0u;
  System4Page page;
};

struct System4Model {
  uint64_t generation = 0u;
  uint64_t page_seq = 0u;
  int32_t sprite = 0;
  uintptr_t window = 0u;  // HWND
  int32_t origin_x = 0;   // design pixels, as placed
  int32_t origin_y = 0;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<system4::PageGlyph, system4::kMaxGroupChars> glyphs{};
};

struct System4Submit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct System4LookupRuntime {
  // ── HookWorker-owned ──
  bool installed = false;
  bool provider_offered = false;
  HWND window = nullptr;
  HWND failed_window = nullptr;
  uint64_t next_generation = 0u;
  uint64_t processed_submit = 0u;
  std::array<System4LookupPage, kSystem4LookupPageSlots> pages{};
  uint32_t next_page_slot = 0u;
  System4Model model;  // the offered model
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  uint32_t last_retire = UINT32_MAX;

  // ── input side (window thread), under input_lock ──
  SRWLOCK input_lock = SRWLOCK_INIT;
  system4::PressState press;
  System4Model input_model;

  // ── shared ──
  std::atomic<uint32_t> model_version{0u};  // seqlock: odd while writing
  System4Model shared_model;
  std::array<std::atomic<uint64_t>, kSystem4SubmitSlots> submit_seq = {};
  std::array<System4Submit, kSystem4SubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint32_t> claimed{0u};
  std::atomic<uint32_t> presses{0u};
  std::atomic<uint32_t> press_reject{0u};
};

System4LookupRuntime g_system4_lookup;

// The chained-to procedure; published before ours is visible and never
// cleared (a message in flight may still chain through it).
std::atomic<WNDPROC> g_system4_previous_proc{nullptr};
std::atomic<bool> g_system4_window_unicode{false};

// ── HookWorker: pages and the model ────────────────────────────────────────

// Called by the text lane for every published page with geometry.
void NoteSystem4PublishedPage(const System4Page& page, uint64_t text_event) {
  auto& rt = g_system4_lookup;
  if (!rt.installed) return;
  System4LookupPage& slot =
      rt.pages[rt.next_page_slot++ % kSystem4LookupPageSlots];
  slot.text_event = text_event;
  slot.page = page;
}

void PublishSystem4Model(const System4Model& model) {
  auto& rt = g_system4_lookup;
  const uint32_t version = rt.model_version.load(std::memory_order_relaxed);
  rt.model_version.store(version + 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.shared_model = model;
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_version.store(version + 2u, std::memory_order_release);
}

bool ReadSystem4Model(System4Model* out) {
  auto& rt = g_system4_lookup;
  const uint32_t before = rt.model_version.load(std::memory_order_acquire);
  if ((before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.shared_model;
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_version.load(std::memory_order_acquire) == before;
}

void RetireSystem4Lookup(uint32_t reason) {
  auto& rt = g_system4_lookup;
  if (reason != rt.last_retire) {
    rt.last_retire = reason;
    System4Log(L"system4-lookup: gate=%u groups=%u presses=%u claimed=%u "
               L"reject=%u",
               reason, g_system4.groups.load(std::memory_order_relaxed),
               rt.presses.load(std::memory_order_relaxed),
               rt.claimed.load(std::memory_order_relaxed),
               rt.press_reject.load(std::memory_order_relaxed));
  }
  if (rt.model.generation != 0u) {
    rt.model.generation = 0u;
    rt.model.count = 0u;
    PublishSystem4Model(rt.model);
  }
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSystem4);
  }
}

struct System4DpiScope {
  explicit System4DpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~System4DpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Logical (the window's own DPI context, what its messages carry) and
// physical client sizes.
bool ReadSystem4Client(HWND game, int32_t* logical_w, int32_t* logical_h,
                       int32_t* physical_w, int32_t* physical_h) {
  RECT logical = {}, physical = {};
  {
    const DPI_AWARENESS_CONTEXT context = GetWindowDpiAwarenessContext(game);
    if (context == nullptr) return false;
    System4DpiScope own(context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) return false;
  }
  {
    System4DpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
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

bool ReplaceSystem4WindowProcedure(HWND window);

struct System4WindowSearch {
  HWND best = nullptr;
  int64_t area = 0;
};

BOOL CALLBACK FindSystem4WindowProc(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<System4WindowSearch*>(param);
  RECT client = {};
  if (!IsWindowVisible(window) || GetWindow(window, GW_OWNER) != nullptr ||
      !GetClientRect(window, &client)) {
    return TRUE;
  }
  const int64_t area = static_cast<int64_t>(client.right - client.left) *
                       (client.bottom - client.top);
  if (area > search->area) {
    search->area = area;
    search->best = window;
  }
  return TRUE;
}

// The game window: the VM thread's largest visible unowned top-level window,
// subclassed once per HWND.
void BindSystem4Window() {
  auto& rt = g_system4_lookup;
  if (rt.window != nullptr && IsWindow(rt.window)) return;
  rt.window = nullptr;
  if (rt.failed_window != nullptr && !IsWindow(rt.failed_window)) {
    rt.failed_window = nullptr;
  }
  const DWORD thread = g_system4.vm_thread;
  if (thread == 0u) return;
  System4WindowSearch search;
  EnumThreadWindows(thread, &FindSystem4WindowProc,
                    reinterpret_cast<LPARAM>(&search));
  if (search.best == nullptr) {
    // The VM may run off the window's thread: the process's own windows.
    EnumWindows(
        [](HWND window, LPARAM param) -> BOOL {
          DWORD pid = 0u;
          GetWindowThreadProcessId(window, &pid);
          return pid == GetCurrentProcessId()
                     ? FindSystem4WindowProc(window, param)
                     : TRUE;
        },
        reinterpret_cast<LPARAM>(&search));
  }
  const HWND window = search.best;
  if (window == nullptr || window == rt.failed_window) return;
  if (!ReplaceSystem4WindowProcedure(window)) {
    rt.failed_window = window;
    return;
  }
  rt.window = window;
}

// The page's sprite still shows that page, visible, where it was drawn.
const System4SpriteSlot* System4Placement(int32_t sprite, uint64_t page_seq) {
  const System4SpriteSlot* slot = FindSystem4Sprite(sprite);
  if (slot == nullptr ||
      slot->page_seq.load(std::memory_order_acquire) != page_seq ||
      slot->view.load(std::memory_order_acquire) == 0u) {
    return nullptr;
  }
  return slot;
}

// Returns 0 when built, else the gate that failed.
uint32_t BuildSystem4Model(const System4LookupPage& entry,
                           System4Model* model) {
  auto& rt = g_system4_lookup;
  const HWND game = rt.window;
  if (game == nullptr || !IsWindow(game) || IsIconic(game)) return 10u;
  int32_t logical_w = 0, logical_h = 0, physical_w = 0, physical_h = 0;
  if (!ReadSystem4Client(game, &logical_w, &logical_h, &physical_w,
                         &physical_h)) {
    return 11u;
  }
  const System4Page& page = entry.page;
  system4::Viewport viewport;
  if (!system4::ComputeViewport(page.design_w, page.design_h, logical_w,
                                logical_h, &viewport)) {
    return 12u;
  }
  const System4SpriteSlot* slot = System4Placement(page.sprite, page.page_seq);
  if (slot == nullptr) return 13u;
  if (page.glyphs.empty() || page.glyphs.size() > system4::kMaxGroupChars) {
    return 14u;
  }
  model->page_seq = page.page_seq;
  model->sprite = page.sprite;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->origin_x = slot->x.load(std::memory_order_acquire);
  model->origin_y = slot->y.load(std::memory_order_acquire);
  model->design_w = page.design_w;
  model->design_h = page.design_h;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = static_cast<uint32_t>(page.glyphs.size());
  std::copy(page.glyphs.begin(), page.glyphs.end(), model->glyphs.begin());
  if (!(model->origin_x > -page.design_w &&
        model->origin_x < page.design_w * 2 &&
        model->origin_y > -page.design_h &&
        model->origin_y < page.design_h * 2)) {
    return 15u;
  }
  return 0u;
}

bool SameSystem4Geometry(const System4Model& a, const System4Model& b) {
  return a.page_seq == b.page_seq && a.sprite == b.sprite &&
         a.window == b.window && a.origin_x == b.origin_x &&
         a.origin_y == b.origin_y && a.design_w == b.design_w &&
         a.design_h == b.design_h && a.logical_w == b.logical_w &&
         a.logical_h == b.logical_h && a.physical_w == b.physical_w &&
         a.physical_h == b.physical_h && a.count == b.count;
}

bool System4Viewport(const System4Model& model, bool physical,
                     system4::Viewport* viewport) {
  return system4::ComputeViewport(
      model.design_w, model.design_h,
      physical ? model.physical_w : model.logical_w,
      physical ? model.physical_h : model.logical_h, viewport);
}

// A sprite-local rectangle's client rectangle (logical or physical pixels).
bool System4GlyphClientRect(const System4Model& model, double x, double y,
                            double w, double h, bool physical,
                            system4::PixelRect* rect) {
  system4::Viewport viewport;
  return System4Viewport(model, physical, &viewport) &&
         system4::DesignRectToClient(viewport, model.origin_x + x,
                                     model.origin_y + y, w, h, rect);
}

void PublishSystem4Hit(const System4Submit& submit) {
  auto& rt = g_system4_lookup;
  const System4Model& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count) {
    System4Log(L"system4-lookup: hit dropped gen=%llu model=%llu",
               static_cast<unsigned long long>(submit.generation),
               static_cast<unsigned long long>(model.generation));
    return;
  }
  const system4::PageGlyph& glyph = model.glyphs[submit.glyph];
  const std::wstring& line = rt.model_line;
  const size_t units = line.size();
  if (glyph.source_index >= units ||
      fushi_voice_hook::LookupUtf16SourceLength(
          line.data(), static_cast<uint32_t>(units), glyph.source_index) !=
          1u) {
    System4Log(L"system4-lookup: hit dropped source=%u",
               static_cast<unsigned>(glyph.source_index));
    return;
  }
  system4::PixelRect rect;
  if (!System4GlyphClientRect(model, glyph.x, glyph.y, glyph.w, glyph.h, true,
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
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdSystem4;
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
  System4Log(L"system4-lookup: hit gen=%llu char=%u rect=%d,%d %dx%d "
             L"view=%dx%d published=%d",
             static_cast<unsigned long long>(model.generation),
             static_cast<unsigned>(glyph.source_index), rect.x, rect.y, rect.w,
             rect.h, model.physical_w, model.physical_h, published ? 1 : 0);
}

bool System4CardVisible(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// The highlight over the glyphs: the looked-up term while its card is up,
// else the glyph under the cursor.  Logical pixels, the process's own DPI
// context, which the highlight window shares.
bool UpdateSystem4Highlight(const System4Model& model) {
  auto& rt = g_system4_lookup;
  const HWND game = rt.window;
  if (game == nullptr || model.generation == 0u ||
      GetForegroundWindow() != game) {
    return false;
  }
  POINT origin = {0, 0};
  if (!ClientToScreen(game, &origin)) return false;
  system4::PixelRect rect;
  uint32_t start = 0u, length = 0u;
  if (ReadLookupTermHighlight(&start, &length)) {
    int32_t x = 0, y = 0, w = 0, h = 0;
    if (!system4::TermRect(model.glyphs.data(), model.count, start, length, &x,
                           &y, &w, &h) ||
        !System4GlyphClientRect(model, x, y, w, h, false, &rect)) {
      return false;
    }
  } else {
    if (System4CardVisible(game)) return false;
    POINT cursor = {};
    if (!GetCursorPos(&cursor) || WindowFromPoint(cursor) != game) {
      return false;
    }
    system4::Viewport viewport;
    double dx = 0.0, dy = 0.0;
    size_t hit = 0u;
    if (!System4Viewport(model, false, &viewport) ||
        !system4::ClientPointToDesign(viewport, cursor.x - origin.x,
                                      cursor.y - origin.y, &dx, &dy) ||
        !system4::HitTestPage(model.glyphs.data(), model.count, model.origin_x,
                              model.origin_y, dx, dy, &hit)) {
      return false;
    }
    const system4::PageGlyph& g = model.glyphs[hit];
    if (!System4GlyphClientRect(model, g.x, g.y, g.w, g.h, false, &rect)) {
      return false;
    }
  }
  RequestLookupHoverHighlight(fushi_voice_hook::kLookupGeometryProviderIdSystem4,
                              origin.x + rect.x, origin.y + rect.y, rect.w,
                              rect.h);
  return true;
}

struct System4HighlightScope {
  bool keep = false;
  ~System4HighlightScope() {
    if (!keep) {
      ClearLookupHoverHighlight(
          fushi_voice_hook::kLookupGeometryProviderIdSystem4);
    }
  }
};

void ProcessSystem4LookupTick() {
  auto& rt = g_system4_lookup;
  if (!rt.installed) return;
  System4HighlightScope highlight;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    RetireSystem4Lookup(1u);
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  // Claimed presses first: they refer to the model offered so far.
  const uint64_t latest = rt.submit_count.load(std::memory_order_acquire);
  if (latest != rt.processed_submit) {
    rt.processed_submit = latest;
    auto& slot_seq = rt.submit_seq[latest % kSystem4SubmitSlots];
    if (slot_seq.load(std::memory_order_acquire) == latest) {
      std::atomic_thread_fence(std::memory_order_acquire);
      const System4Submit submit = rt.submits[latest % kSystem4SubmitSlots];
      std::atomic_thread_fence(std::memory_order_acquire);
      if (slot_seq.load(std::memory_order_acquire) == latest) {
        PublishSystem4Hit(submit);
      }
    }
  }
  BindSystem4Window();
  if (rt.window == nullptr) {
    RetireSystem4Lookup(2u);
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(g_header, &line, &event,
                                                &thread,
                                                system4::kMaxGroupChars * 2u)) {
    RetireSystem4Lookup(3u);
    return;
  }
  // The selected line is the published page of that text event.
  const System4LookupPage* entry = nullptr;
  for (const System4LookupPage& candidate : rt.pages) {
    if (candidate.text_event == 0u || candidate.page.text != line) continue;
    if (entry == nullptr || candidate.text_event > entry->text_event) {
      entry = &candidate;
    }
  }
  if (entry == nullptr) {
    RetireSystem4Lookup(4u);
    return;
  }
  System4Model built;
  const uint32_t failed = BuildSystem4Model(*entry, &built);
  if (failed != 0u) {
    RetireSystem4Lookup(failed);
    return;
  }
  if (rt.model.generation == 0u || rt.model_line != line ||
      rt.model_text_event != event || !SameSystem4Geometry(rt.model, built)) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishSystem4Model(rt.model);
    System4Log(L"system4-lookup: model gen=%llu glyphs=%u sprite=%d "
               L"origin=%d,%d design=%dx%d client=%dx%d view=%dx%d",
               static_cast<unsigned long long>(rt.model.generation),
               rt.model.count, rt.model.sprite, rt.model.origin_x,
               rt.model.origin_y, rt.model.design_w, rt.model.design_h,
               rt.model.logical_w, rt.model.logical_h, rt.model.physical_w,
               rt.model.physical_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSystem4)) {
    if (!rt.provider_offered) rt.last_retire = UINT32_MAX;
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
  } else {
    RetireSystem4Lookup(5u);
    return;
  }
  highlight.keep = UpdateSystem4Highlight(rt.model);
}

// ── input side ─────────────────────────────────────────────────────────────

bool RejectSystem4Press(uint32_t reason) {
  g_system4_lookup.press_reject.store(reason, std::memory_order_relaxed);
  return false;
}

// May a press at client (logical) x,y of `hwnd` become a lookup?  Runs under
// input_lock.
bool EvaluateSystem4Press(HWND hwnd, int32_t x, int32_t y,
                          System4Submit* submit) {
  auto& rt = g_system4_lookup;
  rt.presses.fetch_add(1u, std::memory_order_relaxed);
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RejectSystem4Press(1u);
  }
  System4Model& model = rt.input_model;
  if (!ReadSystem4Model(&model) || model.generation == 0u ||
      model.count == 0u || hwnd == nullptr ||
      model.window != reinterpret_cast<uintptr_t>(hwnd)) {
    return RejectSystem4Press(2u);
  }
  // The modelled page is still the one on its sprite, shown, where it was.
  const System4SpriteSlot* slot = System4Placement(model.sprite, model.page_seq);
  if (slot == nullptr ||
      slot->x.load(std::memory_order_acquire) != model.origin_x ||
      slot->y.load(std::memory_order_acquire) != model.origin_y) {
    return RejectSystem4Press(3u);
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSystem4)) {
    return RejectSystem4Press(4u);
  }
  if (System4CardVisible(hwnd)) return RejectSystem4Press(7u);
  if (GetForegroundWindow() != hwnd) return RejectSystem4Press(8u);
  if ((GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RejectSystem4Press(9u);
  }
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return RejectSystem4Press(5u);
  }
  system4::Viewport viewport;
  double dx = 0.0, dy = 0.0;
  size_t hit = 0u;
  if (!System4Viewport(model, false, &viewport) ||
      !system4::ClientPointToDesign(viewport, x, y, &dx, &dy) ||
      !system4::HitTestPage(model.glyphs.data(), model.count, model.origin_x,
                            model.origin_y, dx, dy, &hit)) {
    return RejectSystem4Press(6u);
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

void QueueSystem4Submit(const System4Submit& submit) {
  auto& rt = g_system4_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kSystem4SubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kSystem4SubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
  rt.claimed.fetch_add(1u, std::memory_order_relaxed);
}

LRESULT CALLBACK System4WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  auto& rt = g_system4_lookup;
  const auto kind =
      message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK
          ? system4::ButtonMessage::kDown
      : message == WM_LBUTTONUP ? system4::ButtonMessage::kUp
                                : system4::ButtonMessage::kOther;
  if (kind != system4::ButtonMessage::kOther &&
      g_system4.live.load(std::memory_order_acquire)) {
    bool swallow = false;
    {
      AcquireSRWLockExclusive(&rt.input_lock);
      const system4::MessageDecision decision =
          system4::DecideMessage(&rt.press, kind);
      swallow = decision.swallow;
      if (decision.evaluate) {
        System4Submit submit;
        const bool claimed = EvaluateSystem4Press(
            hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), &submit);
        if (system4::ResolvePress(&rt.press, claimed)) {
          RejectSystem4Press(0u);
          QueueSystem4Submit(submit);
          swallow = true;
        }
      }
      ReleaseSRWLockExclusive(&rt.input_lock);
    }
    if (swallow) return 0;
  }
  const WNDPROC previous =
      g_system4_previous_proc.load(std::memory_order_acquire);
  const bool unicode = g_system4_window_unicode.load(std::memory_order_acquire);
  if (previous == nullptr) {
    return unicode ? DefWindowProcW(hwnd, message, wparam, lparam)
                   : DefWindowProcA(hwnd, message, wparam, lparam);
  }
  return unicode ? CallWindowProcW(previous, hwnd, message, wparam, lparam)
                 : CallWindowProcA(previous, hwnd, message, wparam, lparam);
}

LONG_PTR ReadSystem4WindowProcedure(HWND window, bool unicode) {
  return unicode ? GetWindowLongPtrW(window, GWLP_WNDPROC)
                 : GetWindowLongPtrA(window, GWLP_WNDPROC);
}

LONG_PTR WriteSystem4WindowProcedure(HWND window, bool unicode,
                                     LONG_PTR procedure) {
  return unicode ? SetWindowLongPtrW(window, GWLP_WNDPROC, procedure)
                 : SetWindowLongPtrA(window, GWLP_WNDPROC, procedure);
}

// Worker: put our procedure into a newly bound window's chain, chaining to
// whatever was there.  Called once per HWND; false leaves it untouched.
bool ReplaceSystem4WindowProcedure(HWND window) {
  if (window == nullptr) return false;
  const bool unicode = IsWindowUnicode(window) != FALSE;
  const LONG_PTR ours = reinterpret_cast<LONG_PTR>(&System4WindowProc);
  const LONG_PTR current = ReadSystem4WindowProcedure(window, unicode);
  if (current == 0 || current == ours) return false;
  g_system4_window_unicode.store(unicode, std::memory_order_release);
  g_system4_previous_proc.store(reinterpret_cast<WNDPROC>(current),
                                std::memory_order_release);
  SetLastError(0);
  const LONG_PTR replaced = WriteSystem4WindowProcedure(window, unicode, ours);
  const bool ok = replaced != 0 || GetLastError() == 0;
  if (ok && replaced != 0 && replaced != current) {
    g_system4_previous_proc.store(reinterpret_cast<WNDPROC>(replaced),
                                  std::memory_order_release);
  }
  System4Log(L"system4-lookup: window=%p procedure replaced=%d unicode=%d",
             window, ok ? 1 : 0, unicode ? 1 : 0);
  return ok;
}

// Worker, shutdown: give the window its previous procedure back while ours
// is still the head of its chain (a later subclass chaining to ours keeps
// ours, which then passes everything through).
void RestoreSystem4WindowProcedure() {
  auto& rt = g_system4_lookup;
  const HWND window = rt.window;
  rt.window = nullptr;
  if (window == nullptr || !IsWindow(window)) return;
  const bool unicode = g_system4_window_unicode.load(std::memory_order_acquire);
  const WNDPROC previous =
      g_system4_previous_proc.load(std::memory_order_acquire);
  if (previous == nullptr ||
      ReadSystem4WindowProcedure(window, unicode) !=
          reinterpret_cast<LONG_PTR>(&System4WindowProc)) {
    return;
  }
  WriteSystem4WindowProcedure(window, unicode,
                              reinterpret_cast<LONG_PTR>(previous));
}

bool InstallSystem4Lookup() {
  auto& rt = g_system4_lookup;
  if (rt.installed) return true;
  // The hit test relies on every sprite state change being tracked: the
  // placement, visibility, deletion and clear detours are all in place
  // whenever the text lane is installed (InstallSystem4Text).
  if (!g_system4.installed || g_system4.get_text_x == nullptr ||
      g_system4.get_text_y == nullptr || g_system4.get_x == nullptr ||
      g_system4.get_y == nullptr || g_system4.get_show == nullptr ||
      g_system4.screen_w == nullptr || g_system4.screen_h == nullptr) {
    return false;
  }
  rt.installed = true;
  System4Log(L"system4-lookup: installed");
  return true;
}

void ShutdownSystem4Lookup() {
  auto& rt = g_system4_lookup;
  RetireSystem4Lookup(0u);
  ClearLookupHoverHighlight(fushi_voice_hook::kLookupGeometryProviderIdSystem4);
  RestoreSystem4WindowProcedure();
  rt.failed_window = nullptr;
  rt.installed = false;
}

bool System4LookupSensorInstalled() { return g_system4_lookup.installed; }

#else  // !_M_IX86

bool InstallSystem4Lookup() { return false; }
void ProcessSystem4LookupTick() {}
void ShutdownSystem4Lookup() {}
bool System4LookupSensorInstalled() { return false; }

#endif  // _M_IX86

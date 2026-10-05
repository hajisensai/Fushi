// Kogado "Hy" in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdKogadoHy).  Engine facts, signatures and every
// decision rule live in kogado_hy_core.h and are unit-tested; this file binds
// them to Win32, the published text lane and the v19 registry.
//
// Threads:
//   * HookWorker — ProcessKogadoHyLookupTick: keeps the click units the text
//     lane published, finds the unit of the host's selected line, places its
//     glyphs on the message panel (the panel chain's offsets, read live) and
//     on the client, offers / retires the provider, publishes the model for
//     the game thread and turns claimed presses into registry hits.
//   * window thread — the game window's procedure, replaced by the worker for
//     each game HWND it binds (SetWindowLongPtr, chained to the previous
//     procedure with CallWindowProc; restored at shutdown while still ours;
//     the window thread is not the script thread that renders the rows).
//     The engine reads clicks only as window messages, for mouse and promoted
//     touch alike.  A left press on exactly one glyph of the
//     current model, with every gate passing, is swallowed together with its
//     own UP and queued for the worker; anything else reaches the engine
//     unchanged.
//
// Fail closed everywhere: an unresolved layout, a hidden or moved panel, a
// client with another aspect than the design screen or a missing native-input
// admission retires the provider or refuses the click.

#if defined(_M_IX86)

constexpr uint32_t kKogadoHyUnitSlots = 4u;
constexpr uint32_t kKogadoHyModelGlyphs = 512u;
constexpr uint32_t kKogadoHySubmitSlots = 8u;
constexpr uint64_t kKogadoHyWindowRetryMs = 500u;

struct KogadoHyUnit {
  uint64_t unit = 0u;
  uint64_t text_event = 0u;
  uintptr_t window_object = 0u;
  uintptr_t rows = 0u;
  uint32_t first_row = 0u;
  uint32_t last_row = 0u;
  uint32_t stride = 0u;
  std::wstring text;
  std::vector<uint8_t> bytes;
};

struct KogadoHyModelGlyph {
  int32_t x = 0;  // panel pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = kogado_hy::kNoSource;
};

struct KogadoHyModel {
  uint64_t generation = 0u;
  uint64_t unit = 0u;
  uint32_t last_row = 0u;
  uintptr_t window = 0u;  // HWND
  uintptr_t panel = 0u;
  int32_t origin_x = 0;  // design pixels
  int32_t origin_y = 0;
  int32_t design_w = 0;  // the window's logical client
  int32_t design_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<KogadoHyModelGlyph, kKogadoHyModelGlyphs> glyphs{};
};

struct KogadoHySubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct KogadoHyLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  kogado_hy::LookupSiteResult site_result =
      kogado_hy::LookupSiteResult::kNoPanelExports;
  bool provider_offered = false;
  // The bound game window: set only once our procedure is in its chain, so a
  // destroyed / recreated window (a new HWND) is bound and subclassed afresh.
  HWND window = nullptr;
  // A window whose procedure refused the replacement: not retried while that
  // HWND lives, and never offered (its clicks always reach the engine).
  HWND failed_window = nullptr;
  uint64_t window_retry_tick = 0u;
  uint64_t next_generation = 0u;
  uint64_t processed_submit = 0u;
  std::array<KogadoHyUnit, kKogadoHyUnitSlots> units{};
  uint32_t next_unit_slot = 0u;
  KogadoHyModel model;           // the offered model
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  std::array<kogado_hy::UnitGlyph, kogado_hy::kMaxUnitGlyphs> scratch{};
  uint32_t last_retire = UINT32_MAX;

  // ── resolved once ──
  kogado_hy::LookupSites layout;

  // ── window-thread-owned ──
  bool up_pending = false;
  KogadoHyModel input_model;

  // ── shared ──
  std::atomic<uint32_t> model_version{0u};  // seqlock: odd while writing
  KogadoHyModel shared_model;
  std::array<std::atomic<uint64_t>, kKogadoHySubmitSlots> submit_seq = {};
  std::array<KogadoHySubmit, kKogadoHySubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint32_t> claimed{0u};
  std::atomic<uint32_t> presses{0u};
  std::atomic<uint32_t> press_reject{0u};
};

KogadoHyLookupRuntime g_kogado_hy_lookup;

// The bound window's previous procedure (whoever subclassed it before us) and
// whether that window is Unicode; published before each replacement is
// visible.  Never cleared: a call already in flight on the window thread may
// still chain through it after a restore.
std::atomic<WNDPROC> g_kogado_hy_previous_proc{nullptr};
std::atomic<bool> g_kogado_hy_window_unicode{false};

template <typename T>
bool ReadKogadoHyValue(uintptr_t address, T* out) {
  if (address < 0x10000u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(T));
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Where a panel sits on the design screen: its offset plus its parents', as
// the exported ClientToScreen composes it.  Every panel of the chain must be
// shown; a chain that does not end within the bound fails closed.
bool ReadKogadoHyPanelOrigin(uintptr_t panel, int32_t* x, int32_t* y) {
  const auto& layout = g_kogado_hy_lookup.layout;
  int64_t sx = 0, sy = 0;
  uintptr_t node = panel;
  for (uint32_t depth = 0u; node != 0u; ++depth) {
    if (depth >= kogado_hy::kMaxPanelChain) return false;
    int32_t px = 0, py = 0;
    uint8_t shown = 0u;
    uintptr_t parent = 0u;
    if (!ReadKogadoHyValue(node + layout.panel_x, &px) ||
        !ReadKogadoHyValue(node + layout.panel_y, &py) ||
        !ReadKogadoHyValue(node + layout.panel_shown, &shown) ||
        !ReadKogadoHyValue(node + layout.panel_parent, &parent) ||
        shown == 0u) {
      return false;
    }
    sx += px;
    sy += py;
    node = parent;
  }
  if (sx < 0 || sy < 0 || sx > kogado_hy::kMaxDesignSide ||
      sy > kogado_hy::kMaxDesignSide) {
    return false;
  }
  *x = static_cast<int32_t>(sx);
  *y = static_cast<int32_t>(sy);
  return true;
}

// The panel that shows a unit's row array (the window object's field for it).
bool ReadKogadoHyUnitPanel(uintptr_t window_object, uintptr_t rows,
                           uintptr_t* panel) {
  if (rows < window_object) return false;
  const uint32_t field = kogado_hy::ArrayPanel(
      g_kogado_hy_lookup.layout, static_cast<uint32_t>(rows - window_object));
  return field != 0u && ReadKogadoHyValue(window_object + field, panel) &&
         *panel != 0u;
}

// ── HookWorker: units and the model ────────────────────────────────────────

bool ReplaceKogadoHyWindowProcedure(HWND window);

// Called by the text lane for every published unit (kogado_hy_text.inc).
void NoteKogadoHyPublishedUnit(const KogadoHyPageEvent& event,
                               const std::wstring& text, uint64_t text_event) {
  auto& rt = g_kogado_hy_lookup;
  if (!rt.installed) return;
  KogadoHyUnit& slot = rt.units[rt.next_unit_slot++ % kKogadoHyUnitSlots];
  slot.unit = event.unit;
  slot.text_event = text_event;
  slot.window_object = event.window;
  slot.rows = event.rows;
  slot.first_row = event.first_row;
  slot.last_row = event.last_row;
  slot.stride = event.stride;
  slot.text = text;
  slot.bytes.assign(event.bytes,
                    event.bytes + static_cast<size_t>(event.last_row + 1u) *
                                      event.stride);
}

void PublishKogadoHyModel(const KogadoHyModel& model) {
  auto& rt = g_kogado_hy_lookup;
  const uint32_t version = rt.model_version.load(std::memory_order_relaxed);
  rt.model_version.store(version + 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.shared_model = model;
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_version.store(version + 2u, std::memory_order_release);
}

bool ReadKogadoHyModel(KogadoHyModel* out) {
  auto& rt = g_kogado_hy_lookup;
  const uint32_t before = rt.model_version.load(std::memory_order_acquire);
  if ((before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.shared_model;
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_version.load(std::memory_order_acquire) == before;
}

void RetireKogadoHyLookup(uint32_t reason) {
  auto& rt = g_kogado_hy_lookup;
  if (reason != rt.last_retire) {
    rt.last_retire = reason;
    KogadoHyLog(L"kogado-hy-lookup: gate=%u renders=%u presses=%u reject=%u",
                reason, g_kogado_hy.render_hits.load(std::memory_order_relaxed),
                rt.presses.load(std::memory_order_relaxed),
                rt.press_reject.load(std::memory_order_relaxed));
  }
  if (rt.model.generation != 0u) {
    rt.model.generation = 0u;
    rt.model.count = 0u;
    PublishKogadoHyModel(rt.model);
  }
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdKogadoHy);
  }
}

// The game window: the one visible top-level (non-child) window of this
// process whose class the game image registered, with a client area (the
// hidden TApplication owner window has none; the host's overlay windows
// belong to the hook DLL).
void FindKogadoHyWindow() {
  auto& rt = g_kogado_hy_lookup;
  if (rt.window != nullptr && IsWindow(rt.window)) return;
  // Destroyed: its procedure chain went with it, nothing to restore.
  rt.window = nullptr;
  if (rt.failed_window != nullptr && !IsWindow(rt.failed_window)) {
    rt.failed_window = nullptr;
  }
  const uint64_t now = GetTickCount64();
  if (rt.window_retry_tick != 0u &&
      now - rt.window_retry_tick < kKogadoHyWindowRetryMs) {
    return;
  }
  rt.window_retry_tick = now;
  struct Search {
    HMODULE image = nullptr;
    HWND window = nullptr;
    uint32_t matches = 0u;
  } search;
  search.image = GetModuleHandleW(nullptr);
  EnumWindows(
      [](HWND hwnd, LPARAM context) -> BOOL {
        auto* s = reinterpret_cast<Search*>(context);
        DWORD pid = 0u;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != GetCurrentProcessId() ||
            reinterpret_cast<HMODULE>(GetClassLongPtrW(hwnd, GCLP_HMODULE)) !=
                s->image) {
          return TRUE;
        }
        RECT client = {};
        // A VCL form is owned by the hidden TApplication window, so its
        // GetParent() is that owner: only a child style rules a window out.
        if (!IsWindowVisible(hwnd) ||
            (GetWindowLongW(hwnd, GWL_STYLE) & WS_CHILD) != 0 ||
            !GetClientRect(hwnd, &client) || client.right <= 0 ||
            client.bottom <= 0) {
          return TRUE;
        }
        ++s->matches;
        s->window = hwnd;
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  if (search.matches != 1u || search.window == rt.failed_window) return;
  if (!ReplaceKogadoHyWindowProcedure(search.window)) {
    rt.failed_window = search.window;
    return;
  }
  rt.window = search.window;
}

struct KogadoHyDpiScope {
  explicit KogadoHyDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~KogadoHyDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Logical (the design screen the engine draws) and physical client sizes.
bool ReadKogadoHyClient(HWND game, int32_t* logical_w, int32_t* logical_h,
                        int32_t* physical_w, int32_t* physical_h) {
  RECT logical = {}, physical = {};
  {
    const DPI_AWARENESS_CONTEXT context = GetWindowDpiAwarenessContext(game);
    if (context == nullptr) return false;
    KogadoHyDpiScope own(context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) return false;
  }
  {
    KogadoHyDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return false;
    }
  }
  *logical_w = logical.right - logical.left;
  *logical_h = logical.bottom - logical.top;
  *physical_w = physical.right - physical.left;
  *physical_h = physical.bottom - physical.top;
  return kogado_hy::DesignPlausible(*logical_w, *logical_h) &&
         *physical_w > 0 && *physical_h > 0;
}

// Returns 0 when built, else the gate that failed.
uint32_t BuildKogadoHyModel(const KogadoHyUnit& unit, KogadoHyModel* model) {
  auto& rt = g_kogado_hy_lookup;
  const HWND game = rt.window;
  if (game == nullptr || !IsWindow(game) || IsIconic(game)) return 10u;
  int32_t design_w = 0, design_h = 0, physical_w = 0, physical_h = 0;
  if (!ReadKogadoHyClient(game, &design_w, &design_h, &physical_w,
                          &physical_h)) {
    return 11u;
  }
  // A stretched client shows the whole design screen at one aspect.
  const int64_t cross = static_cast<int64_t>(physical_w) * design_h -
                        static_cast<int64_t>(physical_h) * design_w;
  const int64_t limit = (std::max)(design_w, design_h);
  if (cross > limit || cross < -limit) return 12u;
  uintptr_t panel = 0u;
  int32_t origin_x = 0, origin_y = 0;
  if (!ReadKogadoHyUnitPanel(unit.window_object, unit.rows, &panel) ||
      !ReadKogadoHyPanelOrigin(panel, &origin_x, &origin_y)) {
    return 13u;
  }
  const size_t count = kogado_hy::BuildUnitGlyphs(
      unit.bytes.data(), unit.stride, unit.first_row, unit.last_row,
      rt.layout, rt.scratch.data(), rt.scratch.size());
  if (count == 0u || count != unit.text.size() ||
      count > kKogadoHyModelGlyphs) {
    return 14u;
  }
  model->unit = unit.unit;
  model->last_row = unit.last_row;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->panel = panel;
  model->origin_x = origin_x;
  model->origin_y = origin_y;
  model->design_w = design_w;
  model->design_h = design_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = static_cast<uint32_t>(count);
  for (size_t i = 0u; i < count; ++i) {
    const auto& g = rt.scratch[i];
    kogado_hy::PixelRect rect;
    if (!kogado_hy::ProjectRect(origin_x + g.x, origin_y + g.y, g.w, g.h,
                                design_w, design_h, physical_w, physical_h,
                                &rect)) {
      return 15u;
    }
    model->glyphs[i] = {g.x, g.y, g.w, g.h, g.source_index};
  }
  return 0u;
}

bool SameKogadoHyGeometry(const KogadoHyModel& a, const KogadoHyModel& b) {
  if (a.unit != b.unit || a.last_row != b.last_row || a.window != b.window ||
      a.panel != b.panel || a.origin_x != b.origin_x ||
      a.origin_y != b.origin_y || a.design_w != b.design_w ||
      a.design_h != b.design_h || a.physical_w != b.physical_w ||
      a.physical_h != b.physical_h || a.count != b.count) {
    return false;
  }
  for (uint32_t i = 0u; i < a.count; ++i) {
    if (a.glyphs[i].x != b.glyphs[i].x || a.glyphs[i].y != b.glyphs[i].y ||
        a.glyphs[i].source_index != b.glyphs[i].source_index) {
      return false;
    }
  }
  return true;
}

void PublishKogadoHyHit(const KogadoHySubmit& submit) {
  auto& rt = g_kogado_hy_lookup;
  const KogadoHyModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count) {
    KogadoHyLog(L"kogado-hy-lookup: hit dropped gen=%llu model=%llu",
                static_cast<unsigned long long>(submit.generation),
                static_cast<unsigned long long>(model.generation));
    return;
  }
  const KogadoHyModelGlyph& glyph = model.glyphs[submit.glyph];
  const std::wstring& line = rt.model_line;
  const size_t units = line.size();
  if (glyph.source_index >= units ||
      fushi_voice_hook::LookupUtf16SourceLength(
          line.data(), static_cast<uint32_t>(units), glyph.source_index) !=
          1u) {
    KogadoHyLog(L"kogado-hy-lookup: hit dropped source=%u",
                static_cast<unsigned>(glyph.source_index));
    return;
  }
  kogado_hy::PixelRect rect;
  if (!kogado_hy::ProjectRect(model.origin_x + glyph.x,
                              model.origin_y + glyph.y, glyph.w, glyph.h,
                              model.design_w, model.design_h,
                              model.physical_w, model.physical_h, &rect)) {
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
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdKogadoHy;
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
  KogadoHyLog(L"kogado-hy-lookup: hit gen=%llu char=%u rect=%d,%d %dx%d "
              L"view=%dx%d published=%d",
              static_cast<unsigned long long>(model.generation),
              static_cast<unsigned>(glyph.source_index), rect.x, rect.y,
              rect.w, rect.h, model.physical_w, model.physical_h,
              published ? 1 : 0);
}

void ProcessKogadoHyLookupTick() {
  auto& rt = g_kogado_hy_lookup;
  if (!rt.installed) return;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    RetireKogadoHyLookup(1u);
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  // Claimed presses first: they refer to the model offered so far.
  const uint64_t latest = rt.submit_count.load(std::memory_order_acquire);
  if (latest != rt.processed_submit) {
    rt.processed_submit = latest;
    auto& slot_seq = rt.submit_seq[latest % kKogadoHySubmitSlots];
    if (slot_seq.load(std::memory_order_acquire) == latest) {
      std::atomic_thread_fence(std::memory_order_acquire);
      const KogadoHySubmit submit = rt.submits[latest % kKogadoHySubmitSlots];
      std::atomic_thread_fence(std::memory_order_acquire);
      if (slot_seq.load(std::memory_order_acquire) == latest) {
        PublishKogadoHyHit(submit);
      }
    }
  }
  FindKogadoHyWindow();
  if (rt.window == nullptr) {
    RetireKogadoHyLookup(2u);
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(g_header, &line, &event,
                                                &thread,
                                                kKogadoHyModelGlyphs)) {
    RetireKogadoHyLookup(3u);
    return;
  }
  // The selected line is the latest published unit with that text.
  const KogadoHyUnit* unit = nullptr;
  for (uint32_t i = 0u; i < kKogadoHyUnitSlots; ++i) {
    const KogadoHyUnit& candidate = rt.units[i];
    if (candidate.unit == 0u || candidate.text != line) continue;
    if (unit == nullptr || candidate.unit > unit->unit ||
        (candidate.unit == unit->unit && candidate.last_row > unit->last_row)) {
      unit = &candidate;
    }
  }
  if (unit == nullptr) {
    RetireKogadoHyLookup(4u);
    return;
  }
  KogadoHyModel built;
  const uint32_t failed = BuildKogadoHyModel(*unit, &built);
  if (failed != 0u) {
    RetireKogadoHyLookup(failed);
    return;
  }
  if (rt.model.generation == 0u || rt.model_line != line ||
      rt.model_text_event != event || !SameKogadoHyGeometry(rt.model, built)) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishKogadoHyModel(rt.model);
    KogadoHyLog(L"kogado-hy-lookup: model gen=%llu unit=%llu glyphs=%u "
                L"origin=%d,%d design=%dx%d view=%dx%d",
                static_cast<unsigned long long>(rt.model.generation),
                static_cast<unsigned long long>(rt.model.unit), rt.model.count,
                rt.model.origin_x, rt.model.origin_y, rt.model.design_w,
                rt.model.design_h, rt.model.physical_w, rt.model.physical_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdKogadoHy)) {
    if (!rt.provider_offered) rt.last_retire = UINT32_MAX;
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
  } else {
    RetireKogadoHyLookup(5u);
  }
}

// ── game thread: the window subclass ───────────────────────────────────────

bool KogadoHyShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

bool RejectKogadoHyPress(uint32_t reason) {
  g_kogado_hy_lookup.press_reject.store(reason, std::memory_order_relaxed);
  return false;
}

// May the press at client (logical) x,y become a lookup?
bool KogadoHyPressEligible(HWND hwnd, int32_t x, int32_t y,
                           KogadoHySubmit* submit) {
  auto& rt = g_kogado_hy_lookup;
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RejectKogadoHyPress(1u);
  }
  KogadoHyModel& model = rt.input_model;
  if (!ReadKogadoHyModel(&model) || model.generation == 0u ||
      model.count == 0u || model.window != reinterpret_cast<uintptr_t>(hwnd)) {
    return RejectKogadoHyPress(2u);
  }
  // The unit on screen is still the modelled one, at the modelled row (the
  // script thread publishes both; this runs on the window thread).
  if (g_kogado_hy.shown_unit.load(std::memory_order_acquire) != model.unit ||
      g_kogado_hy.shown_last_row.load(std::memory_order_acquire) !=
          model.last_row) {
    return RejectKogadoHyPress(3u);
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdKogadoHy) ||
      KogadoHyShieldActive(hwnd) || GetForegroundWindow() != hwnd ||
      (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RejectKogadoHyPress(4u);
  }
  RECT client = {};
  int32_t origin_x = 0, origin_y = 0;
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.design_w ||
      client.bottom - client.top != model.design_h ||
      !ReadKogadoHyPanelOrigin(model.panel, &origin_x, &origin_y) ||
      origin_x != model.origin_x || origin_y != model.origin_y) {
    return RejectKogadoHyPress(5u);
  }
  static kogado_hy::UnitGlyph glyphs[kKogadoHyModelGlyphs];
  for (uint32_t i = 0u; i < model.count; ++i) {
    glyphs[i].x = model.glyphs[i].x;
    glyphs[i].y = model.glyphs[i].y;
    glyphs[i].w = model.glyphs[i].w;
    glyphs[i].h = model.glyphs[i].h;
    glyphs[i].source_index = model.glyphs[i].source_index;
  }
  size_t hit = 0u;
  if (!kogado_hy::HitTestGlyphs(glyphs, model.count, origin_x, origin_y, x, y,
                                &hit)) {
    return RejectKogadoHyPress(6u);
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

void QueueKogadoHySubmit(const KogadoHySubmit& submit) {
  auto& rt = g_kogado_hy_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kKogadoHySubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kKogadoHySubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

LRESULT CALLBACK KogadoHyWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  auto& rt = g_kogado_hy_lookup;
  if (g_kogado_hy.live.load(std::memory_order_acquire)) {
    bool swallow = false;
    __try {
      const auto kind =
          message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK
              ? kogado_hy::ButtonMessage::kDown
          : message == WM_LBUTTONUP ? kogado_hy::ButtonMessage::kUp
                                    : kogado_hy::ButtonMessage::kOther;
      const kogado_hy::ClaimDecision decision =
          kogado_hy::DecideButtonMessage(kind, &rt.up_pending);
      swallow = decision.swallow;
      KogadoHySubmit submit;
      if (decision.evaluate) rt.presses.fetch_add(1u, std::memory_order_relaxed);
      if (decision.evaluate &&
          KogadoHyPressEligible(hwnd, GET_X_LPARAM(lparam),
                                GET_Y_LPARAM(lparam), &submit)) {
        RejectKogadoHyPress(0u);
        QueueKogadoHySubmit(submit);
        rt.claimed.fetch_add(1u, std::memory_order_relaxed);
        rt.up_pending = true;
        swallow = true;
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      swallow = false;
    }
    if (swallow) return 0;
  }
  const WNDPROC previous =
      g_kogado_hy_previous_proc.load(std::memory_order_acquire);
  const bool unicode =
      g_kogado_hy_window_unicode.load(std::memory_order_acquire);
  if (previous == nullptr) {
    return unicode ? DefWindowProcW(hwnd, message, wparam, lparam)
                   : DefWindowProcA(hwnd, message, wparam, lparam);
  }
  return unicode ? CallWindowProcW(previous, hwnd, message, wparam, lparam)
                 : CallWindowProcA(previous, hwnd, message, wparam, lparam);
}

LONG_PTR ReadKogadoHyWindowProcedure(HWND window, bool unicode) {
  return unicode ? GetWindowLongPtrW(window, GWLP_WNDPROC)
                 : GetWindowLongPtrA(window, GWLP_WNDPROC);
}

LONG_PTR WriteKogadoHyWindowProcedure(HWND window, bool unicode,
                                      LONG_PTR procedure) {
  return unicode ? SetWindowLongPtrW(window, GWLP_WNDPROC, procedure)
                 : SetWindowLongPtrA(window, GWLP_WNDPROC, procedure);
}

// Worker: put our procedure into a newly bound game window's chain, chaining
// to whatever was there (the engine's VCL procedure or another component's
// subclass).  Called once per HWND; false leaves the window untouched.
bool ReplaceKogadoHyWindowProcedure(HWND window) {
  if (window == nullptr) return false;
  const bool unicode = IsWindowUnicode(window) != FALSE;
  const LONG_PTR ours = reinterpret_cast<LONG_PTR>(&KogadoHyWindowProc);
  const LONG_PTR current = ReadKogadoHyWindowProcedure(window, unicode);
  // Ours already (lost track of it): chaining to ourselves would loop.
  if (current == 0 || current == ours) return false;
  // The window thread can enter our procedure the instant the swap lands, so
  // what it reads is published first.
  g_kogado_hy_window_unicode.store(unicode, std::memory_order_release);
  g_kogado_hy_previous_proc.store(reinterpret_cast<WNDPROC>(current),
                                  std::memory_order_release);
  SetLastError(0);
  const LONG_PTR replaced = WriteKogadoHyWindowProcedure(window, unicode, ours);
  const bool ok = replaced != 0 || GetLastError() == 0;
  // The procedure the window really had at the swap is the one to chain to
  // (another component may have subclassed it since we read it; until this
  // store the earlier one, still a valid procedure of the chain, is used).
  if (ok && replaced != 0 && replaced != current) {
    g_kogado_hy_previous_proc.store(reinterpret_cast<WNDPROC>(replaced),
                                    std::memory_order_release);
  }
  KogadoHyLog(L"kogado-hy-lookup: window=%p procedure replaced=%d unicode=%d",
              window, ok ? 1 : 0, unicode ? 1 : 0);
  return ok;
}

// Worker, shutdown: hand the bound window its previous procedure back, but
// only while ours is still the head of its chain.  If a later subclass chains
// to ours, unhooking would cut it off; ours stays and passes everything
// through (the lookup is retired, so no press is claimed any more).
void RestoreKogadoHyWindowProcedure() {
  auto& rt = g_kogado_hy_lookup;
  const HWND window = rt.window;
  rt.window = nullptr;
  if (window == nullptr || !IsWindow(window)) return;
  const bool unicode =
      g_kogado_hy_window_unicode.load(std::memory_order_acquire);
  const WNDPROC previous =
      g_kogado_hy_previous_proc.load(std::memory_order_acquire);
  if (previous == nullptr ||
      ReadKogadoHyWindowProcedure(window, unicode) !=
          reinterpret_cast<LONG_PTR>(&KogadoHyWindowProc)) {
    return;
  }
  WriteKogadoHyWindowProcedure(window, unicode,
                               reinterpret_cast<LONG_PTR>(previous));
}

bool InstallKogadoHyLookup() {
  auto& rt = g_kogado_hy_lookup;
  if (rt.installed) return true;
  if (rt.resolved || !g_kogado_hy.installed) return false;
  rt.resolved = true;
  kogado_hy::ImageView view;
  if (!LoadKogadoHyPristineView(&view)) return false;
  rt.site_result =
      kogado_hy::ResolveLookupSites(view, g_kogado_hy.sites, &rt.layout);
  KogadoHyLog(L"kogado-hy-lookup: result=%u pitch=%u row=%ux%u panel "
              L"x=0x%x y=0x%x parent=0x%x shown=0x%x arrays=%u",
              static_cast<unsigned>(rt.site_result), rt.layout.row_pitch,
              rt.layout.row_width, rt.layout.row_height, rt.layout.panel_x,
              rt.layout.panel_y, rt.layout.panel_parent, rt.layout.panel_shown,
              rt.layout.array_count);
  rt.installed = rt.site_result == kogado_hy::LookupSiteResult::kResolved;
  return rt.installed;
}

void ShutdownKogadoHyLookup() {
  auto& rt = g_kogado_hy_lookup;
  RetireKogadoHyLookup(0u);
  RestoreKogadoHyWindowProcedure();
  rt.failed_window = nullptr;
  rt.installed = false;
}

bool KogadoHyLookupSensorInstalled() { return g_kogado_hy_lookup.installed; }
bool KogadoHyLookupSitesRejected() {
  return g_kogado_hy_lookup.resolved && !g_kogado_hy_lookup.installed;
}

#else  // !_M_IX86

bool InstallKogadoHyLookup() { return false; }
void ProcessKogadoHyLookupTick() {}
void ShutdownKogadoHyLookup() {}
bool KogadoHyLookupSensorInstalled() { return false; }
bool KogadoHyLookupSitesRejected() { return false; }

#endif  // _M_IX86

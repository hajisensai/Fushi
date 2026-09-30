// BGI / Ethornell message text lane + in-game lookup runtime
// (EngineExactLayout / kLookupGeometryProviderIdBgi).  Engine facts,
// signatures and every decision rule live in bgi_lookup_core.h and are
// unit-tested; this file only binds them to MinHook, Win32, the text lanes and
// the v19 registry.
//
// Threads:
//   * game thread — SetTextImpl detour: calls the engine, then copies the line
//     (bounded CP932 bytes), the receiver / owner identity and the laid-out
//     cells (bounded) into a fixed ring.  No allocation, no IO, no conversion.
//   * message thread — main window procedure detour: a bare WM_LBUTTONDOWN /
//     DBLCLK on a mapped glyph of the current model is swallowed together with
//     its WM_LBUTTONUP, so the engine's key-down latch never sees the click.
//   * HookWorker — ProcessBgiLookupTick: parses and converts queued lines,
//     publishes the text lane, keeps the latest mappable page, re-validates
//     the owner (engine's own drawable predicate, display position), matches
//     the selected line, projects to physical client pixels, offers/retires
//     the provider, publishes the model for the message thread and turns
//     queued presses into registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing, an owner
// class whose drawable / display functions do not decode, a hidden or moved
// owner, markup in the line, a cell count that is not the displayed unit
// count, a text mismatch, a client with another aspect than the design screen
// or a missing native-input admission retires the provider or refuses the
// click, and the click then reaches the game unchanged.

#if defined(_M_IX86)

namespace bgi_lookup = fushi_voice_hook::bgi_lookup;

constexpr uint32_t kBgiEventSlots = 8u;
constexpr uint32_t kBgiModelSlots = 2u;
constexpr uint32_t kBgiSubmitSlots = 8u;
constexpr uint32_t kBgiModelLogBudget = 24u;
constexpr uint32_t kBgiOwnerAbiCache = 4u;
constexpr uint64_t kBgiWindowRetryMs = 500u;
constexpr uint64_t kBgiTextDedupeMs = 500u;

struct BgiTextEvent {
  uint64_t tick = 0u;
  uintptr_t receiver = 0u;
  uintptr_t receiver_vtable = 0u;
  uintptr_t owner = 0u;
  uintptr_t owner_vtable = 0u;
  int32_t render = 0;
  uint32_t text_bytes = 0u;
  uint32_t cell_count = 0u;
  bool cells_overflow = false;
  uint8_t text[bgi_lookup::kMaxTextBytes + 1u] = {};
  bgi_lookup::Cell cells[bgi_lookup::kMaxCells] = {};
};

struct BgiModelGlyph {
  bgi_lookup::LineGlyph line;
  bgi_lookup::PixelRect rect;  // physical client pixels
};

struct BgiModel {
  uint64_t generation = 0u;
  uint64_t page = 0u;
  uint64_t event_seq = 0u;  // lines captured when the model was built
  uintptr_t window = 0u;
  uintptr_t owner = 0u;
  uintptr_t owner_vtable = 0u;
  bgi_lookup::OwnerAbi abi;
  int32_t owner_x = 0;
  int32_t owner_y = 0;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<BgiModelGlyph, bgi_lookup::kMaxCells> glyphs{};
};

struct BgiSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct BgiPage {
  bool valid = false;
  uint64_t id = 0u;
  uintptr_t owner = 0u;
  uintptr_t owner_vtable = 0u;
  bgi_lookup::OwnerAbi abi;
  uint64_t text_event = 0u;
  uint32_t count = 0u;
  std::array<bgi_lookup::Cell, bgi_lookup::kMaxCells> cells{};
  std::array<uint32_t, bgi_lookup::kMaxCells> codepoints{};
  std::array<uint16_t, bgi_lookup::kMaxCells> sources{};
  std::wstring text;
};

struct BgiOwnerAbiEntry {
  uintptr_t vtable = 0u;
  bool decoded = false;
  bgi_lookup::OwnerAbi abi;
};

struct BgiLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  bgi_lookup::SiteResult site_result = bgi_lookup::SiteResult::kNotX86;
  bool provider_offered = false;
  bool window_hooked = false;
  bool window_rejected = false;
  uint64_t window_retry_tick = 0u;
  uint64_t processed_event_seq = 0u;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint64_t next_page = 0u;
  uint32_t logged_models = 0u;
  uint32_t logged_pages = 0u;
  BgiTextEvent event_copy;
  BgiPage page;
  BgiModel model;
  BgiModel candidate;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  std::array<bgi_lookup::LineGlyph, bgi_lookup::kMaxCells> scratch{};
  std::array<BgiOwnerAbiEntry, kBgiOwnerAbiCache> abis{};
  uint32_t next_abi = 0u;
  std::wstring last_text;
  uint64_t last_text_thread = 0u;
  uint64_t last_text_tick = 0u;
  uint64_t last_text_event = 0u;

  // ── resolved once, read everywhere ──
  bgi_lookup::Sites sites;
  uintptr_t image_base = 0u;
  HWND window = nullptr;

  // ── message-thread-owned ──
  bgi_lookup::ClaimState claim;
  BgiModel input_model;
  std::array<bgi_lookup::LineGlyph, bgi_lookup::kMaxCells> input_lines{};

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> event_count{0u};
  std::array<std::atomic<uint64_t>, kBgiEventSlots> event_seq = {};
  std::array<BgiTextEvent, kBgiEventSlots> events = {};
  std::array<std::atomic<uint32_t>, kBgiModelSlots> model_seq = {};
  std::array<BgiModel, kBgiModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kBgiSubmitSlots> submit_seq = {};
  std::array<BgiSubmit, kBgiSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  std::atomic<uint32_t> impl_hits{0u};
};

BgiLookupRuntime g_bgi_lookup;
using BgiImplThisFn = int(__thiscall*)(uintptr_t, const char*, int, int, int);
using BgiImplStdFn = int(__stdcall*)(uintptr_t, const char*, int, int, int);
BgiImplThisFn g_bgi_impl_this_original = nullptr;
BgiImplStdFn g_bgi_impl_std_original = nullptr;
WNDPROC g_bgi_wndproc_original = nullptr;

template <typename T>
bool ReadBgiValue(uintptr_t address, T* out) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(T));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

bool ReadBgiBytes(uintptr_t address, void* out, size_t bytes) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), bytes);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

// ── two-slot seqlock (model) ───────────────────────────────────────────────

size_t BgiModelBytes(uint32_t count) {
  return offsetof(BgiModel, glyphs) +
         static_cast<size_t>(count) * sizeof(BgiModelGlyph);
}

void PublishBgiModel(const BgiModel& value) {
  auto& rt = g_bgi_lookup;
  const uint32_t current = rt.published_model.load(std::memory_order_acquire);
  const uint32_t slot = current >= kBgiModelSlots
                            ? 0u
                            : static_cast<uint32_t>((current + 1u) %
                                                    kBgiModelSlots);
  const uint32_t seq = rt.model_seq[slot].load(std::memory_order_relaxed);
  rt.model_seq[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&rt.models[slot], &value, BgiModelBytes(value.count));
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_seq[slot].store((seq | 1u) + 1u, std::memory_order_release);
  rt.published_model.store(slot, std::memory_order_release);
}

bool ReadBgiModelBytes(BgiModel* out, size_t bytes) {
  auto& rt = g_bgi_lookup;
  const uint32_t slot = rt.published_model.load(std::memory_order_acquire);
  if (out == nullptr || slot >= kBgiModelSlots) return false;
  const uint32_t before = rt.model_seq[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &rt.models[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_seq[slot].load(std::memory_order_acquire) == before &&
         rt.published_model.load(std::memory_order_acquire) == slot;
}

bool ReadBgiModel(BgiModel* out) {
  if (!ReadBgiModelBytes(out, offsetof(BgiModel, glyphs))) return false;
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(bgi_lookup::kMaxCells));
  return ReadBgiModelBytes(out, BgiModelBytes(count)) && out->count == count;
}

void InvalidateBgiModel() {
  g_bgi_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

// ── game thread: SetTextImpl ───────────────────────────────────────────────

// Copies the line and its laid-out cells into the next ring slot.  The cell
// list is only valid now: the message object is released after the reveal.
void CaptureBgiText(uintptr_t self, const char* text, int render) {
  auto& rt = g_bgi_lookup;
  rt.impl_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire) || self == 0u ||
      text == nullptr) {
    return;
  }
  // Empty lines (the engine clears a sibling object after every line) carry
  // nothing and must not age the model.
  uint8_t first = 0u;
  if (!ReadBgiValue(reinterpret_cast<uintptr_t>(text), &first) || first == 0u) {
    return;
  }
  const uint64_t sequence =
      rt.event_count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.event_seq[sequence % kBgiEventSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  BgiTextEvent& event = rt.events[sequence % kBgiEventSlots];
  event.tick = GetTickCount64();
  event.receiver = self;
  event.render = render;
  event.text_bytes = 0u;
  event.cell_count = 0u;
  event.cells_overflow = false;
  bool ok = true;
  __try {
    const auto* bytes = reinterpret_cast<const uint8_t*>(text);
    uint32_t length = 0u;
    while (length < bgi_lookup::kMaxTextBytes && bytes[length] != 0u) {
      event.text[length] = bytes[length];
      ++length;
    }
    event.text[length] = 0u;
    event.text_bytes = length;
    event.receiver_vtable = *reinterpret_cast<const uintptr_t*>(self);
    event.owner = *reinterpret_cast<const uintptr_t*>(
        self + rt.sites.owner_offset);
    event.owner_vtable =
        event.owner == 0u ? 0u : *reinterpret_cast<const uintptr_t*>(event.owner);
    uintptr_t cell = *reinterpret_cast<const uintptr_t*>(
        self + rt.sites.list_offset + bgi_lookup::kCellLinkOffset);
    uint32_t count = 0u;
    while (cell != 0u) {
      if (count >= bgi_lookup::kMaxCells) {
        event.cells_overflow = true;
        break;
      }
      bgi_lookup::Cell& out = event.cells[count++];
      out.x = *reinterpret_cast<const int32_t*>(cell + bgi_lookup::kCellXOffset);
      out.y = *reinterpret_cast<const int32_t*>(cell + bgi_lookup::kCellYOffset);
      out.w = *reinterpret_cast<const int32_t*>(
          cell + bgi_lookup::kCellSurfaceWidthOffset);
      out.h = *reinterpret_cast<const int32_t*>(
          cell + bgi_lookup::kCellSurfaceHeightOffset);
      cell = *reinterpret_cast<const uintptr_t*>(
          cell + bgi_lookup::kCellLinkOffset);
    }
    event.cell_count = count;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  if (!ok) {
    event.text_bytes = 0u;
    event.cell_count = 0u;
  }
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
}

int __fastcall BgiImplThisDetour(uintptr_t self, uintptr_t, const char* text,
                                 int render, int a2, int a3) {
  const int result = g_bgi_impl_this_original(self, text, render, a2, a3);
  CaptureBgiText(self, text, render);
  return result;
}

int __stdcall BgiImplStdDetour(uintptr_t self, const char* text, int render,
                               int a2, int a3) {
  const int result = g_bgi_impl_std_original(self, text, render, a2, a3);
  CaptureBgiText(self, text, render);
  return result;
}

// ── message thread: main window procedure ─────────────────────────────────

void QueueBgiSubmit(const BgiSubmit& submit) {
  auto& rt = g_bgi_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kBgiSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kBgiSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool BgiShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// The owner still is what the model was built from: same class, drawn by the
// engine's own predicate, at the same display position.
bool BgiOwnerMatchesModel(const BgiModel& model) {
  uint8_t owner[0x400] = {};
  if (model.abi.max_field > sizeof(owner) ||
      !ReadBgiBytes(model.owner, owner, model.abi.max_field)) {
    return false;
  }
  uintptr_t vtable = 0u;
  std::memcpy(&vtable, owner, sizeof(vtable));
  int32_t x = 0, y = 0;
  return vtable == model.owner_vtable &&
         bgi_lookup::EvaluateDrawable(model.abi, owner, model.abi.max_field) &&
         bgi_lookup::EvaluatePosition(model.abi, owner, model.abi.max_field, &x,
                                      &y) &&
         x == model.owner_x && y == model.owner_y;
}

// A left press delivered to the engine's window procedure: may it become a
// lookup?  Only a bare press on exactly one mapped glyph of the current model,
// in the foreground game window, with the host's native-input admission
// applied, no card shielding the game and the owner unchanged on screen.
bool BgiPressEligible(HWND hwnd, WPARAM wparam, LPARAM lparam,
                      BgiSubmit* submit) {
  auto& rt = g_bgi_lookup;
  if (!rt.live.load(std::memory_order_acquire) || g_header == nullptr ||
      g_stop || !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return false;
  }
  BgiModel& model = rt.input_model;
  if (!ReadBgiModel(&model) || model.generation == 0u || model.count == 0u) {
    return false;
  }
  // A line captured after the model was built (the worker has not caught up)
  // means the page on screen may already be another one.
  if (reinterpret_cast<uintptr_t>(hwnd) != model.window ||
      rt.event_count.load(std::memory_order_acquire) != model.event_seq ||
      !fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdBgi) ||
      BgiShieldActive(hwnd) || GetForegroundWindow() != hwnd ||
      (wparam & (MK_SHIFT | MK_CONTROL | MK_RBUTTON | MK_MBUTTON)) != 0u ||
      (GetKeyState(VK_MENU) & 0x8000) != 0 || !BgiOwnerMatchesModel(model)) {
    return false;
  }
  // lparam and GetClientRect are the window's logical client pixels (this is
  // the window's own thread, so its DPI awareness applies).
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return false;
  }
  int32_t x = 0, y = 0;
  if (!bgi_lookup::ClientToDesign(
          static_cast<int16_t>(LOWORD(lparam)),
          static_cast<int16_t>(HIWORD(lparam)), model.logical_w,
          model.logical_h, model.design_w, model.design_h, &x, &y)) {
    return false;
  }
  auto& lines = rt.input_lines;
  for (uint32_t index = 0u; index < model.count; ++index) {
    lines[index] = model.glyphs[index].line;
  }
  size_t hit = 0u;
  if (!bgi_lookup::HitTestLine(lines.data(), model.count, x, y, &hit)) {
    return false;
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

LRESULT CALLBACK BgiWndProcDetour(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  auto& rt = g_bgi_lookup;
  if (rt.live.load(std::memory_order_acquire) &&
      (bgi_lookup::NeedsEligibility(message) ||
       message == bgi_lookup::kMessageLeftUp)) {
    bool eligible = false;
    BgiSubmit submit;
    if (bgi_lookup::NeedsEligibility(message)) {
      __try {
        eligible = BgiPressEligible(hwnd, wparam, lparam, &submit);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        eligible = false;
      }
    }
    const auto decision = bgi_lookup::DecideMessage(message, eligible, &rt.claim);
    if (decision.submit) {
      QueueBgiSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.swallow) return 0;
  }
  return g_bgi_wndproc_original(hwnd, message, wparam, lparam);
}

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void BgiLookupLog(const wchar_t* format, ...) {
  wchar_t line[512] = {};
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
  wchar_t stamped[640] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[1920] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

// One MinHook transaction; all or nothing.  A target someone else already
// hooked installs none.
bool InstallBgiHook(void* target, void* detour, void** original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, detour, original) == MH_OK;
    ok = created && MH_QueueEnableHook(target) == MH_OK &&
         MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = target;
  } else {
    if (created) MH_RemoveHook(target);
    *original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

bool InstallBgiLookup() {
  auto& rt = g_bgi_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    // Re-install after a shutdown: the detours are still chained and only
    // need to start recording again.  A rejected image stays rejected.
    if (!rt.hooks_installed) return false;
    rt.claim = bgi_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    rt.site_result = bgi_lookup::SiteResult::kNotX86;
  } else {
    rt.site_result = bgi_lookup::ResolveSites(image, &rt.sites);
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  if (rt.site_result != bgi_lookup::SiteResult::kResolved) {
    BgiLookupLog(L"bgi-lookup: sites unresolved result=%u scan=%.1fms",
                 static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  rt.image_base = reinterpret_cast<uintptr_t>(image.base);
  rt.claim = bgi_lookup::ClaimState();
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  void* target = reinterpret_cast<void*>(rt.image_base + rt.sites.set_text_impl);
  const bool hooked =
      rt.sites.generation == bgi_lookup::Generation::kThiscall
          ? InstallBgiHook(target, reinterpret_cast<void*>(&BgiImplThisDetour),
                           reinterpret_cast<void**>(&g_bgi_impl_this_original))
          : InstallBgiHook(target, reinterpret_cast<void*>(&BgiImplStdDetour),
                           reinterpret_cast<void**>(&g_bgi_impl_std_original));
  rt.hooks_installed = hooked;
  rt.installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  BgiLookupLog(
      L"bgi-lookup: sites gen=%u impl=+0x%lx exvt=+0x%lx layout=+0x%lx "
      L"slot=0x%x owner=0x%x list=0x%x screen=+0x%lx hooks=%d scan=%.1fms",
      static_cast<unsigned>(rt.sites.generation),
      static_cast<unsigned long>(rt.sites.set_text_impl),
      static_cast<unsigned long>(rt.sites.ex_vtable),
      static_cast<unsigned long>(rt.sites.layout), rt.sites.layout_slot_disp,
      rt.sites.owner_offset, rt.sites.list_offset,
      static_cast<unsigned long>(rt.sites.screen_widths), hooked ? 1 : 0,
      scan_ms);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

// Owner ABI of one class, decoded once from its own vtable functions.
const bgi_lookup::OwnerAbi* BgiOwnerAbi(uintptr_t vtable) {
  auto& rt = g_bgi_lookup;
  if (vtable == 0u) return nullptr;
  for (const auto& entry : rt.abis) {
    if (entry.vtable == vtable) return entry.decoded ? &entry.abi : nullptr;
  }
  BgiOwnerAbiEntry& entry = rt.abis[rt.next_abi % kBgiOwnerAbiCache];
  ++rt.next_abi;
  entry = BgiOwnerAbiEntry();
  entry.vtable = vtable;
  // Only code and tables of the game's own image are decoded.
  const uintptr_t base = rt.image_base;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  const bool opened = fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
      reinterpret_cast<HMODULE>(base), &image);
  auto read = [&image, base, opened](uintptr_t address,
                                     size_t bytes) -> const uint8_t* {
    if (!opened || address < base || address - base >= image.size ||
        fushi_voice_hook::exact_lookup::FindSectionForRva(
            image, address - base, bytes) == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<const uint8_t*>(address);
  };
  entry.decoded = bgi_lookup::DecodeOwnerAbi(vtable, read, &entry.abi);
  BgiLookupLog(
      L"bgi-lookup: owner class vt=+0x%lx decoded=%d drawable=%u display=%u "
      L"terms=%u camera=%d",
      static_cast<unsigned long>(vtable - base), entry.decoded ? 1 : 0,
      entry.abi.drawable_count, entry.abi.display_slot,
      entry.abi.position_count, entry.abi.has_camera ? 1 : 0);
  return entry.decoded ? &entry.abi : nullptr;
}

bool ReadBgiOwnerPosition(uintptr_t owner, const bgi_lookup::OwnerAbi& abi,
                          uintptr_t* vtable, bool* drawable, int32_t* x,
                          int32_t* y) {
  uint8_t bytes[0x400] = {};
  if (abi.max_field > sizeof(bytes) ||
      !ReadBgiBytes(owner, bytes, abi.max_field)) {
    return false;
  }
  std::memcpy(vtable, bytes, sizeof(*vtable));
  *drawable = bgi_lookup::EvaluateDrawable(abi, bytes, abi.max_field);
  return bgi_lookup::EvaluatePosition(abi, bytes, abi.max_field, x, y);
}

bool ReadBgiDesignSize(int32_t* w, int32_t* h) {
  auto& rt = g_bgi_lookup;
  uint32_t index = 0u;
  uint32_t widths[8] = {};
  uint32_t heights[8] = {};
  const uintptr_t base = rt.image_base;
  return ReadBgiValue(base + rt.sites.screen_index, &index) &&
         ReadBgiBytes(base + rt.sites.screen_widths, widths, sizeof(widths)) &&
         ReadBgiBytes(base + rt.sites.screen_widths + 0x20u, heights,
                      sizeof(heights)) &&
         bgi_lookup::DesignSizeFrom(index, widths, heights, w, h);
}

uint64_t PublishBgiTextLine(const std::wstring& text, uint64_t identity,
                            uintptr_t address, uint64_t tick) {
  auto& rt = g_bgi_lookup;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  constexpr wchar_t kHookCode[] = L"ENGINE:BGI:message_set_text";
  constexpr char kHookName[] = "BGI exact";
  const uint64_t thread_id =
      fushi_voice_hook::NativeTextThreadIdFrom(identity, kHookCode, kHookName);
  // The engine lays a line out once; a repeat of the same line on the same
  // lane within the window is a re-render, not a new line.
  if (thread_id == rt.last_text_thread && text == rt.last_text &&
      tick - rt.last_text_tick <= kBgiTextDedupeMs) {
    return rt.last_text_event;
  }
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.thread_address = address;
  write.thread_context = address;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceBgi;
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
  // An exact engine producer is live: the GDI glyph fallback yields (BGI
  // rasterises every glyph through TextOut into a scratch DIB).
  g_header->luna_active = 1;
  rt.last_text = text;
  rt.last_text_thread = thread_id;
  rt.last_text_tick = tick;
  rt.last_text_event = event;
  return event;
}

// Converts one queued line; publishes it and, when the receiver is an Ex
// message object whose cells map one-to-one onto the displayed units, makes
// it the current page.  Any newer line replaces the page (fail closed).
void ProcessBgiTextEvent(const BgiTextEvent& event) {
  auto& rt = g_bgi_lookup;
  if (event.text_bytes == 0u) return;
  const bgi_lookup::ParsedText parsed =
      bgi_lookup::ParseLine(event.text, event.text_bytes);
  std::wstring text;
  std::array<uint32_t, bgi_lookup::kMaxCells> codepoints{};
  std::array<uint16_t, bgi_lookup::kMaxCells> sources{};
  bool mappable = !parsed.markup && !parsed.truncated &&
                  parsed.count <= bgi_lookup::kMaxCells;
  for (uint32_t index = 0u; index < parsed.count; ++index) {
    const bgi_lookup::TextUnit& unit = parsed.units[index];
    const char* bytes = unit.source
                            ? reinterpret_cast<const char*>(event.text +
                                                            unit.offset)
                            : reinterpret_cast<const char*>(
                                  bgi_lookup::kAutoPrefix[parsed.auto_prefix -
                                                          4u]);
    const int length = unit.source ? unit.length : 2;
    wchar_t wide[4] = {};
    const int converted = MultiByteToWideChar(
        932, MB_ERR_INVALID_CHARS, bytes, length, wide, 4);
    if (converted != 1) {
      mappable = false;
      if (converted <= 0 || !unit.source) continue;
      text.append(wide, static_cast<size_t>(converted));
      continue;
    }
    if (index < bgi_lookup::kMaxCells) {
      codepoints[index] = wide[0];
      sources[index] = unit.source
                           ? static_cast<uint16_t>(text.size())
                           : bgi_lookup::kNoSource;
    }
    if (unit.source) text.push_back(wide[0]);
  }
  if (text.empty()) return;

  const bgi_lookup::OwnerAbi* abi = BgiOwnerAbi(event.owner_vtable);
  int32_t owner_x = 0, owner_y = 0;
  bool drawable = false;
  uintptr_t live_vtable = 0u;
  if (abi != nullptr &&
      !ReadBgiOwnerPosition(event.owner, *abi, &live_vtable, &drawable,
                            &owner_x, &owner_y)) {
    owner_x = 0;
    owner_y = 0;
  }
  const uintptr_t base = rt.image_base;
  const uint32_t owner_class =
      event.owner_vtable >= base
          ? static_cast<uint32_t>(event.owner_vtable - base)
          : 0u;
  const uint64_t identity =
      bgi_lookup::LaneIdentity(owner_class, owner_x, owner_y);
  const uint64_t text_event =
      PublishBgiTextLine(text, identity, event.owner, event.tick);

  BgiPage& page = rt.page;
  page.valid = false;
  const bool ex = event.receiver_vtable == base + rt.sites.ex_vtable;
  if (!ex || !mappable || abi == nullptr || event.cells_overflow ||
      event.cell_count != parsed.count || text_event == 0u) {
    if (rt.logged_pages < kBgiModelLogBudget) {
      ++rt.logged_pages;
      BgiLookupLog(
          L"bgi-lookup: page unmapped ex=%d markup=%d units=%u cells=%u "
          L"overflow=%d abi=%d event=%llu",
          ex ? 1 : 0, parsed.markup ? 1 : 0, parsed.count, event.cell_count,
          event.cells_overflow ? 1 : 0, abi != nullptr ? 1 : 0,
          static_cast<unsigned long long>(text_event));
    }
    return;
  }
  page.valid = true;
  page.id = ++rt.next_page;
  page.owner = event.owner;
  page.owner_vtable = event.owner_vtable;
  page.abi = *abi;
  page.text_event = text_event;
  page.count = event.cell_count;
  std::copy_n(event.cells, event.cell_count, page.cells.begin());
  page.codepoints = codepoints;
  page.sources = sources;
  page.text = text;
}

void DrainBgiTextEvents() {
  auto& rt = g_bgi_lookup;
  const uint64_t latest = rt.event_count.load(std::memory_order_acquire);
  if (latest == rt.processed_event_seq) return;
  uint64_t next = rt.processed_event_seq + 1u;
  if (latest - rt.processed_event_seq > kBgiEventSlots) {
    next = latest - kBgiEventSlots + 1u;  // overrun: oldest lines are lost
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.event_seq[next % kBgiEventSlots];
    if (slot_seq.load(std::memory_order_acquire) != next) break;  // in flight
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.event_copy, &rt.events[next % kBgiEventSlots],
                sizeof(BgiTextEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_event_seq = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;  // torn
    ProcessBgiTextEvent(rt.event_copy);
  }
}

// The main window: the one visible top-level window of this process whose
// (ANSI) window procedure lies in the game image's code.  Its procedure is
// hooked once.
void TryHookBgiWindow() {
  auto& rt = g_bgi_lookup;
  if (rt.window_hooked || rt.window_rejected) return;
  const uint64_t now = GetTickCount64();
  if (rt.window_retry_tick != 0u && now - rt.window_retry_tick < kBgiWindowRetryMs) {
    return;
  }
  rt.window_retry_tick = now;
  struct Search {
    uintptr_t base = 0u;
    fushi_voice_hook::exact_lookup::LoadedPeImage image;
    HWND window = nullptr;
    uintptr_t procedure = 0u;
    uint32_t matches = 0u;
  } search;
  search.base = rt.image_base;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          reinterpret_cast<HMODULE>(search.base), &search.image)) {
    return;
  }
  EnumWindows(
      [](HWND hwnd, LPARAM context) -> BOOL {
        auto* s = reinterpret_cast<Search*>(context);
        DWORD pid = 0u;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) ||
            IsWindowUnicode(hwnd)) {
          return TRUE;
        }
        const uintptr_t procedure = static_cast<uintptr_t>(
            GetWindowLongPtrA(hwnd, GWLP_WNDPROC));
        if (procedure < s->base ||
            !bgi_lookup::IsExecutableRva(s->image, procedure - s->base, 16u)) {
          return TRUE;
        }
        ++s->matches;
        s->window = hwnd;
        s->procedure = procedure;
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  if (search.matches == 0u) return;  // not created yet
  if (search.matches != 1u) {
    rt.window_rejected = true;
    BgiLookupLog(L"bgi-lookup: main window ambiguous (%u candidates)",
                 search.matches);
    return;
  }
  rt.window = search.window;
  rt.window_hooked = InstallBgiHook(
      reinterpret_cast<void*>(search.procedure),
      reinterpret_cast<void*>(&BgiWndProcDetour),
      reinterpret_cast<void**>(&g_bgi_wndproc_original));
  if (!rt.window_hooked) rt.window_rejected = true;
  BgiLookupLog(L"bgi-lookup: window procedure +0x%lx hooked=%d",
               static_cast<unsigned long>(search.procedure - search.base),
               rt.window_hooked ? 1 : 0);
}

void RetireBgiLookup() {
  auto& rt = g_bgi_lookup;
  InvalidateBgiModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdBgi);
  }
}

struct BgiDpiScope {
  explicit BgiDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~BgiDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Diagnostic detail of the last model-build failure (worker only).
struct BgiModelFailure {
  // 1 window 2 dpi 3 owner 4 hidden 5 design 6 aspect 7 no match 8 projection
  uint32_t step = 0u;
  int32_t a = 0, b = 0, c = 0, d = 0;
};
BgiModelFailure g_bgi_model_failure;

bool FailBgiModel(uint32_t step, int32_t a = 0, int32_t b = 0, int32_t c = 0,
                  int32_t d = 0) {
  g_bgi_model_failure = {step, a, b, c, d};
  return false;
}

bool BuildBgiModel(const BgiPage& page, const std::wstring& line,
                   BgiModel* model, uint32_t* first_glyph) {
  auto& rt = g_bgi_lookup;
  const HWND game = rt.window;
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game)) {
    return FailBgiModel(1u);
  }
  // "Logical" is what the window's own thread sees (lparam and GetClientRect
  // in the window procedure): measured under the window's DPI awareness, which
  // a compatibility setting may have made system-aware for this process.
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT window_context =
        GetWindowDpiAwarenessContext(game);
    if (window_context == nullptr) return FailBgiModel(2u);
    BgiDpiScope own(window_context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailBgiModel(2u);
    }
  }
  {
    BgiDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailBgiModel(2u);
    }
  }
  uintptr_t vtable = 0u;
  bool drawable = false;
  int32_t owner_x = 0, owner_y = 0;
  if (!ReadBgiOwnerPosition(page.owner, page.abi, &vtable, &drawable, &owner_x,
                            &owner_y) ||
      vtable != page.owner_vtable) {
    return FailBgiModel(3u);
  }
  if (!drawable) return FailBgiModel(4u);
  int32_t design_w = 0, design_h = 0;
  if (!ReadBgiDesignSize(&design_w, &design_h)) return FailBgiModel(5u);
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  if (!bgi_lookup::ClientMatchesDesign(logical_w, logical_h, design_w,
                                       design_h) ||
      !bgi_lookup::ClientMatchesDesign(physical_w, physical_h, design_w,
                                       design_h)) {
    return FailBgiModel(6u, design_w, design_h, logical_w, logical_h);
  }
  auto& glyphs = rt.scratch;
  const size_t count = bgi_lookup::BuildPageGlyphs(
      page.cells.data(), page.count, page.codepoints.data(),
      page.sources.data(), page.count, owner_x, owner_y, glyphs.data(),
      glyphs.size());
  if (count == 0u) return FailBgiModel(7u, 0, static_cast<int32_t>(page.count));
  const size_t first = bgi_lookup::MapSelectedSuffix(
      glyphs.data(), count, line.data(), line.size());
  if (first >= count) {
    return FailBgiModel(7u, 1, static_cast<int32_t>(count),
                        static_cast<int32_t>(line.size()));
  }
  model->page = page.id;
  model->event_seq = rt.processed_event_seq;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->owner = page.owner;
  model->owner_vtable = page.owner_vtable;
  model->abi = page.abi;
  model->owner_x = owner_x;
  model->owner_y = owner_y;
  model->design_w = design_w;
  model->design_h = design_h;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = 0u;
  for (size_t index = first; index < count; ++index) {
    const auto& glyph = glyphs[index];
    if (glyph.source_index == bgi_lookup::kNoSource) continue;
    BgiModelGlyph& out = model->glyphs[model->count];
    // Every mapped glyph must project into the client: a partially visible
    // line is not a line the user can be looking at.
    if (!bgi_lookup::ProjectCell(glyph, design_w, design_h, physical_w,
                                 physical_h, &out.rect)) {
      return FailBgiModel(8u, glyph.x, glyph.y, physical_w, physical_h);
    }
    out.line = glyph;
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(first);
  return model->count != 0u;
}

bool SameBgiModelGeometry(const BgiModel& left, const BgiModel& right) {
  if (left.page != right.page || left.event_seq != right.event_seq ||
      left.window != right.window ||
      left.owner != right.owner || left.owner_x != right.owner_x ||
      left.owner_y != right.owner_y || left.design_w != right.design_w ||
      left.design_h != right.design_h || left.logical_w != right.logical_w ||
      left.logical_h != right.logical_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.line.source_index != b.line.source_index) {
      return false;
    }
  }
  return true;
}

bool PublishBgiLookupHit(const BgiSubmit& submit) {
  auto& rt = g_bgi_lookup;
  const BgiModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count ||
      rt.model_line.empty()) {
    return false;
  }
  const auto& glyph = model.glyphs[submit.glyph];
  const size_t units = rt.model_line.size();
  if (glyph.line.source_index == bgi_lookup::kNoSource ||
      glyph.line.source_length == 0u || glyph.line.source_index >= units ||
      glyph.line.source_length > units - glyph.line.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          rt.model_line.data(), static_cast<uint32_t>(units),
          glyph.line.source_index) != glyph.line.source_length) {
    return false;
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
      static_cast<int>(units), nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdBgi;
  publication.char_index = glyph.line.source_index;
  publication.source_length = glyph.line.source_length;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = rt.model_text_event;
  publication.geometry_generation = model.generation;
  publication.glyph_x = glyph.rect.x;
  publication.glyph_y = glyph.rect.y;
  publication.glyph_w = glyph.rect.w;
  publication.glyph_h = glyph.rect.h;
  publication.view_w = model.physical_w;
  publication.view_h = model.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  BgiLookupLog(
      L"bgi-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"design=%d,%d %dx%d view=%dx%d published=%d",
      static_cast<unsigned long long>(model.generation), submit.glyph,
      glyph.line.source_index, glyph.line.source_length, glyph.rect.x,
      glyph.rect.y, glyph.rect.w, glyph.rect.h, glyph.line.x, glyph.line.y,
      glyph.line.w, glyph.line.h, model.physical_w, model.physical_h,
      published ? 1 : 0);
  return published;
}

bool ReadLatestBgiSubmit(BgiSubmit* out) {
  auto& rt = g_bgi_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kBgiSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kBgiSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Why the last tick retired (0 = offered).  Logged once per change so a
// silent provider always says which gate it is waiting on.
void NoteBgiRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  static uint32_t budget = 48u;
  const uint32_t key =
      reason == 4u ? 100u + g_bgi_model_failure.step : reason;
  if (key == last || budget == 0u) return;
  last = key;
  --budget;
  static const wchar_t* const kNames[] = {
      L"offered",          L"lookup-disabled", L"no-page",
      L"no-selected-text", L"model-unbuilt",   L"offer-rejected",
      L"no-window"};
  if (reason == 4u) {
    const auto& f = g_bgi_model_failure;
    BgiLookupLog(L"bgi-lookup: gate=%s step=%u %d,%d,%d,%d impl=%u",
                 kNames[reason], f.step, f.a, f.b, f.c, f.d,
                 g_bgi_lookup.impl_hits.load());
    return;
  }
  BgiLookupLog(L"bgi-lookup: gate=%s", reason < 7u ? kNames[reason] : L"?");
}

void ProcessBgiLookupTick() {
  auto& rt = g_bgi_lookup;
  if (!rt.installed) return;
  // The text lane does not depend on the lookup switch.
  DrainBgiTextEvents();
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteBgiRetire(1u);
    RetireBgiLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  TryHookBgiWindow();
  if (!rt.window_hooked) {
    NoteBgiRetire(6u);
    RetireBgiLookup();
    return;
  }
  if (!rt.page.valid) {
    NoteBgiRetire(2u);
    RetireBgiLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, bgi_lookup::kMaxCells)) {
    NoteBgiRetire(3u);
    RetireBgiLookup();
    return;
  }
  BgiModel& built = rt.candidate;
  uint32_t first_glyph = 0u;
  if (!BuildBgiModel(rt.page, line, &built, &first_glyph)) {
    NoteBgiRetire(4u);
    RetireBgiLookup();
    return;
  }
  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameBgiModelGeometry(rt.model, built);
  if (!same) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishBgiModel(rt.model);
    if (rt.logged_models < kBgiModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      BgiLookupLog(
          L"bgi-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
          L"skipped=%u owner=%d,%d first=%d,%d %dx%d (design %d,%d) "
          L"last=%d,%d %dx%d view=%dx%d client=%dx%d design=%dx%d",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event),
          static_cast<unsigned>(line.size()), rt.model.count, first_glyph,
          rt.model.owner_x, rt.model.owner_y, first.rect.x, first.rect.y,
          first.rect.w, first.rect.h, first.line.x, first.line.y, last.rect.x,
          last.rect.y, last.rect.w, last.rect.h, rt.model.physical_w,
          rt.model.physical_h, rt.model.logical_w, rt.model.logical_h,
          rt.model.design_w, rt.model.design_h);
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdBgi)) {
    if (!rt.provider_offered) {
      BgiLookupLog(L"bgi-lookup: OfferReady gen=%llu glyphs=%u",
                   static_cast<unsigned long long>(rt.model.generation),
                   rt.model.count);
    }
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteBgiRetire(0u);
  } else {
    NoteBgiRetire(5u);
    RetireBgiLookup();
    return;
  }
  BgiSubmit submit;
  if (ReadLatestBgiSubmit(&submit)) (void)PublishBgiLookupHit(submit);
}

void ShutdownBgiLookup() {
  auto& rt = g_bgi_lookup;
  // The detours stay chained (MinHook owns them for the process lifetime);
  // clearing `live` turns each into a pure forwarder and drops any claim.
  rt.live.store(false, std::memory_order_release);
  rt.claim = bgi_lookup::ClaimState();
  rt.page.valid = false;
  RetireBgiLookup();
  rt.installed = false;
}

bool BgiLookupSensorInstalled() { return g_bgi_lookup.installed; }
bool BgiLookupSitesRejected() {
  return g_bgi_lookup.resolved && !g_bgi_lookup.hooks_installed;
}

#else  // !_M_IX86

bool InstallBgiLookup() { return false; }
void ProcessBgiLookupTick() {}
void ShutdownBgiLookup() {}
bool BgiLookupSensorInstalled() { return false; }
bool BgiLookupSitesRejected() { return false; }

#endif  // _M_IX86

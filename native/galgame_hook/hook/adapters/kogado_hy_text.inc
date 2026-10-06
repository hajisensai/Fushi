// Kogado "Hy" message text lane runtime.  Engine facts, site resolution and
// the page rules live in kogado_hy_core.h and are unit-tested; this file binds
// them to MinHook, Win32 and the text lanes.
//
// Threads:
//   * game thread — WAIT entry stub: the script's click wait closes the
//     current click unit; the next row rendered opens the next one.
//   * game thread — RENDER entry stub: the message window is about to show
//     row `row` of a row array; rows 0..row of that array (bounded:
//     kMaxRows x stride bytes) are copied into a fixed ring with the window
//     and array addresses and the unit's first row.  A unit also opens at
//     row 0 (a click cleared the page) and when the window switches arrays.
//     No allocation, no IO, no conversion.
//   * HookWorker — ProcessKogadoHyTextTick: composes the click unit so far
//     (speaker row dropped, rows joined), converts it from CP932 and
//     publishes it on the engine's exact lane.  Each new row republishes the
//     longer unit, so the host folds the rows of one unit into one line (a
//     progressive update of the same lane).
//
// Without a resolved WAIT the unit is the page: right for the adventure
// window (a click clears it), too long for the full-screen window (it keeps
// several click units on one page).
//
// Fail closed: an unresolved signature installs nothing; a row that is not
// clean CP932 publishes nothing for that page.

#if defined(_M_IX86)

namespace kogado_hy = fushi_voice_hook::kogado_hy;

constexpr uint32_t kKogadoHyPageSlots = 8u;
constexpr uint32_t kKogadoHyLogBudget = 2048u;

struct KogadoHyPageEvent {
  uint64_t sequence = 0u;
  uint64_t tick = 0u;
  uint64_t unit = 0u;
  uintptr_t window = 0u;
  uintptr_t rows = 0u;
  uint32_t first_row = 0u;
  uint32_t last_row = 0u;
  uint32_t stride = 0u;
  uint8_t bytes[kogado_hy::kMaxPageBytes] = {};
};

struct KogadoHyTextRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  kogado_hy::SiteResult site_result = kogado_hy::SiteResult::kNoExports;
  uint64_t processed_seq = 0u;
  uint32_t logged = 0u;
  KogadoHyPageEvent copy;
  std::wstring last_text;
  uint64_t last_unit = 0u;
  uint64_t last_event = 0u;
  bool wait_hooked = false;
  kogado_hy::WaitResult wait_result = kogado_hy::WaitResult::kNoShowMessage;

  // ── resolved once, read everywhere ──
  kogado_hy::Sites sites;
  kogado_hy::WaitSite wait;
  uintptr_t image_base = 0u;

  // ── game-thread-owned ──
  // Both detours run on the thread that runs the script (WAIT is a script
  // command, RENDER is reached from the message command), so these need no
  // synchronisation.
  uint64_t current_unit = 0u;
  uintptr_t current_rows = 0u;
  uint32_t unit_first_row = 0u;
  bool unit_closed = false;

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> count{0u};
  std::array<std::atomic<uint64_t>, kKogadoHyPageSlots> seq = {};
  std::array<KogadoHyPageEvent, kKogadoHyPageSlots> events = {};
  std::atomic<uint32_t> render_hits{0u};
  std::atomic<uint32_t> wait_hits{0u};
  // The unit and row last rendered, for the window thread's click gate.
  std::atomic<uint64_t> shown_unit{0u};
  std::atomic<uint32_t> shown_last_row{0u};
};

KogadoHyTextRuntime g_kogado_hy;
struct KogadoHyPageEvent;
void NoteKogadoHyPublishedUnit(const KogadoHyPageEvent& event,
                               const std::wstring& text, uint64_t text_event);
void* g_kogado_hy_render_original = nullptr;
void* g_kogado_hy_wait_original = nullptr;
volatile LONG g_kogado_hy_diag = 0;

constexpr LONG kKogadoHyDiagSitesResolved = 0x1;
constexpr LONG kKogadoHyDiagHookInstalled = 0x2;
constexpr LONG kKogadoHyDiagRowObserved = 0x4;
constexpr LONG kKogadoHyDiagTextPublished = 0x8;
constexpr LONG kKogadoHyDiagRowRejected = 0x10;
constexpr LONG kKogadoHyDiagWaitInstalled = 0x20;
constexpr LONG kKogadoHyDiagWaitObserved = 0x40;

void KogadoHyLog(const wchar_t* format, ...) {
  auto& rt = g_kogado_hy;
  if (rt.logged >= kKogadoHyLogBudget) return;
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

// ── game thread: RENDER entry ──────────────────────────────────────────────

// RENDER's register arguments: eax = window, edx = row array, ecx = row.
void __cdecl KogadoHyRenderObserve(uintptr_t window, uintptr_t rows,
                                   uint32_t row) {
  auto& rt = g_kogado_hy;
  rt.render_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire)) return;
  const uint32_t stride = rt.sites.stride;
  if (row >= kogado_hy::kMaxRows || rows == 0u || window == 0u) return;
  // Row 0 opens a unit (the click cleared the array and the counter), so
  // does the other array of the same window and the first row after a click
  // wait.
  if (row == 0u || rows != rt.current_rows) {
    ++rt.current_unit;
    rt.current_rows = rows;
    rt.unit_first_row = 0u;
    rt.unit_closed = false;
  } else if (rt.unit_closed || row < rt.unit_first_row) {
    ++rt.current_unit;
    rt.unit_first_row = row;
    rt.unit_closed = false;
  }
  const uint64_t sequence = rt.count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.seq[sequence % kKogadoHyPageSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  KogadoHyPageEvent& event = rt.events[sequence % kKogadoHyPageSlots];
  bool copied = false;
  __try {
    std::memcpy(event.bytes, reinterpret_cast<const void*>(rows),
                static_cast<size_t>(row + 1u) * stride);
    copied = true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  if (!copied) return;  // slot stays 0: never handed to the worker
  rt.shown_unit.store(rt.current_unit, std::memory_order_release);
  rt.shown_last_row.store(row, std::memory_order_release);
  event.sequence = sequence;
  event.tick = GetTickCount64();
  event.unit = rt.current_unit;
  event.window = window;
  event.rows = rows;
  event.first_row = rt.unit_first_row;
  event.last_row = row;
  event.stride = stride;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
}

// WAIT entry (eax = the game object): the click unit on screen is complete.
void __cdecl KogadoHyWaitObserve() {
  auto& rt = g_kogado_hy;
  rt.wait_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire)) return;
  rt.unit_closed = true;
}

__declspec(naked) void KogadoHyWaitStub() {
  __asm {
    pushfd
    pushad
    call KogadoHyWaitObserve
    popad
    popfd
    jmp dword ptr [g_kogado_hy_wait_original]
  }
}

__declspec(naked) void KogadoHyRenderStub() {
  __asm {
    pushfd
    pushad
    push ecx
    push edx
    push eax
    call KogadoHyRenderObserve
    add esp, 12
    popad
    popfd
    jmp dword ptr [g_kogado_hy_render_original]
  }
}

// ── install ────────────────────────────────────────────────────────────────

// The executable as it is on disk, laid out by section: the signature must
// not depend on what other in-process hookers patched in the live image.
std::vector<uint8_t> g_kogado_hy_pristine;

bool LoadKogadoHyPristineView(kogado_hy::ImageView* view) {
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
  g_kogado_hy_pristine.assign(nt->OptionalHeader.SizeOfImage, 0u);
  std::memcpy(g_kogado_hy_pristine.data(), raw.data(),
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
    if (section.VirtualAddress > g_kogado_hy_pristine.size() ||
        bytes > g_kogado_hy_pristine.size() - section.VirtualAddress ||
        section.PointerToRawData > raw.size() ||
        bytes > raw.size() - section.PointerToRawData) {
      return false;
    }
    std::memcpy(g_kogado_hy_pristine.data() + section.VirtualAddress,
                raw.data() + section.PointerToRawData, bytes);
    if ((section.Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u) {
      if (view->code_count >= view->code.size()) return false;
      view->code[view->code_count++] = {section.VirtualAddress,
                                        section.VirtualAddress + bytes};
    }
  }
  if (nt->OptionalHeader.NumberOfRvaAndSizes > IMAGE_DIRECTORY_ENTRY_EXPORT) {
    const IMAGE_DATA_DIRECTORY& exports =
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    view->export_rva = exports.VirtualAddress;
    view->export_size = exports.Size;
  }
  view->bytes = g_kogado_hy_pristine.data();
  view->size = g_kogado_hy_pristine.size();
  view->va_base = nt->OptionalHeader.ImageBase;
  return view->code_count != 0u;
}

// One detour; a target someone else already hooked installs nothing.
bool InstallKogadoHyHook(void* target, void* stub, void** original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, stub, original) == MH_OK;
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

// The hook target must still be the engine's own bytes.
bool KogadoHyLiveMatches(const kogado_hy::ImageView& view, uintptr_t live_base,
                         uint32_t rva) {
  uint8_t live[8] = {};
  bool same = false;
  __try {
    std::memcpy(live, reinterpret_cast<const void*>(live_base + rva),
                sizeof(live));
    same = rva + sizeof(live) <= view.size &&
           std::memcmp(live, view.bytes + rva, sizeof(live)) == 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return same;
}

bool InstallKogadoHyText() {
  auto& rt = g_kogado_hy;
  if (rt.installed) return true;
  if (rt.resolved) return false;
  rt.resolved = true;
  kogado_hy::ImageView view;
  const uintptr_t live_base =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (!LoadKogadoHyPristineView(&view) || view.va_base != live_base) {
    // A relocated image would need its absolute operands rebased; Hy
    // executables load at their preferred base, anything else fails closed.
    rt.site_result = kogado_hy::SiteResult::kNoExports;
    KogadoHyLog(L"kogado-hy: image unavailable or relocated");
    return false;
  }
  rt.site_result = kogado_hy::ResolveSites(view, &rt.sites);
  if (rt.site_result != kogado_hy::SiteResult::kResolved) {
    KogadoHyLog(L"kogado-hy: sites unresolved result=%u",
                static_cast<unsigned>(rt.site_result));
    return false;
  }
  InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagSitesResolved);
  if (!KogadoHyLiveMatches(view, live_base, rt.sites.render)) {
    KogadoHyLog(L"kogado-hy: render target patched in memory");
    return false;
  }
  rt.wait_result = kogado_hy::ResolveWait(view, rt.sites, &rt.wait);
  const bool wait_usable =
      rt.wait_result == kogado_hy::WaitResult::kResolved &&
      KogadoHyLiveMatches(view, live_base, rt.wait.wait);
  rt.image_base = live_base;
  rt.live.store(true, std::memory_order_release);
  // WAIT first: a unit boundary missed while RENDER is already live would
  // join two click units.
  if (wait_usable) {
    rt.wait_hooked = InstallKogadoHyHook(
        reinterpret_cast<void*>(rt.image_base + rt.wait.wait),
        reinterpret_cast<void*>(&KogadoHyWaitStub),
        &g_kogado_hy_wait_original);
    if (rt.wait_hooked) {
      InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagWaitInstalled);
    }
  }
  rt.installed = InstallKogadoHyHook(
      reinterpret_cast<void*>(rt.image_base + rt.sites.render),
      reinterpret_cast<void*>(&KogadoHyRenderStub),
      &g_kogado_hy_render_original);
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  if (rt.installed) InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagHookInstalled);
  KogadoHyLog(L"kogado-hy: render=+0x%lx text=0x%x stride=%u callers=%u "
              L"arrays=%u hook=%d wait=+0x%lx result=%u win=0x%x hook=%d",
              static_cast<unsigned long>(rt.sites.render), rt.sites.text_object,
              rt.sites.stride, rt.sites.callers, rt.sites.base_count,
              rt.installed ? 1 : 0, static_cast<unsigned long>(rt.wait.wait),
              static_cast<unsigned>(rt.wait_result), rt.wait.window_offset,
              rt.wait_hooked ? 1 : 0);
  return rt.installed;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

constexpr wchar_t kKogadoHyHookCode[] = L"ENGINE:KOGADO_HY:message_page";
constexpr char kKogadoHyHookName[] = "Kogado Hy exact";

uint64_t PublishKogadoHyText(const std::wstring& text, uintptr_t window) {
  auto& rt = g_kogado_hy;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  // Lane identity: the engine's renderer and row stride, stable across runs
  // (one message system per process), unlike the heap address of the window.
  const uint64_t identity =
      (static_cast<uint64_t>(rt.sites.render) << 8) ^ rt.sites.stride;
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      identity, kKogadoHyHookCode, kKogadoHyHookName);
  write.thread_address = window;
  write.thread_context = window;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceKogadoHy;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kKogadoHyHookName;
  write.hook_code = kKogadoHyHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields (the
  // engine rasterises every row through TextOutA into an offscreen buffer).
  g_header->luna_active = 1;
  return event;
}

void ProcessKogadoHyPage(const KogadoHyPageEvent& event) {
  auto& rt = g_kogado_hy;
  InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagRowObserved);
  std::string page;
  bool has_speaker = false;
  const kogado_hy::PageResult result =
      kogado_hy::ComposePage(event.bytes, event.stride, event.first_row,
                             event.last_row, &page, &has_speaker);
  if (result == kogado_hy::PageResult::kRejected) {
    InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagRowRejected);
    KogadoHyLog(L"kogado-hy: unit %llu rows %u..%u rejected",
                static_cast<unsigned long long>(event.unit), event.first_row,
                event.last_row);
    return;
  }
  if (result == kogado_hy::PageResult::kNameOnly) return;
  const int units = MultiByteToWideChar(
      932, MB_ERR_INVALID_CHARS, page.data(), static_cast<int>(page.size()),
      nullptr, 0);
  if (units <= 0) {
    InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagRowRejected);
    return;
  }
  std::wstring text(static_cast<size_t>(units), L'\0');
  MultiByteToWideChar(932, MB_ERR_INVALID_CHARS, page.data(),
                      static_cast<int>(page.size()), text.data(), units);
  // A redraw of the unit that is already up publishes nothing new.
  if (event.unit == rt.last_unit && text == rt.last_text) return;
  const uint64_t published = PublishKogadoHyText(text, event.window);
  KogadoHyLog(L"kogado-hy: unit %llu rows=%u..%u speaker=%d units=%u "
              L"event=%llu",
              static_cast<unsigned long long>(event.unit), event.first_row,
              event.last_row, has_speaker ? 1 : 0,
              static_cast<unsigned>(text.size()),
              static_cast<unsigned long long>(published));
  if (published == 0u) return;
  InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagTextPublished);
  rt.last_unit = event.unit;
  rt.last_text = text;
  rt.last_event = published;
  NoteKogadoHyPublishedUnit(event, text, published);
}

void ProcessKogadoHyTextTick() {
  auto& rt = g_kogado_hy;
  if (!rt.installed) return;
  if (rt.wait_hits.load(std::memory_order_relaxed) != 0u) {
    InterlockedOr(&g_kogado_hy_diag, kKogadoHyDiagWaitObserved);
  }
  const uint64_t latest = rt.count.load(std::memory_order_acquire);
  if (latest == rt.processed_seq) return;
  uint64_t next = rt.processed_seq + 1u;
  if (latest - rt.processed_seq > kKogadoHyPageSlots) {
    next = latest - kKogadoHyPageSlots + 1u;
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.seq[next % kKogadoHyPageSlots];
    if (slot_seq.load(std::memory_order_acquire) != next) {
      // In flight, or the copy faulted: a faulted slot never completes, so
      // skip it once the producer has moved past it.
      if (next < latest) {
        rt.processed_seq = next;
        continue;
      }
      break;
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.copy, &rt.events[next % kKogadoHyPageSlots],
                sizeof(KogadoHyPageEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_seq = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;  // torn
    ProcessKogadoHyPage(rt.copy);
  }
}

void ShutdownKogadoHyText() {
  auto& rt = g_kogado_hy;
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

bool KogadoHyTextInstalled() { return g_kogado_hy.installed; }

#else  // !_M_IX86

bool InstallKogadoHyText() { return false; }
void ProcessKogadoHyTextTick() {}
void ShutdownKogadoHyText() {}
bool KogadoHyTextInstalled() { return false; }
volatile LONG g_kogado_hy_diag = 0;

#endif  // _M_IX86

// EntisGLS message text lane runtime.  Engine facts, site resolution, the
// message-tree walk and the page model live in entisgls_core.h and are
// unit-tested; this file binds them to MinHook, Win32 and the text lanes.
//
// Threads:
//   * game thread (the thread that runs the Sakura2 VM) —
//     SGLSpriteMessage::AddMessage(node) detour: the node tree the VM hands
//     the message window (a text node from addMessageText, an XML document
//     from addMessageXML) is walked through a fault-safe reader and its
//     displayed text (ruby readings left out, CR/LF dropped, bounded) is
//     copied into a fixed ring with the sprite address.
//     SGLSpriteMessage::ClearMessage() detour: a page-wipe event for that
//     sprite.  No allocation, no IO, no conversion.
//   * HookWorker — ProcessEntisGlsTextTick: replays the events in order into
//     the page model (entisgls::OnAdd / OnClear) and publishes every click
//     unit whose script step is over (entisgls::OnTick) on the engine's exact
//     lane.
//
// Fail closed: an unresolved or ambiguous site installs nothing; a message
// whose tree faults or exceeds the bounds publishes nothing.

#if defined(_M_IX86)

namespace entisgls = fushi_voice_hook::entisgls;

constexpr uint32_t kEntisGlsEventSlots = 32u;
constexpr uint32_t kEntisGlsLogBudget = 2048u;

enum EntisGlsEventKind : uint32_t {
  kEntisGlsEventDiscard = 0u,  // the copy failed: committed, never applied
  kEntisGlsEventAdd = 1u,
  kEntisGlsEventClear = 2u,
};

struct EntisGlsEvent {
  uint64_t sequence = 0u;
  uint32_t kind = 0u;
  uint32_t result = 0u;  // entisgls::TextResult of an add
  uintptr_t sprite = 0u;
  uint32_t length = 0u;
  wchar_t text[entisgls::kMaxMessageUnits] = {};
};

struct EntisGlsTextRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  entisgls::SiteResult site_result = entisgls::SiteResult::kNoExports;
  uint64_t processed_seq = 0u;
  uint64_t tick = 0u;
  uint32_t logged = 0u;
  EntisGlsEvent copy;
  entisgls::PageModel model;

  // ── resolved once, read everywhere ──
  entisgls::Sites sites;
  uintptr_t image_base = 0u;

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> count{0u};
  std::array<std::atomic<uint64_t>, kEntisGlsEventSlots> seq = {};
  std::array<EntisGlsEvent, kEntisGlsEventSlots> events = {};
  std::atomic<uint32_t> add_hits{0u};
  std::atomic<uint32_t> clear_hits{0u};
};

EntisGlsTextRuntime g_entisgls;
void* g_entisgls_add_original = nullptr;
void* g_entisgls_clear_original = nullptr;
volatile LONG g_entisgls_diag = 0;

constexpr LONG kEntisGlsDiagSitesResolved = 0x1;
constexpr LONG kEntisGlsDiagHooksInstalled = 0x2;
constexpr LONG kEntisGlsDiagMessageObserved = 0x4;
constexpr LONG kEntisGlsDiagTextPublished = 0x8;
constexpr LONG kEntisGlsDiagMessageRejected = 0x10;
constexpr LONG kEntisGlsDiagClearObserved = 0x20;
constexpr LONG kEntisGlsDiagEventsLost = 0x40;

void EntisGlsLog(const wchar_t* format, ...) {
  auto& rt = g_entisgls;
  if (rt.logged >= kEntisGlsLogBudget) return;
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

// ── game thread ────────────────────────────────────────────────────────────

// The walker's reader: plain memory reads that turn a fault into false.
bool EntisGlsReadMemory(void*, uintptr_t address, void* out, uint32_t bytes) {
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Takes a ring slot; the caller fills it and commits it.
EntisGlsEvent* EntisGlsBeginEvent(uint64_t* sequence) {
  auto& rt = g_entisgls;
  *sequence = rt.count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.seq[*sequence % kEntisGlsEventSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  return &rt.events[*sequence % kEntisGlsEventSlots];
}

void EntisGlsCommitEvent(EntisGlsEvent* event, uint64_t sequence) {
  event->sequence = sequence;
  std::atomic_thread_fence(std::memory_order_release);
  g_entisgls.seq[sequence % kEntisGlsEventSlots].store(
      sequence, std::memory_order_release);
}

using EntisGlsAddFn = uintptr_t(__fastcall*)(void* self, void* edx,
                                             uintptr_t node);
using EntisGlsClearFn = uintptr_t(__fastcall*)(void* self, void* edx);

// SGLSpriteMessage::AddMessage(node) — thiscall, one stack argument.
uintptr_t __fastcall EntisGlsAddDetour(void* self, void* edx, uintptr_t node) {
  auto& rt = g_entisgls;
  rt.add_hits.fetch_add(1u, std::memory_order_relaxed);
  if (rt.live.load(std::memory_order_acquire) && self != nullptr) {
    uint64_t sequence = 0u;
    EntisGlsEvent* event = EntisGlsBeginEvent(&sequence);
    uint32_t length = 0u;
    const entisgls::TextResult result = entisgls::CollectMessageText(
        &EntisGlsReadMemory, nullptr, node, event->text,
        entisgls::kMaxMessageUnits, &length);
    event->kind = result == entisgls::TextResult::kOk ? kEntisGlsEventAdd
                                                       : kEntisGlsEventDiscard;
    event->result = static_cast<uint32_t>(result);
    event->sprite = reinterpret_cast<uintptr_t>(self);
    event->length = result == entisgls::TextResult::kOk ? length : 0u;
    EntisGlsCommitEvent(event, sequence);
  }
  return reinterpret_cast<EntisGlsAddFn>(g_entisgls_add_original)(self, edx,
                                                                   node);
}

// SGLSpriteMessage::ClearMessage() — thiscall, no arguments.
uintptr_t __fastcall EntisGlsClearDetour(void* self, void* edx) {
  auto& rt = g_entisgls;
  rt.clear_hits.fetch_add(1u, std::memory_order_relaxed);
  if (rt.live.load(std::memory_order_acquire) && self != nullptr) {
    uint64_t sequence = 0u;
    EntisGlsEvent* event = EntisGlsBeginEvent(&sequence);
    event->kind = kEntisGlsEventClear;
    event->result = 0u;
    event->sprite = reinterpret_cast<uintptr_t>(self);
    event->length = 0u;
    EntisGlsCommitEvent(event, sequence);
  }
  return reinterpret_cast<EntisGlsClearFn>(g_entisgls_clear_original)(self,
                                                                     edx);
}

// ── install ────────────────────────────────────────────────────────────────

// The executable as it is on disk, laid out by section: the signature must
// not depend on what other in-process hookers patched in the live image, nor
// on the loader's relocation of absolute operands (the image is ASLR-enabled;
// operands stay relative to the file's preferred base).
std::vector<uint8_t> g_entisgls_pristine;

bool LoadEntisGlsPristineView(entisgls::ImageView* view) {
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
            size.QuadPart < (128ll << 20);
  if (ok) {
    raw.resize(static_cast<size_t>(size.QuadPart));
    size_t done = 0u;
    while (ok && done < raw.size()) {
      DWORD got = 0u;
      const DWORD want = static_cast<DWORD>(
          (std::min)(raw.size() - done, static_cast<size_t>(1u << 20)));
      ok = ReadFile(file, raw.data() + done, want, &got, nullptr) && got != 0u;
      done += got;
    }
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
  g_entisgls_pristine.assign(nt->OptionalHeader.SizeOfImage, 0u);
  std::memcpy(g_entisgls_pristine.data(), raw.data(),
              nt->OptionalHeader.SizeOfHeaders);
  const auto* sections = IMAGE_FIRST_SECTION(nt);
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
    if (section.VirtualAddress > g_entisgls_pristine.size() ||
        bytes > g_entisgls_pristine.size() - section.VirtualAddress ||
        section.PointerToRawData > raw.size() ||
        bytes > raw.size() - section.PointerToRawData) {
      return false;
    }
    std::memcpy(g_entisgls_pristine.data() + section.VirtualAddress,
                raw.data() + section.PointerToRawData, bytes);
  }
  return fushi_voice_hook::EntisGlsImageView(g_entisgls_pristine.data(),
                                             g_entisgls_pristine.size(), view);
}

// One detour; a target someone else already hooked installs nothing.
bool InstallEntisGlsHook(void* target, void* detour, void** original) {
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

// The first five bytes at a hook target (what the detour replaces; both
// sites' first five bytes carry no relocated operand) must still be the
// engine's own.
bool EntisGlsLiveMatches(const entisgls::ImageView& view, uintptr_t live_base,
                         uint32_t rva) {
  uint8_t live[5] = {};
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

bool InstallEntisGlsText() {
  auto& rt = g_entisgls;
  if (rt.installed) return true;
  if (rt.resolved) return false;
  rt.resolved = true;
  entisgls::ImageView view;
  const uintptr_t live_base =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (!LoadEntisGlsPristineView(&view)) {
    EntisGlsLog(L"entisgls: executable image unavailable");
    return false;
  }
  rt.site_result = entisgls::ResolveSites(view, &rt.sites);
  if (rt.site_result != entisgls::SiteResult::kResolved) {
    EntisGlsLog(L"entisgls: sites unresolved result=%u",
                static_cast<unsigned>(rt.site_result));
    return false;
  }
  InterlockedOr(&g_entisgls_diag, kEntisGlsDiagSitesResolved);
  if (!EntisGlsLiveMatches(view, live_base, rt.sites.add_message) ||
      !EntisGlsLiveMatches(view, live_base, rt.sites.clear_message)) {
    EntisGlsLog(L"entisgls: message methods patched in memory");
    return false;
  }
  rt.image_base = live_base;
  rt.live.store(true, std::memory_order_release);
  // Clear first: a page wipe missed while AddMessage is already live would
  // join two pages.
  const bool clear_hooked = InstallEntisGlsHook(
      reinterpret_cast<void*>(rt.image_base + rt.sites.clear_message),
      reinterpret_cast<void*>(&EntisGlsClearDetour),
      &g_entisgls_clear_original);
  const bool add_hooked =
      clear_hooked &&
      InstallEntisGlsHook(
          reinterpret_cast<void*>(rt.image_base + rt.sites.add_message),
          reinterpret_cast<void*>(&EntisGlsAddDetour),
          &g_entisgls_add_original);
  rt.installed = clear_hooked && add_hooked;
  if (!rt.installed) {
    // Without both, the page model is wrong: the lane stays off.  A clear
    // detour already in place only records events nobody consumes.
    rt.live.store(false, std::memory_order_release);
  } else {
    InterlockedOr(&g_entisgls_diag, kEntisGlsDiagHooksInstalled);
  }
  EntisGlsLog(L"entisgls: add=+0x%lx clear=+0x%lx process=+0x%lx "
              L"getter=+0x%lx base=0x%lx file_base=0x%lx installed=%d",
              static_cast<unsigned long>(rt.sites.add_message),
              static_cast<unsigned long>(rt.sites.clear_message),
              static_cast<unsigned long>(rt.sites.process),
              static_cast<unsigned long>(rt.sites.getter),
              static_cast<unsigned long>(live_base),
              static_cast<unsigned long>(view.va_base),
              rt.installed ? 1 : 0);
  return rt.installed;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

constexpr wchar_t kEntisGlsHookCode[] = L"ENGINE:ENTISGLS:message";
constexpr char kEntisGlsHookName[] = "EntisGLS exact";

uint64_t PublishEntisGlsText(const std::wstring& text, uintptr_t sprite) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  // Lane identity: the engine's AddMessage, stable across runs (the heap
  // address of the sprite is not).
  const uint64_t identity = g_entisgls.sites.add_message;
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      identity, kEntisGlsHookCode, kEntisGlsHookName);
  write.thread_address = sprite;
  write.thread_context = sprite;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceEntisGls;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kEntisGlsHookName;
  write.hook_code = kEntisGlsHookCode;
  write.event_flags = fushi_voice_hook::kTextEventFlagLaneUniqueHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields (the
  // engine rasterises glyphs through GetGlyphOutlineW into its own surfaces).
  g_header->luna_active = 1;
  return event;
}

void ApplyEntisGlsEvent(const EntisGlsEvent& event) {
  auto& rt = g_entisgls;
  switch (event.kind) {
    case kEntisGlsEventAdd:
      InterlockedOr(&g_entisgls_diag, kEntisGlsDiagMessageObserved);
      entisgls::OnAdd(&rt.model, event.sprite, event.text, event.length,
                      rt.tick);
      break;
    case kEntisGlsEventClear:
      InterlockedOr(&g_entisgls_diag, kEntisGlsDiagClearObserved);
      entisgls::OnClear(&rt.model, event.sprite, rt.tick);
      break;
    default:
      InterlockedOr(&g_entisgls_diag, kEntisGlsDiagMessageRejected);
      EntisGlsLog(L"entisgls: message on sprite 0x%lx rejected result=%u",
                  static_cast<unsigned long>(event.sprite), event.result);
      break;
  }
}

void ProcessEntisGlsTextTick() {
  auto& rt = g_entisgls;
  if (!rt.installed) return;
  ++rt.tick;
  const uint64_t latest = rt.count.load(std::memory_order_acquire);
  uint64_t next = rt.processed_seq + 1u;
  if (latest > rt.processed_seq &&
      latest - rt.processed_seq > kEntisGlsEventSlots) {
    // Lapped: the page model lost events; report it and resume.
    InterlockedOr(&g_entisgls_diag, kEntisGlsDiagEventsLost);
    next = latest - kEntisGlsEventSlots + 1u;
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.seq[next % kEntisGlsEventSlots];
    // Every taken sequence is committed (a failed copy as a discard), so an
    // uncommitted slot is in flight: wait for the next tick, in order.
    if (slot_seq.load(std::memory_order_acquire) != next) break;
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.copy, &rt.events[next % kEntisGlsEventSlots],
                sizeof(EntisGlsEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_seq = next;
    if (slot_seq.load(std::memory_order_acquire) != next) {
      InterlockedOr(&g_entisgls_diag, kEntisGlsDiagEventsLost);  // torn
      continue;
    }
    ApplyEntisGlsEvent(rt.copy);
  }
  for (const entisgls::Publication& unit :
       entisgls::OnTick(&rt.model, rt.tick)) {
    const uint64_t event = PublishEntisGlsText(unit.text, unit.sprite);
    EntisGlsLog(L"entisgls: sprite 0x%lx page %llu units=%u event=%llu",
                static_cast<unsigned long>(unit.sprite),
                static_cast<unsigned long long>(unit.page_seq),
                static_cast<unsigned>(unit.text.size()),
                static_cast<unsigned long long>(event));
    if (event != 0u) InterlockedOr(&g_entisgls_diag, kEntisGlsDiagTextPublished);
  }
}

void ShutdownEntisGlsText() {
  auto& rt = g_entisgls;
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

bool EntisGlsTextInstalled() { return g_entisgls.installed; }

#else  // !_M_IX86

bool InstallEntisGlsText() { return false; }
void ProcessEntisGlsTextTick() {}
void ShutdownEntisGlsText() {}
bool EntisGlsTextInstalled() { return false; }
volatile LONG g_entisgls_diag = 0;

#endif  // _M_IX86

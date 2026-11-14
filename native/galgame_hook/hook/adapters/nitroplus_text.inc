// Nitroplus N2System text lane.  Engine facts and every rule live in
// nitroplus_core.h and are unit-tested; this file binds them to MinHook,
// Win32 and the text lanes.
//
// Threads:
//   * game thread — the BacklogAppendChar detour.  It calls the engine first
//     and only a character the engine actually logged (return 1) is fed to
//     the line assembler (fixed arrays, no allocation, no IO, no
//     conversion).  A finished line (the engine's 0x0a) is copied into a
//     fixed event ring.
//   * HookWorker — ProcessNitroplusTextTick: converts each line from CP932
//     and publishes it on the exact lane ENGINE:NITROPLUS:backlog.
//
// Fail closed: a routine that is not proved unique installs nothing; a line
// that overflowed or is not clean CP932 publishes nothing.

#if defined(_M_IX86)

namespace nitroplus = fushi_voice_hook::nitroplus;

constexpr uint32_t kNitroplusEventSlots = 16u;
constexpr uint32_t kNitroplusLogBudget = 2048u;

constexpr LONG kNitroplusDiagHookInstalled = 0x1;
constexpr LONG kNitroplusDiagLineObserved = 0x2;
constexpr LONG kNitroplusDiagTextPublished = 0x4;
constexpr LONG kNitroplusDiagLineRejected = 0x8;
constexpr LONG kNitroplusDiagVoiceTagged = 0x10;
constexpr LONG kNitroplusDiagEventsLost = 0x20;
constexpr LONG kNitroplusDiagForeignThread = 0x40;

volatile LONG g_nitroplus_diag = 0;

using NitroplusAppendFn = int(__cdecl*)(uint32_t, uintptr_t);

struct NitroplusTextRuntime {
  bool resolved = false;
  bool installed = false;
  nitroplus::BacklogSites sites;
  void* target = nullptr;
  std::atomic<bool> live{false};
  // Game thread: the open line.  Only the thread that logged first feeds it
  // (the backlog is a single engine object driven by the script thread).
  std::atomic<DWORD> owner_thread{0};
  nitroplus::Assembler assembler;
  nitroplus::Line finished;
  // The ring: a producer takes a sequence, fills the slot, then commits it.
  std::atomic<uint64_t> count{0};
  std::atomic<uint64_t> seq[kNitroplusEventSlots];
  nitroplus::Line lines[kNitroplusEventSlots];
  uint64_t ticks[kNitroplusEventSlots] = {};
  // HookWorker.
  uint64_t processed = 0;
  nitroplus::Line copy;
  uint32_t logged = 0;
};

NitroplusTextRuntime g_nitroplus;
NitroplusAppendFn g_nitroplus_append_original = nullptr;

void NitroplusLog(const wchar_t* format, ...) {
  auto& rt = g_nitroplus;
  if (rt.logged >= kNitroplusLogBudget) return;
  ++rt.logged;
  wchar_t line[768] = {};
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
  wchar_t stamped[900] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[2800] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

// ── game thread ────────────────────────────────────────────────────────────

// Bounded copy of an engine C string; 0 when it faults.
size_t NitroplusCopyString(const char* source, char* out, size_t capacity) {
  size_t n = 0;
  __try {
    while (n + 1 < capacity && source[n] != '\0') {
      out[n] = source[n];
      ++n;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    n = 0;
  }
  out[n] = '\0';
  return n;
}

void NitroplusNoteVoice(uintptr_t voice) {
  auto& rt = g_nitroplus;
  char name[nitroplus::kVoiceNameBytes] = {};
  char file[nitroplus::kVoiceNameBytes] = {};
  const size_t name_len = NitroplusCopyString(
      reinterpret_cast<const char*>(voice + rt.sites.voice_name_offset), name,
      sizeof(name));
  const char* file_ptr = nullptr;
  __try {
    file_ptr = *reinterpret_cast<const char* const*>(
        voice + rt.sites.voice_file_offset);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    file_ptr = nullptr;
  }
  const size_t file_len =
      file_ptr != nullptr ? NitroplusCopyString(file_ptr, file, sizeof(file)) : 0;
  nitroplus::NoteVoice(&rt.assembler, name, name_len, file, file_len);
}

void NitroplusCommitLine(const nitroplus::Line& line) {
  auto& rt = g_nitroplus;
  const uint64_t sequence =
      rt.count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  const uint32_t slot = static_cast<uint32_t>(sequence % kNitroplusEventSlots);
  rt.seq[slot].store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&rt.lines[slot], &line, sizeof(nitroplus::Line));
  rt.ticks[slot] = GetTickCount64();
  std::atomic_thread_fence(std::memory_order_release);
  rt.seq[slot].store(sequence, std::memory_order_release);
}

int __cdecl NitroplusAppendDetour(uint32_t code, uintptr_t voice) {
  const int logged = g_nitroplus_append_original(code, voice);
  auto& rt = g_nitroplus;
  // A packed pair re-enters this detour as its two halves.
  if (logged == 0 || code > 0xFFFFu ||
      !rt.live.load(std::memory_order_acquire)) {
    return logged;
  }
  const DWORD me = GetCurrentThreadId();
  DWORD owner = 0;
  if (!rt.owner_thread.compare_exchange_strong(owner, me,
                                               std::memory_order_acq_rel) &&
      owner != me) {
    InterlockedOr(&g_nitroplus_diag, kNitroplusDiagForeignThread);
    return logged;
  }
  if (voice != 0u) NitroplusNoteVoice(voice);
  const nitroplus::FeedResult result =
      nitroplus::FeedCode(&rt.assembler, code, &rt.finished);
  if (result == nitroplus::FeedResult::kLineComplete) {
    NitroplusCommitLine(rt.finished);
  } else if (result == nitroplus::FeedResult::kLineDropped) {
    InterlockedOr(&g_nitroplus_diag, kNitroplusDiagLineRejected);
  }
  return logged;
}

// ── install ────────────────────────────────────────────────────────────────

bool InstallNitroplusText() {
  auto& rt = g_nitroplus;
  if (rt.installed) return true;
  if (rt.resolved || !g_cs_ready) return false;
  rt.resolved = true;
  rt.sites = fushi_voice_hook::NitroplusMainModuleSites();
  if (!rt.sites.ok) {
    NitroplusLog(L"nitroplus: refused (reason=%u anchors=%u)",
                 static_cast<unsigned>(rt.sites.refusal),
                 rt.sites.anchors_seen);
    return false;
  }
  auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
  rt.target = base + rt.sites.append_rva;
  for (auto& s : rt.seq) s.store(0u, std::memory_order_relaxed);
  rt.live.store(true, std::memory_order_release);
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) ok = g_hooked_fns[i] != rt.target;
  bool created = false;
  if (ok) {
    created = MH_CreateHook(rt.target,
                            reinterpret_cast<void*>(&NitroplusAppendDetour),
                            reinterpret_cast<void**>(
                                &g_nitroplus_append_original)) == MH_OK;
    ok = created && MH_QueueEnableHook(rt.target) == MH_OK &&
         MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = rt.target;
  } else if (created) {
    MH_RemoveHook(rt.target);
  }
  LeaveCriticalSection(&g_cs);
  rt.installed = ok;
  if (!ok) rt.live.store(false, std::memory_order_release);
  if (ok) InterlockedOr(&g_nitroplus_diag, kNitroplusDiagHookInstalled);
  NitroplusLog(L"nitroplus: append=+0x%x split=+0x%x backlog=0x%x name=+0x%x "
               L"file=+0x%x hooked=%d",
               rt.sites.append_rva, rt.sites.pair_split_rva,
               rt.sites.backlog_global_va, rt.sites.voice_name_offset,
               rt.sites.voice_file_offset, ok ? 1 : 0);
  return ok;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

constexpr char kNitroplusHookName[] = "Nitroplus exact";
constexpr wchar_t kNitroplusHookCode[] = L"ENGINE:NITROPLUS:backlog";

uint64_t PublishNitroplusLine(const std::wstring& text) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      0x4E325359u /* 'N2SY' lane identity */, kNitroplusHookCode,
      kNitroplusHookName);
  write.thread_address = 0u;
  write.thread_context = 0u;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceNitroplus;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kNitroplusHookName;
  write.hook_code = kNitroplusHookCode;
  write.event_flags = fushi_voice_hook::kTextEventFlagLaneUniqueHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields.
  g_header->luna_active = 1;
  return event;
}

void ProcessNitroplusLine(const nitroplus::Line& line) {
  InterlockedOr(&g_nitroplus_diag, kNitroplusDiagLineObserved);
  char bytes[nitroplus::kMaxLineCodes * 2] = {};
  const size_t length = nitroplus::LineToCp932(line, bytes, sizeof(bytes));
  wchar_t wide[nitroplus::kMaxLineCodes + 1] = {};
  const int units =
      length == 0 ? 0
                  : MultiByteToWideChar(932, MB_ERR_INVALID_CHARS, bytes,
                                        static_cast<int>(length), wide,
                                        nitroplus::kMaxLineCodes);
  if (units <= 0) {
    InterlockedOr(&g_nitroplus_diag, kNitroplusDiagLineRejected);
    NitroplusLog(L"nitroplus: line of %u codes rejected (not CP932)",
                 line.count);
    return;
  }
  if (line.has_voice) InterlockedOr(&g_nitroplus_diag, kNitroplusDiagVoiceTagged);
  const uint64_t event =
      PublishNitroplusLine(std::wstring(wide, static_cast<size_t>(units)));
  if (event != 0u) InterlockedOr(&g_nitroplus_diag, kNitroplusDiagTextPublished);
  // The voice tag name is engine metadata (a resource name), never the text.
  wchar_t voice[nitroplus::kVoiceNameBytes] = {};
  if (line.has_voice) {
    MultiByteToWideChar(932, 0, line.voice_name, -1, voice,
                        nitroplus::kVoiceNameBytes);
  }
  NitroplusLog(L"nitroplus: line units=%d voice=%s event=%llu", units,
               line.has_voice ? voice : L"-",
               static_cast<unsigned long long>(event));
}

void ProcessNitroplusTextTick() {
  auto& rt = g_nitroplus;
  if (!rt.installed) return;
  const uint64_t latest = rt.count.load(std::memory_order_acquire);
  if (latest > rt.processed + kNitroplusEventSlots) {
    InterlockedOr(&g_nitroplus_diag, kNitroplusDiagEventsLost);
    rt.processed = latest - kNitroplusEventSlots;
  }
  for (uint64_t next = rt.processed + 1u; next <= latest; ++next) {
    auto& slot_seq = rt.seq[next % kNitroplusEventSlots];
    // Not committed yet: wait for it, in order.
    if (slot_seq.load(std::memory_order_acquire) != next) break;
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.copy, &rt.lines[next % kNitroplusEventSlots],
                sizeof(nitroplus::Line));
    std::atomic_thread_fence(std::memory_order_acquire);
    // Lapped while copying: the next tick reports the loss.
    if (slot_seq.load(std::memory_order_acquire) != next) break;
    rt.processed = next;
    ProcessNitroplusLine(rt.copy);
  }
}

void ShutdownNitroplusText() {
  auto& rt = g_nitroplus;
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

#else  // !_M_IX86

bool InstallNitroplusText() { return false; }
void ProcessNitroplusTextTick() {}
void ShutdownNitroplusText() {}
volatile LONG g_nitroplus_diag = 0;

#endif  // _M_IX86

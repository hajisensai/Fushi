// CMVS per-line voice: runtime half (see cmvs_voice_core.h for the engine
// facts and the site proof).
//
//   * Install: resolve the group loaders from the main image's own exception
//     directory (structural, no hash / file name / title) and detour each.
//     x86 builds have no unwind table to prove a function entry from, so the
//     lane fails closed there and the generic PCM path stays the only audio.
//   * Game thread (detour): forward to the engine, then — only for a non-null
//     buffer from a voice group with an "<id>.ogg" member and an Ogg head —
//     make one bounded copy into a free task slot.  No file IO, no logging.
//   * Worker: full Ogg page validation, de-duplication and the resource write
//     (WriteVoiceOggAt, tick taken when the engine loaded the line).
// cmvs_voice_core.h is included at the top of dll_main.cpp (outside the
// anonymous namespace this file is expanded in).

namespace cmvs_voice = fushi_voice_hook::cmvs_voice;

// Worker / install-time log line (never called from the game-thread detour).
void CmvsVoiceLog(const wchar_t* format, ...) {
  wchar_t line[384] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[512] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[1536] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  CloseHandle(file);
}

struct CmvsVoiceTask {
  volatile LONG state = 0;  // 0 free, 1 filling, 2 ready, 3 worker-owned
  uint64_t tick_ms = 0;
  uint8_t* data = nullptr;
  uint32_t bytes = 0;
  char name[cmvs_voice::kNameBytes] = {};
};

constexpr int kCmvsVoiceTaskSlots = 8;
CmvsVoiceTask g_cmvs_voice_tasks[kCmvsVoiceTaskSlots];
volatile LONG g_cmvs_voice_armed = 0;
volatile LONG g_cmvs_voice_sites = 0;
volatile LONG g_cmvs_voice_written = 0;
char g_cmvs_voice_last_name[cmvs_voice::kNameBytes] = {};
uint64_t g_cmvs_voice_last_tick = 0;

void QueueCmvsVoice(const void* group, const char* name, const uint32_t* size,
                    const void* buffer) {
  if (InterlockedCompareExchange(&g_cmvs_voice_armed, 0, 0) == 0 ||
      buffer == nullptr || size == nullptr || group == nullptr ||
      name == nullptr) {
    return;
  }
  const uint32_t bytes = *size;
  const auto* data = static_cast<const uint8_t*>(buffer);
  if (bytes == 0u || bytes > cmvs_voice::kMaxMemberBytes ||
      !cmvs_voice::HasOggHead(data, bytes) ||
      !cmvs_voice::IsVoiceMemberName(name, cmvs_voice::kNameBytes) ||
      !cmvs_voice::IsVoiceGroup(static_cast<const uint8_t*>(group))) {
    return;
  }
  for (CmvsVoiceTask& task : g_cmvs_voice_tasks) {
    if (InterlockedCompareExchange(&task.state, 1, 0) != 0) continue;
    task.data = static_cast<uint8_t*>(malloc(bytes));
    if (task.data == nullptr) {
      InterlockedExchange(&task.state, 0);
      return;
    }
    memcpy(task.data, data, bytes);
    task.bytes = bytes;
    task.tick_ms = GetTickCount64();
    strncpy_s(task.name, name, _TRUNCATE);
    InterlockedExchange(&task.state, 2);
    return;
  }
}

#ifdef _WIN64

using CmvsGroupLoadFn = void*(__fastcall*)(void* group, const char* name,
                                           uint32_t* size, uintptr_t flag);
CmvsGroupLoadFn g_cmvs_group_load_original[cmvs_voice::kMaxSites] = {};

template <size_t I>
void* __fastcall CmvsGroupLoadDetour(void* group, const char* name,
                                     uint32_t* size, uintptr_t flag) {
  void* result = g_cmvs_group_load_original[I](group, name, size, flag);
  QueueCmvsVoice(group, name, size, result);
  return result;
}

template <size_t... I>
constexpr std::array<void*, sizeof...(I)> MakeCmvsGroupLoadDetours(
    std::index_sequence<I...>) {
  return {reinterpret_cast<void*>(&CmvsGroupLoadDetour<I>)...};
}

const std::array<void*, cmvs_voice::kMaxSites> kCmvsGroupLoadDetours =
    MakeCmvsGroupLoadDetours(std::make_index_sequence<cmvs_voice::kMaxSites>());

bool TryHookCmvsVoice() {
  if (InterlockedCompareExchange(&g_cmvs_voice_armed, 0, 0) != 0) return true;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    CmvsVoiceLog(L"cmvs-voice: main image unreadable");
    return false;
  }
  cmvs_voice::Sites sites;
  const cmvs_voice::SiteResult result =
      cmvs_voice::FindGroupLoaderSites(image.base, image.size, &sites);
  if (result != cmvs_voice::SiteResult::kResolved) {
    CmvsVoiceLog(L"cmvs-voice: sites unresolved result=%u",
                 static_cast<unsigned>(result));
    return false;
  }
  size_t hooked = 0;
  // Hooks that already took stay chained even if a later one fails: each
  // detour only forwards and copies, so a partial set is still correct.
  // HookFn de-duplicates targets, so re-arming after shutdown re-hooks nothing.
  for (size_t i = 0; i < sites.count; ++i) {
    void* target = const_cast<uint8_t*>(image.base) + sites.rva[i];
    const bool ok =
        HookFn(target, kCmvsGroupLoadDetours[i],
               reinterpret_cast<void**>(&g_cmvs_group_load_original[i]));
    if (ok) ++hooked;
    CmvsVoiceLog(L"cmvs-voice: group loader +0x%x hooked=%d", sites.rva[i],
                 ok ? 1 : 0);
  }
  if (hooked == 0u) return false;
  InterlockedExchange(&g_cmvs_voice_sites, static_cast<LONG>(hooked));
  InterlockedExchange(&g_cmvs_voice_armed, 1);
  return true;
}

#else  // !_WIN64

bool TryHookCmvsVoice() {
  CmvsVoiceLog(L"cmvs-voice: x86 build has no unwind table; resource lane off");
  return false;
}

#endif  // _WIN64

void ProcessCmvsVoiceTask(CmvsVoiceTask* task) {
  const bool duplicate =
      strcmp(task->name, g_cmvs_voice_last_name) == 0 &&
      task->tick_ms - g_cmvs_voice_last_tick <= 2000u;
  if (duplicate ||
      fushi_voice_hook::siglus::CompleteOggBytes(task->data, task->bytes) !=
          task->bytes) {
    return;
  }
  wchar_t name[cmvs_voice::kNameBytes] = {};
  if (MultiByteToWideChar(932, 0, task->name, -1, name,
                          static_cast<int>(cmvs_voice::kNameBytes)) == 0) {
    return;
  }
  if (!WriteVoiceOggAt(task->data, task->bytes, name, task->tick_ms)) return;
  // The bytes are the archive member itself, so the host may switch the
  // session to per-line resource pairing; without this bit it stays on the
  // engine-PCM ring and pairs click SEs / BGM as voice.
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
  strncpy_s(g_cmvs_voice_last_name, task->name, _TRUNCATE);
  g_cmvs_voice_last_tick = task->tick_ms;
  if (InterlockedIncrement(&g_cmvs_voice_written) == 1) {
    CmvsVoiceLog(L"cmvs-voice: first voice %ls bytes=%u", name, task->bytes);
  }
}

void ProcessCmvsVoiceTasks() {
  for (CmvsVoiceTask& task : g_cmvs_voice_tasks) {
    if (InterlockedCompareExchange(&task.state, 3, 2) != 2) continue;
    ProcessCmvsVoiceTask(&task);
    free(task.data);
    task.data = nullptr;
    task.bytes = 0;
    InterlockedExchange(&task.state, 0);
  }
}

void StopCmvsVoice() {
  // Detours stay chained for the process lifetime; disarmed they only forward.
  InterlockedExchange(&g_cmvs_voice_armed, 0);
  for (CmvsVoiceTask& task : g_cmvs_voice_tasks) {
    if (InterlockedCompareExchange(&task.state, 3, 2) != 2) continue;
    free(task.data);
    task.data = nullptr;
    task.bytes = 0;
    InterlockedExchange(&task.state, 0);
  }
}

bool CmvsVoiceArmed() {
  return InterlockedCompareExchange(&g_cmvs_voice_armed, 0, 0) != 0;
}

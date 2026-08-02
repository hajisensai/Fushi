// elf AI6 clean voice capture. voice.arc starts with a little-endian entry
// count followed by fixed 272-byte records (256-byte name and four big-endian
// uint32 fields). The final fields are packed size, unpacked size and absolute
// payload offset. The shared kernel detour only queues {path, read offset,
// tick}; index parsing, complete Ogg validation and disk output stay on the
// HookWorker.
#include "elf_ai6_profile.h"

constexpr size_t kElfAi6PathChars = 520;
constexpr int kElfAi6HandleSlots = 8;
constexpr int kElfAi6TaskSlots = 32;

struct ElfAi6ArcHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  wchar_t path[kElfAi6PathChars] = {0};
};

struct ElfAi6VoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint64_t read_offset = 0;
  wchar_t path[kElfAi6PathChars] = {0};
};

ElfAi6ArcHandle g_elf_ai6_handles[kElfAi6HandleSlots];
ElfAi6VoiceTask g_elf_ai6_tasks[kElfAi6TaskSlots];
volatile LONG g_elf_ai6_enabled = 0;
uint64_t g_elf_ai6_last_offset = UINT64_MAX;
uint64_t g_elf_ai6_last_tick = 0;

bool IsElfAi6VoiceArchivePath(const wchar_t* path) {
  if (path == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* base = slash == nullptr ? path : slash + 1;
  return _wcsicmp(base, L"voice.arc") == 0;
}

void RememberElfAi6VoiceArc(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_elf_ai6_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsElfAi6VoiceArchivePath(path) ||
      !g_cs_ready) {
    return;
  }
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == INVALID_HANDLE_VALUE ||
        g_elf_ai6_handles[i].handle == handle) {
      g_elf_ai6_handles[i].handle = handle;
      wcsncpy_s(g_elf_ai6_handles[i].path, path, _TRUNCATE);
      if (g_header != nullptr) {
        g_header->reserved_hook_diagnostics |=
            hibiki_voice_hook::kDiagElfAi6ArcHandleTracked;
      }
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool CopyElfAi6VoiceArcPath(HANDLE handle, wchar_t* out, size_t out_chars) {
  if (handle == INVALID_HANDLE_VALUE || out == nullptr || out_chars == 0 ||
      !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == handle) {
      wcsncpy_s(out, out_chars, g_elf_ai6_handles[i].path, _TRUNCATE);
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetElfAi6VoiceArc(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == handle) {
      g_elf_ai6_handles[i].handle = INVALID_HANDLE_VALUE;
      g_elf_ai6_handles[i].path[0] = 0;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

void QueueElfAi6Voice(const wchar_t* path, uint64_t read_offset) {
  for (int i = 0; i < kElfAi6TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_elf_ai6_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_elf_ai6_tasks[i].tick_ms = GetTickCount64();
    g_elf_ai6_tasks[i].read_offset = read_offset;
    wcsncpy_s(g_elf_ai6_tasks[i].path, path, _TRUNCATE);
    InterlockedExchange(&g_elf_ai6_tasks[i].state, 2);
    return;
  }
}

void ObserveElfAi6VoiceArcRead(HANDLE file, const void* buffer, DWORD done,
                               LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_elf_ai6_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4) {
    return;
  }
  wchar_t path[kElfAi6PathChars] = {0};
  if (!CopyElfAi6VoiceArcPath(file, path, kElfAi6PathChars)) {
    // Some AI6 launchers complete archive open before delayed injection. A
    // ReadFile handle remains classifiable without touching the game's file
    // position, so recover it lazily on the first post-injection read.
    const DWORD chars = GetFinalPathNameByHandleW(
        file, path, static_cast<DWORD>(kElfAi6PathChars), FILE_NAME_NORMALIZED);
    if (chars == 0 || chars >= kElfAi6PathChars ||
        !IsElfAi6VoiceArchivePath(path)) {
      return;
    }
    RememberElfAi6VoiceArc(file, path);
  }
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagElfAi6ArcReadObserved;
  }
  __try {
    if (memcmp(buffer, "OggS", 4) != 0) return;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagElfAi6ArcOggObserved;
  }
  uint64_t start = 0;
  if (overlapped != nullptr) {
    start = (static_cast<uint64_t>(overlapped->OffsetHigh) << 32) |
            overlapped->Offset;
  } else {
    LARGE_INTEGER zero = {};
    LARGE_INTEGER current = {};
    if (!SetFilePointerEx(file, zero, &current, FILE_CURRENT) ||
        current.QuadPart < done) {
      return;
    }
    start = static_cast<uint64_t>(current.QuadPart) - done;
  }
  QueueElfAi6Voice(path, start);
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagElfAi6ArcVoiceQueued;
  }
}

void ProcessElfAi6VoiceTask(ElfAi6VoiceTask* task) {
  HANDLE file = g_orig_CreateFileW(
      task->path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER file_size = {};
  uint8_t count_bytes[hibiki_voice_hook::elf_ai6::kHeaderBytes] = {0};
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  uint64_t index_bytes = 0;
  hibiki_voice_hook::elf_ai6::ArcEntry entry;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
      ReadExact(file, count_bytes, sizeof(count_bytes)) &&
      hibiki_voice_hook::elf_ai6::IndexSize(
          count_bytes, sizeof(count_bytes), nullptr, &index_bytes) &&
      index_bytes <= static_cast<uint64_t>(file_size.QuadPart) &&
      index_bytes <= UINT32_MAX;
  if (valid) {
    index = static_cast<uint8_t*>(malloc(static_cast<size_t>(index_bytes)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, count_bytes, sizeof(count_bytes));
      valid = ReadExact(file, index + sizeof(count_bytes),
                        static_cast<uint32_t>(index_bytes -
                                              sizeof(count_bytes))) &&
          hibiki_voice_hook::elf_ai6::FindEntryForRead(
              index, static_cast<size_t>(index_bytes),
              static_cast<uint64_t>(file_size.QuadPart), task->read_offset,
              &entry);
    }
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.offset;
    ogg = static_cast<uint8_t*>(malloc(entry.size));
    valid = ogg != nullptr &&
        SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
        ReadExact(file, ogg, entry.size) &&
        hibiki_voice_hook::siglus::CompleteOggBytes(ogg, entry.size) ==
            entry.size;
  }
  const bool duplicate = valid && entry.offset == g_elf_ai6_last_offset &&
      task->tick_ms - g_elf_ai6_last_tick <= 2000;
  if (valid && !duplicate) {
    wchar_t member_name[hibiki_voice_hook::elf_ai6::kNameBytes + 1] = {0};
    MultiByteToWideChar(CP_ACP, 0, entry.name, -1, member_name,
                        static_cast<int>(std::size(member_name)));
    WriteVoiceOggAt(ogg, entry.size,
                    member_name[0] == 0 ? L"voice.ogg" : member_name,
                    task->tick_ms);
    g_elf_ai6_last_offset = entry.offset;
    g_elf_ai6_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagElfAi6ArcVoiceCaptured;
    }
  } else if (!valid && g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagElfAi6ArcTaskRejected;
  }
  free(ogg);
  free(index);
  g_orig_CloseHandle(file);
}

void ProcessElfAi6VoiceTasks() {
  for (int i = 0; i < kElfAi6TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_elf_ai6_tasks[i].state, 3, 2) == 2) {
      ProcessElfAi6VoiceTask(&g_elf_ai6_tasks[i]);
      InterlockedExchange(&g_elf_ai6_tasks[i].state, 0);
    }
  }
}

bool TryHookElfAi6ArcVoice() {
  if (!hibiki_voice_hook::MatchesElfAi6Profile(nullptr)) return false;
  const bool ready = TryHookSiglusOvk();
  if (ready) {
    InterlockedExchange(&g_elf_ai6_enabled, 1);
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagElfAi6ArcHooksReady;
      // IPC v13 hosts released before this adapter only inspect the saturated
      // primary readiness word. Preserve resource-audio discovery for those
      // hosts; the secondary bit above is the engine-specific diagnostic.
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagBgiArcHooksReady;
    }
  }
  return ready;
}

void StopElfAi6ArcVoice() {
  InterlockedExchange(&g_elf_ai6_enabled, 0);
  if (!g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    g_elf_ai6_handles[i].handle = INVALID_HANDLE_VALUE;
    g_elf_ai6_handles[i].path[0] = 0;
  }
  LeaveCriticalSection(&g_cs);
}

class ElfAi6Adapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "elf_ai6"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesElfAi6Profile(nullptr);
  }
  bool install() override {
    ready_ = TryHookElfAi6ArcVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessElfAi6VoiceTasks(); }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopElfAi6ArcVoice();
    installed_ = false;
    ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u :
                g_header->reserved_hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

// BGI / Ethornell BURIKO ARC20 clean voice capture. The kernel file detours
// live in siglus_adapter.inc so MinHook installs a single detour per API. The
// ReadFile callback only copies a bounded {path, offset, tick} task. ARC index
// parsing, Ogg validation and file output all run from AdapterRegistry::Poll.
#include "bgi_ethornell_profile.h"

constexpr size_t kBgiPathChars = 520;
constexpr int kBgiHandleSlots = 8;
constexpr int kBgiTaskSlots = 32;

struct BgiArcHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  wchar_t path[kBgiPathChars] = {0};
};

struct BgiVoiceTask {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0;
  uint64_t read_offset = 0;
  wchar_t path[kBgiPathChars] = {0};
};

BgiArcHandle g_bgi_handles[kBgiHandleSlots];
BgiVoiceTask g_bgi_tasks[kBgiTaskSlots];
volatile LONG g_bgi_arc_enabled = 0;
uint64_t g_bgi_last_member = UINT64_MAX;
uint64_t g_bgi_last_tick = 0;
wchar_t g_bgi_last_path[kBgiPathChars] = {0};

bool IsBgiVoiceArchivePath(const wchar_t* path) {
  if (path == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* base = slash == nullptr ? path : slash + 1;
  const size_t len = wcslen(base);
  return len >= 11 && _wcsnicmp(base, L"data031", 7) == 0 &&
         _wcsicmp(base + len - 4, L".arc") == 0;
}

void RememberBgiVoiceArc(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_bgi_arc_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsBgiVoiceArchivePath(path) ||
      !g_cs_ready) {
    return;
  }
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kBgiHandleSlots; ++i) {
    if (g_bgi_handles[i].handle == INVALID_HANDLE_VALUE ||
        g_bgi_handles[i].handle == handle) {
      g_bgi_handles[i].handle = handle;
      wcsncpy_s(g_bgi_handles[i].path, path, _TRUNCATE);
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool CopyBgiVoiceArcPath(HANDLE handle, wchar_t* out, size_t out_chars) {
  if (handle == INVALID_HANDLE_VALUE || out == nullptr || out_chars == 0 ||
      !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kBgiHandleSlots; ++i) {
    if (g_bgi_handles[i].handle == handle) {
      wcsncpy_s(out, out_chars, g_bgi_handles[i].path, _TRUNCATE);
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetBgiVoiceArc(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kBgiHandleSlots; ++i) {
    if (g_bgi_handles[i].handle == handle) {
      g_bgi_handles[i].handle = INVALID_HANDLE_VALUE;
      g_bgi_handles[i].path[0] = 0;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

void QueueBgiVoice(const wchar_t* path, uint64_t read_offset) {
  if (path == nullptr) return;
  for (int i = 0; i < kBgiTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_bgi_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_bgi_tasks[i].tick_ms = GetTickCount64();
    g_bgi_tasks[i].read_offset = read_offset;
    wcsncpy_s(g_bgi_tasks[i].path, path, _TRUNCATE);
    InterlockedExchange(&g_bgi_tasks[i].state, 2);
    return;
  }
}

void ObserveBgiVoiceArcRead(HANDLE file, const void* buffer, DWORD done,
                            LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_bgi_arc_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4) {
    return;
  }
  bool audio_start = false;
  __try {
    const auto* bytes = static_cast<const uint8_t*>(buffer);
    if (memcmp(bytes, "OggS", 4) == 0) {
      audio_start = true;
    } else if (done >= 12 && memcmp(bytes + 4, "bw  ", 4) == 0) {
      const uint32_t ogg_offset = hibiki_voice_hook::bgi::ReadLe32(bytes);
      audio_start = ogg_offset >= 8 && ogg_offset <= done - 4 &&
                    memcmp(bytes + ogg_offset, "OggS", 4) == 0;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (!audio_start) return;

  wchar_t path[kBgiPathChars] = {0};
  if (!CopyBgiVoiceArcPath(file, path, kBgiPathChars)) return;
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
  QueueBgiVoice(path, start);
}

void ProcessBgiVoiceTask(BgiVoiceTask* task) {
  HANDLE file = g_orig_CreateFileW(
      task->path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  LARGE_INTEGER file_size = {};
  uint8_t prefix[hibiki_voice_hook::bgi::kArc20HeaderBytes] = {0};
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  hibiki_voice_hook::bgi::Arc20Entry entry;
  uint32_t count = 0;
  uint64_t data_base = 0;
  uint32_t ogg_offset = 0;
  uint32_t ogg_size = 0;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, prefix, sizeof(prefix));
  if (valid &&
      memcmp(prefix, hibiki_voice_hook::bgi::kArc20Signature,
             hibiki_voice_hook::bgi::kArc20SignatureBytes) == 0) {
    count = hibiki_voice_hook::bgi::ReadLe32(
        prefix + hibiki_voice_hook::bgi::kArc20SignatureBytes);
    data_base = hibiki_voice_hook::bgi::kArc20HeaderBytes +
        static_cast<uint64_t>(count) *
            hibiki_voice_hook::bgi::kArc20EntryBytes;
    valid = count > 0 && count <= hibiki_voice_hook::bgi::kMaxEntryCount &&
            data_base <= static_cast<uint64_t>(file_size.QuadPart) &&
            data_base <= SIZE_MAX;
  } else {
    valid = false;
  }
  if (valid) {
    index = static_cast<uint8_t*>(malloc(static_cast<size_t>(data_base)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, prefix, sizeof(prefix));
      valid = ReadExact(file, index + sizeof(prefix),
                        static_cast<uint32_t>(data_base - sizeof(prefix))) &&
              hibiki_voice_hook::bgi::FindEntryForRead(
                  index, static_cast<size_t>(data_base),
                  static_cast<uint64_t>(file_size.QuadPart),
                  task->read_offset, &entry);
    }
  }
  uint8_t member_header[4096] = {0};
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.member_offset;
    const uint32_t probe_bytes =
        entry.member_size < sizeof(member_header)
            ? entry.member_size
            : static_cast<uint32_t>(sizeof(member_header));
    valid = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
            ReadExact(file, member_header, probe_bytes) &&
            hibiki_voice_hook::bgi::ParseBwOggHeader(
                member_header, probe_bytes, entry.member_size, &ogg_offset,
                &ogg_size);
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.member_offset + ogg_offset;
    ogg = static_cast<uint8_t*>(malloc(ogg_size));
    valid = ogg != nullptr &&
            SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
            ReadExact(file, ogg, ogg_size) &&
            hibiki_voice_hook::siglus::CompleteOggBytes(ogg, ogg_size) ==
                ogg_size;
  }
  const bool duplicate = valid &&
      task->tick_ms - g_bgi_last_tick <= 2000 &&
      g_bgi_last_member == entry.member_offset &&
      _wcsicmp(g_bgi_last_path, task->path) == 0;
  if (valid && !duplicate) {
    wchar_t member_name[hibiki_voice_hook::bgi::kArc20NameBytes + 1] = {0};
    MultiByteToWideChar(CP_ACP, 0, entry.name, -1, member_name,
                        static_cast<int>(std::size(member_name)));
    const wchar_t* slash = wcsrchr(task->path, L'\\');
    const wchar_t* archive = slash == nullptr ? task->path : slash + 1;
    wchar_t storage[260] = {0};
    swprintf_s(storage, L"%s_%s.ogg", archive,
               member_name[0] == 0 ? L"voice" : member_name);
    WriteVoiceOggAt(ogg, ogg_size, storage, task->tick_ms);
    g_bgi_last_member = entry.member_offset;
    g_bgi_last_tick = task->tick_ms;
    wcsncpy_s(g_bgi_last_path, task->path, _TRUNCATE);
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagBgiArcVoiceCaptured;
    }
  }
  free(ogg);
  free(index);
  g_orig_CloseHandle(file);
}

void ProcessBgiVoiceTasks() {
  for (int i = 0; i < kBgiTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_bgi_tasks[i].state, 3, 2) == 2) {
      ProcessBgiVoiceTask(&g_bgi_tasks[i]);
      InterlockedExchange(&g_bgi_tasks[i].state, 0);
    }
  }
}

bool TryHookBgiArcVoice() {
  if (!hibiki_voice_hook::MatchesBgiEthornellProfile(nullptr)) return false;
  const bool ready = TryHookSiglusOvk();
  if (ready) {
    InterlockedExchange(&g_bgi_arc_enabled, 1);
    if (g_header != nullptr) {
      g_header->hook_diagnostics |= hibiki_voice_hook::kDiagBgiArcHooksReady;
    }
  }
  return ready;
}

void StopBgiArcVoice() {
  InterlockedExchange(&g_bgi_arc_enabled, 0);
  if (!g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kBgiHandleSlots; ++i) {
    g_bgi_handles[i].handle = INVALID_HANDLE_VALUE;
    g_bgi_handles[i].path[0] = 0;
  }
  LeaveCriticalSection(&g_cs);
}

class BgiEthornellAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "bgi_ethornell"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesBgiEthornellProfile(nullptr);
  }
  bool install() override {
    ready_ = TryHookBgiArcVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessBgiVoiceTasks(); }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopBgiArcVoice();
    installed_ = false;
    ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

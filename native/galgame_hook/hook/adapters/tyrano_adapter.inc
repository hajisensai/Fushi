// TyranoScript 5 / NW.js clean voice extraction.
//
// Howler/WebAudio feeds Chromium FFmpeg through a custom in-memory AVIOContext,
// so avformat_open_input has no usable voice URL. NW.js still reads each ASAR
// member at its exact archive offset. The shared kernel file detour only spots
// a pre-indexed data/sound/v_* OGG/M4A entry and enqueues a fixed-size task;
// JSON parsing, archive IO, allocation, validation and writing stay in the
// HookWorker polling path.

constexpr int kTyranoAsarHandleSlots = 16;
constexpr int kTyranoAsarTaskSlots = 32;
constexpr uint32_t kMaxAsarHeaderBytes = 16u * 1024u * 1024u;

struct TyranoAsarHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
};

struct TyranoAsarTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint32_t entry_index = 0;
};

TyranoAsarHandle g_tyrano_asar_handles[kTyranoAsarHandleSlots];
TyranoAsarTask g_tyrano_asar_tasks[kTyranoAsarTaskSlots];
std::vector<hibiki_voice_hook::AsarVoiceEntry> g_tyrano_voice_entries;
wchar_t g_tyrano_asar_path[32768] = {0};
volatile LONG g_tyrano_asar_ready = 0;
uint32_t g_tyrano_last_processed_entry = UINT32_MAX;
uint64_t g_tyrano_last_processed_tick = 0;

bool HasAppAsarSuffix(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t length = wcslen(path);
  constexpr wchar_t kSuffix[] = L"app.asar";
  constexpr size_t kSuffixLength = (sizeof(kSuffix) / sizeof(kSuffix[0])) - 1;
  return length >= kSuffixLength &&
         _wcsicmp(path + length - kSuffixLength, kSuffix) == 0;
}

bool LoadTyranoAsarVoiceIndex() {
  if (g_orig_CreateFileW == nullptr || g_orig_ReadFile == nullptr ||
      g_orig_CloseHandle == nullptr) {
    return false;
  }
  wchar_t executable[32768] = {0};
  const DWORD executable_length =
      GetModuleFileNameW(nullptr, executable, 32768);
  if (executable_length == 0 || executable_length >= 32768) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring archive =
      std::wstring(executable) + L"\\resources\\app.asar";
  if (archive.size() + 1 > 32768) return false;

  HANDLE file = g_orig_CreateFileW(
      archive.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  uint32_t header[4] = {0};
  bool valid =
      ReadExact(file, header, static_cast<uint32_t>(sizeof(header)));
  const uint32_t header_size = header[1];
  const uint32_t json_size = header[3];
  valid = valid && header[0] == 4 && header_size >= 8 &&
          json_size > 0 && json_size <= kMaxAsarHeaderBytes &&
          json_size <= header_size;
  std::vector<char> json;
  if (valid) {
    json.resize(json_size);
    valid = ReadExact(file, json.data(), json_size);
  }
  g_orig_CloseHandle(file);
  if (!valid) return false;

  std::vector<hibiki_voice_hook::AsarVoiceEntry> entries;
  const uint64_t data_base = 8u + static_cast<uint64_t>(header_size);
  if (!hibiki_voice_hook::ParseAsarVoiceEntries(
          json.data(), json.size(), data_base, &entries) ||
      entries.empty()) {
    return false;
  }
  g_tyrano_voice_entries.swap(entries);
  wcsncpy_s(g_tyrano_asar_path, archive.c_str(), _TRUNCATE);
  InterlockedExchange(&g_tyrano_asar_ready, 1);
  return true;
}

void RememberTyranoAsar(HANDLE handle, const wchar_t* path) {
  if (handle == INVALID_HANDLE_VALUE || !HasAppAsarSuffix(path) ||
      InterlockedCompareExchange(&g_tyrano_asar_ready, 0, 0) == 0 ||
      !g_cs_ready) {
    return;
  }
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kTyranoAsarHandleSlots; ++i) {
    if (g_tyrano_asar_handles[i].handle == INVALID_HANDLE_VALUE ||
        g_tyrano_asar_handles[i].handle == handle) {
      g_tyrano_asar_handles[i].handle = handle;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool IsTyranoAsarHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return false;
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kTyranoAsarHandleSlots; ++i) {
    if (g_tyrano_asar_handles[i].handle == handle) {
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetTyranoAsar(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kTyranoAsarHandleSlots; ++i) {
    if (g_tyrano_asar_handles[i].handle == handle) {
      g_tyrano_asar_handles[i].handle = INVALID_HANDLE_VALUE;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

void QueueTyranoAsarVoice(uint32_t entry_index) {
  const uint64_t now = GetTickCount64();
  for (int i = 0; i < kTyranoAsarTaskSlots; ++i) {
    TyranoAsarTask* task = &g_tyrano_asar_tasks[i];
    if (InterlockedCompareExchange(&task->state, 1, 0) != 0) continue;
    task->tick_ms = now;
    task->entry_index = entry_index;
    MemoryBarrier();
    InterlockedExchange(&task->state, 2);
    return;
  }
}

void QueueTyranoEntriesInRange(uint64_t start, uint64_t length) {
  const uint64_t end = start + length;
  if (length == 0 || end < start) return;
  for (size_t i = 0; i < g_tyrano_voice_entries.size(); ++i) {
    const auto& entry = g_tyrano_voice_entries[i];
    if (entry.archive_offset < start || entry.archive_offset >= end) continue;
    QueueTyranoAsarVoice(static_cast<uint32_t>(i));
  }
}

void ObserveTyranoAsarReadRequest(HANDLE file, DWORD requested,
                                  LPOVERLAPPED overlapped) {
  if (overlapped == nullptr || requested == 0 ||
      InterlockedCompareExchange(&g_tyrano_asar_ready, 0, 0) == 0 ||
      !IsTyranoAsarHandle(file)) {
    return;
  }
  const uint64_t start =
      (static_cast<uint64_t>(overlapped->OffsetHigh) << 32) |
      overlapped->Offset;
  QueueTyranoEntriesInRange(start, requested);
}

void ObserveTyranoAsarRead(HANDLE file, const void* buffer, DWORD done,
                           LPOVERLAPPED overlapped) {
  if (buffer == nullptr || done < 4 ||
      InterlockedCompareExchange(&g_tyrano_asar_ready, 0, 0) == 0 ||
      !IsTyranoAsarHandle(file)) {
    return;
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
  const uint64_t end = start + done;
  if (end < start) return;
  for (size_t i = 0; i < g_tyrano_voice_entries.size(); ++i) {
    const uint64_t entry_offset = g_tyrano_voice_entries[i].archive_offset;
    if (entry_offset < start || entry_offset > end - 4) continue;
    const size_t relative = static_cast<size_t>(entry_offset - start);
    bool ogg_header = false;
    __try {
      ogg_header = memcmp(static_cast<const uint8_t*>(buffer) + relative,
                          "OggS", 4) == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      return;
    }
    if (ogg_header) QueueTyranoAsarVoice(static_cast<uint32_t>(i));
  }
}

void ProcessTyranoAsarTask(TyranoAsarTask* task) {
  if (task == nullptr ||
      task->entry_index >= g_tyrano_voice_entries.size() ||
      g_orig_CreateFileW == nullptr || g_orig_CloseHandle == nullptr) {
    return;
  }
  if (task->entry_index == g_tyrano_last_processed_entry &&
      task->tick_ms - g_tyrano_last_processed_tick < 500) {
    return;
  }
  const auto& entry = g_tyrano_voice_entries[task->entry_index];
  if (entry.byte_len == 0 || entry.byte_len > UINT32_MAX) return;
  HANDLE file = g_orig_CreateFileW(
      g_tyrano_asar_path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER at = {};
  at.QuadPart = static_cast<LONGLONG>(entry.archive_offset);
  bool valid = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE;
  uint8_t* ogg = nullptr;
  if (valid) {
    ogg = static_cast<uint8_t*>(malloc(static_cast<size_t>(entry.byte_len)));
    valid = ogg != nullptr &&
            ReadExact(file, ogg, static_cast<uint32_t>(entry.byte_len));
    if (valid) {
      const auto format = hibiki_voice_hook::DetectAudioResourceFormat(
          ogg, static_cast<size_t>(entry.byte_len));
      valid = format == hibiki_voice_hook::AudioResourceFormat::kM4a ||
              (format == hibiki_voice_hook::AudioResourceFormat::kOgg &&
               hibiki_voice_hook::siglus::CompleteOggBytes(
                   ogg, static_cast<uint32_t>(entry.byte_len)) ==
                   entry.byte_len);
    }
  }
  g_orig_CloseHandle(file);
  if (valid) {
    const size_t slash = entry.path.find_last_of('/');
    const char* base = entry.path.c_str() +
                       (slash == std::string::npos ? 0 : slash + 1);
    wchar_t storage[260] = {0};
    int converted = MultiByteToWideChar(CP_UTF8, 0, base, -1, storage, 260);
    if (converted <= 0) {
      converted = MultiByteToWideChar(CP_ACP, 0, base, -1, storage, 260);
    }
    if (converted > 0) {
      WriteVoiceOggAt(ogg, static_cast<uint32_t>(entry.byte_len), storage,
                      task->tick_ms);
      g_tyrano_last_processed_entry = task->entry_index;
      g_tyrano_last_processed_tick = task->tick_ms;
      if (g_header != nullptr) {
        g_header->hook_diagnostics |=
            hibiki_voice_hook::kDiagTyranoAsarVoiceCaptured;
      }
    }
  }
  free(ogg);
}

void ProcessTyranoAsarTasks() {
  for (int i = 0; i < kTyranoAsarTaskSlots; ++i) {
    TyranoAsarTask* task = &g_tyrano_asar_tasks[i];
    if (InterlockedCompareExchange(&task->state, 3, 2) == 2) {
      ProcessTyranoAsarTask(task);
      InterlockedExchange(&task->state, 0);
    }
  }
}

bool TryHookTyranoAsarAudio() {
  if (InterlockedCompareExchange(&g_tyrano_asar_ready, 0, 0) != 0) return true;
  const bool file_hooks_ready = TryHookSiglusOvk();
  const bool index_ready = file_hooks_ready && LoadTyranoAsarVoiceIndex();
  if (index_ready && g_header != nullptr) {
    g_header->hook_diagnostics |=
        hibiki_voice_hook::kDiagTyranoAsarHooksReady;
  }
  return index_ready;
}

void StopTyranoAsarAudio() {
  InterlockedExchange(&g_tyrano_asar_ready, 0);
  g_tyrano_voice_entries.clear();
  g_tyrano_asar_path[0] = 0;
  for (int i = 0; i < kTyranoAsarHandleSlots; ++i) {
    g_tyrano_asar_handles[i].handle = INVALID_HANDLE_VALUE;
  }
  g_tyrano_last_processed_entry = UINT32_MAX;
  g_tyrano_last_processed_tick = 0;
}

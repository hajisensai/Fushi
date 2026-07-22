// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
// ══ C.3 SiglusEngine OVK 原始语音捕获 ═══════════════════════════════════════════
// Siglus 角色语音位于 koe/*.ovk：文件头是 count + count 个 16-byte 索引项，每项给出一条
// 完整 Ogg/Vorbis 的 byte_len / absolute_offset。引擎播放台词时从相应 offset ReadFile；在
// 返回 buffer 以 OggS 开头时只投递固定大小任务，HookWorker 另开只读句柄按索引取完整 entry、
// 校验 Ogg EOS 后落盘。ReadFile 路径不分配、不写盘，避免给游戏的解码 IO 线程增加阻塞。

constexpr size_t kSiglusPathChars = 520;
constexpr int kSiglusHandleSlots = 32;
constexpr int kSiglusTaskSlots = 32;
constexpr uint32_t kDiagSiglusOvkOpened = 0x20000000u;
constexpr uint32_t kDiagSiglusVoiceQueued = 0x40000000u;
constexpr uint32_t kDiagSiglusVoiceDumped = 0x80000000u;

struct SiglusOvkHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  wchar_t path[kSiglusPathChars] = {0};
};

struct SiglusVoiceTask {
  volatile LONG state = 0;  // 0=空，1=生产中，2=待消费，3=消费中
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  wchar_t path[kSiglusPathChars] = {0};
};

SiglusOvkHandle g_siglus_handles[kSiglusHandleSlots];
SiglusVoiceTask g_siglus_tasks[kSiglusTaskSlots];
volatile LONG g_visual_arts_ovk_seen = 0;

decltype(&CreateFileW) g_orig_CreateFileW = nullptr;
decltype(&CreateFileA) g_orig_CreateFileA = nullptr;
decltype(&ReadFile) g_orig_ReadFile = nullptr;
decltype(&CloseHandle) g_orig_CloseHandle = nullptr;

// TyranoScript/NW.js uses the same kernel file boundary for app.asar. The
// implementation is included after this adapter so it can reuse these four
// original trampolines without stacking a second MinHook detour.
void RememberTyranoAsar(HANDLE handle, const wchar_t* path);
void ObserveTyranoAsarReadRequest(HANDLE file, DWORD requested,
                                  LPOVERLAPPED overlapped);
void ObserveTyranoAsarRead(HANDLE file, const void* buffer, DWORD done,
                           LPOVERLAPPED overlapped);
void ForgetTyranoAsar(HANDLE handle);
void RememberBgiVoiceArc(HANDLE handle, const wchar_t* path);
void ObserveBgiVoiceArcRead(HANDLE file, const void* buffer, DWORD done,
                            LPOVERLAPPED overlapped);
void ForgetBgiVoiceArc(HANDLE handle);
void RememberArtemisPfs(HANDLE handle, const wchar_t* path);
void ObserveArtemisPfsRead(HANDLE file, DWORD done, LPOVERLAPPED overlapped);
void ForgetArtemisPfs(HANDLE handle);
void RememberCatSystem2Pcm(HANDLE handle, const wchar_t* path);
void ObserveCatSystem2PcmRead(HANDLE file, DWORD done,
                             LPOVERLAPPED overlapped);
void ForgetCatSystem2Pcm(HANDLE handle);

bool HasOvkSuffix(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t len = wcslen(path);
  return len >= 4 && _wcsicmp(path + len - 4, L".ovk") == 0;
}

bool HasOvkSuffix(const char* path) {
  if (path == nullptr) return false;
  const size_t len = strlen(path);
  return len >= 4 && _stricmp(path + len - 4, ".ovk") == 0;
}

bool ContainsInsensitive(const wchar_t* text, const wchar_t* needle) {
  if (text == nullptr || needle == nullptr || *needle == 0) return false;
  const size_t needle_len = wcslen(needle);
  for (const wchar_t* p = text; *p != 0; ++p) {
    if (_wcsnicmp(p, needle, needle_len) == 0) return true;
  }
  return false;
}

bool IsUnityVoiceBundle(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t len = wcslen(path);
  return len >= 7 && _wcsicmp(path + len - 7, L".bundle") == 0 &&
         ContainsInsensitive(path, L"voice");
}

void RememberUnityVoiceBundle(const wchar_t* path) {
  if (!IsUnityVoiceBundle(path) || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  wcsncpy_s(g_last_unity_voice_bundle, path, _TRUNCATE);
  LeaveCriticalSection(&g_cs);
}

void RememberSiglusOvk(HANDLE handle, const wchar_t* path) {
  if (handle == INVALID_HANDLE_VALUE || path == nullptr || !g_cs_ready) return;
  bool remembered = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kSiglusHandleSlots; ++i) {
    if (g_siglus_handles[i].handle == INVALID_HANDLE_VALUE ||
        g_siglus_handles[i].handle == handle) {
      g_siglus_handles[i].handle = handle;
      wcsncpy_s(g_siglus_handles[i].path, path, _TRUNCATE);
      remembered = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  if (remembered) {
    InterlockedExchange(&g_visual_arts_ovk_seen, 1);
    if (g_header != nullptr) {
      g_header->reserved_luna |= kDiagSiglusOvkOpened;
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagVisualArtsOvkHooksReady;
    }
  }
}

bool CopySiglusOvkPath(HANDLE handle, wchar_t* out, size_t out_chars) {
  if (handle == INVALID_HANDLE_VALUE || out == nullptr || out_chars == 0 ||
      !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kSiglusHandleSlots; ++i) {
    if (g_siglus_handles[i].handle == handle) {
      wcsncpy_s(out, out_chars, g_siglus_handles[i].path, _TRUNCATE);
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetSiglusOvk(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kSiglusHandleSlots; ++i) {
    if (g_siglus_handles[i].handle == handle) {
      g_siglus_handles[i].handle = INVALID_HANDLE_VALUE;
      g_siglus_handles[i].path[0] = 0;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

HANDLE WINAPI Detour_CreateFileW(LPCWSTR file_name, DWORD desired_access,
                                  DWORD share_mode,
                                  LPSECURITY_ATTRIBUTES security,
                                  DWORD creation_disposition,
                                  DWORD flags_and_attributes,
                                  HANDLE template_file) {
  HANDLE result = g_orig_CreateFileW(file_name, desired_access, share_mode,
                                     security, creation_disposition,
                                     flags_and_attributes, template_file);
  if (result != INVALID_HANDLE_VALUE && HasOvkSuffix(file_name)) {
    RememberSiglusOvk(result, file_name);
  }
  if (result != INVALID_HANDLE_VALUE) RememberTyranoAsar(result, file_name);
  if (result != INVALID_HANDLE_VALUE) RememberBgiVoiceArc(result, file_name);
  if (result != INVALID_HANDLE_VALUE) RememberArtemisPfs(result, file_name);
  if (result != INVALID_HANDLE_VALUE) RememberCatSystem2Pcm(result, file_name);
  if (result != INVALID_HANDLE_VALUE) RememberUnityVoiceBundle(file_name);
  return result;
}

HANDLE WINAPI Detour_CreateFileA(LPCSTR file_name, DWORD desired_access,
                                  DWORD share_mode,
                                  LPSECURITY_ATTRIBUTES security,
                                  DWORD creation_disposition,
                                  DWORD flags_and_attributes,
                                  HANDLE template_file) {
  HANDLE result = g_orig_CreateFileA(file_name, desired_access, share_mode,
                                     security, creation_disposition,
                                     flags_and_attributes, template_file);
  if (result != INVALID_HANDLE_VALUE && HasOvkSuffix(file_name)) {
    wchar_t wide[kSiglusPathChars] = {0};
    const int converted = MultiByteToWideChar(CP_ACP, 0, file_name, -1, wide,
                                               kSiglusPathChars);
    if (converted > 0) RememberSiglusOvk(result, wide);
  }
  if (result != INVALID_HANDLE_VALUE && file_name != nullptr) {
    wchar_t wide[kUnityBundlePathChars] = {0};
    const int converted = MultiByteToWideChar(
        CP_ACP, 0, file_name, -1, wide, kUnityBundlePathChars);
    if (converted > 0) {
      RememberTyranoAsar(result, wide);
      RememberBgiVoiceArc(result, wide);
      RememberArtemisPfs(result, wide);
      RememberCatSystem2Pcm(result, wide);
      RememberUnityVoiceBundle(wide);
    }
  }
  return result;
}

void QueueSiglusVoice(const wchar_t* path, uint64_t offset) {
  if (path == nullptr) return;
  const uint64_t now = GetTickCount64();
  for (int i = 0; i < kSiglusTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_siglus_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_siglus_tasks[i].tick_ms = now;
    g_siglus_tasks[i].offset = offset;
    wcsncpy_s(g_siglus_tasks[i].path, path, _TRUNCATE);
    InterlockedExchange(&g_siglus_tasks[i].state, 2);
    if (g_header != nullptr) g_header->reserved_luna |= kDiagSiglusVoiceQueued;
    return;
  }
}

BOOL WINAPI Detour_ReadFile(HANDLE file, LPVOID buffer, DWORD requested,
                            LPDWORD bytes_read, LPOVERLAPPED overlapped) {
  if (g_capture_enabled && overlapped != nullptr && requested > 0) {
    ObserveTyranoAsarReadRequest(file, requested, overlapped);
  }
  const BOOL ok =
      g_orig_ReadFile(file, buffer, requested, bytes_read, overlapped);
  const DWORD done = bytes_read != nullptr ? *bytes_read : 0;
  if (!ok || done < 4 || buffer == nullptr || !g_capture_enabled) return ok;
  ObserveTyranoAsarRead(file, buffer, done, overlapped);
  ObserveBgiVoiceArcRead(file, buffer, done, overlapped);
  ObserveArtemisPfsRead(file, done, overlapped);
  ObserveCatSystem2PcmRead(file, done, overlapped);
  if (InterlockedCompareExchange(&g_visual_arts_ovk_seen, 0, 0) == 0) return ok;

  wchar_t path[kSiglusPathChars] = {0};
  if (!CopySiglusOvkPath(file, path, kSiglusPathChars)) return ok;
  __try {
    if (memcmp(buffer, "OggS", 4) != 0) return ok;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return ok;
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
      return ok;
    }
    start = static_cast<uint64_t>(current.QuadPart) - done;
  }
  QueueSiglusVoice(path, start);
  return ok;
}

BOOL WINAPI Detour_CloseHandle(HANDLE handle) {
  ForgetTyranoAsar(handle);
  ForgetBgiVoiceArc(handle);
  ForgetArtemisPfs(handle);
  ForgetCatSystem2Pcm(handle);
  if (InterlockedCompareExchange(&g_visual_arts_ovk_seen, 0, 0) != 0) {
    ForgetSiglusOvk(handle);
  }
  return g_orig_CloseHandle(handle);
}

bool ReadExact(HANDLE file, void* buffer, uint32_t bytes) {
  uint8_t* out = static_cast<uint8_t*>(buffer);
  uint32_t done = 0;
  while (done < bytes) {
    DWORD part = 0;
    if (!g_orig_ReadFile(file, out + done, bytes - done, &part, nullptr) ||
        part == 0) {
      return false;
    }
    done += part;
  }
  return true;
}

void ProcessSiglusVoiceTask(SiglusVoiceTask* task) {
  HANDLE file = g_orig_CreateFileW(
      task->path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                       FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  LARGE_INTEGER size = {};
  uint32_t count = 0;
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  hibiki_voice_hook::siglus::OvkEntry entry;
  bool valid = GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
               ReadExact(file, &count, sizeof(count)) && count > 0 &&
               count <= hibiki_voice_hook::siglus::kMaxEntryCount;
  if (valid) {
    const uint64_t index_bytes64 = sizeof(uint32_t) +
        static_cast<uint64_t>(count) * hibiki_voice_hook::siglus::kOvkEntryBytes;
    valid = index_bytes64 <= static_cast<uint64_t>(size.QuadPart) &&
            index_bytes64 <= SIZE_MAX;
    if (valid) {
      const size_t index_bytes = static_cast<size_t>(index_bytes64);
      index = static_cast<uint8_t*>(malloc(index_bytes));
      valid = index != nullptr;
      if (valid) {
        memcpy(index, &count, sizeof(count));
        valid = ReadExact(file, index + sizeof(count),
                          static_cast<uint32_t>(index_bytes - sizeof(count)));
      }
      if (valid) {
        valid = hibiki_voice_hook::siglus::FindEntryAtOffset(
            index, index_bytes, static_cast<uint64_t>(size.QuadPart),
            task->offset, &entry);
      }
    }
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.offset;
    valid = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE;
  }
  if (valid) {
    ogg = static_cast<uint8_t*>(malloc(entry.byte_len));
    valid = ogg != nullptr && ReadExact(file, ogg, entry.byte_len) &&
            hibiki_voice_hook::siglus::CompleteOggBytes(ogg, entry.byte_len) ==
                entry.byte_len;
  }
  if (valid) {
    const wchar_t* slash = wcsrchr(task->path, L'\\');
    const wchar_t* base = slash != nullptr ? slash + 1 : task->path;
    wchar_t storage[260] = {0};
    swprintf_s(storage, L"%s_%u.ogg", base, entry.id);
    WriteVoiceOggAt(ogg, entry.byte_len, storage, task->tick_ms);
    if (g_header != nullptr) {
      g_header->reserved_luna |= kDiagSiglusVoiceDumped;
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagVisualArtsOvkCaptured;
    }
  }
  free(ogg);
  free(index);
  g_orig_CloseHandle(file);
}

void ProcessSiglusVoiceTasks() {
  for (int i = 0; i < kSiglusTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_siglus_tasks[i].state, 3, 2) == 2) {
      ProcessSiglusVoiceTask(&g_siglus_tasks[i]);
      InterlockedExchange(&g_siglus_tasks[i].state, 0);
    }
  }
}

bool IsSiglusEngine() {
  wchar_t path[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* base = slash != nullptr ? slash + 1 : path;
  return _wcsicmp(base, L"SiglusEngine.exe") == 0;
}

bool TryHookSiglusOvk() {
  const bool siglus = IsSiglusEngine();
  // Windows 10/11 上 kernel32 的文件 API 是 forwarder；MinHook 不能对那段转发桩建 trampoline。
  // 游戏 IAT 最终也落到 KernelBase 实现，故优先 hook KernelBase，旧系统再退 kernel32。
  HMODULE kernel = GetModuleHandleW(L"KernelBase.dll");
  if (kernel == nullptr) kernel = GetModuleHandleW(L"kernel32.dll");
  if (kernel == nullptr) return false;
  const bool create_w = HookFn(
      reinterpret_cast<void*>(GetProcAddress(kernel, "CreateFileW")),
      reinterpret_cast<void*>(&Detour_CreateFileW),
      reinterpret_cast<void**>(&g_orig_CreateFileW));
  const bool create_a = HookFn(
      reinterpret_cast<void*>(GetProcAddress(kernel, "CreateFileA")),
      reinterpret_cast<void*>(&Detour_CreateFileA),
      reinterpret_cast<void**>(&g_orig_CreateFileA));
  const bool read = HookFn(
      reinterpret_cast<void*>(GetProcAddress(kernel, "ReadFile")),
      reinterpret_cast<void*>(&Detour_ReadFile),
      reinterpret_cast<void**>(&g_orig_ReadFile));
  const bool close = HookFn(
      reinterpret_cast<void*>(GetProcAddress(kernel, "CloseHandle")),
      reinterpret_cast<void*>(&Detour_CloseHandle),
      reinterpret_cast<void**>(&g_orig_CloseHandle));
  const bool ready = create_w && create_a && read && close;
  if (ready && siglus && g_header != nullptr) {
    g_header->reserved_luna |= kDiagSiglusOvkHooksReady;
  }
  return ready;
}

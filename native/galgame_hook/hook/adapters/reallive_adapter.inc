// RealLive / old VisualArt's adapter.
//
// 身份：reallive_profile.h 的结构判据（exe 文件里的 ASCII Gameexe.ini + Seen 剧本名，或
// 标准安装目录 Gameexe.ini + Seen.txt），Siglus 标志一票否决；不认 exe 名 / 摘要 / 标题。
// 共享 OVK 路径（siglus_adapter.inc）照旧对任何进程开放，看到合法 OVK 也不据此宣称身份。
//
// 语音：koe/*.nwk（u32 count + 12 字节索引项，成员是 NWA 差分压缩 PCM）。文件 API 的
// detour 仍只有 siglus_adapter.inc 那一份共享 KernelBase broker；这里只挂三个观察点：
//   Remember（CreateFile）：按 *.nwk 后缀登记句柄——纯表项，不做 IO；
//   Observe（ReadFile）：身份已认领时，缓冲区前 16 字节像 NWA 头才投一个固定大小
//     {path, offset, tick} 任务，队满即丢；
//   Forget（CloseHandle）：无锁摘表（BUG-2046 纪律）。
// 索引解析、成员读取、NWA 解码与 WAV 落盘全部在 HookWorker（Poll → ProcessPendingEvents）。
// reallive_nwk.h / siglus_launch_win32.h 由 dll_main.cpp 在匿名命名空间之外引入。
#include "reallive_profile.h"

constexpr size_t kRealliveNwkPathChars = 520;
constexpr int kRealliveNwkHandleSlots = 8;
constexpr int kRealliveNwkTaskSlots = 32;
// 同一成员被引擎连续读多次（先读头、再读块表/块体）只算一次播放。
constexpr uint64_t kRealliveNwkRepeatWindowMs = 1500;
// 身份测量失败（exe 被占用等）只在有界时间窗内重试，且不写永久否定缓存。
constexpr uint64_t kRealliveIdentityRetryIntervalMs = 1000;
constexpr uint64_t kRealliveIdentityRetryWindowMs = 30000;

// adapter 自报 flags（AdapterReportSlot.flags 透传，含义只属本 adapter）。
constexpr LONG kRealliveFlagIdentityMatched = 0x00000001;
constexpr LONG kRealliveFlagImageSignature = 0x00000002;
constexpr LONG kRealliveFlagDirectorySignature = 0x00000004;
constexpr LONG kRealliveFlagIdentityUnmeasurable = 0x00000008;
constexpr LONG kRealliveFlagFileHooksReady = 0x00000010;
constexpr LONG kRealliveFlagNwkHandleTracked = 0x00000020;
constexpr LONG kRealliveFlagNwkReadQueued = 0x00000040;
constexpr LONG kRealliveFlagNwkVoiceExported = 0x00000080;
constexpr LONG kRealliveFlagNwkTaskRejected = 0x00000100;
constexpr LONG kRealliveFlagNwkQueueFull = 0x00000200;

struct RealliveNwkHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  wchar_t path[kRealliveNwkPathChars] = {0};
};

struct RealliveNwkTask {
  volatile LONG state = 0;  // 0=空，1=生产中，2=待消费，3=消费中
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  wchar_t path[kRealliveNwkPathChars] = {0};
};

RealliveNwkHandle g_reallive_nwk_handles[kRealliveNwkHandleSlots];
RealliveNwkTask g_reallive_nwk_tasks[kRealliveNwkTaskSlots];
volatile LONG g_reallive_capture_armed = 0;
volatile LONG g_reallive_flags = 0;
// 0 = 未测量，1 = RealLive，-1 = 已测量且不是。只有测量成功才写 ±1。
volatile LONG g_reallive_identity_state = 0;
uint64_t g_reallive_identity_first_attempt_ms = 0;
uint64_t g_reallive_identity_last_attempt_ms = 0;
// worker 私有的去重状态（只在 HookWorker 上读写）。
uint64_t g_reallive_last_export_offset = UINT64_MAX;
uint64_t g_reallive_last_export_tick = 0;
wchar_t g_reallive_last_export_path[kRealliveNwkPathChars] = {0};

void MarkRealliveFlag(LONG flag) {
  InterlockedOr(&g_reallive_flags, flag);
}

bool HasNwkSuffix(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t len = wcslen(path);
  return len >= 4 && _wcsicmp(path + len - 4, L".nwk") == 0;
}

void RememberRealliveNwk(HANDLE handle, const wchar_t* path) {
  if (handle == INVALID_HANDLE_VALUE || !HasNwkSuffix(path)) return;
  const bool remembered = fushi_voice_hook::RememberTrackedHandle(
      g_reallive_nwk_handles, handle, [path](RealliveNwkHandle& slot) {
        wcsncpy_s(slot.path, path, _TRUNCATE);
      });
  if (remembered) MarkRealliveFlag(kRealliveFlagNwkHandleTracked);
}

bool CopyRealliveNwkPath(HANDLE handle, wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0) return false;
  return fushi_voice_hook::ReadTrackedHandle(
      g_reallive_nwk_handles, handle,
      [out, out_chars](const RealliveNwkHandle& slot) {
        wcsncpy_s(out, out_chars, slot.path, _TRUNCATE);
      });
}

void ForgetRealliveNwk(HANDLE handle) {
  fushi_voice_hook::ForgetTrackedHandle(g_reallive_nwk_handles, handle);
}

void QueueRealliveNwkVoice(const wchar_t* path, uint64_t offset) {
  const uint64_t now = GetTickCount64();
  for (int i = 0; i < kRealliveNwkTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_reallive_nwk_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_reallive_nwk_tasks[i].tick_ms = now;
    g_reallive_nwk_tasks[i].offset = offset;
    wcsncpy_s(g_reallive_nwk_tasks[i].path, path, _TRUNCATE);
    InterlockedExchange(&g_reallive_nwk_tasks[i].state, 2);
    MarkRealliveFlag(kRealliveFlagNwkReadQueued);
    return;
  }
  MarkRealliveFlag(kRealliveFlagNwkQueueFull);
}

// 游戏线程：固定 16 字节检查 + 有界拷贝 + 入队，不分配、不做 IO（SetFilePointerEx 只查询
// 当前位置，与 Siglus/BGI 同一做法）。
void ObserveRealliveNwkRead(HANDLE file, const void* buffer, DWORD done,
                            LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_reallive_capture_armed, 0, 0) == 0 ||
      buffer == nullptr || done < 16) {
    return;
  }
  bool header = false;
  __try {
    header = fushi_voice_hook::reallive::LooksLikeNwaHeaderPrefix(
        static_cast<const uint8_t*>(buffer), done);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (!header) return;
  wchar_t path[kRealliveNwkPathChars] = {0};
  if (!CopyRealliveNwkPath(file, path, kRealliveNwkPathChars)) return;
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
  QueueRealliveNwkVoice(path, start);
}

// Worker：按索引精确对上成员起点 → 读整条 NWA → 校验并解码 → WAV 落盘。
void ProcessRealliveNwkTask(const RealliveNwkTask& task) {
  namespace rl = fushi_voice_hook::reallive;
  const uint64_t since_last = task.tick_ms >= g_reallive_last_export_tick
      ? task.tick_ms - g_reallive_last_export_tick
      : g_reallive_last_export_tick - task.tick_ms;
  if (task.offset == g_reallive_last_export_offset &&
      since_last < kRealliveNwkRepeatWindowMs &&
      _wcsicmp(task.path, g_reallive_last_export_path) == 0) {
    return;
  }
  HANDLE file = g_orig_CreateFileW(
      task.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    MarkRealliveFlag(kRealliveFlagNwkTaskRejected);
    return;
  }
  LARGE_INTEGER size = {};
  uint32_t count = 0;
  uint8_t* index = nullptr;
  uint8_t* nwa = nullptr;
  uint8_t* wav = nullptr;
  size_t wav_bytes = 0;
  rl::NwkEntry entry;
  rl::NwaHeader header;
  bool valid = GetFileSizeEx(file, &size) != FALSE && size.QuadPart > 0 &&
               ReadExact(file, reinterpret_cast<uint8_t*>(&count),
                                 sizeof(count)) &&
               count > 0 && count <= rl::kMaxNwkEntryCount;
  size_t index_bytes = 0;
  if (valid) {
    index_bytes = sizeof(uint32_t) +
                  static_cast<size_t>(count) * rl::kNwkEntryBytes;
    valid = static_cast<uint64_t>(index_bytes) <=
            static_cast<uint64_t>(size.QuadPart);
  }
  if (valid) {
    index = static_cast<uint8_t*>(malloc(index_bytes));
    valid = index != nullptr;
  }
  if (valid) {
    memcpy(index, &count, sizeof(count));
    valid = ReadExact(file, index + sizeof(count),
                              static_cast<uint32_t>(index_bytes - sizeof(count))) &&
            rl::FindNwkEntryAtOffset(index, index_bytes,
                                     static_cast<uint64_t>(size.QuadPart),
                                     task.offset, &entry);
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.offset;
    nwa = static_cast<uint8_t*>(malloc(entry.byte_len));
    valid = nwa != nullptr &&
            SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
            ReadExact(file, nwa, entry.byte_len) &&
            rl::ParseNwaHeader(nwa, entry.byte_len, &header);
  }
  if (valid) {
    wav_bytes = rl::NwaWavBytes(header);
    wav = static_cast<uint8_t*>(malloc(wav_bytes));
    valid = wav != nullptr &&
            rl::DecodeNwaToWav(nwa, entry.byte_len, header, wav, wav_bytes);
  }
  if (valid) {
    const wchar_t* slash = wcsrchr(task.path, L'\\');
    const wchar_t* base = slash != nullptr ? slash + 1 : task.path;
    // 与 OVK 同形：<归档名>_<成员 voice id>.wav；成员 id 是引擎的 KOE 查找键。
    const std::wstring storage = std::wstring(base) + L"_" +
                                 std::to_wstring(entry.voice_id) + L".wav";
    valid = WriteVoiceOggAt(wav, static_cast<uint32_t>(wav_bytes),
                            storage.c_str(), task.tick_ms);
  }
  if (valid) {
    g_reallive_last_export_offset = task.offset;
    g_reallive_last_export_tick = task.tick_ms;
    wcsncpy_s(g_reallive_last_export_path, task.path, _TRUNCATE);
    MarkRealliveFlag(kRealliveFlagNwkVoiceExported);
  } else {
    MarkRealliveFlag(kRealliveFlagNwkTaskRejected);
  }
  free(wav);
  free(nwa);
  free(index);
  g_orig_CloseHandle(file);
}

void ProcessRealliveNwkTasks() {
  for (int i = 0; i < kRealliveNwkTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_reallive_nwk_tasks[i].state, 3, 2) == 2) {
      ProcessRealliveNwkTask(g_reallive_nwk_tasks[i]);
      InterlockedExchange(&g_reallive_nwk_tasks[i].state, 0);
    }
  }
}

bool RealliveRegularFileExists(const std::wstring& dir, const wchar_t* name) {
  const std::wstring path = dir + L"\\" + name;
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// 读磁盘上的 exe 文件（不读进程内存：那段会被 Luna/本 DLL 的 hook 改写），64 KB 分块喂
// 扫描器，上界 kMaxImageScanBytes。打不开返回 false（= 未测量）。
bool MeasureRealliveImage(const wchar_t* executable, uint32_t* markers) {
  HANDLE file = CreateFileW(
      executable, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  uint8_t* chunk = static_cast<uint8_t*>(malloc(64 * 1024));
  if (chunk == nullptr) {
    CloseHandle(file);
    return false;
  }
  fushi_voice_hook::reallive::ImageSignatureScanner scanner;
  uint64_t scanned = 0;
  bool ok = true;
  while (scanned < fushi_voice_hook::reallive::kMaxImageScanBytes) {
    DWORD read = 0;
    if (!ReadFile(file, chunk, 64 * 1024, &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    scanner.Feed(chunk, read);
    scanned += read;
  }
  free(chunk);
  CloseHandle(file);
  if (ok) *markers = scanner.markers();
  return ok;
}

bool IsRealliveEngine() {
  const LONG state = InterlockedCompareExchange(&g_reallive_identity_state, 0, 0);
  if (state != 0) return state > 0;
  const uint64_t now = GetTickCount64();
  if (g_reallive_identity_last_attempt_ms != 0 &&
      now - g_reallive_identity_last_attempt_ms < kRealliveIdentityRetryIntervalMs) {
    return false;
  }
  if (g_reallive_identity_first_attempt_ms == 0) {
    g_reallive_identity_first_attempt_ms = now;
  }
  g_reallive_identity_last_attempt_ms = now;

  wchar_t executable[MAX_PATH] = {0};
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return false;
  const wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  const std::wstring directory(executable,
                               static_cast<size_t>(slash - executable));

  fushi_voice_hook::reallive::IdentityInputs inputs;
  inputs.siglus_executable = IsSiglusEngine();
  inputs.siglus_directory =
      fushi_voice_hook::DirectoryLooksLikeSiglusOnDisk(directory);
  inputs.reallive_directory = fushi_voice_hook::reallive::DirectoryLooksLikeReallive(
      directory, RealliveRegularFileExists);
  inputs.image_measured = MeasureRealliveImage(executable, &inputs.image_markers);
  if (!inputs.image_measured && !inputs.reallive_directory) {
    // 测量失败不是否定结论：窗口内下次再量，窗口耗尽才定为「不是」。
    MarkRealliveFlag(kRealliveFlagIdentityUnmeasurable);
    if (now - g_reallive_identity_first_attempt_ms >= kRealliveIdentityRetryWindowMs) {
      InterlockedExchange(&g_reallive_identity_state, -1);
    }
    return false;
  }
  if (inputs.reallive_directory) MarkRealliveFlag(kRealliveFlagDirectorySignature);
  if (inputs.image_measured &&
      fushi_voice_hook::reallive::IsRealliveImageSignature(inputs.image_markers)) {
    MarkRealliveFlag(kRealliveFlagImageSignature);
  }
  const bool matched = fushi_voice_hook::MatchesRealliveProfile(inputs);
  if (matched) MarkRealliveFlag(kRealliveFlagIdentityMatched);
  InterlockedExchange(&g_reallive_identity_state, matched ? 1 : -1);
  return matched;
}

class RealliveAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "reallive"; }
  bool probe() const override { return IsRealliveEngine(); }
  bool install() override {
    if (installed_ || !probe()) return installed_;
    // 共享 KernelBase broker（幂等）；RealLive 身份成立后才武装 NWK 入队。
    if (!TryHookSiglusOvk()) return false;
    MarkRealliveFlag(kRealliveFlagFileHooksReady);
    InterlockedExchange(&g_reallive_capture_armed, 1);
    installed_ = true;
    return true;
  }
  // 身份测量可能在注入窗口里因 exe 被占用而失败：Poll 上有界重试（IsRealliveEngine
  // 自带时间节流与窗口），认领后只剩任务消费。
  void ProcessPendingEvents() {
    if (!installed_ && g_capture_enabled) install();
    ProcessRealliveNwkTasks();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {
    // File APIs are installed at startup; module notifications remain a profile extension seam.
  }
  void shutdown() override {
    InterlockedExchange(&g_reallive_capture_armed, 0);
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_reallive_flags, 0, 0))};
  }

 private:
  bool installed_ = false;
};

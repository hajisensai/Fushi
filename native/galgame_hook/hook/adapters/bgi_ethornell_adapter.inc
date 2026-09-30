// BGI / Ethornell clean voice capture for both archive generations
// (`PackFile    ` and `BURIKO ARC20`, see bgi_arc.h). The kernel file detours
// live in siglus_adapter.inc so MinHook installs a single detour per API. The
// ReadFile callback only copies a bounded {path, offset, tick} task. Archive
// index parsing, voice-archive classification, Ogg validation and file output
// all run from AdapterRegistry::Poll.
//
// Which archive holds per-line voice is decided structurally, per archive, on
// the worker (bgi::VoiceArchiveTally: every sampled member is a mono `bw`
// wrapper). The previous `data031*.arc` file-name rule was one title's layout
// and, on the 2016 AUGUST trial it was written against, actually pointed at the
// SE archive (data03110.arc: 143 of 146 members stereo); that title's voice
// lives in data04xxx.arc, as does the 2011 PackFile-generation trial's.
#include "bgi_ethornell_profile.h"
// 正文文本道 + 游戏内查词（SetTextImpl 捕获、字形几何、主窗口过程点击认领）在
// bgi_lookup.inc，结构判据与纯逻辑在 bgi_lookup_core.h（由 dll_main.cpp 在顶层引入）。
#include "bgi_lookup.inc"

constexpr size_t kBgiPathChars = 520;
// Every `.arc` is tracked now (classification happens later on the worker),
// and BGI titles ship ~45-60 archives; a full table would silently drop
// voice-archive handles.
constexpr int kBgiHandleSlots = 64;
constexpr int kBgiTaskSlots = 32;
constexpr int kBgiVerdictSlots = 128;

// 无锁句柄表（tracked_handle_table.h）：Forget 走 CloseHandle detour，不得进 g_cs（BUG-2046）。
struct BgiArcHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  wchar_t path[kBgiPathChars] = {0};
};

struct BgiVoiceTask {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0;
  uint64_t read_offset = 0;
  wchar_t path[kBgiPathChars] = {0};
};

// Worker-only: touched exclusively from ProcessBgiVoiceTask on the Poll
// thread, so no synchronisation. Keyed by path + file size.
struct BgiArchiveVerdict {
  bool used = false;
  bool voice = false;
  uint64_t file_size = 0;
  wchar_t path[kBgiPathChars] = {0};
};

BgiArcHandle g_bgi_handles[kBgiHandleSlots];
BgiVoiceTask g_bgi_tasks[kBgiTaskSlots];
BgiArchiveVerdict g_bgi_verdicts[kBgiVerdictSlots];
int g_bgi_next_verdict = 0;
volatile LONG g_bgi_arc_enabled = 0;
uint64_t g_bgi_last_member = UINT64_MAX;
uint64_t g_bgi_last_tick = 0;
wchar_t g_bgi_last_path[kBgiPathChars] = {0};

// Only the extension: whether an archive is BGI at all, and whether it holds
// per-line voice, is decided from its bytes on the worker.
bool IsBgiArchivePath(const wchar_t* path) {
  if (path == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* base = slash == nullptr ? path : slash + 1;
  const size_t len = wcslen(base);
  return len > 4 && _wcsicmp(base + len - 4, L".arc") == 0;
}

void RememberBgiVoiceArc(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_bgi_arc_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsBgiArchivePath(path)) {
    return;
  }
  fushi_voice_hook::RememberTrackedHandle(
      g_bgi_handles, handle, [path](BgiArcHandle& slot) {
        wcsncpy_s(slot.path, path, _TRUNCATE);
      });
}

bool CopyBgiVoiceArcPath(HANDLE handle, wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0) return false;
  return fushi_voice_hook::ReadTrackedHandle(
      g_bgi_handles, handle, [out, out_chars](const BgiArcHandle& slot) {
        wcsncpy_s(out, out_chars, slot.path, _TRUNCATE);
      });
}

void ForgetBgiVoiceArc(HANDLE handle) {
  fushi_voice_hook::ForgetTrackedHandle(g_bgi_handles, handle);
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
      const uint32_t ogg_offset = fushi_voice_hook::bgi::ReadLe32(bytes);
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

const BgiArchiveVerdict* FindBgiArchiveVerdict(const wchar_t* path,
                                               uint64_t file_size) {
  for (const BgiArchiveVerdict& verdict : g_bgi_verdicts) {
    if (verdict.used && verdict.file_size == file_size &&
        _wcsicmp(verdict.path, path) == 0) {
      return &verdict;
    }
  }
  return nullptr;
}

void RememberBgiArchiveVerdict(const wchar_t* path, uint64_t file_size,
                               bool voice) {
  BgiArchiveVerdict& slot = g_bgi_verdicts[g_bgi_next_verdict];
  g_bgi_next_verdict = (g_bgi_next_verdict + 1) % kBgiVerdictSlots;
  slot.used = true;
  slot.voice = voice;
  slot.file_size = file_size;
  wcsncpy_s(slot.path, path, _TRUNCATE);
}

// Package-level voice classification (bgi_arc.h VoiceArchiveTally): read the
// fixed `bw` header of a bounded, evenly spaced sample of members. A read
// failure counts as a rejected member, never as a voice verdict.
bool ClassifyBgiVoiceArchive(HANDLE file, const uint8_t* index,
                             size_t index_bytes,
                             const ::fushi_voice_hook::bgi::ArcLayout& layout,
                             uint64_t file_size) {
  namespace bgi = ::fushi_voice_hook::bgi;
  bgi::VoiceArchiveTally tally;
  const uint32_t samples = bgi::VoiceClassifySampleCount(layout.count);
  for (uint32_t k = 0; k < samples; ++k) {
    const uint32_t i = bgi::VoiceClassifySampleIndex(layout.count, k);
    bgi::ArcEntry member;
    uint8_t head[64] = {0};
    uint32_t head_bytes = 0;
    if (bgi::ReadArcEntry(index, index_bytes, layout, i, file_size, &member)) {
      head_bytes = member.member_size < sizeof(head)
                       ? member.member_size
                       : static_cast<uint32_t>(sizeof(head));
      LARGE_INTEGER at = {};
      at.QuadPart = static_cast<LONGLONG>(member.member_offset);
      if (head_bytes == 0 ||
          SetFilePointerEx(file, at, nullptr, FILE_BEGIN) == FALSE ||
          !ReadExact(file, head, head_bytes)) {
        head_bytes = 0;
      }
    }
    tally.Add(head, head_bytes, member.member_size);
    if (!tally.IsVoiceArchive()) return false;
  }
  return tally.IsVoiceArchive();
}

void ProcessBgiVoiceTask(BgiVoiceTask* task) {
  namespace bgi = ::fushi_voice_hook::bgi;
  HANDLE file = g_orig_CreateFileW(
      task->path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  LARGE_INTEGER file_size = {};
  uint8_t prefix[bgi::kArcHeaderBytes] = {0};
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  bgi::ArcEntry entry;
  bgi::ArcLayout layout;
  uint32_t ogg_offset = 0;
  uint32_t ogg_size = 0;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, prefix, sizeof(prefix)) &&
               bgi::ParseArcHeader(prefix, sizeof(prefix),
                                   static_cast<uint64_t>(file_size.QuadPart),
                                   &layout) &&
               layout.data_base <= SIZE_MAX &&
               layout.data_base - sizeof(prefix) <= UINT32_MAX;
  if (valid) {
    index = static_cast<uint8_t*>(
        malloc(static_cast<size_t>(layout.data_base)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, prefix, sizeof(prefix));
      valid = ReadExact(
          file, index + sizeof(prefix),
          static_cast<uint32_t>(layout.data_base - sizeof(prefix)));
    }
  }
  if (valid) {
    const uint64_t size = static_cast<uint64_t>(file_size.QuadPart);
    const BgiArchiveVerdict* cached = FindBgiArchiveVerdict(task->path, size);
    bool voice_archive = false;
    if (cached != nullptr) {
      voice_archive = cached->voice;
    } else {
      voice_archive = ClassifyBgiVoiceArchive(
          file, index, static_cast<size_t>(layout.data_base), layout, size);
      RememberBgiArchiveVerdict(task->path, size, voice_archive);
    }
    valid = voice_archive &&
            bgi::FindEntryForRead(index, static_cast<size_t>(layout.data_base),
                                  size, task->read_offset, &entry);
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
            bgi::ParseBwOggHeader(
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
            fushi_voice_hook::siglus::CompleteOggBytes(ogg, ogg_size) ==
                ogg_size;
  }
  const bool duplicate = valid &&
      task->tick_ms - g_bgi_last_tick <= 2000 &&
      g_bgi_last_member == entry.member_offset &&
      _wcsicmp(g_bgi_last_path, task->path) == 0;
  if (valid && !duplicate) {
    wchar_t member_name[bgi::kMaxNameBytes + 1] = {0};
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
          fushi_voice_hook::kDiagBgiArcVoiceCaptured;
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
  if (!fushi_voice_hook::MatchesBgiEthornellProfile(nullptr)) return false;
  const bool ready = TryHookSiglusOvk();
  if (ready) {
    InterlockedExchange(&g_bgi_arc_enabled, 1);
    if (g_header != nullptr) {
      g_header->hook_diagnostics |= fushi_voice_hook::kDiagBgiArcHooksReady;
    }
  }
  return ready;
}

void StopBgiArcVoice() {
  InterlockedExchange(&g_bgi_arc_enabled, 0);
  fushi_voice_hook::ClearTrackedHandles(g_bgi_handles);
}

class BgiEthornellAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "bgi_ethornell"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesBgiEthornellProfile(nullptr);
  }
  bool install() override {
    // 文本道与查词站点只来自 exe 自身结构、与语音归档无关：身份成立就装（语音层失败时
    // 文本照常）。结构不符的映像一个钩子也不装。
    if (probe()) text_installed_ = InstallBgiLookup() || text_installed_;
    ready_ = TryHookBgiArcVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() {
    ProcessBgiVoiceTasks();
    ProcessBgiLookupTick();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (BgiLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // Sites were resolved and rejected: terminal for this executable, so the
    // host gets the digest to report instead of waiting for a gate.
    if (BgiLookupSitesRejected()) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                fushi_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
    // The registry only asks after probe() held (identity is structural).
    report.state = fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownBgiLookup();
    text_installed_ = false;
    StopBgiArcVoice();
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
  bool text_installed_ = false;
};

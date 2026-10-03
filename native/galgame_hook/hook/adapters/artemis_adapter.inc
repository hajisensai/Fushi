// Artemis Engine PF8 clean voice capture. The PF8 index is parsed once on the
// hook worker before the game resumes, for every archive of the set (.pfs,
// .pfs.000, ...). ReadFile callbacks only binary-search an
// immutable table and enqueue bounded {entry, tick} metadata. File IO, XOR
// decryption, Ogg validation and output remain on AdapterRegistry::Poll.
// The in-game lookup provider (glyph geometry + click claim) lives in
// artemis_lookup.inc; its structural rules are in artemis_lookup_core.h.
#include "artemis_profile.h"
#include "artemis_lookup.inc"

constexpr size_t kArtemisPathChars = 520;
constexpr size_t kArtemisNameBytes = 192;
constexpr int kArtemisArchiveSlots = 16;
constexpr int kArtemisHandleSlots = 16;
constexpr int kArtemisTaskSlots = 32;
constexpr size_t kArtemisSha1Bytes = 20;

struct ArtemisVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  char name[kArtemisNameBytes] = {0};
};

// One archive of the game's archive set (`<name>.pfs`, `<name>.pfs.000`, ...).
// Offsets are relative to its own file and PF8 keys are per index, so a voice
// read is resolved against the archive whose handle it came from.  Filled on
// the worker before g_artemis_enabled is set; immutable while enabled.
struct ArtemisArchive {
  wchar_t path[kArtemisPathChars] = {0};
  uint8_t key[kArtemisSha1Bytes] = {0};
  bool encrypted = false;
  ArtemisVoiceRange* ranges = nullptr;
  LONG range_count = 0;
};

// A handle slot being filled; never equal to a real file handle.
const HANDLE kArtemisSlotReserved =
    reinterpret_cast<HANDLE>(static_cast<intptr_t>(-3));

struct ArtemisPfsHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG archive = 0;  // written before `handle` is published
};

struct ArtemisVoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint32_t archive = 0;
  uint32_t entry_index = 0;
  uint64_t selected_thread_id = 0;  // text selection when the read happened
  uint64_t baseline_text_seq = 0;   // text_write_count when the read happened
};

ArtemisArchive g_artemis_archives[kArtemisArchiveSlots];
volatile LONG g_artemis_archive_count = 0;
ArtemisPfsHandle g_artemis_handles[kArtemisHandleSlots];
ArtemisVoiceTask g_artemis_tasks[kArtemisTaskSlots];
volatile LONG g_artemis_enabled = 0;
uint32_t g_artemis_last_archive = UINT32_MAX;
uint64_t g_artemis_last_offset = UINT64_MAX;
uint64_t g_artemis_last_tick = 0;

bool ComputeArtemisSha1(const uint8_t* data, uint32_t size,
                        uint8_t* output) {
  if (data == nullptr || size == 0 || output == nullptr) return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_bytes = 0;
  DWORD result_bytes = 0;
  uint8_t* object = nullptr;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA1_ALGORITHM,
                                        nullptr, 0) >= 0 &&
            BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                              reinterpret_cast<PUCHAR>(&object_bytes),
                              sizeof(object_bytes), &result_bytes, 0) >= 0 &&
            object_bytes > 0;
  if (ok) {
    object = static_cast<uint8_t*>(malloc(object_bytes));
    ok = object != nullptr &&
         BCryptCreateHash(algorithm, &hash, object, object_bytes, nullptr, 0,
                          0) >= 0 &&
         BCryptHashData(hash, const_cast<PUCHAR>(data), size, 0) >= 0 &&
         BCryptFinishHash(hash, output, kArtemisSha1Bytes, 0) >= 0;
  }
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  free(object);
  return ok;
}

bool LoadArtemisPfsIndex(const wchar_t* path,
                         std::vector<ArtemisVoiceRange>* ranges,
                         uint8_t* key, bool* encrypted) {
  if (path == nullptr || ranges == nullptr || key == nullptr ||
      encrypted == nullptr) {
    return false;
  }
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER file_size = {};
  uint8_t header[fushi_voice_hook::artemis::kMinimumHeaderBytes] = {0};
  fushi_voice_hook::artemis::IndexInfo info;
  uint8_t* index = nullptr;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, header, sizeof(header)) &&
               fushi_voice_hook::artemis::ParseIndexInfo(
                   header, sizeof(header), &info) &&
               info.total_bytes <= static_cast<uint64_t>(file_size.QuadPart) &&
               info.total_bytes <= UINT32_MAX;
  if (valid) {
    index = static_cast<uint8_t*>(malloc(info.total_bytes));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, header, sizeof(header));
      valid = ReadExact(file, index + sizeof(header),
                        static_cast<uint32_t>(info.total_bytes - sizeof(header)));
    }
  }
  if (valid) {
    fushi_voice_hook::artemis::EntryCursor cursor;
    valid = fushi_voice_hook::artemis::BeginEntries(
        index, info.total_bytes, &cursor, &info);
    for (uint32_t i = 0; valid && i < info.entry_count; ++i) {
      fushi_voice_hook::artemis::EntryView entry;
      valid = fushi_voice_hook::artemis::NextEntry(
          &cursor, static_cast<uint64_t>(file_size.QuadPart), &entry);
      if (!valid || !fushi_voice_hook::artemis::IsVoiceOgg(entry)) continue;
      ArtemisVoiceRange range;
      range.offset = entry.offset;
      range.size = entry.size;
      const size_t name_bytes = (std::min)(
          fushi_voice_hook::artemis::TrimmedNameLength(entry),
          kArtemisNameBytes - 1);
      memcpy(range.name, entry.name, name_bytes);
      range.name[name_bytes] = 0;
      ranges->push_back(range);
    }
  }
  if (valid && ranges->empty()) valid = false;
  if (valid) {
    std::sort(ranges->begin(), ranges->end(),
              [](const ArtemisVoiceRange& left,
                 const ArtemisVoiceRange& right) {
                return left.offset < right.offset;
              });
    *encrypted = info.format == fushi_voice_hook::artemis::Format::kPf8;
    if (*encrypted) {
      valid = ComputeArtemisSha1(
          index + fushi_voice_hook::artemis::kIndexDataStart,
          info.index_size, key);
    } else {
      memset(key, 0, kArtemisSha1Bytes);
    }
  }
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

// Indexes every voice-bearing archive of the set next to the executable.
// Stopping at the first one misses the dialogue voices whenever they live in
// a continuation archive.
bool FindAndLoadArtemisPfs() {
  wchar_t executable[kArtemisPathChars] = {0};
  if (GetModuleFileNameW(nullptr, executable, kArtemisPathChars) == 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring pattern = std::wstring(executable) + L"\\*.pfs*";
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  LONG loaded = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        !fushi_voice_hook::artemis::IsArchiveSetLeaf(found.cFileName)) {
      continue;
    }
    const std::wstring path = std::wstring(executable) + L"\\" + found.cFileName;
    if (path.size() >= kArtemisPathChars) continue;
    std::vector<ArtemisVoiceRange> ranges;
    ArtemisArchive& archive = g_artemis_archives[loaded];
    if (!LoadArtemisPfsIndex(path.c_str(), &ranges, archive.key,
                             &archive.encrypted)) {
      continue;
    }
    archive.ranges = static_cast<ArtemisVoiceRange*>(
        malloc(ranges.size() * sizeof(ArtemisVoiceRange)));
    if (archive.ranges == nullptr) continue;
    memcpy(archive.ranges, ranges.data(),
           ranges.size() * sizeof(ArtemisVoiceRange));
    archive.range_count = static_cast<LONG>(ranges.size());
    wcsncpy_s(archive.path, path.c_str(), _TRUNCATE);
    ++loaded;
  } while (loaded < kArtemisArchiveSlots && FindNextFileW(search, &found));
  FindClose(search);
  InterlockedExchange(&g_artemis_archive_count, loaded);
  return loaded != 0;
}

const wchar_t* ArtemisPathLeaf(const wchar_t* path) {
  if (path == nullptr) return L"";
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash)) {
    slash = forward;
  }
  return slash == nullptr ? path : slash + 1;
}

// Index of the loaded archive `path` names, or -1.
LONG FindArtemisArchive(const wchar_t* path) {
  if (path == nullptr || *path == 0) return -1;
  const LONG count = InterlockedCompareExchange(&g_artemis_archive_count, 0, 0);
  for (LONG i = 0; i < count; ++i) {
    const wchar_t* loaded = g_artemis_archives[i].path;
    if (_wcsicmp(path, loaded) == 0 ||
        _wcsicmp(ArtemisPathLeaf(path), ArtemisPathLeaf(loaded)) == 0) {
      return i;
    }
  }
  return -1;
}

void RememberArtemisPfs(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_artemis_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE) {
    return;
  }
  const LONG archive = FindArtemisArchive(path);
  if (archive < 0) return;
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_artemis_handles[i].handle);
    const HANDLE current = static_cast<HANDLE>(
        InterlockedCompareExchangePointer(slot, nullptr, nullptr));
    if (current == handle) return;
    // Reserve the slot, then fill `archive`, then publish the handle: a
    // reader that matches the handle always sees its own archive.
    if (current != INVALID_HANDLE_VALUE ||
        InterlockedCompareExchangePointer(slot, kArtemisSlotReserved,
                                          INVALID_HANDLE_VALUE) !=
            INVALID_HANDLE_VALUE) {
      continue;
    }
    InterlockedExchange(&g_artemis_handles[i].archive, archive);
    InterlockedExchangePointer(slot, handle);
    return;
  }
}

// Archive index of a remembered handle, or -1.
LONG FindArtemisPfsHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return -1;
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_artemis_handles[i].handle);
    if (InterlockedCompareExchangePointer(slot, nullptr, nullptr) == handle) {
      return InterlockedCompareExchange(&g_artemis_handles[i].archive, 0, 0);
    }
  }
  return -1;
}

void ForgetArtemisPfs(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return;
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_artemis_handles[i].handle);
    if (InterlockedCompareExchangePointer(
            slot, INVALID_HANDLE_VALUE, handle) == handle) {
      return;
    }
  }
}

void QueueArtemisVoice(uint32_t archive, uint32_t entry_index) {
  for (int i = 0; i < kArtemisTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_artemis_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_artemis_tasks[i].tick_ms = GetTickCount64();
    g_artemis_tasks[i].archive = archive;
    g_artemis_tasks[i].entry_index = entry_index;
    const uint64_t selected = fushi_voice_hook::SelectedTextThreadId(g_header);
    g_artemis_tasks[i].selected_thread_id = selected;
    g_artemis_tasks[i].baseline_text_seq =
        selected != 0 && g_header != nullptr
            ? fushi_voice_hook::AtomicLoadPreview64(&g_header->text_write_count)
            : 0;
    InterlockedExchange(&g_artemis_tasks[i].state, 2);
    return;
  }
}

void ObserveArtemisPfsRead(HANDLE file, DWORD done, LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_artemis_enabled, 0, 0) == 0 || done == 0) {
    return;
  }
  const LONG archive = FindArtemisPfsHandle(file);
  if (archive < 0 ||
      archive >= InterlockedCompareExchange(&g_artemis_archive_count, 0, 0)) {
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
  const long entry = fushi_voice_hook::artemis::FindRangeStartingAt(
      g_artemis_archives[archive].ranges,
      g_artemis_archives[archive].range_count, start);
  if (entry >= 0) {
    QueueArtemisVoice(static_cast<uint32_t>(archive),
                      static_cast<uint32_t>(entry));
  }
}

// Artemis runs a block's {"vo"} before drawing its text, so the voice member
// is read shortly before the line is published (kArtemisFollowingTextWindowMs).
// Returns false while that line may still arrive; the task then stays queued.
bool ProcessArtemisVoiceTask(ArtemisVoiceTask* task) {
  const LONG archives =
      InterlockedCompareExchange(&g_artemis_archive_count, 0, 0);
  if (task == nullptr || task->archive >= static_cast<uint32_t>(archives)) {
    return true;
  }
  const ArtemisArchive& archive = g_artemis_archives[task->archive];
  if (archive.ranges == nullptr ||
      task->entry_index >= static_cast<uint32_t>(archive.range_count)) {
    return true;
  }
  const ArtemisVoiceRange range = archive.ranges[task->entry_index];
  if (range.offset == g_artemis_last_offset &&
      task->archive == g_artemis_last_archive &&
      task->tick_ms >= g_artemis_last_tick &&
      task->tick_ms - g_artemis_last_tick <= 2000) {
    return true;
  }
  fushi_voice_hook::VoiceTextCandidate
      candidates[fushi_voice_hook::kTextLaneSlotCount] = {};
  const size_t candidate_count =
      CollectSelectedLaneCandidates(task->selected_thread_id, candidates);
  const auto decision = fushi_voice_hook::ResolveFollowingSelectedText(
      task->tick_ms,
      task->tick_ms + fushi_voice_hook::kArtemisFollowingTextWindowMs,
      GetTickCount64(), task->selected_thread_id, task->baseline_text_seq,
      candidates, candidate_count);
  if (decision.state == fushi_voice_hook::VoiceResourcePairState::kWait) {
    return false;
  }
  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return true;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  uint8_t* ogg = static_cast<uint8_t*>(malloc(range.size));
  bool valid = ogg != nullptr &&
               SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
               ReadExact(file, ogg, range.size);
  if (valid && archive.encrypted) {
    for (uint32_t i = 0; i < range.size; ++i) {
      ogg[i] ^= archive.key[i % kArtemisSha1Bytes];
    }
  }
  valid = valid &&
      fushi_voice_hook::siglus::CompleteOggBytes(ogg, range.size) == range.size;
  if (valid) {
    wchar_t name[kArtemisNameBytes] = {0};
    int converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        range.name, -1, name,
                                        static_cast<int>(kArtemisNameBytes));
    if (converted == 0) {
      MultiByteToWideChar(CP_ACP, 0, range.name, -1, name,
                          static_cast<int>(kArtemisNameBytes));
    }
    WriteVoiceOggAt(ogg, range.size, name[0] == 0 ? L"voice.ogg" : name,
                    task->tick_ms, decision.text_event_id);
    g_artemis_last_offset = range.offset;
    g_artemis_last_archive = task->archive;
    g_artemis_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          fushi_voice_hook::kDiagArtemisPfsVoiceCaptured;
    }
  }
  free(ogg);
  g_orig_CloseHandle(file);
  return true;
}

void ProcessArtemisVoiceTasks() {
  for (int i = 0; i < kArtemisTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_artemis_tasks[i].state, 3, 2) == 2) {
      const bool done = ProcessArtemisVoiceTask(&g_artemis_tasks[i]);
      InterlockedExchange(&g_artemis_tasks[i].state, done ? 0 : 2);
    }
  }
}

bool TryHookArtemisPfsVoice() {
  if (!fushi_voice_hook::MatchesArtemisProfile(nullptr)) return false;
  const bool hooks_ready = TryHookSiglusOvk();
  if (!hooks_ready || !FindAndLoadArtemisPfs()) return false;
  InterlockedExchange(&g_artemis_enabled, 1);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |= fushi_voice_hook::kDiagArtemisPfsHooksReady;
  }
  return true;
}

void StopArtemisPfsVoice() {
  InterlockedExchange(&g_artemis_enabled, 0);
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(&g_artemis_handles[i].handle),
        INVALID_HANDLE_VALUE);
  }
  const LONG count = InterlockedExchange(&g_artemis_archive_count, 0);
  for (LONG i = 0; i < count; ++i) {
    free(g_artemis_archives[i].ranges);
    g_artemis_archives[i] = ArtemisArchive();
  }
}

class ArtemisPfsAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "artemis_pfs"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesArtemisProfile(nullptr);
  }
  bool install() override {
    // Lookup first: its sites come from the executable's structure alone and
    // resolve in milliseconds, so its inline hooks land while the injector
    // still holds the game suspended.  The PF8 index parse below reads
    // multi-GB archives and routinely outlives the startup budget; hooks
    // installed after resume race the renderer's D3D initialisation (one run
    // hung with HookWorker inside MinHook's thread freeze, GetThreadContext,
    // while the main thread was compiling shaders).  A rejected image
    // installs nothing.
    if (probe()) InstallArtemisLookup();
    ready_ = TryHookArtemisPfsVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() {
    ProcessArtemisVoiceTasks();
    ProcessArtemisLookupTick();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (ArtemisLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // Sites were resolved and rejected: terminal for this executable, so the
    // host gets the digest to report instead of waiting for a gate.
    if (ArtemisLookupSitesRejected()) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                fushi_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
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
    ShutdownArtemisLookup();
    StopArtemisPfsVoice();
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
};

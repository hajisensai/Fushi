// Artemis Engine PF8 clean voice capture. The PF8 index is parsed once on the
// hook worker before the game resumes. ReadFile callbacks only binary-search an
// immutable table and enqueue bounded {entry, tick} metadata. File IO, XOR
// decryption, Ogg validation and output remain on AdapterRegistry::Poll.
#include "artemis_profile.h"

constexpr size_t kArtemisPathChars = 520;
constexpr size_t kArtemisNameBytes = 192;
constexpr int kArtemisHandleSlots = 8;
constexpr int kArtemisTaskSlots = 32;
constexpr size_t kArtemisSha1Bytes = 20;

struct ArtemisVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  char name[kArtemisNameBytes] = {0};
};

struct ArtemisPfsHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
};

struct ArtemisVoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint32_t entry_index = 0;
};

ArtemisPfsHandle g_artemis_handles[kArtemisHandleSlots];
ArtemisVoiceTask g_artemis_tasks[kArtemisTaskSlots];
ArtemisVoiceRange* g_artemis_ranges = nullptr;
volatile LONG g_artemis_range_count = 0;
volatile LONG g_artemis_enabled = 0;
wchar_t g_artemis_pfs_path[kArtemisPathChars] = {0};
uint8_t g_artemis_key[kArtemisSha1Bytes] = {0};
bool g_artemis_encrypted = false;
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
  uint8_t header[hibiki_voice_hook::artemis::kMinimumHeaderBytes] = {0};
  hibiki_voice_hook::artemis::IndexInfo info;
  uint8_t* index = nullptr;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, header, sizeof(header)) &&
               hibiki_voice_hook::artemis::ParseIndexInfo(
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
    hibiki_voice_hook::artemis::EntryCursor cursor;
    valid = hibiki_voice_hook::artemis::BeginEntries(
        index, info.total_bytes, &cursor, &info);
    for (uint32_t i = 0; valid && i < info.entry_count; ++i) {
      hibiki_voice_hook::artemis::EntryView entry;
      valid = hibiki_voice_hook::artemis::NextEntry(
          &cursor, static_cast<uint64_t>(file_size.QuadPart), &entry);
      if (!valid || !hibiki_voice_hook::artemis::IsVoiceOgg(entry)) continue;
      ArtemisVoiceRange range;
      range.offset = entry.offset;
      range.size = entry.size;
      const size_t name_bytes = (std::min)(
          hibiki_voice_hook::artemis::TrimmedNameLength(entry),
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
    *encrypted = info.format == hibiki_voice_hook::artemis::Format::kPf8;
    if (*encrypted) {
      valid = ComputeArtemisSha1(
          index + hibiki_voice_hook::artemis::kIndexDataStart,
          info.index_size, key);
    } else {
      memset(key, 0, kArtemisSha1Bytes);
    }
  }
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

bool FindAndLoadArtemisPfs() {
  wchar_t executable[kArtemisPathChars] = {0};
  if (GetModuleFileNameW(nullptr, executable, kArtemisPathChars) == 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring pattern = std::wstring(executable) + L"\\*.pfs";
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool loaded = false;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    const std::wstring path = std::wstring(executable) + L"\\" + found.cFileName;
    std::vector<ArtemisVoiceRange> ranges;
    uint8_t key[kArtemisSha1Bytes] = {0};
    bool encrypted = false;
    if (!LoadArtemisPfsIndex(path.c_str(), &ranges, key, &encrypted)) continue;
    auto* published = static_cast<ArtemisVoiceRange*>(
        malloc(ranges.size() * sizeof(ArtemisVoiceRange)));
    if (published == nullptr) continue;
    memcpy(published, ranges.data(), ranges.size() * sizeof(ArtemisVoiceRange));
    g_artemis_ranges = published;
    memcpy(g_artemis_key, key, sizeof(g_artemis_key));
    g_artemis_encrypted = encrypted;
    wcsncpy_s(g_artemis_pfs_path, path.c_str(), _TRUNCATE);
    InterlockedExchange(&g_artemis_range_count,
                        static_cast<LONG>(ranges.size()));
    loaded = true;
    break;
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return loaded;
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

bool IsTargetArtemisPfsPath(const wchar_t* path) {
  if (path == nullptr || *path == 0 || g_artemis_pfs_path[0] == 0) {
    return false;
  }
  return _wcsicmp(path, g_artemis_pfs_path) == 0 ||
         _wcsicmp(ArtemisPathLeaf(path),
                  ArtemisPathLeaf(g_artemis_pfs_path)) == 0;
}

void RememberArtemisPfs(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_artemis_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsTargetArtemisPfsPath(path)) {
    return;
  }
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_artemis_handles[i].handle);
    const HANDLE current = static_cast<HANDLE>(
        InterlockedCompareExchangePointer(slot, nullptr, nullptr));
    if (current == handle) return;
    if (current == INVALID_HANDLE_VALUE &&
        InterlockedCompareExchangePointer(
            slot, handle, INVALID_HANDLE_VALUE) == INVALID_HANDLE_VALUE) {
      return;
    }
  }
}

bool IsArtemisPfsHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return false;
  for (int i = 0; i < kArtemisHandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_artemis_handles[i].handle);
    if (InterlockedCompareExchangePointer(slot, nullptr, nullptr) == handle) {
      return true;
    }
  }
  return false;
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

void QueueArtemisVoice(uint32_t entry_index) {
  for (int i = 0; i < kArtemisTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_artemis_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_artemis_tasks[i].tick_ms = GetTickCount64();
    g_artemis_tasks[i].entry_index = entry_index;
    InterlockedExchange(&g_artemis_tasks[i].state, 2);
    return;
  }
}

void ObserveArtemisPfsRead(HANDLE file, DWORD done, LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_artemis_enabled, 0, 0) == 0 || done == 0 ||
      !IsArtemisPfsHandle(file)) {
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
  const LONG count = InterlockedCompareExchange(&g_artemis_range_count, 0, 0);
  ArtemisVoiceRange* ranges = g_artemis_ranges;
  if (ranges == nullptr || count <= 0) return;
  LONG low = 0;
  LONG high = count;
  while (low < high) {
    const LONG middle = low + (high - low) / 2;
    if (ranges[middle].offset < start) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  LONG candidate = low;
  if (candidate > 0 &&
      ranges[candidate - 1].offset + ranges[candidate - 1].size > start) {
    --candidate;
  }
  if (candidate < count && ranges[candidate].offset < end &&
      ranges[candidate].offset + ranges[candidate].size > start) {
    QueueArtemisVoice(static_cast<uint32_t>(candidate));
  }
}

void ProcessArtemisVoiceTask(ArtemisVoiceTask* task) {
  const LONG count = InterlockedCompareExchange(&g_artemis_range_count, 0, 0);
  if (task == nullptr || task->entry_index >= static_cast<uint32_t>(count) ||
      g_artemis_ranges == nullptr) {
    return;
  }
  const ArtemisVoiceRange range = g_artemis_ranges[task->entry_index];
  if (range.offset == g_artemis_last_offset &&
      task->tick_ms - g_artemis_last_tick <= 2000) {
    return;
  }
  HANDLE file = g_orig_CreateFileW(
      g_artemis_pfs_path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  uint8_t* ogg = static_cast<uint8_t*>(malloc(range.size));
  bool valid = ogg != nullptr &&
               SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
               ReadExact(file, ogg, range.size);
  if (valid && g_artemis_encrypted) {
    for (uint32_t i = 0; i < range.size; ++i) {
      ogg[i] ^= g_artemis_key[i % kArtemisSha1Bytes];
    }
  }
  valid = valid &&
      hibiki_voice_hook::siglus::CompleteOggBytes(ogg, range.size) == range.size;
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
                    task->tick_ms);
    g_artemis_last_offset = range.offset;
    g_artemis_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagArtemisPfsVoiceCaptured;
    }
  }
  free(ogg);
  g_orig_CloseHandle(file);
}

void ProcessArtemisVoiceTasks() {
  for (int i = 0; i < kArtemisTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_artemis_tasks[i].state, 3, 2) == 2) {
      ProcessArtemisVoiceTask(&g_artemis_tasks[i]);
      InterlockedExchange(&g_artemis_tasks[i].state, 0);
    }
  }
}

bool TryHookArtemisPfsVoice() {
  if (!hibiki_voice_hook::MatchesArtemisProfile(nullptr)) return false;
  const bool hooks_ready = TryHookSiglusOvk();
  if (!hooks_ready || !FindAndLoadArtemisPfs()) return false;
  InterlockedExchange(&g_artemis_enabled, 1);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |= hibiki_voice_hook::kDiagArtemisPfsHooksReady;
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
  free(g_artemis_ranges);
  g_artemis_ranges = nullptr;
  InterlockedExchange(&g_artemis_range_count, 0);
}

class ArtemisPfsAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "artemis_pfs"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesArtemisProfile(nullptr);
  }
  bool install() override {
    ready_ = TryHookArtemisPfsVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessArtemisVoiceTasks(); }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopArtemisPfsVoice();
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

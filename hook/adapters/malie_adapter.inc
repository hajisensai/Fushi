// Malie clean voice capture for the measured Dies irae LIBP/CFI release.
// Archive parsing and CFI decryption run on the worker. ReadFile callbacks
// only match immutable archive ranges and enqueue fixed-size metadata.
#include "malie_profile.h"

constexpr size_t kMaliePathChars = 520;
constexpr size_t kMalieNameBytes =
    hibiki_voice_hook::malie::kLibpNameBytes + 1;
constexpr int kMalieArchiveSlots = 8;
constexpr int kMalieHandleSlots = 16;
constexpr int kMalieMappingSlots = 16;
constexpr int kMalieTaskSlots = 32;

struct MalieVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  char name[kMalieNameBytes] = {0};
};

struct MalieArchive {
  wchar_t path[kMaliePathChars] = {0};
  uint64_t file_size = 0;
  MalieVoiceRange* ranges = nullptr;
  uint32_t range_count = 0;
};

struct MalieHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  uint32_t archive_index = 0;
};

struct MalieMapping {
  HANDLE handle = INVALID_HANDLE_VALUE;
  uint32_t archive_index = 0;
};

struct MalieVoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint32_t archive_index = 0;
  uint32_t entry_index = 0;
};

MalieArchive g_malie_archives[kMalieArchiveSlots];
MalieHandle g_malie_handles[kMalieHandleSlots];
MalieMapping g_malie_mappings[kMalieMappingSlots];
MalieVoiceTask g_malie_tasks[kMalieTaskSlots];
volatile LONG g_malie_archive_count = 0;
volatile LONG g_malie_enabled = 0;
uint64_t g_malie_last_archive_offset = UINT64_MAX;
uint64_t g_malie_last_tick = 0;

void QueueMalieVoice(uint32_t archive_index, uint32_t entry_index);

const wchar_t* MaliePathLeaf(const wchar_t* path) {
  if (path == nullptr) return L"";
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash)) {
    slash = forward;
  }
  return slash == nullptr ? path : slash + 1;
}

bool HasMalieArchiveName(const wchar_t* path) {
  const wchar_t* leaf = MaliePathLeaf(path);
  return _wcsicmp(leaf, L"data2.dat") == 0;
}

bool LoadMalieArchive(const wchar_t* path, MalieArchive* archive) {
  if (path == nullptr || archive == nullptr) return false;
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  LARGE_INTEGER file_size = {};
  uint8_t encrypted_header[hibiki_voice_hook::malie::kLibpHeaderBytes] = {};
  uint8_t decrypted_header[hibiki_voice_hook::malie::kLibpHeaderBytes] = {};
  hibiki_voice_hook::malie::LibpHeader header;
  uint8_t* encrypted_index = nullptr;
  uint8_t* decrypted_index = nullptr;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, encrypted_header, sizeof(encrypted_header));
  if (valid) {
    hibiki_voice_hook::malie::DecryptCfiBlock(0, encrypted_header,
                                              decrypted_header);
    valid = hibiki_voice_hook::malie::ParseLibpHeader(
        decrypted_header, sizeof(decrypted_header),
        static_cast<uint64_t>(file_size.QuadPart), &header);
  }

  uint64_t encrypted_index_bytes = 0;
  if (valid) {
    encrypted_index_bytes = hibiki_voice_hook::malie::AlignUp(
        header.index_bytes, static_cast<uint64_t>(16));
    valid = encrypted_index_bytes <=
                static_cast<uint64_t>(file_size.QuadPart) &&
            encrypted_index_bytes <= UINT32_MAX;
  }
  if (valid) {
    encrypted_index =
        static_cast<uint8_t*>(malloc(static_cast<size_t>(encrypted_index_bytes)));
    decrypted_index =
        static_cast<uint8_t*>(malloc(static_cast<size_t>(encrypted_index_bytes)));
    valid = encrypted_index != nullptr && decrypted_index != nullptr;
  }
  if (valid) {
    LARGE_INTEGER zero = {};
    valid = SetFilePointerEx(file, zero, nullptr, FILE_BEGIN) != FALSE &&
            ReadExact(file, encrypted_index,
                      static_cast<uint32_t>(encrypted_index_bytes)) &&
            hibiki_voice_hook::malie::DecryptCfiRange(
                0, encrypted_index, static_cast<size_t>(encrypted_index_bytes),
                decrypted_index);
  }

  std::vector<MalieVoiceRange> ranges;
  for (uint32_t i = 0; valid && i < header.entry_count; ++i) {
    hibiki_voice_hook::malie::LibpEntryView entry;
    valid = hibiki_voice_hook::malie::ParseLibpEntry(
        decrypted_index, static_cast<size_t>(encrypted_index_bytes), header, i,
        static_cast<uint64_t>(file_size.QuadPart), &entry);
    if (!valid || !hibiki_voice_hook::malie::IsVoiceOgg(entry)) continue;
    const uint64_t encrypted_member_bytes = hibiki_voice_hook::malie::AlignUp(
        entry.size, static_cast<uint64_t>(16));
    if (encrypted_member_bytes >
        static_cast<uint64_t>(file_size.QuadPart) - entry.member_offset) {
      continue;
    }
    MalieVoiceRange range;
    range.offset = entry.member_offset;
    range.size = entry.size;
    const size_t name_bytes =
        (std::min)(entry.name_length, kMalieNameBytes - 1);
    memcpy(range.name, entry.name, name_bytes);
    range.name[name_bytes] = 0;
    ranges.push_back(range);
  }
  if (valid && ranges.empty()) valid = false;
  if (valid) {
    std::sort(ranges.begin(), ranges.end(),
              [](const MalieVoiceRange& left, const MalieVoiceRange& right) {
                return left.offset < right.offset;
              });
    archive->ranges = static_cast<MalieVoiceRange*>(
        malloc(ranges.size() * sizeof(MalieVoiceRange)));
    valid = archive->ranges != nullptr;
    if (valid) {
      memcpy(archive->ranges, ranges.data(),
             ranges.size() * sizeof(MalieVoiceRange));
      archive->range_count = static_cast<uint32_t>(ranges.size());
      archive->file_size = static_cast<uint64_t>(file_size.QuadPart);
      wcsncpy_s(archive->path, path, _TRUNCATE);
    }
  }

  free(decrypted_index);
  free(encrypted_index);
  g_orig_CloseHandle(file);
  return valid;
}

bool FindAndLoadMalieArchives() {
  wchar_t executable[kMaliePathChars] = {0};
  if (GetModuleFileNameW(nullptr, executable, kMaliePathChars) == 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring path = std::wstring(executable) + L"\\data2.dat";
  const LONG count = LoadMalieArchive(path.c_str(), &g_malie_archives[0]) ? 1 : 0;
  InterlockedExchange(&g_malie_archive_count, count);
  return count > 0;
}

int FindMalieArchiveByPath(const wchar_t* path) {
  if (path == nullptr || !HasMalieArchiveName(path)) return -1;
  const wchar_t* leaf = MaliePathLeaf(path);
  const LONG count = InterlockedCompareExchange(&g_malie_archive_count, 0, 0);
  for (LONG i = 0; i < count; ++i) {
    if (_wcsicmp(leaf, MaliePathLeaf(g_malie_archives[i].path)) == 0) {
      return static_cast<int>(i);
    }
  }
  return -1;
}

void RememberMalieArchive(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE) {
    return;
  }
  const int archive_index = FindMalieArchiveByPath(path);
  if (archive_index < 0) return;
  const HANDLE reserved = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
  for (int i = 0; i < kMalieHandleSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_handles[i].handle);
    const HANDLE current = static_cast<HANDLE>(
        InterlockedCompareExchangePointer(slot, nullptr, nullptr));
    if (current == handle) return;
    if (current != INVALID_HANDLE_VALUE) continue;
    if (InterlockedCompareExchangePointer(slot, reserved,
                                          INVALID_HANDLE_VALUE) ==
        INVALID_HANDLE_VALUE) {
      g_malie_handles[i].archive_index = static_cast<uint32_t>(archive_index);
      InterlockedExchangePointer(slot, handle);
      if (g_header != nullptr) {
        g_header->reserved_hook_diagnostics |=
            hibiki_voice_hook::kDiagMalieArchiveHandleTracked;
      }
      return;
    }
  }
}

int FindMalieArchiveByHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return -1;
  for (int i = 0; i < kMalieHandleSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_handles[i].handle);
    if (InterlockedCompareExchangePointer(slot, nullptr, nullptr) == handle) {
      return static_cast<int>(g_malie_handles[i].archive_index);
    }
  }
  return -1;
}

int ResolveMalieArchiveByHandle(HANDLE handle) {
  int archive_index = FindMalieArchiveByHandle(handle);
  if (archive_index >= 0 || GetFileType(handle) != FILE_TYPE_DISK) {
    return archive_index;
  }
  wchar_t path[kMaliePathChars] = {0};
  const DWORD chars = GetFinalPathNameByHandleW(
      handle, path, kMaliePathChars, FILE_NAME_NORMALIZED);
  if (chars == 0 || chars >= kMaliePathChars) return -1;
  RememberMalieArchive(handle, path);
  return FindMalieArchiveByHandle(handle);
}

void RememberMalieMapping(HANDLE mapping, HANDLE file) {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0 ||
      mapping == nullptr || mapping == INVALID_HANDLE_VALUE) {
    return;
  }
  const int archive_index = ResolveMalieArchiveByHandle(file);
  if (archive_index < 0) return;
  const HANDLE reserved = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
  for (int i = 0; i < kMalieMappingSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_mappings[i].handle);
    const HANDLE current = static_cast<HANDLE>(
        InterlockedCompareExchangePointer(slot, nullptr, nullptr));
    if (current == mapping) return;
    if (current != INVALID_HANDLE_VALUE) continue;
    if (InterlockedCompareExchangePointer(slot, reserved,
                                          INVALID_HANDLE_VALUE) ==
        INVALID_HANDLE_VALUE) {
      g_malie_mappings[i].archive_index =
          static_cast<uint32_t>(archive_index);
      InterlockedExchangePointer(slot, mapping);
      if (g_header != nullptr) {
        g_header->reserved_hook_diagnostics |=
            hibiki_voice_hook::kDiagMalieMappingTracked;
      }
      return;
    }
  }
}

void ForgetMalieMapping(HANDLE handle) {
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) return;
  for (int i = 0; i < kMalieMappingSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_mappings[i].handle);
    if (InterlockedCompareExchangePointer(slot, INVALID_HANDLE_VALUE, handle) ==
        handle) {
      return;
    }
  }
}

void ObserveMalieMappedRange(HANDLE mapping, uint64_t offset, SIZE_T bytes) {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0 ||
      bytes == 0 || bytes > hibiki_voice_hook::malie::kMaxVoiceBytes) {
    return;
  }
  int archive_index = -1;
  for (int i = 0; i < kMalieMappingSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_mappings[i].handle);
    if (InterlockedCompareExchangePointer(slot, nullptr, nullptr) == mapping) {
      archive_index = static_cast<int>(g_malie_mappings[i].archive_index);
      break;
    }
  }
  const LONG archive_count =
      InterlockedCompareExchange(&g_malie_archive_count, 0, 0);
  if (archive_index < 0 || archive_index >= archive_count) return;
  const uint64_t end = offset + static_cast<uint64_t>(bytes);
  if (end < offset) return;
  const MalieArchive& archive = g_malie_archives[archive_index];
  for (uint32_t i = 0; i < archive.range_count; ++i) {
    const MalieVoiceRange& range = archive.ranges[i];
    if (range.offset >= end) break;
    if (range.offset + range.size > offset) {
      if (g_header != nullptr) {
        g_header->reserved_hook_diagnostics |=
            hibiki_voice_hook::kDiagMalieMappedRangeObserved |
            hibiki_voice_hook::kDiagMalieVoiceRangeQueued;
      }
      QueueMalieVoice(static_cast<uint32_t>(archive_index), i);
      return;
    }
  }
}

void ForgetMalieArchive(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return;
  for (int i = 0; i < kMalieHandleSlots; ++i) {
    auto* slot =
        reinterpret_cast<PVOID volatile*>(&g_malie_handles[i].handle);
    if (InterlockedCompareExchangePointer(slot, INVALID_HANDLE_VALUE, handle) ==
        handle) {
      return;
    }
  }
}

void QueueMalieVoice(uint32_t archive_index, uint32_t entry_index) {
  for (int i = 0; i < kMalieTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_malie_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_malie_tasks[i].tick_ms = GetTickCount64();
    g_malie_tasks[i].archive_index = archive_index;
    g_malie_tasks[i].entry_index = entry_index;
    InterlockedExchange(&g_malie_tasks[i].state, 2);
    return;
  }
}

void ObserveMalieArchiveRange(HANDLE file, uint64_t start, uint64_t bytes) {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0 || bytes == 0) {
    return;
  }
  const int archive_index = ResolveMalieArchiveByHandle(file);
  const LONG archive_count =
      InterlockedCompareExchange(&g_malie_archive_count, 0, 0);
  if (archive_index < 0 || archive_index >= archive_count) return;
  const uint64_t end = start + bytes;
  if (end < start) return;
  const MalieArchive& archive = g_malie_archives[archive_index];
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagMalieReadRangeObserved;
  }
  uint32_t low = 0;
  uint32_t high = archive.range_count;
  while (low < high) {
    const uint32_t middle = low + (high - low) / 2;
    if (archive.ranges[middle].offset < start) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  uint32_t candidate = low;
  if (candidate > 0 &&
      archive.ranges[candidate - 1].offset +
              archive.ranges[candidate - 1].size > start) {
    --candidate;
  }
  if (candidate < archive.range_count &&
      archive.ranges[candidate].offset < end &&
      archive.ranges[candidate].offset + archive.ranges[candidate].size >
          start) {
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagMalieVoiceRangeQueued;
    }
    QueueMalieVoice(static_cast<uint32_t>(archive_index), candidate);
  }
}

void ObserveMalieArchiveReadRequest(HANDLE file, DWORD requested,
                                    LPOVERLAPPED overlapped) {
  if (overlapped == nullptr || requested == 0) return;
  const uint64_t start =
      (static_cast<uint64_t>(overlapped->OffsetHigh) << 32) |
      overlapped->Offset;
  ObserveMalieArchiveRange(file, start, requested);
}

void ObserveMalieArchiveRead(HANDLE file, DWORD done, LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0 || done == 0) {
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
  ObserveMalieArchiveRange(file, start, done);
}

void ProcessMalieVoiceTask(MalieVoiceTask* task) {
  const LONG archive_count =
      InterlockedCompareExchange(&g_malie_archive_count, 0, 0);
  if (task == nullptr ||
      task->archive_index >= static_cast<uint32_t>(archive_count)) {
    return;
  }
  const MalieArchive& archive = g_malie_archives[task->archive_index];
  if (task->entry_index >= archive.range_count) return;
  const MalieVoiceRange range = archive.ranges[task->entry_index];
  const uint64_t archive_offset =
      (static_cast<uint64_t>(task->archive_index) << 56) ^ range.offset;
  if (archive_offset == g_malie_last_archive_offset &&
      task->tick_ms - g_malie_last_tick <= 2000) {
    return;
  }
  const uint64_t encrypted_bytes64 = hibiki_voice_hook::malie::AlignUp(
      range.size, static_cast<uint64_t>(16));
  if (encrypted_bytes64 > UINT32_MAX ||
      encrypted_bytes64 > archive.file_size - range.offset) {
    return;
  }
  const uint32_t encrypted_bytes = static_cast<uint32_t>(encrypted_bytes64);
  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  uint8_t* encrypted = static_cast<uint8_t*>(malloc(encrypted_bytes));
  uint8_t* ogg = static_cast<uint8_t*>(malloc(encrypted_bytes));
  bool valid = encrypted != nullptr && ogg != nullptr &&
               SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
               ReadExact(file, encrypted, encrypted_bytes) &&
               hibiki_voice_hook::malie::DecryptCfiRange(
                   range.offset, encrypted, encrypted_bytes, ogg) &&
               hibiki_voice_hook::siglus::CompleteOggBytes(ogg, range.size) ==
                   range.size;
  if (valid) {
    wchar_t name[kMalieNameBytes] = {0};
    MultiByteToWideChar(CP_ACP, 0, range.name, -1, name,
                        static_cast<int>(kMalieNameBytes));
    WriteVoiceOggAt(ogg, range.size, name[0] == 0 ? L"voice.ogg" : name,
                    task->tick_ms);
    g_malie_last_archive_offset = archive_offset;
    g_malie_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagMalieLibpVoiceCaptured;
    }
  }
  free(ogg);
  free(encrypted);
  g_orig_CloseHandle(file);
}

void ProcessMalieVoiceTasks() {
  for (int i = 0; i < kMalieTaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_malie_tasks[i].state, 3, 2) == 2) {
      ProcessMalieVoiceTask(&g_malie_tasks[i]);
      InterlockedExchange(&g_malie_tasks[i].state, 0);
    }
  }
}

bool TryHookMalieLibpVoice() {
  if (!hibiki_voice_hook::MatchesMalieProfile(nullptr)) return false;
  const bool hooks_ready = TryHookSiglusOvk();
  if (!hooks_ready || !FindAndLoadMalieArchives()) return false;
  InterlockedExchange(&g_malie_enabled, 1);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |= hibiki_voice_hook::kDiagMalieLibpHooksReady;
  }
  return true;
}

void StopMalieLibpVoice() {
  InterlockedExchange(&g_malie_enabled, 0);
  for (int i = 0; i < kMalieHandleSlots; ++i) {
    InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(&g_malie_handles[i].handle),
        INVALID_HANDLE_VALUE);
  }
  for (int i = 0; i < kMalieMappingSlots; ++i) {
    InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(&g_malie_mappings[i].handle),
        INVALID_HANDLE_VALUE);
  }
  const LONG archive_count = InterlockedExchange(&g_malie_archive_count, 0);
  for (LONG i = 0; i < archive_count; ++i) {
    free(g_malie_archives[i].ranges);
    g_malie_archives[i] = {};
  }
}

class MalieLibpAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "malie_libp"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesMalieProfile(nullptr);
  }
  bool install() override {
    ready_ = TryHookMalieLibpVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessMalieVoiceTasks(); }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopMalieLibpVoice();
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

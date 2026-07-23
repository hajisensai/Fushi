// CatSystem2 clean voice capture for unencrypted KIF pcm_*.int archives.
// The worker parses all voice archive indices before process resume. ReadFile
// callbacks only match immutable ranges and enqueue fixed-size metadata.
#include "catsystem2_profile.h"

constexpr size_t kCatSystem2PathChars = 520;
constexpr size_t kCatSystem2NameBytes = 64;
constexpr int kCatSystem2ArchiveSlots = 32;
constexpr int kCatSystem2HandleSlots = 32;
constexpr int kCatSystem2TaskSlots = 32;

struct CatSystem2VoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  char name[kCatSystem2NameBytes] = {0};
};

struct CatSystem2Archive {
  wchar_t path[kCatSystem2PathChars] = {0};
  CatSystem2VoiceRange* ranges = nullptr;
  uint32_t range_count = 0;
};

struct CatSystem2Handle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  uint32_t archive_index = 0;
};

struct CatSystem2VoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint32_t archive_index = 0;
  uint32_t entry_index = 0;
};

CatSystem2Archive g_catsystem2_archives[kCatSystem2ArchiveSlots];
CatSystem2Handle g_catsystem2_handles[kCatSystem2HandleSlots];
CatSystem2VoiceTask g_catsystem2_tasks[kCatSystem2TaskSlots];
volatile LONG g_catsystem2_archive_count = 0;
volatile LONG g_catsystem2_enabled = 0;
uint64_t g_catsystem2_last_archive_offset = UINT64_MAX;
uint64_t g_catsystem2_last_tick = 0;

bool HasCatSystem2PcmArchiveName(const wchar_t* path) {
  if (path == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash)) {
    slash = forward;
  }
  const wchar_t* leaf = slash == nullptr ? path : slash + 1;
  const size_t length = wcslen(leaf);
  return length >= 9 && _wcsnicmp(leaf, L"pcm_", 4) == 0 &&
         _wcsicmp(leaf + length - 4, L".int") == 0;
}

const wchar_t* CatSystem2PathLeaf(const wchar_t* path) {
  if (path == nullptr) return L"";
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash)) {
    slash = forward;
  }
  return slash == nullptr ? path : slash + 1;
}

bool LoadCatSystem2Archive(const wchar_t* path, CatSystem2Archive* archive) {
  if (path == nullptr || archive == nullptr) return false;
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER file_size = {};
  uint8_t header_bytes[hibiki_voice_hook::catsystem2::kHeaderBytes] = {0};
  hibiki_voice_hook::catsystem2::Header header;
  uint8_t* index = nullptr;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, header_bytes, sizeof(header_bytes)) &&
               hibiki_voice_hook::catsystem2::ParseHeader(
                   header_bytes, sizeof(header_bytes), &header) &&
               header.index_bytes <= static_cast<uint64_t>(file_size.QuadPart) &&
               header.index_bytes <= UINT32_MAX;
  if (valid) {
    index = static_cast<uint8_t*>(malloc(header.index_bytes));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, header_bytes, sizeof(header_bytes));
      valid = ReadExact(
          file, index + sizeof(header_bytes),
          static_cast<uint32_t>(header.index_bytes - sizeof(header_bytes)));
    }
  }
  std::vector<CatSystem2VoiceRange> ranges;
  bool encrypted = false;
  for (uint32_t i = 0; valid && i < header.entry_count; ++i) {
    hibiki_voice_hook::catsystem2::EntryView entry;
    valid = hibiki_voice_hook::catsystem2::ParseEntry(
        index, header.index_bytes, i,
        static_cast<uint64_t>(file_size.QuadPart), &entry);
    if (!valid) break;
    if (hibiki_voice_hook::catsystem2::IsEncryptionKey(entry)) {
      encrypted = true;
      continue;
    }
    if (!hibiki_voice_hook::catsystem2::IsVoiceOgg(entry)) continue;
    CatSystem2VoiceRange range;
    range.offset = entry.offset;
    range.size = entry.size;
    const size_t name_bytes =
        (std::min)(entry.name_length, kCatSystem2NameBytes - 1);
    memcpy(range.name, entry.name, name_bytes);
    range.name[name_bytes] = 0;
    ranges.push_back(range);
  }
  if (valid && (encrypted || ranges.empty())) valid = false;
  if (valid) {
    std::sort(ranges.begin(), ranges.end(),
              [](const CatSystem2VoiceRange& left,
                 const CatSystem2VoiceRange& right) {
                return left.offset < right.offset;
              });
    archive->ranges = static_cast<CatSystem2VoiceRange*>(
        malloc(ranges.size() * sizeof(CatSystem2VoiceRange)));
    valid = archive->ranges != nullptr;
    if (valid) {
      memcpy(archive->ranges, ranges.data(),
             ranges.size() * sizeof(CatSystem2VoiceRange));
      archive->range_count = static_cast<uint32_t>(ranges.size());
      wcsncpy_s(archive->path, path, _TRUNCATE);
    }
  }
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

bool FindAndLoadCatSystem2Archives() {
  wchar_t executable[kCatSystem2PathChars] = {0};
  if (GetModuleFileNameW(nullptr, executable, kCatSystem2PathChars) == 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring pattern = std::wstring(executable) + L"\\pcm_*.int";
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  LONG count = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        count >= kCatSystem2ArchiveSlots) {
      continue;
    }
    const std::wstring path = std::wstring(executable) + L"\\" + found.cFileName;
    if (LoadCatSystem2Archive(path.c_str(), &g_catsystem2_archives[count])) {
      ++count;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  InterlockedExchange(&g_catsystem2_archive_count, count);
  return count > 0;
}

int FindCatSystem2ArchiveByPath(const wchar_t* path) {
  if (path == nullptr || !HasCatSystem2PcmArchiveName(path)) return -1;
  const wchar_t* leaf = CatSystem2PathLeaf(path);
  const LONG count =
      InterlockedCompareExchange(&g_catsystem2_archive_count, 0, 0);
  for (LONG i = 0; i < count; ++i) {
    const wchar_t* target = CatSystem2PathLeaf(g_catsystem2_archives[i].path);
    if (_wcsicmp(leaf, target) == 0) return static_cast<int>(i);
  }
  return -1;
}

void RememberCatSystem2Pcm(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_catsystem2_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE) {
    return;
  }
  const int archive_index = FindCatSystem2ArchiveByPath(path);
  if (archive_index < 0) return;
  const HANDLE reserved =
      reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
  for (int i = 0; i < kCatSystem2HandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_catsystem2_handles[i].handle);
    const HANDLE current = static_cast<HANDLE>(
        InterlockedCompareExchangePointer(slot, nullptr, nullptr));
    if (current == handle) return;
    if (current != INVALID_HANDLE_VALUE) continue;
    if (InterlockedCompareExchangePointer(
            slot, reserved, INVALID_HANDLE_VALUE) == INVALID_HANDLE_VALUE) {
      g_catsystem2_handles[i].archive_index =
          static_cast<uint32_t>(archive_index);
      InterlockedExchangePointer(slot, handle);
      return;
    }
  }
}

int FindCatSystem2ArchiveByHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return -1;
  for (int i = 0; i < kCatSystem2HandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_catsystem2_handles[i].handle);
    if (InterlockedCompareExchangePointer(slot, nullptr, nullptr) == handle) {
      return static_cast<int>(g_catsystem2_handles[i].archive_index);
    }
  }
  return -1;
}

void ForgetCatSystem2Pcm(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return;
  for (int i = 0; i < kCatSystem2HandleSlots; ++i) {
    auto* slot = reinterpret_cast<PVOID volatile*>(
        &g_catsystem2_handles[i].handle);
    if (InterlockedCompareExchangePointer(
            slot, INVALID_HANDLE_VALUE, handle) == handle) {
      return;
    }
  }
}

void QueueCatSystem2Voice(uint32_t archive_index, uint32_t entry_index) {
  for (int i = 0; i < kCatSystem2TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_catsystem2_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    g_catsystem2_tasks[i].tick_ms = GetTickCount64();
    g_catsystem2_tasks[i].archive_index = archive_index;
    g_catsystem2_tasks[i].entry_index = entry_index;
    InterlockedExchange(&g_catsystem2_tasks[i].state, 2);
    return;
  }
}

void ObserveCatSystem2PcmRead(HANDLE file, DWORD done,
                             LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_catsystem2_enabled, 0, 0) == 0 ||
      done == 0) {
    return;
  }
  const int archive_index = FindCatSystem2ArchiveByHandle(file);
  const LONG archive_count =
      InterlockedCompareExchange(&g_catsystem2_archive_count, 0, 0);
  if (archive_index < 0 || archive_index >= archive_count) return;
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
  const CatSystem2Archive& archive = g_catsystem2_archives[archive_index];
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
    QueueCatSystem2Voice(static_cast<uint32_t>(archive_index), candidate);
  }
}

void ProcessCatSystem2VoiceTask(CatSystem2VoiceTask* task) {
  const LONG archive_count =
      InterlockedCompareExchange(&g_catsystem2_archive_count, 0, 0);
  if (task == nullptr || task->archive_index >=
                             static_cast<uint32_t>(archive_count)) {
    return;
  }
  const CatSystem2Archive& archive = g_catsystem2_archives[task->archive_index];
  if (task->entry_index >= archive.range_count) return;
  const CatSystem2VoiceRange range = archive.ranges[task->entry_index];
  const uint64_t archive_offset =
      (static_cast<uint64_t>(task->archive_index) << 32) | range.offset;
  if (archive_offset == g_catsystem2_last_archive_offset &&
      task->tick_ms - g_catsystem2_last_tick <= 2000) {
    return;
  }
  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  uint8_t* ogg = static_cast<uint8_t*>(malloc(range.size));
  bool valid = ogg != nullptr &&
               SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
               ReadExact(file, ogg, range.size) &&
               hibiki_voice_hook::siglus::CompleteOggBytes(ogg, range.size) ==
                   range.size;
  if (valid) {
    wchar_t name[kCatSystem2NameBytes] = {0};
    MultiByteToWideChar(932, 0, range.name, -1, name,
                        static_cast<int>(kCatSystem2NameBytes));
    WriteVoiceOggAt(ogg, range.size, name[0] == 0 ? L"voice.ogg" : name,
                    task->tick_ms);
    g_catsystem2_last_archive_offset = archive_offset;
    g_catsystem2_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          hibiki_voice_hook::kDiagCatSystem2PcmVoiceCaptured;
    }
  }
  free(ogg);
  g_orig_CloseHandle(file);
}

void ProcessCatSystem2VoiceTasks() {
  for (int i = 0; i < kCatSystem2TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_catsystem2_tasks[i].state, 3, 2) == 2) {
      ProcessCatSystem2VoiceTask(&g_catsystem2_tasks[i]);
      InterlockedExchange(&g_catsystem2_tasks[i].state, 0);
    }
  }
}

bool TryHookCatSystem2PcmVoice() {
  if (!hibiki_voice_hook::MatchesCatSystem2Profile(nullptr)) return false;
  const bool hooks_ready = TryHookSiglusOvk();
  if (!hooks_ready || !FindAndLoadCatSystem2Archives()) return false;
  InterlockedExchange(&g_catsystem2_enabled, 1);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |=
        hibiki_voice_hook::kDiagCatSystem2PcmHooksReady;
  }
  return true;
}

void StopCatSystem2PcmVoice() {
  InterlockedExchange(&g_catsystem2_enabled, 0);
  for (int i = 0; i < kCatSystem2HandleSlots; ++i) {
    InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(&g_catsystem2_handles[i].handle),
        INVALID_HANDLE_VALUE);
  }
  const LONG archive_count =
      InterlockedExchange(&g_catsystem2_archive_count, 0);
  for (LONG i = 0; i < archive_count; ++i) {
    free(g_catsystem2_archives[i].ranges);
    g_catsystem2_archives[i] = {};
  }
}

class CatSystem2Adapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "catsystem2"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesCatSystem2Profile(nullptr);
  }
  bool install() override {
    ready_ = TryHookCatSystem2PcmVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessCatSystem2VoiceTasks(); }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopCatSystem2PcmVoice();
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

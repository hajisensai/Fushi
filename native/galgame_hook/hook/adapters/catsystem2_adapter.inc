// CatSystem2 clean per-line voice, two lanes over the pcm_*.int archives:
//   * index lane — unencrypted KIF: the worker parses the voice archive indices
//     before process resume; ReadFile callbacks only match immutable ranges and
//     enqueue fixed-size metadata; the worker re-reads the exact member bytes.
//   * engine lane — every other pcm_*.int (commercial builds encrypt KIF): the
//     engine's own Archive::ReadEntry returns plaintext member bytes to its Ogg
//     decoder; a detour copies those bytes in bounded chunks and the worker
//     assembles, verifies (Ogg page CRCs) and publishes one file per member.
//     Nothing here decrypts or derives keys.  Sites and layout:
//     catsystem2_voice_core.h.
// An archive belongs to exactly one lane, so a member is never published twice.
#include "catsystem2_profile.h"
// 游戏内查词（字形几何 + 点击认领）在 catsystem2_lookup.inc，结构判据与纯逻辑在
// catsystem2_lookup_core.h（由 dll_main.cpp 在顶层引入）。
#include "catsystem2_lookup.inc"

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
  uint8_t header_bytes[fushi_voice_hook::catsystem2::kHeaderBytes] = {0};
  fushi_voice_hook::catsystem2::Header header;
  uint8_t* index = nullptr;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadExact(file, header_bytes, sizeof(header_bytes)) &&
               fushi_voice_hook::catsystem2::ParseHeader(
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
    fushi_voice_hook::catsystem2::EntryView entry;
    valid = fushi_voice_hook::catsystem2::ParseEntry(
        index, header.index_bytes, i,
        static_cast<uint64_t>(file_size.QuadPart), &entry);
    if (!valid) break;
    if (fushi_voice_hook::catsystem2::IsEncryptionKey(entry)) {
      encrypted = true;
      continue;
    }
    if (!fushi_voice_hook::catsystem2::IsVoiceOgg(entry)) continue;
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

void RememberCatSystem2EngineArchive(HANDLE handle, const wchar_t* path);

void RememberCatSystem2Pcm(HANDLE handle, const wchar_t* path) {
  if (handle == INVALID_HANDLE_VALUE || !HasCatSystem2PcmArchiveName(path)) {
    return;
  }
  const int archive_index =
      InterlockedCompareExchange(&g_catsystem2_enabled, 0, 0) == 0
          ? -1
          : FindCatSystem2ArchiveByPath(path);
  if (archive_index < 0) {
    // Not an index-lane archive (encrypted, or the index lane is off): the
    // engine lane owns it.
    RememberCatSystem2EngineArchive(handle, path);
    return;
  }
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

void ForgetCatSystem2EngineArchive(HANDLE handle);

void ForgetCatSystem2Pcm(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE) return;
  ForgetCatSystem2EngineArchive(handle);
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
               fushi_voice_hook::siglus::CompleteOggBytes(ogg, range.size) ==
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
          fushi_voice_hook::kDiagCatSystem2PcmVoiceCaptured;
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

// ── engine lane ────────────────────────────────────────────────────────────

// Adapter-reported flags (AdapterReportSlot.flags; meaning local to this
// adapter).
constexpr LONG kCs2FlagIndexLane = 0x00000001;          // unencrypted archives
constexpr LONG kCs2FlagSitesResolved = 0x00000002;
constexpr LONG kCs2FlagSitesRejected = 0x00000004;
constexpr LONG kCs2FlagEngineHooked = 0x00000008;
constexpr LONG kCs2FlagEngineArchiveTracked = 0x00000010;
constexpr LONG kCs2FlagChunkQueued = 0x00000020;
constexpr LONG kCs2FlagChunkQueueFull = 0x00000040;
constexpr LONG kCs2FlagVoicePublished = 0x00000080;
constexpr LONG kCs2FlagPartialPublished = 0x00000100;
constexpr LONG kCs2FlagMemberRejected = 0x00000200;
constexpr LONG kCs2FlagTextBound = 0x00000400;
constexpr LONG kCs2FlagRangeOverflow = 0x00000800;
constexpr LONG kCs2FlagWriteFailed = 0x00001000;

volatile LONG g_catsystem2_flags = 0;

void MarkCatSystem2Flag(LONG flag) { InterlockedOr(&g_catsystem2_flags, flag); }

constexpr int kCs2EngineArchiveSlots = 32;
constexpr int kCs2ForeignArchiveSlots = 64;
constexpr int kCs2UnknownArchiveSlots = 8;
constexpr size_t kCs2ArchiveLeafChars = 32;

struct Cs2EngineArchive {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  wchar_t leaf[kCs2ArchiveLeafChars] = {0};
};

struct Cs2ForeignArchive {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
};

// Voice archives the engine lane owns (CreateFile time, or classified later).
Cs2EngineArchive g_cs2_engine_archives[kCs2EngineArchiveSlots];
// Archive handles known not to be engine-lane voice archives (bgm/se/image…,
// or index-lane pcm archives), so ReadEntry stops asking about them.
Cs2ForeignArchive g_cs2_foreign_archives[kCs2ForeignArchiveSlots];
// Archive handles ReadEntry saw before either table knew them: the worker
// asks the kernel for their file name.  This is what makes the lane work when
// the archives were opened before it armed (a late attach, or a startup
// install that outran the injector's resume budget).
volatile LONG_PTR g_cs2_unknown_archives[kCs2UnknownArchiveSlots] = {0};
// Set once the ReadEntry detour is live; the detour copies nothing before.
volatile LONG g_cs2_engine_armed = 0;

void RememberCatSystem2EngineArchive(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_cs2_engine_armed, 0, 0) == 0) return;
  fushi_voice_hook::ForgetTrackedHandle(g_cs2_foreign_archives, handle);
  const bool remembered = fushi_voice_hook::RememberTrackedHandle(
      g_cs2_engine_archives, handle, [path](Cs2EngineArchive& slot) {
        wcsncpy_s(slot.leaf, CatSystem2PathLeaf(path), _TRUNCATE);
      });
  if (!remembered) return;
  MarkCatSystem2Flag(kCs2FlagEngineArchiveTracked);
  // Same readiness semantics as the other resource lanes: the ReadEntry
  // detour is live and a voice archive is really open, so the host pairs this
  // session's lines with per-line resources instead of the mixed stream.
  if (g_header != nullptr) {
    InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->hook_diagnostics),
                  static_cast<LONG>(
                      fushi_voice_hook::kDiagCatSystem2PcmHooksReady));
  }
}

// CloseHandle detour path: lock-free table edits only (BUG-2046).
void ForgetCatSystem2EngineArchive(HANDLE handle) {
  fushi_voice_hook::ForgetTrackedHandle(g_cs2_engine_archives, handle);
  fushi_voice_hook::ForgetTrackedHandle(g_cs2_foreign_archives, handle);
  const LONG_PTR value = reinterpret_cast<LONG_PTR>(handle);
  for (volatile LONG_PTR& slot : g_cs2_unknown_archives) {
    InterlockedCompareExchangePointer(reinterpret_cast<PVOID volatile*>(&slot),
                                      nullptr, reinterpret_cast<PVOID>(value));
  }
}

// Game threads: remember an unclassified archive handle for the worker (a
// value store, deduplicated; a full list drops it until the next read).
void NoteCatSystem2UnknownArchive(HANDLE handle) {
  const LONG_PTR value = reinterpret_cast<LONG_PTR>(handle);
  if (!fushi_voice_hook::IsTrackableHandleValue(handle)) return;
  for (volatile LONG_PTR& slot : g_cs2_unknown_archives) {
    if (slot == value) return;
  }
  for (volatile LONG_PTR& slot : g_cs2_unknown_archives) {
    if (InterlockedCompareExchangePointer(
            reinterpret_cast<PVOID volatile*>(&slot),
            reinterpret_cast<PVOID>(value), nullptr) == nullptr) {
      return;
    }
  }
}

bool IsCatSystem2IndexLaneHandle(HANDLE handle) {
  return FindCatSystem2ArchiveByHandle(handle) >= 0;
}

// Worker: classify each noted handle by the kernel's name for it.  A voice
// archive the index lane does not own joins the engine lane; anything else is
// remembered as foreign.
void ClassifyCatSystem2UnknownArchives() {
  for (volatile LONG_PTR& slot : g_cs2_unknown_archives) {
    const LONG_PTR value = slot;
    if (value == 0) continue;
    const HANDLE handle = reinterpret_cast<HANDLE>(value);
    if (!fushi_voice_hook::IsTrackedHandle(g_cs2_engine_archives, handle) &&
        !fushi_voice_hook::IsTrackedHandle(g_cs2_foreign_archives, handle)) {
      // The value came from an archive object's own handle; a disk-file check
      // keeps a value closed and reused meanwhile (a pipe) away from the name
      // query.  CloseHandle also drops the value from this list.
      wchar_t path[kCatSystem2PathChars] = {0};
      const DWORD length =
          GetFileType(handle) == FILE_TYPE_DISK
              ? GetFinalPathNameByHandleW(
                    handle, path, static_cast<DWORD>(kCatSystem2PathChars),
                    FILE_NAME_NORMALIZED | VOLUME_NAME_NONE)
              : 0;
      if (length != 0 && length < kCatSystem2PathChars) {
        if (HasCatSystem2PcmArchiveName(path) &&
            !IsCatSystem2IndexLaneHandle(handle)) {
          RememberCatSystem2EngineArchive(handle, path);
        } else {
          fushi_voice_hook::RememberTrackedHandle(
              g_cs2_foreign_archives, handle, [](Cs2ForeignArchive&) {});
        }
      }
    }
    InterlockedCompareExchangePointer(reinterpret_cast<PVOID volatile*>(&slot),
                                      nullptr, reinterpret_cast<PVOID>(value));
  }
}

#if defined(_M_IX86)

namespace cs2_voice = fushi_voice_hook::catsystem2_voice;

constexpr int kCs2ChunkSlots = 64;
constexpr uint32_t kCs2ChunkBytes = 8704;  // one vorbisfile read (8500) fits
constexpr int kCs2MemberSlots = 8;
// The audio thread tops a playing voice up every 0.5–1 s (one 8500-byte read
// is ~0.6 s of a measured line); a member without a read for this long was
// stopped by the next line.  The margin keeps low-bitrate voices, whose single
// read lasts longer, from being settled mid-playback.
constexpr uint64_t kCs2MemberAbandonMs = 4000;
// After publishing, reads of the same member (ov_open re-reads, EOF polls)
// are the same playback for this long after its last read.
constexpr uint64_t kCs2MemberRepeatMs = 2000;

struct Cs2VoiceChunk {
  volatile LONG state = 0;  // 0 free, 1 writing, 2 ready, 3 consuming
  uint64_t tick_ms = 0;
  uint64_t selected_thread_id = 0;
  uintptr_t handle = 0;
  uint32_t member_start = 0;
  uint32_t member_size = 0;
  uint32_t offset = 0;
  uint32_t length = 0;
  wchar_t archive[kCs2ArchiveLeafChars] = {0};
  char name[cs2_voice::kEntryNameBytes] = {0};
  uint8_t data[kCs2ChunkBytes] = {0};
};

struct Cs2ReadProbe {
  uintptr_t handle = 0;
  uint32_t member_start = 0;
  uint32_t member_size = 0;
  uint32_t offset = 0;
  // False while the worker has not classified the archive handle yet; the
  // read is then queued only provisionally (see AdmitCs2UnclassifiedRead).
  bool classified = false;
  wchar_t archive[kCs2ArchiveLeafChars] = {0};
  char name[cs2_voice::kEntryNameBytes] = {0};
};

using Cs2ReadEntryFn = int32_t(__fastcall*)(uintptr_t archive, uintptr_t edx,
                                            uintptr_t entry, uint8_t* buffer,
                                            int32_t length);

// Allocated when the lane arms (only in a CatSystem2 process).
Cs2VoiceChunk* g_cs2_chunks = nullptr;
Cs2ReadEntryFn g_cs2_read_entry_original = nullptr;
bool g_cs2_engine_resolved = false;  // worker-only
bool g_cs2_engine_hooked = false;    // worker-only

// Engine fields read before the call.  SEH-guarded: plain copies only.
bool ReadCs2EntryFields(uintptr_t archive, uintptr_t entry, uintptr_t* handle,
                        uint32_t* position, uint32_t* offset, uint32_t* size) {
  __try {
    *handle = *reinterpret_cast<const uintptr_t*>(
        archive + cs2_voice::kArchiveHandleOffset);
    *position = *reinterpret_cast<const uint32_t*>(
        entry + cs2_voice::kEntryPositionOffset);
    *offset = *reinterpret_cast<const uint32_t*>(
        entry + cs2_voice::kEntryOffsetOffset);
    *size = *reinterpret_cast<const uint32_t*>(
        entry + cs2_voice::kEntrySizeOffset);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void CopyCs2EntryName(uintptr_t entry, char* out, size_t out_bytes) {
  out[0] = 0;
  __try {
    const char* name =
        reinterpret_cast<const char*>(entry + cs2_voice::kEntryNameOffset);
    size_t length = 0;
    while (length + 1 < out_bytes && name[length] != 0) {
      out[length] = name[length];
      ++length;
    }
    // A name longer than the copy bound is not the member name we publish.
    out[name[length] == 0 ? length : 0] = 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    out[0] = 0;
  }
}

bool CopyCs2Bytes(uint8_t* out, const uint8_t* in, uint32_t bytes) {
  __try {
    memcpy(out, in, bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Game threads (main + audio streaming): a table lookup and a few field reads.
bool ProbeCs2VoiceRead(uintptr_t archive, uintptr_t entry,
                       Cs2ReadProbe* probe) {
  if (InterlockedCompareExchange(&g_cs2_engine_armed, 0, 0) == 0 ||
      archive == 0 || entry == 0) {
    return false;
  }
  uint32_t position = 0;
  uint32_t size = 0;
  if (!ReadCs2EntryFields(archive, entry, &probe->handle, &position,
                          &probe->offset, &size) ||
      !cs2_voice::PlausibleEntry(position, probe->offset, size)) {
    return false;
  }
  const HANDLE handle = reinterpret_cast<HANDLE>(probe->handle);
  probe->classified = fushi_voice_hook::ReadTrackedHandle(
      g_cs2_engine_archives, handle, [probe](const Cs2EngineArchive& slot) {
        wcsncpy_s(probe->archive, slot.leaf, _TRUNCATE);
      });
  if (!probe->classified) {
    if (fushi_voice_hook::IsTrackedHandle(g_cs2_foreign_archives, handle)) {
      return false;
    }
    NoteCatSystem2UnknownArchive(handle);
  }
  probe->member_start = position - probe->offset;
  probe->member_size = size;
  CopyCs2EntryName(entry, probe->name, sizeof(probe->name));
  return true;
}

// An identical range of the same member is still waiting for the worker
// (ov_open reads the head and tail more than once).
bool Cs2ChunkPending(const Cs2ReadProbe& probe, uint32_t offset,
                     uint32_t length) {
  for (int i = 0; i < kCs2ChunkSlots; ++i) {
    Cs2VoiceChunk& slot = g_cs2_chunks[i];
    const LONG state = InterlockedCompareExchange(&slot.state, 0, 0);
    if ((state == 2 || state == 3) && slot.handle == probe.handle &&
        slot.member_start == probe.member_start && slot.offset == offset &&
        slot.length == length) {
      return true;
    }
  }
  return false;
}

bool Cs2BytesStartWithOgg(const uint8_t* buffer, uint32_t done) {
  if (done < 4) return false;
  __try {
    return memcmp(buffer, "OggS", 4) == 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// The worker has not classified this archive yet (its first read since the
// lane armed).  A voice archive's first playback is a burst of reads within
// milliseconds — all of it before the next worker pass — so it is queued
// provisionally and kept or dropped when the handle is classified.  Only an
// Ogg member qualifies: its head read starts with "OggS", and the rest of the
// burst belongs to a member whose head is still queued.  Image, script and
// other non-Ogg reads never queue.
bool AdmitCs2UnclassifiedRead(const Cs2ReadProbe& probe,
                              const uint8_t* buffer, uint32_t done) {
  if (probe.offset == 0) return Cs2BytesStartWithOgg(buffer, done);
  for (int i = 0; i < kCs2ChunkSlots; ++i) {
    Cs2VoiceChunk& slot = g_cs2_chunks[i];
    const LONG state = InterlockedCompareExchange(&slot.state, 0, 0);
    if ((state == 2 || state == 3) && slot.handle == probe.handle &&
        slot.member_start == probe.member_start && slot.offset == 0) {
      return true;
    }
  }
  return false;
}

// Bounded copies into free chunk slots; a full queue drops the rest.
void QueueCs2VoiceBytes(const Cs2ReadProbe& probe, const uint8_t* buffer,
                        uint32_t done) {
  const uint64_t now = GetTickCount64();
  const uint64_t selected = fushi_voice_hook::SelectedTextThreadId(g_header);
  for (uint32_t at = 0; at < done; at += kCs2ChunkBytes) {
    const uint32_t length = (std::min)(kCs2ChunkBytes, done - at);
    const uint32_t offset = probe.offset + at;
    if (Cs2ChunkPending(probe, offset, length)) continue;
    Cs2VoiceChunk* slot = nullptr;
    for (int i = 0; i < kCs2ChunkSlots; ++i) {
      if (InterlockedCompareExchange(&g_cs2_chunks[i].state, 1, 0) == 0) {
        slot = &g_cs2_chunks[i];
        break;
      }
    }
    if (slot == nullptr) {
      MarkCatSystem2Flag(kCs2FlagChunkQueueFull);
      return;
    }
    if (!CopyCs2Bytes(slot->data, buffer + at, length)) {
      InterlockedExchange(&slot->state, 0);
      return;
    }
    slot->tick_ms = now;
    slot->selected_thread_id = selected;
    slot->handle = probe.handle;
    slot->member_start = probe.member_start;
    slot->member_size = probe.member_size;
    slot->offset = offset;
    slot->length = length;
    memcpy(slot->archive, probe.archive, sizeof(slot->archive));
    memcpy(slot->name, probe.name, sizeof(slot->name));
    InterlockedExchange(&slot->state, 2);
    MarkCatSystem2Flag(kCs2FlagChunkQueued);
  }
}

// Archive::ReadEntry(entry, buffer, length) is __thiscall (archive in ecx);
// the __fastcall signature carries ecx/edx and the three stack arguments.
int32_t __fastcall Cs2ReadEntryDetour(uintptr_t archive, uintptr_t edx,
                                      uintptr_t entry, uint8_t* buffer,
                                      int32_t length) {
  Cs2ReadProbe probe;
  const bool voice = ProbeCs2VoiceRead(archive, entry, &probe);
  const int32_t done =
      g_cs2_read_entry_original(archive, edx, entry, buffer, length);
  if (voice && buffer != nullptr &&
      cs2_voice::PlausibleRead(probe.offset, probe.member_size, done) &&
      (probe.classified ||
       AdmitCs2UnclassifiedRead(probe, buffer, static_cast<uint32_t>(done)))) {
    QueueCs2VoiceBytes(probe, buffer, static_cast<uint32_t>(done));
  }
  return done;
}

// ── worker: assembly, verification, publication ──

struct Cs2Member {
  bool used = false;
  bool decided = false;  // bytes verified; waiting only for the text binding
  bool done = false;     // published or rejected; the key stays for repeats
  uintptr_t handle = 0;
  uint32_t start = 0;
  uint32_t size = 0;
  uint64_t first_tick = 0;
  uint64_t last_tick = 0;
  uint64_t selected_thread_id = 0;
  wchar_t archive[kCs2ArchiveLeafChars] = {0};
  char name[cs2_voice::kEntryNameBytes] = {0};
  uint8_t* data = nullptr;
  cs2_voice::RangeSet have;
  cs2_voice::MemberDecision decision;
};

Cs2Member g_cs2_members[kCs2MemberSlots];  // worker-only

// Committed lines of the selected thread's lane, with the Luna hook name of
// the newest one.  False when the selection is gone or has no lane.
bool CollectCatSystem2SelectedLines(
    uint64_t selected_thread_id,
    fushi_voice_hook::VoiceTextCandidate* candidates, size_t* candidate_count,
    char* hook_name, size_t hook_name_bytes) {
  *candidate_count = 0;
  hook_name[0] = 0;
  if (g_header == nullptr || g_text_base == nullptr ||
      selected_thread_id == 0 ||
      fushi_voice_hook::SelectedTextThreadId(g_header) != selected_thread_id) {
    return false;
  }
  fushi_voice_hook::TextLane* lanes = fushi_voice_hook::TextLanesOf(g_header);
  if (lanes == nullptr) return false;
  uint32_t lane_index = 0;
  bool lane_found = false;
  for (uint32_t i = 0; i < g_header->text_lane_count; ++i) {
    if (fushi_voice_hook::AtomicLoadPreview64(&lanes[i].thread_id) ==
        selected_thread_id) {
      lane_index = i;
      lane_found = true;
      break;
    }
  }
  if (!lane_found) return false;
  const uint64_t lane_written =
      fushi_voice_hook::AtomicLoadPreview64(&lanes[lane_index].write_count);
  const uint32_t lane_slots = g_header->text_lane_slot_count;
  const uint64_t first_lane_seq =
      lane_written > lane_slots ? lane_written - lane_slots + 1 : 1;
  for (uint64_t lane_seq = first_lane_seq;
       lane_seq <= lane_written &&
       *candidate_count < fushi_voice_hook::kTextLaneSlotCount;
       ++lane_seq) {
    auto* slot = reinterpret_cast<TextSlot*>(fushi_voice_hook::TextLaneSlotAt(
        g_header, lane_index, lane_seq));
    if (slot == nullptr ||
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
      continue;
    }
    MemoryBarrier();
    fushi_voice_hook::VoiceTextCandidate candidate;
    candidate.seq = fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
    candidate.timestamp_ms = slot->timestamp_ms;
    candidate.thread_id = slot->thread_id;
    candidate.byte_len = slot->byte_len;
    candidate.is_line = slot->event_kind == fushi_voice_hook::kTextEventLine;
    char name[sizeof(slot->hook_name)] = {0};
    memcpy(name, slot->hook_name, sizeof(name) - 1);
    MemoryBarrier();
    if (fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
      continue;
    }
    candidates[(*candidate_count)++] = candidate;
    strncpy_s(hook_name, hook_name_bytes, name, _TRUNCATE);
  }
  return true;
}

// The selected-thread line this member's playback belongs to (see
// cs2_voice::SelectedLineOrder).  Returns false while a following line may
// still arrive; `force` settles with whatever is known now.  No selection,
// no line in the window, or a changed selection: unmarked (0).
bool ResolveCatSystem2VoiceText(const Cs2Member& member, uint64_t now,
                                bool force, uint64_t* text_event_id) {
  *text_event_id = 0;
  fushi_voice_hook::VoiceTextCandidate
      candidates[fushi_voice_hook::kTextLaneSlotCount] = {};
  size_t count = 0;
  char hook_name[sizeof(TextSlot::hook_name)] = {0};
  if (!CollectCatSystem2SelectedLines(member.selected_thread_id, candidates,
                                      &count, hook_name, sizeof(hook_name))) {
    return true;
  }
  if (cs2_voice::SelectedLineOrder(hook_name) ==
      cs2_voice::LineOrder::kPrecedesVoice) {
    const auto decision = fushi_voice_hook::ResolvePrecedingSelectedText(
        member.first_tick, member.selected_thread_id, candidates, count,
        cs2_voice::kTextBindingWindowMs);
    if (decision.state == fushi_voice_hook::VoiceResourcePairState::kMatched) {
      *text_event_id = decision.text_event_id;
    }
    return true;
  }
  const auto decision = fushi_voice_hook::ResolveFollowingSelectedText(
      member.first_tick, member.first_tick + cs2_voice::kTextBindingWindowMs,
      now, member.selected_thread_id, 0, candidates, count);
  if (decision.state == fushi_voice_hook::VoiceResourcePairState::kMatched) {
    *text_event_id = decision.text_event_id;
    return true;
  }
  return force ||
         decision.state != fushi_voice_hook::VoiceResourcePairState::kWait;
}

void ReleaseCs2Member(Cs2Member* member) {
  free(member->data);
  *member = Cs2Member();
}

void PublishCs2Member(Cs2Member* member, uint64_t text_event_id) {
  const cs2_voice::MemberDecision& d = member->decision;
  wchar_t name[cs2_voice::kEntryNameBytes] = {0};
  if (member->name[0] != 0) {
    MultiByteToWideChar(932, 0, member->name, -1, name,
                        static_cast<int>(cs2_voice::kEntryNameBytes));
  }
  const bool partial = d.verdict == cs2_voice::MemberVerdict::kPublishPartial;
  const std::wstring storage =
      cs2_voice::BuildVoiceStorageName(member->archive, name, partial);
  const bool written = WriteVoiceOggAt(member->data, d.bytes, storage.c_str(),
                                       member->first_tick, text_event_id);
  if (!written) {
    MarkCatSystem2Flag(kCs2FlagWriteFailed);
  } else {
    MarkCatSystem2Flag(partial ? kCs2FlagPartialPublished
                               : kCs2FlagVoicePublished);
    if (text_event_id != 0) MarkCatSystem2Flag(kCs2FlagTextBound);
  }
  Cs2LookupLog(L"catsystem2-voice: %ls %ls bytes=%lu/%lu tick=%llu "
               L"text_event=%llu written=%d",
               partial ? L"partial" : L"complete", storage.c_str(),
               static_cast<unsigned long>(d.bytes),
               static_cast<unsigned long>(member->size),
               static_cast<unsigned long long>(member->first_tick),
               static_cast<unsigned long long>(text_event_id), written ? 1 : 0);
}

// Verifies the member once its bytes are complete (or it was abandoned),
// then publishes it as soon as its text binding is known.  The bytes are
// dropped afterwards; the key stays so the same playback's later reads are
// recognised.  `force` (eviction) publishes without waiting for a line.
void SettleCs2Member(Cs2Member* member, bool abandoned, uint64_t now,
                     bool force) {
  if (member->done) return;
  if (!member->decided) {
    const cs2_voice::MemberDecision decision = cs2_voice::DecideMember(
        member->data, member->size, member->have, abandoned || force);
    if (decision.verdict == cs2_voice::MemberVerdict::kWait) return;
    if (decision.verdict == cs2_voice::MemberVerdict::kReject) {
      MarkCatSystem2Flag(kCs2FlagMemberRejected);
      Cs2LookupLog(L"catsystem2-voice: rejected %ls member bytes=%lu have=%lu",
                   member->archive, static_cast<unsigned long>(member->size),
                   static_cast<unsigned long>(member->have.Prefix()));
      member->done = true;
      free(member->data);
      member->data = nullptr;
      return;
    }
    member->decision = decision;
    member->decided = true;
  }
  uint64_t text_event_id = 0;
  if (!ResolveCatSystem2VoiceText(*member, now, force, &text_event_id)) return;
  PublishCs2Member(member, text_event_id);
  member->done = true;
  free(member->data);
  member->data = nullptr;
}

Cs2Member* FindOrAddCs2Member(const Cs2VoiceChunk& chunk, uint64_t now) {
  Cs2Member* free_slot = nullptr;
  for (Cs2Member& member : g_cs2_members) {
    if (!member.used) {
      if (free_slot == nullptr) free_slot = &member;
      continue;
    }
    if (member.handle == chunk.handle && member.start == chunk.member_start &&
        member.size == chunk.member_size) {
      return &member;
    }
  }
  if (free_slot == nullptr) {
    // Evict the member read least recently; an unfinished one is settled
    // (published without waiting further) first.
    for (Cs2Member& member : g_cs2_members) {
      if (free_slot == nullptr || member.last_tick < free_slot->last_tick) {
        free_slot = &member;
      }
    }
    SettleCs2Member(free_slot, true, now, true);
    ReleaseCs2Member(free_slot);
  }
  uint8_t* data = static_cast<uint8_t*>(calloc(chunk.member_size, 1));
  if (data == nullptr) return nullptr;
  Cs2Member& member = *free_slot;
  member.used = true;
  member.handle = chunk.handle;
  member.start = chunk.member_start;
  member.size = chunk.member_size;
  member.first_tick = chunk.tick_ms;
  member.last_tick = chunk.tick_ms;
  member.selected_thread_id = chunk.selected_thread_id;
  memcpy(member.archive, chunk.archive, sizeof(member.archive));
  memcpy(member.name, chunk.name, sizeof(member.name));
  member.data = data;
  return &member;
}

void AbsorbCs2Chunk(Cs2VoiceChunk* chunk_slot, uint64_t now) {
  const Cs2VoiceChunk& chunk = *chunk_slot;
  if (chunk.member_size == 0 || chunk.member_size > cs2_voice::kMaxMemberBytes ||
      chunk.offset > chunk.member_size ||
      chunk.length > chunk.member_size - chunk.offset) {
    return;
  }
  if (chunk.archive[0] == 0) {
    // Provisional: keep it only if the archive was classified as an
    // engine-lane voice archive (classification ran before this pass).
    wchar_t leaf[kCs2ArchiveLeafChars] = {0};
    if (!fushi_voice_hook::ReadTrackedHandle(
            g_cs2_engine_archives, reinterpret_cast<HANDLE>(chunk.handle),
            [&leaf](const Cs2EngineArchive& slot) {
              wcsncpy_s(leaf, slot.leaf, _TRUNCATE);
            }) ||
        leaf[0] == 0) {
      return;
    }
    memcpy(chunk_slot->archive, leaf, sizeof(leaf));
  }
  Cs2Member* member = FindOrAddCs2Member(chunk, now);
  if (member == nullptr) return;
  if (chunk.tick_ms > member->last_tick) member->last_tick = chunk.tick_ms;
  // Verified bytes are final; later reads of the same playback add nothing.
  if (member->done || member->decided) return;
  if (chunk.tick_ms < member->first_tick) {
    // Slots are claimed out of order; the earliest read opens the playback.
    member->first_tick = chunk.tick_ms;
    member->selected_thread_id = chunk.selected_thread_id;
  }
  if (member->name[0] == 0 && chunk.name[0] != 0) {
    memcpy(member->name, chunk.name, sizeof(member->name));
  }
  if (!member->have.Add(chunk.offset, chunk.offset + chunk.length)) {
    MarkCatSystem2Flag(kCs2FlagRangeOverflow);
    return;
  }
  memcpy(member->data + chunk.offset, chunk.data, chunk.length);
}

void ProcessCatSystem2EngineVoice() {
  if (g_cs2_chunks == nullptr) return;
  ClassifyCatSystem2UnknownArchives();
  const uint64_t now = GetTickCount64();
  for (int i = 0; i < kCs2ChunkSlots; ++i) {
    if (InterlockedCompareExchange(&g_cs2_chunks[i].state, 3, 2) == 2) {
      AbsorbCs2Chunk(&g_cs2_chunks[i], now);
      InterlockedExchange(&g_cs2_chunks[i].state, 0);
    }
  }
  for (Cs2Member& member : g_cs2_members) {
    if (!member.used) continue;
    const uint64_t idle = now > member.last_tick ? now - member.last_tick : 0;
    if (!member.done) {
      SettleCs2Member(&member, idle >= kCs2MemberAbandonMs, now, false);
    }
    if (member.done && idle >= kCs2MemberRepeatMs) ReleaseCs2Member(&member);
  }
}

// Resolves ReadEntry from structure and hooks it.  Worker thread, before the
// suspended game resumes; resolution runs once per process.
bool TryHookCatSystem2EngineVoice() {
  if (g_cs2_engine_resolved) {
    if (g_cs2_engine_hooked) InterlockedExchange(&g_cs2_engine_armed, 1);
    return g_cs2_engine_hooked;
  }
  g_cs2_engine_resolved = true;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  cs2_voice::VoiceImportSlots imports;
  cs2_voice::VoiceSites sites;
  cs2_voice::VoiceSiteResult result = cs2_voice::VoiceSiteResult::kBigReadMissing;
  if (fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    imports.set_file_pointer = cs2_lookup::FindImportSlotRva(
        image, "kernel32.dll", "SetFilePointer");
    imports.read_file =
        cs2_lookup::FindImportSlotRva(image, "kernel32.dll", "ReadFile");
    result = cs2_voice::ResolveVoiceSites(image, imports, &sites);
  }
  if (result != cs2_voice::VoiceSiteResult::kResolved) {
    MarkCatSystem2Flag(kCs2FlagSitesRejected);
    Cs2LookupLog(L"catsystem2-voice: sites unresolved result=%u",
                 static_cast<unsigned>(result));
    return false;
  }
  MarkCatSystem2Flag(kCs2FlagSitesResolved);
  g_cs2_chunks = static_cast<Cs2VoiceChunk*>(
      VirtualAlloc(nullptr, sizeof(Cs2VoiceChunk) * kCs2ChunkSlots,
                   MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  // VirtualAlloc zero-fills: every slot starts free (state 0).
  g_cs2_engine_hooked =
      g_cs2_chunks != nullptr &&
      HookFn(reinterpret_cast<void*>(sites.read_entry),
             reinterpret_cast<void*>(&Cs2ReadEntryDetour),
             reinterpret_cast<void**>(&g_cs2_read_entry_original));
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  Cs2LookupLog(L"catsystem2-voice: sites bigread=+0x%lx readentry=+0x%lx "
               L"plain=+0x%lx hooked=%d",
               static_cast<unsigned long>(sites.big_read - base),
               static_cast<unsigned long>(sites.read_entry - base),
               static_cast<unsigned long>(sites.plain_block - base),
               g_cs2_engine_hooked ? 1 : 0);
  if (!g_cs2_engine_hooked) return false;
  MarkCatSystem2Flag(kCs2FlagEngineHooked);
  InterlockedExchange(&g_cs2_engine_armed, 1);
  return true;
}

void StopCatSystem2EngineVoice() {
  // The detour stays chained (MinHook owns it for the process lifetime);
  // disarming turns it into a pure forwarder.
  InterlockedExchange(&g_cs2_engine_armed, 0);
  fushi_voice_hook::ClearTrackedHandles(g_cs2_engine_archives);
  fushi_voice_hook::ClearTrackedHandles(g_cs2_foreign_archives);
  for (volatile LONG_PTR& slot : g_cs2_unknown_archives) {
    InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(&slot),
                               nullptr);
  }
  for (Cs2Member& member : g_cs2_members) {
    if (member.used) ReleaseCs2Member(&member);
  }
}

#else  // !_M_IX86 — CatSystem2 is an x86 engine.

void ProcessCatSystem2EngineVoice() {}
bool TryHookCatSystem2EngineVoice() { return false; }
void StopCatSystem2EngineVoice() {
  InterlockedExchange(&g_cs2_engine_armed, 0);
  fushi_voice_hook::ClearTrackedHandles(g_cs2_engine_archives);
  fushi_voice_hook::ClearTrackedHandles(g_cs2_foreign_archives);
}

#endif  // _M_IX86

// Index lane: only when at least one pcm_*.int is unencrypted.
bool TryHookCatSystem2PcmVoice() {
  if (!FindAndLoadCatSystem2Archives()) return false;
  InterlockedExchange(&g_catsystem2_enabled, 1);
  MarkCatSystem2Flag(kCs2FlagIndexLane);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |=
        fushi_voice_hook::kDiagCatSystem2PcmHooksReady;
  }
  return true;
}

void StopCatSystem2PcmVoice() {
  StopCatSystem2EngineVoice();
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

class CatSystem2Adapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "catsystem2"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesCatSystem2Profile(nullptr);
  }
  bool install() override {
    if (!probe()) return false;
    // 查词站点只来自 exe 自身结构、与语音归档无关：身份成立就装（语音归档加密/缺失时
    // 语音层失败，查词照常）。结构不符的映像一个钩子也不装。
    lookup_installed_ = InstallCatSystem2Lookup() || lookup_installed_;
    // Both voice lanes observe archive opens through the shared KernelBase
    // broker; arm them before the suspended game resumes and opens pcm_*.int.
    if (!TryHookSiglusOvk()) return false;
    const bool index_lane = TryHookCatSystem2PcmVoice();
    const bool engine_lane = TryHookCatSystem2EngineVoice();
    ready_ = index_lane || engine_lane;
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() {
    ProcessCatSystem2VoiceTasks();
    ProcessCatSystem2EngineVoice();
    ProcessCatSystem2LookupTick();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (CatSystem2LookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // Sites were resolved and rejected: terminal for this executable, so the
    // host gets the digest to report instead of waiting for a gate.
    if (CatSystem2LookupSitesRejected()) {
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
    ShutdownCatSystem2Lookup();
    lookup_installed_ = false;
    StopCatSystem2PcmVoice();
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_catsystem2_flags, 0, 0))};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
  bool lookup_installed_ = false;
};

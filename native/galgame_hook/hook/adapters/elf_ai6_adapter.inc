// elf AI6 clean voice capture. voice.arc starts with a little-endian entry
// count followed by fixed 272-byte records (256-byte name and four big-endian
// uint32 fields). The final fields are packed size, unpacked size and absolute
// payload offset. The shared kernel detour only queues {duplicated archive
// handle, read offset, tick}; index parsing, structural/EOS Ogg validation and
// disk output stay on the HookWorker.
#include "elf_ai6_profile.h"
#include "../voice_resource_pairing.h"

constexpr size_t kElfAi6PathChars = 520;
constexpr int kElfAi6HandleSlots = 8;
constexpr int kElfAi6TaskSlots = 32;

struct ElfAi6ArcHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
};

struct ElfAi6VoiceTask {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  uint64_t read_offset = 0;
  uint64_t selected_thread_id = 0;
  HANDLE source_handle = INVALID_HANDLE_VALUE;
};

ElfAi6ArcHandle g_elf_ai6_handles[kElfAi6HandleSlots];
ElfAi6VoiceTask g_elf_ai6_tasks[kElfAi6TaskSlots];
volatile LONG g_elf_ai6_enabled = 0;
fushi_voice_hook::ElfAi6FileIdentity g_elf_ai6_archive_identity;
uint64_t g_elf_ai6_last_offset = UINT64_MAX;
uint64_t g_elf_ai6_last_tick = 0;

bool IsElfAi6VoiceArchivePath(const wchar_t* path) {
  if (path == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* base = slash == nullptr ? path : slash + 1;
  return _wcsicmp(base, L"voice.arc") == 0;
}

void RememberElfAi6VoiceArc(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_elf_ai6_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsElfAi6VoiceArchivePath(path) ||
      !g_cs_ready) {
    return;
  }
  fushi_voice_hook::ElfAi6FileIdentity identity;
  if (!fushi_voice_hook::ReadElfAi6FileIdentity(handle, &identity) ||
      !fushi_voice_hook::SameElfAi6FileIdentity(
          identity, g_elf_ai6_archive_identity)) {
    return;
  }
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == INVALID_HANDLE_VALUE ||
        g_elf_ai6_handles[i].handle == handle) {
      g_elf_ai6_handles[i].handle = handle;
      if (g_header != nullptr) {
        g_header->reserved_hook_diagnostics |=
            fushi_voice_hook::kDiagElfAi6ArcHandleTracked;
      }
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool IsTrackedElfAi6VoiceArc(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == handle) {
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetElfAi6VoiceArc(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    if (g_elf_ai6_handles[i].handle == handle) {
      g_elf_ai6_handles[i].handle = INVALID_HANDLE_VALUE;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool QueueElfAi6Voice(HANDLE source_handle, uint64_t read_offset) {
  for (int i = 0; i < kElfAi6TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_elf_ai6_tasks[i].state, 1, 0) != 0) {
      continue;
    }
    HANDLE owned_handle = INVALID_HANDLE_VALUE;
    if (!DuplicateHandle(GetCurrentProcess(), source_handle,
                         GetCurrentProcess(), &owned_handle, 0, FALSE,
                         DUPLICATE_SAME_ACCESS)) {
      InterlockedExchange(&g_elf_ai6_tasks[i].state, 0);
      return false;
    }
    if (InterlockedCompareExchange(&g_elf_ai6_enabled, 0, 0) == 0) {
      g_orig_CloseHandle(owned_handle);
      InterlockedExchange(&g_elf_ai6_tasks[i].state, 0);
      return false;
    }
    g_elf_ai6_tasks[i].tick_ms = GetTickCount64();
    g_elf_ai6_tasks[i].read_offset = read_offset;
    g_elf_ai6_tasks[i].selected_thread_id =
        fushi_voice_hook::SelectedTextThreadId(g_header);
    g_elf_ai6_tasks[i].source_handle = owned_handle;
    InterlockedExchange(&g_elf_ai6_tasks[i].state, 2);
    return true;
  }
  return false;
}

void ObserveElfAi6VoiceArcRead(HANDLE file, const void* buffer, DWORD done,
                               LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_elf_ai6_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4) {
    return;
  }
  if (!IsTrackedElfAi6VoiceArc(file)) {
    // Some AI6 launchers complete archive open before delayed injection. A
    // ReadFile handle remains classifiable without touching the game's file
    // position, so recover it lazily on the first post-injection read.
    wchar_t path[kElfAi6PathChars] = {0};
    const DWORD chars = GetFinalPathNameByHandleW(
        file, path, static_cast<DWORD>(kElfAi6PathChars), FILE_NAME_NORMALIZED);
    if (chars == 0 || chars >= kElfAi6PathChars ||
        !IsElfAi6VoiceArchivePath(path)) {
      return;
    }
    RememberElfAi6VoiceArc(file, path);
    if (!IsTrackedElfAi6VoiceArc(file)) return;
  }
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagElfAi6ArcReadObserved;
  }
  __try {
    if (memcmp(buffer, "OggS", 4) != 0) return;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagElfAi6ArcOggObserved;
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
  const bool queued = QueueElfAi6Voice(file, start);
  if (queued && g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagElfAi6ArcVoiceQueued;
  } else if (!queued && g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagElfAi6ArcTaskRejected;
  }
}

uint64_t FindElfAi6PrecedingTextEvent(const ElfAi6VoiceTask& task) {
  if (g_header == nullptr || g_text_base == nullptr ||
      task.selected_thread_id == 0 ||
      fushi_voice_hook::SelectedTextThreadId(g_header) !=
          task.selected_thread_id) {
    return 0;
  }
  fushi_voice_hook::TextLane* lanes =
      fushi_voice_hook::TextLanesOf(g_header);
  if (lanes == nullptr) return 0;
  uint32_t lane_index = 0;
  bool lane_found = false;
  for (uint32_t i = 0; i < g_header->text_lane_count; ++i) {
    if (fushi_voice_hook::AtomicLoadPreview64(&lanes[i].thread_id) ==
        task.selected_thread_id) {
      lane_index = i;
      lane_found = true;
      break;
    }
  }
  if (!lane_found) return 0;

  fushi_voice_hook::VoiceTextCandidate
      candidates[fushi_voice_hook::kTextLaneSlotCount] = {};
  size_t candidate_count = 0;
  const uint64_t lane_written =
      fushi_voice_hook::AtomicLoadPreview64(&lanes[lane_index].write_count);
  const uint32_t lane_slots = g_header->text_lane_slot_count;
  const uint64_t first_lane_seq =
      lane_written > lane_slots ? lane_written - lane_slots + 1 : 1;
  for (uint64_t lane_seq = first_lane_seq;
       lane_seq <= lane_written &&
       candidate_count < fushi_voice_hook::kTextLaneSlotCount;
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
    MemoryBarrier();
    if (fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
      continue;
    }
    candidates[candidate_count++] = candidate;
  }
  const auto decision = fushi_voice_hook::ResolvePrecedingSelectedText(
      task.tick_ms, task.selected_thread_id, candidates, candidate_count);
  return decision.state ==
          fushi_voice_hook::VoiceResourcePairState::kMatched
      ? decision.text_event_id
      : 0;
}

void ProcessElfAi6VoiceTask(ElfAi6VoiceTask* task) {
  const HANDLE source_handle = task->source_handle;
  task->source_handle = INVALID_HANDLE_VALUE;
  HANDLE file = ReOpenFile(source_handle, GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE |
                               FILE_SHARE_DELETE,
                           0);
  g_orig_CloseHandle(source_handle);
  if (file == INVALID_HANDLE_VALUE) {
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          fushi_voice_hook::kDiagElfAi6ArcTaskRejected;
    }
    return;
  }
  LARGE_INTEGER file_size = {};
  uint8_t count_bytes[fushi_voice_hook::elf_ai6::kHeaderBytes] = {0};
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  uint64_t index_bytes = 0;
  fushi_voice_hook::elf_ai6::ArcEntry entry;
  fushi_voice_hook::ElfAi6FileIdentity identity;
  bool valid = fushi_voice_hook::ReadElfAi6FileIdentity(file, &identity) &&
      fushi_voice_hook::SameElfAi6FileIdentity(
          identity, g_elf_ai6_archive_identity) &&
      GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
      ReadExact(file, count_bytes, sizeof(count_bytes)) &&
      fushi_voice_hook::elf_ai6::IndexSize(
          count_bytes, sizeof(count_bytes), nullptr, &index_bytes) &&
      index_bytes <= static_cast<uint64_t>(file_size.QuadPart) &&
      index_bytes <= UINT32_MAX;
  if (valid) {
    index = static_cast<uint8_t*>(malloc(static_cast<size_t>(index_bytes)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, count_bytes, sizeof(count_bytes));
      valid = ReadExact(file, index + sizeof(count_bytes),
                        static_cast<uint32_t>(index_bytes -
                                              sizeof(count_bytes))) &&
          fushi_voice_hook::elf_ai6::FindEntryForRead(
              index, static_cast<size_t>(index_bytes),
              static_cast<uint64_t>(file_size.QuadPart), task->read_offset,
              &entry);
    }
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.offset;
    ogg = static_cast<uint8_t*>(malloc(entry.size));
    valid = ogg != nullptr &&
        SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
        ReadExact(file, ogg, entry.size) &&
        fushi_voice_hook::siglus::CompleteOggBytes(ogg, entry.size) ==
            entry.size;
  }
  const bool duplicate = valid && entry.offset == g_elf_ai6_last_offset &&
      task->tick_ms - g_elf_ai6_last_tick <= 2000;
  if (valid && !duplicate) {
    wchar_t member_name[64] = {0};
    swprintf_s(member_name, L"elf_ai6_%llu.ogg",
               static_cast<unsigned long long>(entry.offset));
    const uint64_t text_event_id = FindElfAi6PrecedingTextEvent(*task);
    valid = WriteVoiceOggAt(ogg, entry.size, member_name, task->tick_ms,
                            text_event_id);
  }
  if (valid && !duplicate) {
    g_elf_ai6_last_offset = entry.offset;
    g_elf_ai6_last_tick = task->tick_ms;
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          fushi_voice_hook::kDiagElfAi6ArcVoiceCaptured;
    }
  } else if (!valid && g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagElfAi6ArcTaskRejected;
  }
  free(ogg);
  free(index);
  g_orig_CloseHandle(file);
}

void ProcessElfAi6VoiceTasks() {
  for (int i = 0; i < kElfAi6TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_elf_ai6_tasks[i].state, 3, 2) == 2) {
      ProcessElfAi6VoiceTask(&g_elf_ai6_tasks[i]);
      InterlockedExchange(&g_elf_ai6_tasks[i].state, 0);
    }
  }
}

bool TryHookElfAi6ArcVoice() {
  fushi_voice_hook::ElfAi6FileIdentity identity;
  if (!fushi_voice_hook::ProbeElfAi6Profile(&identity)) return false;
  g_elf_ai6_archive_identity = identity;
  const bool ready = TryHookSiglusOvk();
  if (ready) {
    InterlockedExchange(&g_elf_ai6_enabled, 1);
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          fushi_voice_hook::kDiagElfAi6ArcHooksReady;
    }
  }
  return ready;
}

void StopElfAi6ArcVoice() {
  InterlockedExchange(&g_elf_ai6_enabled, 0);
  if (!g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6HandleSlots; ++i) {
    g_elf_ai6_handles[i].handle = INVALID_HANDLE_VALUE;
  }
  LeaveCriticalSection(&g_cs);
  for (int i = 0; i < kElfAi6TaskSlots; ++i) {
    if (InterlockedCompareExchange(&g_elf_ai6_tasks[i].state, 0, 2) == 2) {
      const HANDLE source_handle = g_elf_ai6_tasks[i].source_handle;
      g_elf_ai6_tasks[i].source_handle = INVALID_HANDLE_VALUE;
      if (source_handle != INVALID_HANDLE_VALUE) {
        g_orig_CloseHandle(source_handle);
      }
    }
  }
}

class ElfAi6Adapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "elf_ai6"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesElfAi6Profile(nullptr);
  }
  bool install() override {
    ready_ = TryHookElfAi6ArcVoice();
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() { ProcessElfAi6VoiceTasks(); }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopElfAi6ArcVoice();
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u :
                g_header->reserved_hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

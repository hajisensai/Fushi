// Malie Ogg decoder-input voice lane.
//
// Identity is the engine's "CFI" I/O scheme table (malie_profile.h).  Voice
// is taken where the engine hands bytes to its Ogg Vorbis decoder: the
// decoder's input refill `ogg_sync_wrote(dec, n)` (malie_engine_io_core.h).
// Nothing here reads, decrypts or indexes the archive.
//   * game / audio threads — ogg_sync_wrote detour: only from the decoder's
//     refill call sites (return address), a bounded copy of the n bytes at
//     oy->data + oy->fill and of the decoder's path field, into a fixed slot
//     ring; no allocation, no IO.
//   * HookWorker — orders the chunks, keeps the decoders whose path is below
//     a "voice" directory, assembles each from its first (BOS) page and
//     publishes it once the Ogg stream is complete through its EOS page.
#include "malie_profile.h"

namespace malie_io = ::fushi_voice_hook::malie_io;
namespace malie_lookup = ::fushi_voice_hook::malie_lookup;

typedef int32_t(__cdecl* MalieSyncWroteFn)(void* oy, int32_t bytes);

constexpr int kMalieChunkSlots = 96;
constexpr size_t kMaliePathChars = 260;
constexpr int kMalieMemberSlots = 8;
constexpr uint32_t kMalieMaxMemberBytes = 16u * 1024u * 1024u;
constexpr uint64_t kMalieRepeatWindowMs = 3000;
constexpr uint64_t kMalieIdleDropMs = 20000;
// A voice usually starts a moment before its message unit is parsed; a
// complete voice waits this long for the unit naming it.
constexpr uint64_t kMalieBindWaitMs = 2000;
// A decoder that stopped receiving input this long before its EOS page was
// stopped by the next line: its whole-page prefix is published.
constexpr uint64_t kMaliePartialIdleMs = 3000;

struct MalieChunk {
  volatile LONG state = 0;  // 0 free, 1 filling, 2 ready, 3 worker
  LONG seq = 0;
  uint64_t tick_ms = 0;
  uintptr_t decoder = 0;
  uint32_t length = 0;
  wchar_t path[kMaliePathChars] = {0};
  uint8_t data[malie_io::kFeedBytes] = {0};
};

struct MalieMember {  // worker-only
  bool used = false;
  bool done = false;
  uint32_t complete = 0;  // verified Ogg bytes, 0 while incomplete
  bool partial = false;   // `complete` is a whole-page prefix
  uint64_t complete_tick = 0;
  uintptr_t decoder = 0;
  uint64_t first_tick = 0;
  uint64_t last_tick = 0;
  std::wstring path;
  std::vector<uint8_t> bytes;
};

MalieSyncWroteFn g_malie_sync_wrote_original = nullptr;
malie_io::OggFeedSites g_malie_feed;
volatile LONG g_malie_enabled = 0;
volatile LONG g_malie_chunk_seq = 0;
MalieChunk g_malie_chunks[kMalieChunkSlots];
MalieMember g_malie_members[kMalieMemberSlots];
std::wstring g_malie_last_published;
uint64_t g_malie_last_published_tick = 0;

void MalieLog(const wchar_t* format, ...) {
  wchar_t line[512] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = g_orig_CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                   nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[640] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu malie: %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[1920] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

void MarkMalieIo(uint32_t bit) {
  if (g_header != nullptr) g_header->reserved_hook_diagnostics |= bit;
}

bool IsMalieFeedReturn(uintptr_t address) {
  for (size_t i = 0; i < g_malie_feed.feed_count; ++i) {
    if (g_malie_feed.feed_returns[i] == address) return true;
  }
  return false;
}

// Copies the refill bytes and the decoder path; false when the object does
// not read as a decoder (unreadable, out of range or unterminated path).
bool CopyMalieFeed(uintptr_t oy, uint32_t bytes, MalieChunk* chunk) {
  __try {
    const uint8_t* data = *reinterpret_cast<uint8_t* const*>(
        oy + malie_io::kSyncDataOffset);
    const int32_t storage = *reinterpret_cast<const int32_t*>(
        oy + malie_io::kSyncStorageOffset);
    const int32_t fill =
        *reinterpret_cast<const int32_t*>(oy + malie_io::kSyncFillOffset);
    if (data == nullptr || storage <= 0 || fill < 0 ||
        static_cast<int64_t>(fill) + bytes > storage) {
      return false;
    }
    const wchar_t* path =
        reinterpret_cast<const wchar_t*>(oy + g_malie_feed.path_field);
    size_t length = 0;
    while (length < kMaliePathChars && path[length] != 0) ++length;
    if (length == 0 || length == kMaliePathChars) return false;
    memcpy(chunk->path, path, length * sizeof(wchar_t));
    chunk->path[length] = 0;
    memcpy(chunk->data, data + fill, bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

int32_t __cdecl MalieSyncWroteDetour(void* oy, int32_t bytes) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  if (bytes > 0 && static_cast<uint32_t>(bytes) <= malie_io::kFeedBytes &&
      oy != nullptr &&
      InterlockedCompareExchange(&g_malie_enabled, 0, 0) != 0 &&
      IsMalieFeedReturn(caller)) {
    for (int i = 0; i < kMalieChunkSlots; ++i) {
      MalieChunk& slot = g_malie_chunks[i];
      if (InterlockedCompareExchange(&slot.state, 1, 0) != 0) continue;
      if (CopyMalieFeed(reinterpret_cast<uintptr_t>(oy),
                        static_cast<uint32_t>(bytes), &slot)) {
        slot.seq = InterlockedIncrement(&g_malie_chunk_seq);
        slot.tick_ms = GetTickCount64();
        slot.decoder = reinterpret_cast<uintptr_t>(oy);
        slot.length = static_cast<uint32_t>(bytes);
        InterlockedExchange(&slot.state, 2);
        MarkMalieIo(fushi_voice_hook::kDiagMalieReadRangeObserved);
      } else {
        InterlockedExchange(&slot.state, 0);
      }
      break;
    }
  }
  return g_malie_sync_wrote_original(oy, bytes);
}

// ── worker ────────────────────────────────────────────────────────────────

bool MalieChunkStartsStream(const MalieChunk& chunk) {
  // A BOS page: capture pattern, version 0, header-type "beginning".
  return chunk.length >= 27 && memcmp(chunk.data, "OggS", 4) == 0 &&
         chunk.data[4] == 0 && (chunk.data[5] & 0x02) != 0;
}

// The text event of the latest message unit that carried this voice tag
// (malie_lookup.inc); 0 when no unit names it.
uint64_t MalieTextEventForVoice(const std::wstring& key, uint64_t tick);
void PublishMalieMember(MalieMember* member, uint64_t text_event);
void StopMalieMember(MalieMember* member, uint64_t now);

uint64_t MalieMemberTextEvent(const MalieMember& member) {
  return MalieTextEventForVoice(
      malie_lookup::VoiceKeyFromPath(member.path.c_str()), member.first_tick);
}

MalieMember* FindMalieMember(uintptr_t decoder, const wchar_t* path) {
  for (auto& member : g_malie_members) {
    if (member.used && member.decoder == decoder && member.path == path) {
      return &member;
    }
  }
  return nullptr;
}

MalieMember* StartMalieMember(const MalieChunk& chunk) {
  MalieMember* slot = FindMalieMember(chunk.decoder, chunk.path);
  if (slot == nullptr) {
    for (auto& member : g_malie_members) {
      if (!member.used) {
        slot = &member;
        break;
      }
    }
  }
  if (slot == nullptr) {
    // Evict the stalest decoder.
    slot = &g_malie_members[0];
    for (auto& member : g_malie_members) {
      if (member.last_tick < slot->last_tick) slot = &member;
    }
    if (slot->complete != 0 && !slot->done) {
      PublishMalieMember(slot, MalieMemberTextEvent(*slot));
    }
    MalieLog(L"voice: evicted %ls bytes=%lu", slot->path.c_str(),
             static_cast<unsigned long>(slot->bytes.size()));
  }
  *slot = MalieMember();
  slot->used = true;
  slot->decoder = chunk.decoder;
  slot->first_tick = chunk.tick_ms;
  slot->last_tick = chunk.tick_ms;
  slot->path = chunk.path;
  return slot;
}

void PublishMalieMember(MalieMember* member, uint64_t text_event) {
  member->done = true;
  const uint32_t complete = member->complete;
  const std::wstring storage =
      malie_io::VoiceStorageName(member->path.c_str(), member->partial);
  if (!member->partial && storage == g_malie_last_published &&
      member->first_tick - g_malie_last_published_tick <=
          kMalieRepeatWindowMs) {
    // The same file decoded twice for one playback (e.g. a lip-sync pass).
    MalieLog(L"voice: duplicate decode %ls", storage.c_str());
    return;
  }
  const bool written =
      WriteVoiceOggAt(member->bytes.data(), complete, storage.c_str(),
                      member->first_tick, text_event);
  if (written) {
    g_malie_last_published = storage;
    g_malie_last_published_tick = member->first_tick;
    if (g_header != nullptr) {
      g_header->hook_diagnostics |=
          fushi_voice_hook::kDiagMalieLibpVoiceCaptured;
    }
  }
  MalieLog(L"voice: %ls bytes=%lu/%lu tick=%llu text_event=%llu written=%d",
           storage.c_str(), static_cast<unsigned long>(complete),
           static_cast<unsigned long>(member->bytes.size()),
           static_cast<unsigned long long>(member->first_tick),
           static_cast<unsigned long long>(text_event), written ? 1 : 0);
}

void ProcessMalieChunk(const MalieChunk& chunk) {
  if (!malie_io::IsVoicePath(chunk.path)) return;
  MalieMember* member = nullptr;
  if (MalieChunkStartsStream(chunk)) {
    // A new voice stops every other playback still waiting for input.
    for (auto& other : g_malie_members) {
      if (other.used && !(other.decoder == chunk.decoder &&
                          other.path == chunk.path)) {
        StopMalieMember(&other, chunk.tick_ms);
      }
    }
    member = StartMalieMember(chunk);
    MarkMalieIo(fushi_voice_hook::kDiagMalieVoiceRangeQueued);
  } else {
    member = FindMalieMember(chunk.decoder, chunk.path);
    // A decoder whose head was never seen cannot be assembled.
    if (member == nullptr || member->done || member->complete != 0) return;
  }
  if (member->bytes.size() + chunk.length > kMalieMaxMemberBytes) {
    MalieLog(L"voice: oversized %ls", member->path.c_str());
    *member = MalieMember();
    return;
  }
  member->bytes.insert(member->bytes.end(), chunk.data,
                       chunk.data + chunk.length);
  member->last_tick = chunk.tick_ms;
  const uint32_t complete = fushi_voice_hook::siglus::CompleteOggBytes(
      member->bytes.data(), static_cast<uint32_t>(member->bytes.size()));
  if (complete != 0) {
    member->complete = complete;
    member->complete_tick = chunk.tick_ms;
  }
}

// A playback that will receive no more input: keep its whole-page prefix.
void StopMalieMember(MalieMember* member, uint64_t now) {
  if (!member->used || member->done || member->complete != 0) return;
  const uint32_t prefix = malie_io::OggPagePrefixBytes(
      member->bytes.data(), static_cast<uint32_t>(member->bytes.size()));
  if (prefix == 0) {
    MalieLog(L"voice: incomplete %ls bytes=%lu dropped", member->path.c_str(),
             static_cast<unsigned long>(member->bytes.size()));
    member->done = true;
    return;
  }
  member->complete = prefix;
  member->partial = true;
  member->complete_tick = now;
}

// Publishes each complete voice once its message unit is known, or after the
// bind wait without one.
void SettleMalieMembers(uint64_t now) {
  for (auto& member : g_malie_members) {
    if (!member.used || member.done || member.complete == 0) continue;
    const uint64_t text_event = MalieMemberTextEvent(member);
    if (text_event != 0 || now - member.complete_tick >= kMalieBindWaitMs) {
      PublishMalieMember(&member, text_event);
    }
  }
}

void ProcessMalieVoiceTasks() {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0) return;
  // Ready chunks in feed order.
  int order[kMalieChunkSlots] = {};
  int count = 0;
  for (int i = 0; i < kMalieChunkSlots; ++i) {
    if (InterlockedCompareExchange(&g_malie_chunks[i].state, 3, 2) == 2) {
      order[count++] = i;
    }
  }
  std::sort(order, order + count, [](int left, int right) {
    return g_malie_chunks[left].seq < g_malie_chunks[right].seq;
  });
  for (int k = 0; k < count; ++k) {
    ProcessMalieChunk(g_malie_chunks[order[k]]);
    InterlockedExchange(&g_malie_chunks[order[k]].state, 0);
  }
  const uint64_t now = GetTickCount64();
  for (auto& member : g_malie_members) {
    if (member.used && now - member.last_tick > kMaliePartialIdleMs) {
      StopMalieMember(&member, now);
    }
  }
  SettleMalieMembers(now);
  for (auto& member : g_malie_members) {
    if (member.used && member.done && now - member.last_tick > kMalieIdleDropMs) {
      member = MalieMember();
    }
  }
}

bool InstallMalieHook(void* target, void* detour, void** original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, detour, original) == MH_OK;
    ok = created && MH_QueueEnableHook(target) == MH_OK &&
         MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = target;
  } else {
    if (created) MH_RemoveHook(target);
    *original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

#include "malie_lookup.inc"

bool g_malie_hooks_installed = false;

bool TryHookMalieDecoderVoice() {
  if (g_malie_hooks_installed) {
    InterlockedExchange(&g_malie_enabled, 1);
    return true;
  }
  if (!fushi_voice_hook::MatchesMalieProfile(nullptr)) return false;
  ::fushi_voice_hook::exact_lookup::LoadedPeImage image;
  const HMODULE module = GetModuleHandleW(nullptr);
  malie_io::OggFeedSites sites;
  const malie_io::FeedResult result =
      ::fushi_voice_hook::exact_lookup::OpenLoadedPeImage(module, &image)
          ? malie_io::ResolveOggFeed(image, &sites)
          : malie_io::FeedResult::kNotX86;
  if (result != malie_io::FeedResult::kResolved) {
    MalieLog(L"decoder input: unresolved result=%lu",
             static_cast<unsigned long>(result));
    return false;
  }
  g_malie_feed = sites;
  const bool ok = InstallMalieHook(
      reinterpret_cast<void*>(sites.sync_wrote),
      reinterpret_cast<void*>(&MalieSyncWroteDetour),
      reinterpret_cast<void**>(&g_malie_sync_wrote_original));
  MalieLog(L"decoder input: wrote=+0x%lx feeds=%lu stream=+0x%lx "
           L"path=+0x%lx hook=%d",
           static_cast<unsigned long>(sites.sync_wrote -
                                      reinterpret_cast<uintptr_t>(module)),
           static_cast<unsigned long>(sites.feed_count),
           static_cast<unsigned long>(sites.stream_field),
           static_cast<unsigned long>(sites.path_field), ok ? 1 : 0);
  if (!ok) return false;
  g_malie_hooks_installed = true;
  InterlockedExchange(&g_malie_enabled, 1);
  MarkMalieIo(fushi_voice_hook::kDiagMalieArchiveHandleTracked);
  if (g_header != nullptr) {
    g_header->hook_diagnostics |= fushi_voice_hook::kDiagMalieLibpHooksReady;
  }
  return true;
}

void StopMalieDecoderVoice() {
  InterlockedExchange(&g_malie_enabled, 0);
  for (auto& chunk : g_malie_chunks) InterlockedExchange(&chunk.state, 0);
  for (auto& member : g_malie_members) member = MalieMember();
}

class MalieLibpAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "malie_libp"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesMalieProfile(nullptr);
  }
  bool install() override {
    const bool voice = TryHookMalieDecoderVoice();
    const bool lookup = InstallMalieLookup();
    ready_ = voice || lookup;
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() {
    ProcessMalieVoiceTasks();
    ProcessMalieLookupTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopMalieDecoderVoice();
    ShutdownMalieLookup();
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

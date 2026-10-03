// Malie Ogg decoder-input voice lane.
//
// Identity is the engine's "CFI" I/O scheme table (malie_profile.h).  Voice
// is taken where the engine hands bytes to its Ogg Vorbis decoder: the
// decoder's input refill `ogg_sync_wrote(dec, n)` (malie_engine_io_core.h).
// Nothing here reads, decrypts or indexes the archive.
//   * game / audio threads — ogg_sync_wrote detour: only from the decoder's
//     refill call sites (return address).  Every such refill takes the next
//     global feed number (the order and the stall clock of the assembler).
//     The decoder's path field is read onto the stack; only a path below a
//     "voice" directory takes a ring slot (bounded copy of the n bytes at
//     oy->data + oy->fill).  A voice refill that finds no free slot is
//     recorded as lost (decoder + feed) so its stream is cut and marked
//     damaged instead of being assembled with a hole.  No allocation, no IO.
//   * HookWorker — hands the chunks and loss records to
//     malie_io::VoiceAssembler in feed order and writes what it publishes.
#include "malie_profile.h"

namespace malie_io = ::fushi_voice_hook::malie_io;
namespace malie_lookup = ::fushi_voice_hook::malie_lookup;

typedef int32_t(__cdecl* MalieSyncWroteFn)(void* oy, int32_t bytes);

constexpr int kMalieChunkSlots = 96;
constexpr int kMalieDropSlots = 8;
constexpr size_t kMaliePathChars = 260;
// How often a not-yet-ready image is fingerprinted again (malie_profile.h).
constexpr uint64_t kMalieProfileRecheckMs = 1000;

struct MalieChunk {
  volatile LONG state = 0;  // 0 free, 1 filling, 2 ready, 3 worker
  uint64_t feed = 0;
  uint64_t tick_ms = 0;
  uintptr_t decoder = 0;
  uint32_t length = 0;
  wchar_t path[kMaliePathChars] = {0};
  uint8_t data[malie_io::kFeedBytes] = {0};
};

// A voice refill that could not be copied (no free chunk slot).
struct MalieDropRecord {
  volatile LONG state = 0;  // 0 free, 1 filling, 2 ready, 3 worker
  uint64_t feed = 0;
  uintptr_t decoder = 0;
};

MalieSyncWroteFn g_malie_sync_wrote_original = nullptr;
malie_io::OggFeedSites g_malie_feed;
volatile LONG g_malie_enabled = 0;
// Refills from the decoder's refill sites, voice or not (feed order).
volatile LONG64 g_malie_feed_seq = 0;
// Refills between taking a feed number and publishing their result.
volatile LONG g_malie_inflight = 0;
// Lost voice refills whose loss record found no free slot either.
volatile LONG g_malie_drop_overflow = 0;
MalieChunk g_malie_chunks[kMalieChunkSlots];
MalieDropRecord g_malie_drops[kMalieDropSlots];
malie_io::VoiceAssembler g_malie_assembler;  // worker-only

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

// Reads the decoder's path field into `path` (kMaliePathChars, terminated);
// false when unreadable, empty or unterminated.
bool ReadMalieDecoderPath(uintptr_t oy, wchar_t* path) {
  __try {
    const wchar_t* source =
        reinterpret_cast<const wchar_t*>(oy + g_malie_feed.path_field);
    size_t length = 0;
    while (length < kMaliePathChars && source[length] != 0) {
      path[length] = source[length];
      ++length;
    }
    if (length == 0 || length == kMaliePathChars) return false;
    path[length] = 0;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Copies the refill bytes; false when the sync state does not read as one
// (unreadable or out of range).
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
    memcpy(chunk->data, data + fill, bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// A voice refill that was not copied: its stream must not be assembled across
// the hole.
void NoteMalieDrop(uintptr_t decoder, uint64_t feed) {
  for (int i = 0; i < kMalieDropSlots; ++i) {
    MalieDropRecord& record = g_malie_drops[i];
    if (InterlockedCompareExchange(&record.state, 1, 0) != 0) continue;
    record.feed = feed;
    record.decoder = decoder;
    InterlockedExchange(&record.state, 2);
    return;
  }
  InterlockedIncrement(&g_malie_drop_overflow);
}

int32_t __cdecl MalieSyncWroteDetour(void* oy, int32_t bytes) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  if (bytes > 0 && static_cast<uint32_t>(bytes) <= malie_io::kFeedBytes &&
      oy != nullptr &&
      InterlockedCompareExchange(&g_malie_enabled, 0, 0) != 0 &&
      IsMalieFeedReturn(caller)) {
    // In flight before the feed number exists: the worker only takes feeds
    // up to a horizon it read while nothing was in flight.
    InterlockedIncrement(&g_malie_inflight);
    const uint64_t feed =
        static_cast<uint64_t>(InterlockedIncrement64(&g_malie_feed_seq));
    const uintptr_t decoder = reinterpret_cast<uintptr_t>(oy);
    wchar_t path[kMaliePathChars];
    if (ReadMalieDecoderPath(decoder, path) && malie_io::IsVoicePath(path)) {
      MalieChunk* slot = nullptr;
      for (int i = 0; i < kMalieChunkSlots && slot == nullptr; ++i) {
        if (InterlockedCompareExchange(&g_malie_chunks[i].state, 1, 0) == 0) {
          slot = &g_malie_chunks[i];
        }
      }
      if (slot != nullptr &&
          CopyMalieFeed(decoder, static_cast<uint32_t>(bytes), slot)) {
        memcpy(slot->path, path, sizeof(slot->path));
        slot->feed = feed;
        slot->tick_ms = GetTickCount64();
        slot->decoder = decoder;
        slot->length = static_cast<uint32_t>(bytes);
        InterlockedExchange(&slot->state, 2);
        MarkMalieIo(fushi_voice_hook::kDiagMalieReadRangeObserved);
      } else {
        if (slot != nullptr) InterlockedExchange(&slot->state, 0);
        NoteMalieDrop(decoder, feed);
      }
    }
    InterlockedDecrement(&g_malie_inflight);
  }
  return g_malie_sync_wrote_original(oy, bytes);
}

// ── worker ────────────────────────────────────────────────────────────────

// The text event of the latest message unit that carried this voice tag
// (malie_lookup.inc); 0 when no unit names it.
uint64_t MalieTextEventForVoice(const std::wstring& key, uint64_t tick);

class MalieVoiceSink final : public malie_io::VoiceSink {
 public:
  uint64_t TextEvent(const std::wstring& path, uint64_t first_tick) override {
    return MalieTextEventForVoice(malie_lookup::VoiceKeyFromPath(path.c_str()),
                                  first_tick);
  }
  bool Write(const uint8_t* data, uint32_t bytes, const std::wstring& storage,
             uint64_t first_tick, uint64_t text_event) override {
    const bool written =
        WriteVoiceOggAt(data, bytes, storage.c_str(), first_tick, text_event);
    if (written && g_header != nullptr) {
      g_header->hook_diagnostics |=
          fushi_voice_hook::kDiagMalieLibpVoiceCaptured;
    }
    MalieLog(L"voice: %ls bytes=%lu tick=%llu text_event=%llu written=%d "
             L"lost=%lu damaged=%lu",
             storage.c_str(), static_cast<unsigned long>(bytes),
             static_cast<unsigned long long>(first_tick),
             static_cast<unsigned long long>(text_event), written ? 1 : 0,
             static_cast<unsigned long>(g_malie_assembler.dropped()),
             static_cast<unsigned long>(g_malie_assembler.damaged()));
    return written;
  }
  void Note(const wchar_t* what, const std::wstring& path, uint32_t a,
            uint32_t b) override {
    MalieLog(L"voice: %ls %ls %lu %lu", what, path.c_str(),
             static_cast<unsigned long>(a), static_cast<unsigned long>(b));
  }
};

MalieVoiceSink g_malie_voice_sink;

// Returns ready items of the rings to free (after a Stop: they belong to the
// stopped capture).  Slots still being filled are left to their producer.
void DiscardMalieReadyItems() {
  for (auto& chunk : g_malie_chunks) {
    InterlockedCompareExchange(&chunk.state, 0, 2);
  }
  for (auto& record : g_malie_drops) {
    InterlockedCompareExchange(&record.state, 0, 2);
  }
}

struct MalieFeedItem {
  uint64_t feed = 0;
  int index = 0;
  bool drop = false;
};

void ProcessMalieVoiceTasks() {
  if (InterlockedCompareExchange(&g_malie_enabled, 0, 0) == 0) {
    DiscardMalieReadyItems();
    return;
  }
  // Horizon first, then "nothing in flight": every refill numbered up to the
  // horizon has then published its chunk / loss record (or was not voice).
  const uint64_t horizon =
      static_cast<uint64_t>(InterlockedCompareExchange64(&g_malie_feed_seq, 0, 0));
  if (InterlockedCompareExchange(&g_malie_inflight, 0, 0) != 0) return;
  const uint64_t now = GetTickCount64();
  if (InterlockedExchange(&g_malie_drop_overflow, 0) != 0) {
    // Where the holes are is unknown: cut every stream still receiving.
    g_malie_assembler.DropAll(now, g_malie_voice_sink);
  }
  MalieFeedItem items[kMalieChunkSlots + kMalieDropSlots];
  int count = 0;
  for (int i = 0; i < kMalieChunkSlots; ++i) {
    MalieChunk& chunk = g_malie_chunks[i];
    if (InterlockedCompareExchange(&chunk.state, 3, 2) != 2) continue;
    if (chunk.feed > horizon) {
      InterlockedExchange(&chunk.state, 2);  // next round
      continue;
    }
    items[count++] = {chunk.feed, i, false};
  }
  for (int i = 0; i < kMalieDropSlots; ++i) {
    MalieDropRecord& record = g_malie_drops[i];
    if (InterlockedCompareExchange(&record.state, 3, 2) != 2) continue;
    if (record.feed > horizon) {
      InterlockedExchange(&record.state, 2);
      continue;
    }
    items[count++] = {record.feed, i, true};
  }
  std::sort(items, items + count,
            [](const MalieFeedItem& left, const MalieFeedItem& right) {
              return left.feed < right.feed;
            });
  for (int k = 0; k < count; ++k) {
    const MalieFeedItem& item = items[k];
    if (item.drop) {
      MalieDropRecord& record = g_malie_drops[item.index];
      g_malie_assembler.Drop(record.decoder, record.feed, now,
                             g_malie_voice_sink);
      InterlockedExchange(&record.state, 0);
      continue;
    }
    MalieChunk& chunk = g_malie_chunks[item.index];
    if (malie_io::StartsOggStream(chunk.data, chunk.length)) {
      MarkMalieIo(fushi_voice_hook::kDiagMalieVoiceRangeQueued);
    }
    malie_io::FeedChunk feed;
    feed.feed = chunk.feed;
    feed.decoder = chunk.decoder;
    feed.tick = chunk.tick_ms;
    feed.path = chunk.path;
    feed.data = chunk.data;
    feed.length = chunk.length;
    g_malie_assembler.Feed(feed, g_malie_voice_sink);
    InterlockedExchange(&chunk.state, 0);
  }
  g_malie_assembler.Settle(horizon, now, g_malie_voice_sink);
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

// Runs on the HookWorker thread (AdapterRegistry::Shutdown from the worker
// loop), the only consumer of the rings.  Producers may be inside the detour
// right now: a slot they are filling (state 1) is theirs and is never
// touched here — clearing it would let a second producer claim a slot still
// being written.  Ready items are discarded, the rest after they publish
// (ProcessMalieVoiceTasks while disabled).
void StopMalieDecoderVoice() {
  InterlockedExchange(&g_malie_enabled, 0);
  DiscardMalieReadyItems();
  InterlockedExchange(&g_malie_drop_overflow, 0);
  g_malie_assembler.Reset();
}

class MalieLibpAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "malie_libp"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesMalieProfile(nullptr);
  }
  bool install() override {
    NoteProfileState();
    const bool voice = TryHookMalieDecoderVoice();
    const bool lookup = InstallMalieLookup();
    ready_ = voice || lookup;
    installed_ = installed_ || ready_;
    return ready_;
  }
  void ProcessPendingEvents() {
    RecheckProfile();
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
    shut_down_ = true;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  // The first probe ran before the game's main thread resumed; an image that
  // was not ready then (still unpacking) is measured again once it changed,
  // and installed when it matches.
  void RecheckProfile() {
    if (shut_down_ || installed_ ||
        fushi_voice_hook::MalieProfileState() !=
            malie_io::ProfileState::kImageNotReady) {
      return;
    }
    const uint64_t now = GetTickCount64();
    if (recheck_tick_ != 0 && now - recheck_tick_ < kMalieProfileRecheckMs) {
      return;
    }
    recheck_tick_ = now;
    fushi_voice_hook::MeasureMalieProfile();
    NoteProfileState();
    if (fushi_voice_hook::MalieProfileState() ==
        malie_io::ProfileState::kMatched) {
      install();
    }
  }
  // Logs a match and every verdict reached after "image not ready"; the
  // first refusal of a game that is simply not Malie stays silent.
  void NoteProfileState() {
    const auto state = fushi_voice_hook::MalieProfileState();
    if (state == logged_state_) return;
    const bool was_not_ready =
        logged_state_ == malie_io::ProfileState::kImageNotReady;
    logged_state_ = state;
    if (state != malie_io::ProfileState::kMatched && !was_not_ready) return;
    static const wchar_t* const kNames[] = {L"unmeasured", L"matched",
                                            L"image-not-ready", L"rejected"};
    const uint32_t index = static_cast<uint32_t>(state);
    MalieLog(L"identity: %ls (scheme result=%lu)",
             index < 4u ? kNames[index] : L"?",
             static_cast<unsigned long>(
                 fushi_voice_hook::MalieProfile().last_result.load()));
  }

  bool installed_ = false;
  bool ready_ = false;
  bool shut_down_ = false;
  uint64_t recheck_tick_ = 0;
  malie_io::ProfileState logged_state_ = malie_io::ProfileState::kUnmeasured;
};

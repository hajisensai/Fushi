// YU-RIS per-line voice at the decoder input (yuris_voice_core.h).
//
// The detour sits on the engine's ov_open_callbacks call target.  When the
// datasource is one of the engine's own memory-stream sound objects (the
// callbacks are the engine's static table), the game thread copies the
// encoded Ogg the engine is about to decode — bounded, into a preallocated
// slot — together with the resource name the script played, and returns.
// The HookWorker validates the stream (complete Ogg, Vorbis, mono) and writes
// it as a resource clip named after the engine's resource; the consumer pairs
// it with the line on screen.  No archive is read and nothing is decoded or
// decrypted here: these are the bytes the engine already handed to its
// decoder.

#if defined(_M_IX86)

namespace yuris_voice = fushi_voice_hook::yuris_voice;

constexpr uint32_t kYurisClipSlots = 4u;
constexpr uint32_t kYurisClipBytes = 1u << 20;
constexpr uint32_t kYurisNameBytes = 128u;

// Adapter-local diagnostics (AdapterDiagnostics::flags).
constexpr uint32_t kYurisDiagVoiceHooksReady = 0x00000001u;
constexpr uint32_t kYurisDiagDecoderInputObserved = 0x00000002u;
constexpr uint32_t kYurisDiagVoiceCaptured = 0x00000004u;
constexpr uint32_t kYurisDiagClipRejected = 0x00000008u;
constexpr uint32_t kYurisDiagClipDropped = 0x00000010u;
constexpr uint32_t kYurisDiagDecoderSitesRejected = 0x00000020u;

volatile LONG g_yuris_diag = 0;

void NoteYurisDiag(uint32_t bit) {
  InterlockedOr(&g_yuris_diag, static_cast<LONG>(bit));
}

struct YurisOvCallbacks {
  void* read;
  void* seek;
  void* close;
  void* tell;
};
using YurisOvOpenFn = int(__cdecl*)(void*, void*, const char*, long,
                                    YurisOvCallbacks);

struct YurisClipSlot {
  volatile LONG state = 0;  // 0 free, 1 producing, 2 pending, 3 consuming
  uint64_t tick = 0u;
  uint32_t bytes = 0u;
  char name[kYurisNameBytes] = {};
  uint8_t data[kYurisClipBytes] = {};
};

struct YurisVoiceRuntime {
  bool resolved = false;
  bool installed = false;
  yuris_voice::DecoderSites sites;
  uintptr_t image_base = 0u;
  uintptr_t read_callback = 0u;
  std::atomic<bool> live{false};
  // game thread: the stream each sound object last opened.  Reopening the
  // same stream (restart, loop) is not a new clip.
  struct Opened {
    uintptr_t source = 0u;
    uintptr_t data = 0u;
    uint32_t bytes = 0u;
  };
  std::array<Opened, 32> opened{};
  uint32_t next_opened = 0u;
};

YurisVoiceRuntime g_yuris_voice;

// Worker-only: validated clips waiting for the message they voice.
struct YurisPendingVoice {
  bool used = false;
  uint64_t tick = 0u;
  std::vector<uint8_t> data;
  wchar_t storage[kYurisNameBytes] = {};
};
std::array<YurisPendingVoice, 4> g_yuris_pending_voices;
YurisClipSlot g_yuris_clips[kYurisClipSlots];
YurisOvOpenFn g_yuris_ov_open_original = nullptr;

void CaptureYurisDecoderInput(void* source, void* read) {
  auto& rt = g_yuris_voice;
  if (!rt.live.load(std::memory_order_acquire) || source == nullptr ||
      reinterpret_cast<uintptr_t>(read) != rt.read_callback) {
    return;
  }
  __try {
    const auto base = reinterpret_cast<uintptr_t>(source);
    const auto* data =
        *reinterpret_cast<const uint8_t* const*>(base + rt.sites.data);
    const uint32_t bytes =
        *reinterpret_cast<const uint32_t*>(base + rt.sites.size);
    NoteYurisDiag(kYurisDiagDecoderInputObserved);
    if (data == nullptr || bytes < 64u || std::memcmp(data, "OggS", 4) != 0) {
      return;
    }
    const uint64_t now = GetTickCount64();
    YurisVoiceRuntime::Opened* entry = nullptr;
    for (auto& opened : rt.opened) {
      if (opened.source == base) entry = &opened;
    }
    if (entry != nullptr && entry->data == reinterpret_cast<uintptr_t>(data) &&
        entry->bytes == bytes) {
      return;  // the same stream reopened by the same sound object
    }
    if (entry == nullptr) {
      entry = &rt.opened[rt.next_opened++ % rt.opened.size()];
      entry->source = base;
    }
    entry->data = reinterpret_cast<uintptr_t>(data);
    entry->bytes = bytes;
    if (bytes > kYurisClipBytes) return;  // music-sized: not a line of voice
    for (YurisClipSlot& slot : g_yuris_clips) {
      if (InterlockedCompareExchange(&slot.state, 1, 0) != 0) continue;
      slot.tick = now;
      slot.bytes = bytes;
      std::memcpy(slot.data, data, bytes);
      size_t n = 0u;
      const auto* name = reinterpret_cast<const char*>(source);
      while (n + 1u < kYurisNameBytes && name[n] != '\0') {
        slot.name[n] = name[n];
        ++n;
      }
      slot.name[n] = '\0';
      InterlockedExchange(&slot.state, 2);
      return;
    }
    NoteYurisDiag(kYurisDiagClipDropped);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

int __cdecl YurisOvOpenDetour(void* source, void* file, const char* initial,
                              long initial_bytes, YurisOvCallbacks callbacks) {
  CaptureYurisDecoderInput(source, callbacks.read);
  return g_yuris_ov_open_original(source, file, initial, initial_bytes,
                                  callbacks);
}

void ProcessYurisClip(YurisClipSlot& slot) {
  uint32_t rate = 0u;
  const uint32_t channels =
      yuris_voice::OggVorbisChannels(slot.data, slot.bytes, &rate);
  char base[kYurisNameBytes] = {};
  if (channels != 1u ||
      fushi_voice_hook::siglus::CompleteOggBytes(slot.data, slot.bytes) !=
          slot.bytes ||
      yuris_voice::ResourceBasename(slot.name, kYurisNameBytes, base,
                                    sizeof(base)) == 0u) {
    // Stereo (music / ambience), a truncated stream or no resource name.
    NoteYurisDiag(kYurisDiagClipRejected);
    return;
  }
  wchar_t storage[kYurisNameBytes] = {};
  if (MultiByteToWideChar(932, 0, base, -1, storage,
                          static_cast<int>(std::size(storage))) <= 0) {
    NoteYurisDiag(kYurisDiagClipRejected);
    return;
  }
  // Held until the message it voices is published (BindYurisPendingVoice).
  for (YurisPendingVoice& pending : g_yuris_pending_voices) {
    if (pending.used) continue;
    pending.used = true;
    pending.tick = slot.tick;
    pending.data.assign(slot.data, slot.data + slot.bytes);
    wcsncpy_s(pending.storage, storage, _TRUNCATE);
    return;
  }
  NoteYurisDiag(kYurisDiagClipDropped);
}

void PublishYurisPendingVoice(YurisPendingVoice& pending,
                              uint64_t text_event) {
  if (WriteVoiceOggAt(pending.data.data(),
                      static_cast<uint32_t>(pending.data.size()),
                      pending.storage, pending.tick, text_event)) {
    NoteYurisDiag(kYurisDiagVoiceCaptured);
    // The bytes are the engine's own resource (the decoder input), so the
    // host can pair per line instead of falling back to PCM / loopback.
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
  }
  pending.used = false;
  pending.data.clear();
  pending.data.shrink_to_fit();
}

// The script plays a line's voice and then shows the line: the first message
// published within the binding window after a clip opened is the line it
// voices (measured on both samples: the clip opens 88-276 ms before the
// message's first character).  The clip is written with that message's text
// event id, so the host pairs by identity, not by a timing guess.
void BindYurisPendingVoice(uint64_t text_event, uint64_t text_tick) {
  for (YurisPendingVoice& pending : g_yuris_pending_voices) {
    if (pending.used && text_tick >= pending.tick &&
        text_tick - pending.tick <= yuris_voice::kVoiceToTextWindowMs) {
      PublishYurisPendingVoice(pending, text_event);
    }
  }
}

void ProcessYurisVoiceTasks() {
  for (YurisClipSlot& slot : g_yuris_clips) {
    if (InterlockedCompareExchange(&slot.state, 3, 2) == 2) {
      ProcessYurisClip(slot);
      InterlockedExchange(&slot.state, 0);
    }
  }
  // A clip no message followed (a voiced effect, a backlog replay): publish it
  // without an owner; the host then only time-pairs it.
  const uint64_t now = GetTickCount64();
  for (YurisPendingVoice& pending : g_yuris_pending_voices) {
    if (pending.used && now - pending.tick > yuris_voice::kVoiceToTextWindowMs) {
      PublishYurisPendingVoice(pending, 0u);
    }
  }
}

bool InstallYurisVoice() {
  auto& rt = g_yuris_voice;
  if (rt.installed) {
    rt.live.store(true, std::memory_order_release);
    return true;
  }
  if (rt.resolved) return false;
  rt.resolved = true;
  const yuris_lookup::ImageView& view = g_yuris_pristine_view;
  const uintptr_t live_base =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (view.bytes == nullptr || view.va_base != live_base) {
    NoteYurisDiag(kYurisDiagDecoderSitesRejected);
    return false;
  }
  const auto result = yuris_voice::ResolveDecoderSites(view, &rt.sites);
  if (result != yuris_voice::DecoderResult::kResolved ||
      !YurisLiveMatches(live_base, rt.sites.ov_open, 8u)) {
    NoteYurisDiag(kYurisDiagDecoderSitesRejected);
    YurisLookupLog(L"yuris-voice: decoder sites unresolved result=%u",
                   static_cast<unsigned>(result));
    return false;
  }
  rt.image_base = live_base;
  rt.read_callback =
      static_cast<uintptr_t>(yuris_lookup::U32(view, rt.sites.callbacks));
  rt.live.store(true, std::memory_order_release);
  void* target = reinterpret_cast<void*>(live_base + rt.sites.ov_open);
  bool ok = false;
  if (g_cs_ready) {
    EnterCriticalSection(&g_cs);
    ok = g_hooked_count + 1 <= 64;
    for (int i = 0; ok && i < g_hooked_count; ++i) {
      ok = g_hooked_fns[i] != target;
    }
    bool created = false;
    if (ok) {
      created = MH_CreateHook(target,
                              reinterpret_cast<void*>(&YurisOvOpenDetour),
                              reinterpret_cast<void**>(
                                  &g_yuris_ov_open_original)) == MH_OK;
      ok = created && MH_QueueEnableHook(target) == MH_OK &&
           MH_ApplyQueued() == MH_OK;
    }
    if (ok) {
      g_hooked_fns[g_hooked_count++] = target;
    } else if (created) {
      MH_RemoveHook(target);
    }
    LeaveCriticalSection(&g_cs);
  }
  rt.installed = ok;
  if (!ok) rt.live.store(false, std::memory_order_release);
  if (ok) NoteYurisDiag(kYurisDiagVoiceHooksReady);
  YurisLookupLog(L"yuris-voice: decoder ov_open=+0x%lx data=0x%x size=0x%x "
                 L"sites=%u hooked=%d",
                 static_cast<unsigned long>(rt.sites.ov_open), rt.sites.data,
                 rt.sites.size, rt.sites.sites, ok ? 1 : 0);
  return ok;
}

void StopYurisVoice() {
  g_yuris_voice.live.store(false, std::memory_order_release);
}

#else  // !_M_IX86

volatile LONG g_yuris_diag = 0;
bool InstallYurisVoice() { return false; }
void ProcessYurisVoiceTasks() {}
void StopYurisVoice() {}
void BindYurisPendingVoice(uint64_t, uint64_t) {}

#endif  // _M_IX86

// FVP (Favorite View Point) adapter: native TextPrint text lane + engine-exact
// in-game lookup (fvp_lookup.inc) and clean per-line voice from the engine's
// own audio decoder input.
//
// Voice: `AudioPlay` reaches ChannelPlay, which reads the channel's named
// resource into memory and hands that memory to the channel sound object's
// SoundLoad (the decoder's input; it sniffs RIFF / OggS and opens the stream
// from those bytes) — see fvp_lookup_core.h ResolveAudioSites.  The
// ChannelPlay detour remembers the resource name (bounded) and its script
// position for its own thread; the SoundLoad detour copies the bytes it is
// handed into a preallocated slot only when that resource name is a voice
// resource (a `voice` directory component, fvp_format.h IsVoiceResourceName).
// The channel count is corroboration only (the bytes really are Ogg Vorbis),
// never the classifier.  Binding to the dialogue print goes by script order:
// the print of the same dispatch (fvp_lookup_core.h BindVoiceInDispatch),
// with a bounded "next print in script order" fallback.  Validation and file
// output run from AdapterRegistry::Poll.  No archive is opened or parsed.
#include "fvp_profile.h"
#include "fvp_lookup.inc"

#if defined(_M_IX86)

constexpr uint32_t kFvpVoiceSlots = 4u;
// A voice line is tens of KiB; a longer stream (BGM) is not copied.
constexpr uint32_t kFvpVoiceMaxBytes = 2u * 1024u * 1024u;
constexpr size_t kFvpVoiceNameBytes = 64u;

struct FvpVoiceSlot {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0u;
  uint64_t step = 0u;   // script position of its AudioPlay
  uint64_t epoch = 0u;  // draws counted when it ran (its dispatch)
  uint32_t bytes = 0u;
  char name[kFvpVoiceNameBytes] = {};
  uint8_t* data = nullptr;  // kFvpVoiceMaxBytes, allocated at install
};

struct FvpVoiceRuntime {
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  fvp_lookup::AudioSiteResult result = fvp_lookup::AudioSiteResult::kNotX86;
  fvp_lookup::AudioSites sites;
  std::atomic<bool> live{false};
  // Game thread: ChannelPlay → SoundLoad context (one game thread).
  std::atomic<DWORD> play_thread{0u};
  char play_name[kFvpVoiceNameBytes] = {};
  uint64_t play_step = 0u;
  uint64_t play_epoch = 0u;
  std::array<FvpVoiceSlot, kFvpVoiceSlots> slots{};
  std::atomic<uint32_t> dropped{0u};
  uint32_t logged = 0u;
};

FvpVoiceRuntime g_fvp_voice;
using FvpChannelPlayFn = int(__thiscall*)(uintptr_t, int, int);
using FvpSoundLoadFn = int(__thiscall*)(uintptr_t, const void*, uint32_t, int);
FvpChannelPlayFn g_fvp_channel_play_original = nullptr;
FvpSoundLoadFn g_fvp_sound_load_original = nullptr;

int __fastcall FvpChannelPlayDetour(uintptr_t self, uintptr_t, int a, int b) {
  auto& rt = g_fvp_voice;
  const DWORD thread = GetCurrentThreadId();
  DWORD expected = 0u;
  const bool owned =
      rt.live.load(std::memory_order_acquire) && self != 0u &&
      rt.play_thread.compare_exchange_strong(expected, thread,
                                             std::memory_order_acq_rel);
  if (owned) {
    rt.play_name[0] = 0;
    // Same step counter and draw epoch as the TextPrint detour.
    rt.play_step = g_fvp_lookup.script_steps.fetch_add(
                       1u, std::memory_order_acq_rel) +
                   1u;
    rt.play_epoch = g_fvp_lookup.draw_calls.load(std::memory_order_acquire);
    __try {
      const char* name =
          *reinterpret_cast<const char* const*>(self + rt.sites.channel_name);
      size_t length = 0u;
      while (name != nullptr && length + 1u < kFvpVoiceNameBytes &&
             name[length] != 0) {
        rt.play_name[length] = name[length];
        ++length;
      }
      rt.play_name[length] = 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      rt.play_name[0] = 0;
    }
  }
  const int result = g_fvp_channel_play_original(self, a, b);
  if (owned) rt.play_thread.store(0u, std::memory_order_release);
  return result;
}

int __fastcall FvpSoundLoadDetour(uintptr_t self, uintptr_t, const void* data,
                                  uint32_t size, int flag) {
  auto& rt = g_fvp_voice;
  // Only a voice resource is copied: SE / BGM never take a slot.
  if (rt.play_thread.load(std::memory_order_acquire) == GetCurrentThreadId() &&
      data != nullptr && size >= 64u && size <= kFvpVoiceMaxBytes &&
      fushi_voice_hook::fvp::IsVoiceResourceName(rt.play_name,
                                                 kFvpVoiceNameBytes)) {
    bool ogg = false;
    __try {
      ogg = memcmp(data, "OggS", 4) == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      ogg = false;
    }
    FvpVoiceSlot* slot = nullptr;
    for (uint32_t i = 0; ogg && i < kFvpVoiceSlots; ++i) {
      if (rt.slots[i].data != nullptr &&
          InterlockedCompareExchange(&rt.slots[i].state, 1, 0) == 0) {
        slot = &rt.slots[i];
        break;
      }
    }
    if (ogg && slot == nullptr) rt.dropped.fetch_add(1u);
    if (slot != nullptr) {
      bool copied = true;
      __try {
        memcpy(slot->data, data, size);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        copied = false;
      }
      slot->tick_ms = GetTickCount64();
      slot->step = rt.play_step;
      slot->epoch = rt.play_epoch;
      slot->bytes = size;
      memcpy(slot->name, rt.play_name, kFvpVoiceNameBytes);
      InterlockedExchange(&slot->state, copied ? 2 : 0);
    }
  }
  return g_fvp_sound_load_original(self, data, size, flag);
}

// How long a captured voice waits for its dialogue print before it is
// written unbound (time-paired by the consumer).
constexpr uint64_t kFvpVoiceBindWindowMs = 1500u;

void WriteFvpVoiceSlot(FvpVoiceSlot& slot, uint64_t text_event) {
  auto& rt = g_fvp_voice;
  const uint32_t channels =
      fushi_voice_hook::fvp::VorbisChannels(slot.data, slot.bytes);
  const bool complete =
      fushi_voice_hook::siglus::CompleteOggBytes(slot.data, slot.bytes) ==
      slot.bytes;
  wchar_t storage[kFvpVoiceNameBytes + 8u] = {};
  fvp_lookup::AudioStorageName(slot.name, kFvpVoiceNameBytes, storage,
                               std::size(storage));
  bool written = false;
  // The resource name decides (a voice resource); the channel count only
  // corroborates that the bytes are an Ogg Vorbis stream.
  const bool voice = fushi_voice_hook::fvp::IsVoiceResourceName(
      slot.name, kFvpVoiceNameBytes);
  if (voice && channels != 0u && complete) {
    written = WriteVoiceOggAt(slot.data, slot.bytes, storage, slot.tick_ms,
                              text_event);
    if (written) {
      NoteFvpFlag(kFvpFlagVoiceCaptured);
      // The host switches the session to the resource backend on this bit.
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
    }
  }
  if (rt.logged < kFvpModelLogBudget) {
    ++rt.logged;
    FvpLookupLog(L"fvp-voice: decoder input %s bytes=%u channels=%u "
                 L"complete=%d written=%d text_event=%llu dropped=%u",
                 storage, slot.bytes, channels, complete ? 1 : 0,
                 written ? 1 : 0, static_cast<unsigned long long>(text_event),
                 rt.dropped.load());
  }
  InterlockedExchange(&slot.state, 0);
}

// `epoch_now` is the draw counter read before this tick drained the text
// events: every print of a dispatch that ended by then is already in the
// published-text history (Print publishes before the game thread draws).
void ProcessFvpVoiceSlots(uint64_t epoch_now) {
  const uint64_t now = GetTickCount64();
  const uint64_t selected =
      g_header == nullptr
          ? 0u
          : fushi_voice_hook::AtomicLoadPreview64(
                &g_header->selected_text_thread_id);
  for (FvpVoiceSlot& slot : g_fvp_voice.slots) {
    InterlockedCompareExchange(&slot.state, 3, 2);  // claim new captures
    if (InterlockedCompareExchange(&slot.state, 3, 3) != 3) continue;
    // Not an Ogg Vorbis stream: nothing to bind, release without waiting.
    if (fushi_voice_hook::fvp::VorbisChannels(slot.data, slot.bytes) == 0u) {
      WriteFvpVoiceSlot(slot, 0u);
      continue;
    }
    const fvp_lookup::VoiceOrder order{slot.tick_ms, slot.step, slot.epoch};
    const fvp_lookup::DispatchBinding in_dispatch =
        fvp_lookup::BindVoiceInDispatch(g_fvp_published_text.data(),
                                        g_fvp_published_text.size(), order,
                                        selected, epoch_now);
    uint64_t event = in_dispatch.event;
    if (in_dispatch.settled && event == 0u) {
      // The dispatch printed no dialogue: the next print in script order.
      event = fvp_lookup::BindVoiceToFollowingText(
          g_fvp_published_text.data(), g_fvp_published_text.size(), order,
          selected, kFvpVoiceBindWindowMs);
    }
    if (event != 0u || selected == 0u ||
        now - slot.tick_ms > kFvpVoiceBindWindowMs) {
      WriteFvpVoiceSlot(slot, event);
    }
  }
}

bool InstallFvpVoice() {
  auto& rt = g_fvp_voice;
  if (rt.installed) return true;
  if (rt.resolved) {
    // Re-install after a shutdown: the detours are still chained.
    if (!rt.hooks_installed) return false;
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  if (!FvpLookupSitesResolved()) return false;
  rt.resolved = true;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    return false;
  }
  rt.result = fvp_lookup::ResolveAudioSites(
      image, g_fvp_lookup.sites.vm_global, &rt.sites);
  if (rt.result != fvp_lookup::AudioSiteResult::kResolved) {
    FvpLookupLog(L"fvp-voice: sites unresolved result=%u",
                 static_cast<unsigned>(rt.result));
    return false;
  }
  for (FvpVoiceSlot& slot : rt.slots) {
    slot.data = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kFvpVoiceMaxBytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    if (slot.data == nullptr) return false;
  }
  rt.live.store(true, std::memory_order_release);
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  const bool load = InstallFvpHook(
      reinterpret_cast<void*>(base + rt.sites.sound_load),
      reinterpret_cast<void*>(&FvpSoundLoadDetour),
      reinterpret_cast<void**>(&g_fvp_sound_load_original));
  const bool play =
      load && InstallFvpHook(
                  reinterpret_cast<void*>(base + rt.sites.channel_play),
                  reinterpret_cast<void*>(&FvpChannelPlayDetour),
                  reinterpret_cast<void**>(&g_fvp_channel_play_original));
  rt.hooks_installed = load && play;
  rt.installed = rt.hooks_installed;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  if (rt.installed) NoteFvpFlag(kFvpFlagVoiceHooked);
  FvpLookupLog(L"fvp-voice: sites play=+0x%lx load=+0x%lx name=0x%x hooks=%d/%d",
               static_cast<unsigned long>(rt.sites.channel_play),
               static_cast<unsigned long>(rt.sites.sound_load),
               rt.sites.channel_name, play ? 1 : 0, load ? 1 : 0);
  return rt.installed;
}

uint64_t FvpDrawEpoch() {
  return g_fvp_lookup.draw_calls.load(std::memory_order_acquire);
}

void ShutdownFvpVoice() {
  auto& rt = g_fvp_voice;
  // Detours stay chained; clearing `live` makes them pure forwarders.
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

#else  // !_M_IX86

bool InstallFvpVoice() { return false; }
void ProcessFvpVoiceSlots(uint64_t) {}
uint64_t FvpDrawEpoch() { return 0u; }
void ShutdownFvpVoice() {}

#endif  // _M_IX86

class FvpAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "fvp"; }
  // The identity reads the HCB trailer from disk; it cannot change while the
  // process runs, so it is measured once.
  bool probe() const override {
    if (probe_state_ == 0) {
      probe_state_ = fushi_voice_hook::MatchesFvpProfile(nullptr) ? 1 : 2;
    }
    return probe_state_ == 1;
  }
  bool install() override {
    if (!probe()) return false;
    // Text, lookup and voice sites all come from the exe's own structure;
    // each installs or refuses on its own.
    text_installed_ = InstallFvpLookup() || text_installed_;
    voice_installed_ = InstallFvpVoice() || voice_installed_;
    installed_ = text_installed_ || voice_installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    // Epoch first, then drain the prints, then bind the voices against them.
    const uint64_t epoch = FvpDrawEpoch();
    ProcessFvpLookupTick();
    ProcessFvpVoiceSlots(epoch);
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (FvpLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    if (FvpLookupSitesRejected()) {
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
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownFvpLookup();
    ShutdownFvpVoice();
    text_installed_ = false;
    voice_installed_ = false;
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_fvp_flags.load(std::memory_order_relaxed)};
  }

 private:
  mutable int probe_state_ = 0;  // 0 = unmeasured, 1 = FVP, 2 = not FVP
  bool installed_ = false;
  bool text_installed_ = false;
  bool voice_installed_ = false;
};

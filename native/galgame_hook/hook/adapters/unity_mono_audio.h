#pragma once

// Unity (Mono runtime) per-line voice: pure, unit-tested half.
//
// What is a line's voice on a Unity Mono player, structurally:
//   * Playback: every AudioSource start funnels into an engine internal call
//     — `AudioSource.PlayOneShotHelper(AudioSource, AudioClip, float)`,
//     `AudioSource.PlayHelper(AudioSource, ulong)` and the private extern
//     `AudioSource.Play(double)` (PlayDelayed / PlayScheduled) on 2019+
//     players; `PlayOneShot(AudioClip, float)` / `Play(ulong)` are the
//     externs themselves on older ones.  The C entries are hooked (managed
//     wrappers can be inlined by the JIT; the entry cannot be bypassed).
//   * Which clip is voice: the clip must live in an asset bundle whose file
//     the player opened under a `*voice*.bundle` name (the Unity-wide
//     Addressables / AssetBundle naming the IL2CPP path already relies on,
//     `IsUnityVoiceBundle` in siglus_adapter.inc), proven out of process by
//     the injector's extractor finding the clip there — a BGM / SE / jingle
//     clip is not in any voice bundle and never becomes a voice file.  With
//     no voice bundle seen at all nothing is published (the loose-asset
//     fallback would happily extract a sound effect).
//   * Fungus (public VN framework): `WriterAudio.OnVoiceover(AudioClip)` is
//     the framework's own "this line's voice" call and is published even
//     without a voice bundle; `WriterAudio.OnGlyph()` / `OnStart(AudioClip)`
//     play the typing beeps / typing sound effect, and a playback started
//     inside them is not a voice candidate.
//
// Measured (2026-09-28, Frida, Unity 2021.3.10f1 Mono x64 Fungus title — the
// sample only, never an identity input): the line's voice is a
// PlayOneShotHelper on the main thread ~4 ms before SayDialog.DoSay;
// AudioClip.GetData returns false for these Compressed-In-Memory Vorbis clips
// (so no in-process PCM); typing beeps are PlayHelper calls from
// WriterAudio.OnGlyph on the dialog's own source; BGM is a Streaming clip on
// a PlayHelper.
//
// Nothing here consults a hash, file name or title.

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>

#include "unity_mono_lookup_core.h"

namespace fushi_voice_hook::unity_mono_audio {

namespace ul = fushi_voice_hook::unity_mono_lookup;

inline constexpr int kMonoTypeU8 = 0x0b;
inline constexpr int kMonoTypeR8 = 0x0d;

enum class AudioIcall : uint8_t {
  kPlayOneShotHelper = 0,  // static void (AudioSource, AudioClip, float)
  kPlayHelper,             // static void (AudioSource, ulong)
  kPlayDelayed,            // instance void Play(double)
  kLegacyPlayOneShot,      // instance void PlayOneShot(AudioClip, float)
  kLegacyPlay,             // instance void Play(ulong)
  kGetClip,                // instance AudioClip get_clip()
  kCount,
};
inline constexpr size_t kAudioIcallCount =
    static_cast<size_t>(AudioIcall::kCount);

inline constexpr ul::IcallSpec kAudioIcallSpecs[kAudioIcallCount] = {
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "PlayOneShotHelper",
     false, kMonoTypeVoid, 3, {kMonoTypeClass, kMonoTypeClass, kMonoTypeSingle},
     0u},
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "PlayHelper", false,
     kMonoTypeVoid, 2, {kMonoTypeClass, kMonoTypeU8, 0}, 0u},
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "Play", true,
     kMonoTypeVoid, 1, {kMonoTypeR8, 0, 0}, 0u},
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "PlayOneShot", true,
     kMonoTypeVoid, 2, {kMonoTypeClass, kMonoTypeSingle, 0}, 0u},
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "Play", true,
     kMonoTypeVoid, 1, {kMonoTypeU8, 0, 0}, 0u},
    {ul::Icall::kCount, "UnityEngine", "AudioSource", "get_clip", true,
     kMonoTypeClass, 0, {0, 0, 0}, 0u},
};

// Playback entries that carry the clip themselves / read it from the source.
inline constexpr bool AudioIcallCarriesClip(AudioIcall id) {
  return id == AudioIcall::kPlayOneShotHelper ||
         id == AudioIcall::kLegacyPlayOneShot;
}

enum class WriterAudioMethod : uint8_t {
  kOnGlyph = 0,     // void OnGlyph()
  kOnStart,         // void OnStart(AudioClip)
  kOnVoiceover,     // void OnVoiceover(AudioClip)
  kCount,
};
inline constexpr size_t kWriterAudioMethodCount =
    static_cast<size_t>(WriterAudioMethod::kCount);

struct AudioSites {
  void* icalls[kAudioIcallCount] = {};
  void* get_name = nullptr;          // UnityEngine.Object.GetName icall
  uint32_t cached_ptr_offset = 0u;   // UnityEngine.Object.m_CachedPtr
  // Fungus WriterAudio (MonoMethod*): all three or none.
  void* writer_audio[kWriterAudioMethodCount] = {};

  bool HasWriterAudio() const { return writer_audio[0] != nullptr; }
  bool AnyPlayback() const {
    for (size_t i = 0; i < kAudioIcallCount; ++i) {
      if (static_cast<AudioIcall>(i) != AudioIcall::kGetClip &&
          icalls[i] != nullptr) {
        return true;
      }
    }
    return false;
  }
};

enum class AudioSiteResult : uint32_t {
  kResolved = 0,
  kApiIncomplete = 1,
  kNoPlayback = 2,     // no AudioSource playback internal call
  kNoClipGetter = 3,   // a clip-less entry but no AudioSource.get_clip
  kNoObjectName = 4,   // UnityEngine.Object.GetName / m_CachedPtr missing
};

// Caller must be attached to the root domain.
inline AudioSiteResult ResolveAudioSites(const MonoEmbeddingApi& api,
                                         const ul::MonoLookupApi& lookup,
                                         AudioSites* out) {
  if (out == nullptr || !api.CompleteForResolution() || !lookup.Complete()) {
    return AudioSiteResult::kApiIncomplete;
  }
  *out = AudioSites();
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  for (size_t i = 0; i < kAudioIcallCount; ++i) {
    out->icalls[i] = ul::ResolveIcall(api, lookup, list, kAudioIcallSpecs[i]);
  }
  if (!out->AnyPlayback()) {
    *out = AudioSites();
    return AudioSiteResult::kNoPlayback;
  }
  const bool needs_clip_getter =
      out->icalls[static_cast<size_t>(AudioIcall::kPlayHelper)] != nullptr ||
      out->icalls[static_cast<size_t>(AudioIcall::kPlayDelayed)] != nullptr ||
      out->icalls[static_cast<size_t>(AudioIcall::kLegacyPlay)] != nullptr;
  if (needs_clip_getter &&
      out->icalls[static_cast<size_t>(AudioIcall::kGetClip)] == nullptr) {
    *out = AudioSites();
    return AudioSiteResult::kNoClipGetter;
  }
  out->get_name = ul::ResolveIcall(api, lookup, list, ul::kObjectGetNameSpec);
  void* unity_object =
      ul::FindClassInImages(api, list, "UnityEngine", "Object");
  if (out->get_name == nullptr ||
      !ul::FieldOfType(api, lookup, unity_object, "m_CachedPtr", ul::kMonoTypeI,
                       nullptr, &out->cached_ptr_offset)) {
    *out = AudioSites();
    return AudioSiteResult::kNoObjectName;
  }
  // Fungus WriterAudio: optional, all three methods or none.
  void* writer =
      ul::FindClassInImages(api, list, "Fungus", "WriterAudio");
  if (writer != nullptr) {
    const int clip_param[1] = {kMonoTypeClass};
    void* on_glyph = FindMonoMethod(api, writer, "OnGlyph", true,
                                    kMonoTypeVoid, 0, nullptr);
    void* on_start = FindMonoMethod(api, writer, "OnStart", true,
                                    kMonoTypeVoid, 1, clip_param);
    void* on_voiceover = FindMonoMethod(api, writer, "OnVoiceover", true,
                                        kMonoTypeVoid, 1, clip_param);
    if (on_glyph != nullptr && on_start != nullptr && on_voiceover != nullptr) {
      out->writer_audio[static_cast<size_t>(WriterAudioMethod::kOnGlyph)] =
          on_glyph;
      out->writer_audio[static_cast<size_t>(WriterAudioMethod::kOnStart)] =
          on_start;
      out->writer_audio[static_cast<size_t>(WriterAudioMethod::kOnVoiceover)] =
          on_voiceover;
    }
  }
  return AudioSiteResult::kResolved;
}

// ── playback events (main thread -> HookWorker) ─────────────────────────────

inline constexpr uint32_t kAudioFlagFungusVoiceover = 0x1u;
inline constexpr size_t kClipNameUnits = 128u;  // == kUnityClipNameChars
inline constexpr size_t kPendingAudioEvents = 32u;

struct PendingAudioEvent {
  uint64_t seq = 0u;  // index + 1 once complete; written last
  uint64_t timestamp_ms = 0u;
  uint32_t flags = 0u;
  wchar_t name[kClipNameUnits] = {};
};

// A playback started from inside the framework's typing-sound callbacks is a
// beep / typing effect, never the line's voice.  The framework's explicit
// voiceover call is always a candidate.
inline bool IsVoiceCandidate(uint32_t flags, int writer_audio_depth) {
  return (flags & kAudioFlagFungusVoiceover) != 0u || writer_audio_depth <= 0;
}

// HookWorker verdict: publish a resource event only with a voice bundle to
// prove membership in, or for the framework's explicit voiceover.
inline bool ShouldPublishAudioEvent(uint32_t flags, bool voice_bundle_known) {
  return (flags & kAudioFlagFungusVoiceover) != 0u || voice_bundle_known;
}

// The same clip re-started within the window is one playback (a source
// replaying its clip, or two entries seeing the same start).
inline constexpr uint64_t kDuplicateWindowMs = 100u;

struct RecentClip {
  uint64_t timestamp_ms = 0u;
  wchar_t name[kClipNameUnits] = {};
};

inline bool IsDuplicatePlayback(RecentClip* recent, const wchar_t* name,
                                uint64_t timestamp_ms) {
  if (recent == nullptr || name == nullptr) return false;
  const bool duplicate =
      recent->name[0] != 0 &&
      std::wcsncmp(recent->name, name, kClipNameUnits) == 0 &&
      timestamp_ms >= recent->timestamp_ms &&
      timestamp_ms - recent->timestamp_ms < kDuplicateWindowMs;
  recent->timestamp_ms = timestamp_ms;
  size_t i = 0u;
  for (; i + 1u < kClipNameUnits && name[i] != 0; ++i) recent->name[i] = name[i];
  recent->name[i] = 0;
  return duplicate;
}

}  // namespace fushi_voice_hook::unity_mono_audio

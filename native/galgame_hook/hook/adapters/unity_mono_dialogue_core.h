#pragma once

// Unity (Mono runtime) dialogue-surface proof: pure, unit-tested half.
//
// Problem.  Every canvas text (TMPro.TextMeshProUGUI / UnityEngine.UI.Text)
// publishes its own text lane (`unity_tmp:<hex>`, component pointer + setter
// hook code), so a Unity game shows dozens of lanes and the host cannot
// auto-select one by hook code.  Frequency is not a criterion (measured on
// real builds, never identity inputs):
//   * a TMP build: ~50 `TMP_Text.set_text` lanes observed once (UI labels)
//     and the dialogue on one `SetText(string,bool)` lane, also observed once
//     at the moment of the first line;
//   * a TMP 3.2 build: the most observed lane (1071) was a settings-page
//     typewriter preview growing one character at a time and restarting the
//     same sentence; the dialogue was a `SetText(string)` lane (61);
//   * a UI.Text build: one UI.Text lane carried the narration.
//
// Criterion (structural, per component, no title / exe / hash input).  The
// dialogue surface is the canvas text whose shown line is *replaced* after
// the player's advance input, again and again:
//   1. Typewriter growth is one line: a new text that extends the pending
//      text (the pending text is its prefix) is the same line growing; an
//      identical reassignment is nothing.  Anything else replaces the pending
//      line -- that is a commit of the pending line.
//   2. A commit counts only when the outgoing line was *shown*: the lookup
//      sampler (after Canvas.SendWillRenderCanvases) saw at least one of its
//      glyphs readable (active + enabled, not culled, alpha) and inside the
//      Unity screen while it was pending.  Hidden / inactive / off-screen
//      components never count.
//   3. A commit counts only when it differs from the previous counted line
//      (a looping preview of one sentence never counts twice).
//   4. A commit counts only when an advance input (press / key / wheel /
//      touch delivered to the game window and not claimed by the lookup)
//      arrived while the outgoing line was pending.  A commit with no input
//      (timer-driven text: clocks, tickers, auto mode) resets the score.
//   5. Evaluated once per frame (after the canvas update, so a name plate
//      and its body text written in the same frame are compared together):
//      the surface with at least kPromotionCommits counted commits and at
//      least kLeadMargin more than every other tracked surface is the
//      dialogue surface.  A name plate whose speaker alternated on every line
//      ties with the body and promotes nothing until the body is two commits
//      ahead (two lines without a speaker change).  The promoted surface
//      keeps the mark until another one leads under the same rule, a rival
//      with at least kPromotionCommits catches up with it (mark cleared), or
//      its component leaves the candidate table.
//
// Not covered (fail closed: nothing is promoted, the user selects the lane):
// gamepad-only play (no window message), pure auto mode, dialogue the lookup
// sampler cannot model (vertical / rotated text, World Space canvas, a
// non-dynamic UI.Text font), and a dialogue alternating between two
// components line by line.

#include <array>
#include <cstddef>
#include <cstdint>

#include "unity_mono_lookup_core.h"
#include "unity_mono_text.h"

namespace fushi_voice_hook::unity_mono_dialogue {

// Same cap as the text lane's cleaned line (RecordUnityTextChars clean[501]).
inline constexpr size_t kMaxTrackedUnits = 500u;
// Counted commits a surface needs before it can be the dialogue surface.
inline constexpr uint32_t kPromotionCommits = 3u;
// How far the leader must be ahead of every other surface.  2, not 1: a name
// plate and its body text are written one after the other (often in two
// frames), so for a moment either one can be a single commit ahead.
inline constexpr uint32_t kLeadMargin = 2u;
inline constexpr size_t kNoSurface = static_cast<size_t>(-1);

// Window messages that are a player's advance input (all on the Unity
// window's own procedure, which runs on the main thread): left press /
// double click, key press (auto-repeat included: held skip keys), wheel,
// pointer down and WM_TOUCH (a touch tap is also promoted to a left press).
inline constexpr uint32_t kMessageKeyDown = 0x0100u;
inline constexpr uint32_t kMessageLeftDown = 0x0201u;
inline constexpr uint32_t kMessageLeftDouble = 0x0203u;
inline constexpr uint32_t kMessageWheel = 0x020Au;
inline constexpr uint32_t kMessageTouch = 0x0240u;
inline constexpr uint32_t kMessagePointerDown = 0x0246u;

inline bool IsAdvanceInputMessage(uint32_t message) {
  return message == kMessageKeyDown || message == kMessageLeftDown ||
         message == kMessageLeftDouble || message == kMessageWheel ||
         message == kMessageTouch || message == kMessagePointerDown;
}

// The text lane's rich-text stripping (RecordUnityTextChars): `<` opens a tag
// that runs to the next `>`; everything else is kept.  Returns the length
// written (at most `capacity`).
inline size_t StripRichText(const wchar_t* chars, size_t length, wchar_t* out,
                            size_t capacity) {
  if (chars == nullptr || out == nullptr) return 0u;
  size_t written = 0u;
  bool in_tag = false;
  for (size_t i = 0; i < length && written < capacity; ++i) {
    const wchar_t c = chars[i];
    if (c == L'<') {
      in_tag = true;
      continue;
    }
    if (in_tag) {
      if (c == L'>') in_tag = false;
      continue;
    }
    out[written++] = c;
  }
  return written;
}

enum class TextStep : uint8_t {
  kSame = 0,      // identical reassignment
  kGrowth = 1,    // the pending text is a strict prefix of the new text
  kReplaced = 2,  // anything else: the pending line is committed
};

inline TextStep ClassifyTextStep(const wchar_t* pending, size_t pending_length,
                                 const wchar_t* next, size_t next_length) {
  const size_t common =
      pending_length < next_length ? pending_length : next_length;
  for (size_t i = 0; i < common; ++i) {
    if (pending[i] != next[i]) return TextStep::kReplaced;
  }
  if (pending_length == next_length) return TextStep::kSame;
  return pending_length < next_length ? TextStep::kGrowth
                                      : TextStep::kReplaced;
}

inline uint64_t TextHash(const wchar_t* chars, size_t length) {
  uint64_t hash = unity_mono_lookup::kFingerprintSeed;
  return unity_mono_lookup::Fingerprint(hash, chars, length * sizeof(wchar_t));
}

// Was any readable glyph of a successful canvas sample inside the Unity
// screen?  `cells` are Unity screen pixels; `visible` is the sampler's
// readable-and-revealed verdict for that glyph.
inline bool CellsShownOnScreen(const unity_mono_lookup::GlyphCell* cells,
                               size_t count, int32_t screen_w,
                               int32_t screen_h) {
  if (cells == nullptr || screen_w <= 0 || screen_h <= 0) return false;
  const float w = static_cast<float>(screen_w);
  const float h = static_cast<float>(screen_h);
  for (size_t i = 0; i < count; ++i) {
    const auto& cell = cells[i];
    if (cell.visible == 0u) continue;
    if (cell.x1 > 0.0f && cell.x0 < w && cell.y1 > 0.0f && cell.y0 < h) {
      return true;
    }
  }
  return false;
}

// Verdict of one commit (see the criterion above).
enum class CommitVerdict : uint8_t {
  kNone = 0,        // no commit (first text, same text or growth)
  kCounted = 1,     // shown, new, input-caused: +1
  kUnseen = 2,      // never shown while pending: no change
  kRepeated = 3,    // same as the last counted line: no change
  kUnprompted = 4,  // no advance input while pending: score reset
};

struct SurfaceTrack {
  bool active = false;
  uint8_t lane = 0u;  // setter lane bit that wrote the latest text
  uint32_t pending_length = 0u;
  std::array<wchar_t, kMaxTrackedUnits> pending{};
  bool pending_shown = false;
  uint32_t pending_inputs = 0u;  // advance-input count when the line started
  bool has_counted = false;
  uint64_t counted_hash = 0u;
  uint32_t score = 0u;
};

struct TextOutcome {
  TextStep step = TextStep::kSame;
  CommitVerdict verdict = CommitVerdict::kNone;
};

// A setter published `chars` (already rich-text stripped) on `lane` of this
// surface; `inputs` is the advance-input counter now.
inline TextOutcome NoteSurfaceText(SurfaceTrack* track, const wchar_t* chars,
                                   size_t length, uint8_t lane,
                                   uint32_t inputs) {
  TextOutcome outcome;
  if (track == nullptr || chars == nullptr || length == 0u) return outcome;
  if (length > kMaxTrackedUnits) length = kMaxTrackedUnits;
  track->lane = lane;
  if (!track->active) {
    track->active = true;
    outcome.step = TextStep::kGrowth;
  } else {
    outcome.step = ClassifyTextStep(track->pending.data(),
                                    track->pending_length, chars, length);
  }
  if (outcome.step == TextStep::kSame) return outcome;
  if (outcome.step == TextStep::kReplaced) {
    const uint64_t hash =
        TextHash(track->pending.data(), track->pending_length);
    if (!track->pending_shown) {
      outcome.verdict = CommitVerdict::kUnseen;
    } else if (track->has_counted && hash == track->counted_hash) {
      outcome.verdict = CommitVerdict::kRepeated;
    } else if (inputs == track->pending_inputs) {
      outcome.verdict = CommitVerdict::kUnprompted;
      track->score = 0u;
    } else {
      outcome.verdict = CommitVerdict::kCounted;
      ++track->score;
      track->has_counted = true;
      track->counted_hash = hash;
    }
    track->pending_shown = false;
    track->pending_inputs = inputs;
  } else if (track->pending_length == 0u) {
    track->pending_inputs = inputs;  // first text of this surface
  }
  for (size_t i = 0; i < length; ++i) track->pending[i] = chars[i];
  track->pending_length = static_cast<uint32_t>(length);
  return outcome;
}

// A canvas sample of this surface, taken after the latest text was laid out.
inline void NoteSurfaceShown(SurfaceTrack* track, bool shown) {
  if (track != nullptr && track->active && shown) track->pending_shown = true;
}

struct Leader {
  size_t index = kNoSurface;
  uint32_t score = 0u;
  uint32_t runner_up = 0u;
};

// The leader among active surfaces: at least kPromotionCommits and at least
// kLeadMargin ahead of every other surface.
inline Leader PickLeader(const SurfaceTrack* tracks, size_t count) {
  Leader leader;
  if (tracks == nullptr) return leader;
  size_t best = kNoSurface;
  uint32_t best_score = 0u;
  uint32_t second = 0u;
  for (size_t i = 0; i < count; ++i) {
    if (!tracks[i].active) continue;
    const uint32_t score = tracks[i].score;
    if (best == kNoSurface || score > best_score) {
      if (best != kNoSurface) second = best_score;
      best = i;
      best_score = score;
    } else if (score > second) {
      second = score;
    }
  }
  leader.score = best_score;
  leader.runner_up = second;
  if (best != kNoSurface && best_score >= kPromotionCommits &&
      best_score >= second + kLeadMargin) {
    leader.index = best;
  }
  return leader;
}

// The dialogue surface after this frame.  A leader takes over.  Without one
// the current surface stays while it is tracked and no rival with at least
// kPromotionCommits has caught up with it (a tie is no proof either way: the
// mark is cleared rather than left on a surface that is no longer ahead).
inline size_t NextDialogueSurface(const SurfaceTrack* tracks, size_t count,
                                  size_t current) {
  if (tracks == nullptr) return kNoSurface;
  if (current != kNoSurface && (current >= count || !tracks[current].active)) {
    current = kNoSurface;
  }
  const Leader leader = PickLeader(tracks, count);
  if (leader.index != kNoSurface) return leader.index;
  if (current == kNoSurface) return kNoSurface;
  for (size_t i = 0; i < count; ++i) {
    if (i == current || !tracks[i].active) continue;
    if (tracks[i].score >= kPromotionCommits &&
        tracks[i].score >= tracks[current].score) {
      return kNoSurface;
    }
  }
  return current;
}

// Setter lane bit (unity_mono_lookup.inc kUm*Lane*) -> text hook id.
inline bool MonoTextHookIdForLane(uint8_t lane, MonoTextHookId* id) {
  if (id == nullptr) return false;
  switch (lane) {
    case 1u:
      *id = MonoTextHookId::kTmpSetText;
      return true;
    case 2u:
      *id = MonoTextHookId::kTmpSetTextBool;
      return true;
    case 4u:
      *id = MonoTextHookId::kUiTextSetText;
      return true;
    case 8u:
      *id = MonoTextHookId::kTmpSetTextSingle;
      return true;
    default:
      return false;
  }
}

// What the main thread must publish after a text step: the lane that lost
// and the lane that gained the dialogue-surface mark (0 = none).
struct SurfaceChange {
  uintptr_t cleared_object = 0u;
  uint8_t cleared_lane = 0u;
  uintptr_t promoted_object = 0u;
  uint8_t promoted_lane = 0u;
  bool changed() const {
    return cleared_object != 0u || promoted_object != 0u;
  }
};

}  // namespace fushi_voice_hook::unity_mono_dialogue

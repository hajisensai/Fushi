#pragma once

// SGRE scenario-page identity and voice-to-text binding (BUG-4167).
//
// The SGRE scenario renderer lays a whole line out up front and then types it
// by raising the visible-glyph counter; the exact text lane publishes the line
// only once it is fully revealed. The character voice starts with the page,
// so a slow typewriter puts several seconds between "voice started" and "line
// published". The host's unmarked time window ([T-330, T-130]) cannot bridge
// that gap and must not be widened for one engine (BUG-1605: a wide window
// without ownership evidence pairs the previous line's voice).
//
// The adapter therefore carries the ownership itself:
//  - a page starts at its first visible glyph; that tick is the line's text
//    timestamp (when the line began to appear, the same moment the voice
//    starts), not the reveal-complete tick;
//  - a voice resource is bound to the page that was being typed when it
//    started playing (or that began within kSgreVoiceLeadMs after it) and is
//    named with that page's text-lane seq (`fushi_textseq<seq>`), so the host
//    takes its exact event-ID layer.
//
// Because the text timestamp is the first-glyph tick, the host's unmarked
// window ([T-330, T-130]) no longer describes SGRE: an unbound resource keeps
// the legacy unmarked name but is, in practice, not paired by the host. Every
// case the old window paired (voice 130-330 ms before the reveal-complete
// tick) is a voice that started while its page was being typed, which the
// binding below covers as long as it started within kSgreVoiceLagMs of the
// first glyph; the binding, not the unmarked name, is the pairing path.
//
// Everything here is pure and IO-free; the draw callback and the HookWorker
// call into it under the text-lane writer lock.

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "../voice_resource_pairing.h"

namespace fushi_voice_hook {

// A voice may be submitted slightly before the renderer shows the page's
// first glyph (script voice command runs first). Not measured on a real
// session yet; kept well inside the host's marked-resource tolerance.
constexpr uint64_t kSgreVoiceLeadMs = 500;
// A voice that starts more than this long after its page began is not bound
// to it. Equals the host's event-ID tolerance
// (kGalVoiceResourcePairingWindowMs) so a bound resource is never refused.
constexpr uint64_t kSgreVoiceLagMs = 1500;
// How far a voice may start after its page was published and still be that
// page's voice. With instant text (or a page whose first frame is already
// complete) the first glyph, the publication and the voice start coincide;
// the voice is submitted on the XAudio thread while the page is published
// from the draw callback, and GetTickCount64 steps in ~16 ms, so the voice
// tick can land a few ticks after the publication tick. Not measured on a real
// session yet; far below the time needed to read a line and advance to the
// next one, so the next line's voice (the case the exclusion guards) still
// starts outside it.
constexpr uint64_t kSgreVoicePublishRaceMs = 100;
// Upper bound for waiting until the owning page is fully revealed (slowest
// typewriter on a long line). Afterwards the resource is written unmarked.
constexpr uint64_t kSgreVoiceRevealDeadlineMs = 60000;
constexpr size_t kSgrePageHistorySlots = 8;
constexpr size_t kSgrePageMaxTextUnits = 512;

struct SgreScenarioPage {
  uint64_t id = 0;                // 0 = empty slot
  uint64_t first_glyph_tick = 0;  // tick of the first frame with glyphs
  uint64_t text_seq = 0;          // text-lane seq once published, else 0
  uint64_t published_tick = 0;    // tick the line was published (reveal done)
};

// Tracks which scenario page the renderer is currently typing. A page is one
// publishable line: it starts on the first frame with visible glyphs, keeps
// its identity while the visible prefix only grows (typing) or repeats
// (redraw), and ends when the surface shows no glyphs, the visible prefix is
// no longer an extension of the previous frame, or text is appended after the
// line was already published.
class SgreScenarioPageTracker {
 public:
  // Observes one successfully captured frame. Returns the current page.
  SgreScenarioPage Observe(const wchar_t* visible, uint32_t units,
                           uint64_t tick) {
    if (units > kSgrePageMaxTextUnits) units = kSgrePageMaxTextUnits;
    const bool extends_previous =
        open_ && units >= units_ &&
        (units_ == 0 ||
         std::memcmp(prefix_, visible, units_ * sizeof(wchar_t)) == 0);
    const bool appended_after_publish =
        open_ && current().text_seq != 0 && units > units_;
    if (!extends_previous || appended_after_publish) {
      BeginPage(tick);
    }
    if (units != 0) std::memcpy(prefix_, visible, units * sizeof(wchar_t));
    units_ = units;
    return current();
  }

  // The scenario surface showed no glyphs: the current page is over.
  void EndPage() {
    open_ = false;
    units_ = 0;
  }

  // The current page was published to the text lane as [text_seq] at [tick].
  void MarkPublished(uint64_t text_seq, uint64_t tick) {
    if (!open_ || text_seq == 0) return;
    history_[head_].text_seq = text_seq;
    history_[head_].published_tick = tick;
  }

  bool open() const { return open_; }
  bool observed_any_page() const { return next_id_ != 0; }

  // Copies the retained pages (oldest first). Returns the count.
  size_t Snapshot(SgreScenarioPage* out, size_t capacity) const {
    size_t count = 0;
    for (size_t i = 1; i <= kSgrePageHistorySlots && count < capacity; ++i) {
      const SgreScenarioPage& page =
          history_[(head_ + i) % kSgrePageHistorySlots];
      if (page.id != 0) out[count++] = page;
    }
    return count;
  }

  void Reset() { *this = SgreScenarioPageTracker(); }

 private:
  const SgreScenarioPage& current() const { return history_[head_]; }

  void BeginPage(uint64_t tick) {
    head_ = (head_ + 1) % kSgrePageHistorySlots;
    history_[head_] = SgreScenarioPage{++next_id_, tick, 0, 0};
    open_ = true;
    units_ = 0;
  }

  SgreScenarioPage history_[kSgrePageHistorySlots] = {};
  size_t head_ = 0;
  uint64_t next_id_ = 0;
  bool open_ = false;
  uint32_t units_ = 0;
  wchar_t prefix_[kSgrePageMaxTextUnits] = {};
};

// Binds a voice that started playing at [voice_tick] to the scenario page
// that owns it. A page can own the voice only when
//   first_glyph - kSgreVoiceLeadMs <= voice_tick <= first_glyph + kSgreVoiceLagMs
// and, once published, voice_tick <= published_tick + kSgreVoicePublishRaceMs:
// a page whose line had already been fully revealed before the voice started
// is not that voice's page (BUG-4167 review: otherwise the next line's voice,
// when its text fades in later than the lead, was handed to the line still on
// screen and the host took it as an exact event-ID hit on the wrong card). The
// race allowance keeps an instantly revealed page (publication tick == first
// glyph tick) owning the voice that starts with it. Of the candidates the
// earliest page owns the voice: at most one page was being typed when the
// voice started, and a page that only began afterwards (within the lead) owns
// it only when none was.
//  - kUnselected: the exact text lane never produced a page (text comes from
//    elsewhere); the resource is written unmarked right away.
//  - kWait: a page may still begin within the lead, or the owning page is
//    still typing.
//  - kMatched: the owning page is published; text_event_id is its seq.
//  - kExpired: no owning page, the owner was replaced before being published,
//    or the reveal deadline passed. The resource keeps the unmarked name (see
//    the header comment: the host does not pair it).
// [final_pass] decides with what is known now and never waits (queue eviction
// and adapter shutdown: no later page can be observed for this voice).
inline VoiceResourcePairDecision ResolveSgreVoicePage(
    uint64_t voice_tick, uint64_t now_ms, bool lane_observed,
    const SgreScenarioPage* pages, size_t page_count,
    bool final_pass = false) {
  if (!lane_observed) return {VoiceResourcePairState::kUnselected, 0};
  if (!final_pass && now_ms < voice_tick + kSgreVoiceLeadMs) {
    return {VoiceResourcePairState::kWait, 0};
  }
  const SgreScenarioPage* owner = nullptr;
  for (size_t i = 0; i < page_count; ++i) {
    const SgreScenarioPage& page = pages[i];
    if (page.id == 0) continue;
    const bool in_window =
        page.first_glyph_tick <= voice_tick + kSgreVoiceLeadMs &&
        voice_tick <= page.first_glyph_tick + kSgreVoiceLagMs;
    const bool revealed_before_voice =
        page.text_seq != 0 &&
        page.published_tick + kSgreVoicePublishRaceMs < voice_tick;
    if (in_window && !revealed_before_voice &&
        (owner == nullptr || page.id < owner->id)) {
      owner = &page;
    }
  }
  if (owner == nullptr) return {VoiceResourcePairState::kExpired, 0};
  if (owner->text_seq != 0) {
    return {VoiceResourcePairState::kMatched, owner->text_seq};
  }
  bool superseded = false;
  for (size_t i = 0; i < page_count; ++i) {
    if (pages[i].id > owner->id) superseded = true;
  }
  if (final_pass || superseded ||
      now_ms >= voice_tick + kSgreVoiceRevealDeadlineMs) {
    return {VoiceResourcePairState::kExpired, 0};
  }
  return {VoiceResourcePairState::kWait, 0};
}

}  // namespace fushi_voice_hook

#pragma once

// Engine-agnostic "same thread re-emitted the exact same text right away"
// detector.  Engines decide whether their hook surface has that artifact:
//
//   * CatSystem2 EmbedCS2 runs every script string twice 0.2–0.4 s apart
//     (LunaImmediateRepeatFilter in luna_text_selector.h gates by hook name);
//   * Unity text setters (TMP_Text / UI.Text / TextMesh / Naninovel) are
//     re-assigned by game scripts, often every frame, with an unchanged value.
//     A setter call that does not change the component's text is not a new
//     line (feedback bfaVEbHL_s: Road to Empress re-set the same sentence
//     several times per second and flooded the text lane until Fushi froze).
//
// Rule: per thread, exact text only, time-bounded.  Every event (repeat or
// not) becomes the thread's new reference, so a value re-assigned each frame
// stays suppressed for as long as it keeps being re-assigned, while a line the
// player legitimately sees twice in a row needs a click in between and arrives
// after the window.  No executable name, hash or text content is consulted.

#include <cstdint>
#include <cwchar>
#include <map>
#include <string>

namespace fushi_voice_hook {

inline constexpr uint64_t kImmediateTextRepeatWindowMs = 1000u;

class ImmediateTextRepeatFilter {
 public:
  // True when this event only repeats the previous event of the same thread
  // within kImmediateTextRepeatWindowMs.
  bool IsRepeat(uint64_t thread_id, const wchar_t* text, int len,
                uint64_t now_ms) {
    if (text == nullptr || len <= 0) return false;
    Last& last = last_[thread_id];
    const bool repeat =
        last.valid && now_ms >= last.at_ms &&
        now_ms - last.at_ms <= kImmediateTextRepeatWindowMs &&
        last.text.size() == static_cast<size_t>(len) &&
        std::wmemcmp(last.text.data(), text, static_cast<size_t>(len)) == 0;
    last.valid = true;
    last.at_ms = now_ms;
    last.text.assign(text, text + len);
    return repeat;
  }

  void Reset() { last_.clear(); }

 private:
  struct Last {
    bool valid = false;
    uint64_t at_ms = 0u;
    std::wstring text;
  };
  std::map<uint64_t, Last> last_;
};

}  // namespace fushi_voice_hook

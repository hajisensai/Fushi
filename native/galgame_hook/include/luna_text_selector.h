#ifndef HIBIKI_LUNA_TEXT_SELECTOR_H_
#define HIBIKI_LUNA_TEXT_SELECTOR_H_

#include <cstring>
#include <cstdint>
#include <map>
#include <string>

namespace hibiki_voice_hook {

// Some KiriKiri/Luna hook paths concatenate an already complete line with an
// exact second copy.  Preserve a view of the first complete line instead of
// discarding the event as an artifact.  A one-character doubled string remains
// untouched so the artifact filter can continue rejecting single-character
// repetition noise.
inline int LunaNormalizedTextLength(const wchar_t* text, int len) {
  if (text == nullptr || len < 4 || (len % 2) != 0) return len;
  const int half = len / 2;
  for (int i = 0; i < half; ++i) {
    if (text[i] != text[half + i]) return len;
  }
  return half;
}

inline int LunaNormalizedTextLengthForHook(const char* hook_name,
                                           const wchar_t* text, int len) {
  if (hook_name == nullptr || std::strcmp(hook_name, "EmbedKrkrZ") != 0) {
    return len;
  }
  return LunaNormalizedTextLength(text, len);
}

inline bool LunaTextIsArtifact(const wchar_t* text, int len) {
  if (text == nullptr || len <= 1) return false;
  if ((len % 2) == 0) {
    const int half = len / 2;
    if (std::wstring(text, text + half) == std::wstring(text + half, text + len)) {
      return true;
    }
  }
  int segments = 0;
  int first_run = 0;
  bool uniform = true;
  for (int i = 0; i < len;) {
    int j = i + 1;
    while (j < len && text[j] == text[i]) ++j;
    const int run = j - i;
    if (segments == 0) first_run = run;
    else if (run != first_run) uniform = false;
    ++segments;
    i = j;
  }
  if (segments >= 3 && uniform && first_run >= 2) return true;
  int adjacent_equal = 0;
  for (int i = 1; i < len; ++i) {
    if (text[i] == text[i - 1]) ++adjacent_equal;
  }
  return len > 4 && adjacent_equal * 100 >= (len - 1) * 30;
}

class LunaTextSelector {
 public:
  bool ShouldWrite(const std::wstring& hook_code, uint64_t thread_id,
                   bool artifact, uint64_t manually_selected) {
    Stats& stats = stats_[hook_code];
    if (artifact) ++stats.dirty;
    else ++stats.clean;

    const std::wstring* best = nullptr;
    const std::wstring* pristine = nullptr;
    uint64_t best_clean = 0;
    uint64_t pristine_clean = 0;
    uint64_t total_clean = 0;
    for (const auto& entry : stats_) {
      const uint64_t clean = entry.second.clean;
      const uint64_t dirty = entry.second.dirty;
      total_clean += clean;
      if (clean == 0) continue;
      if (dirty == 0 && clean > pristine_clean) {
        pristine = &entry.first;
        pristine_clean = clean;
      }
      if (clean >= dirty && clean > best_clean) {
        best = &entry.first;
        best_clean = clean;
      }
    }
    const std::wstring* winner = pristine != nullptr ? pristine : best;
    if (total_clean >= 3 && winner != nullptr) {
      primed_ = true;
      selected_hook_ = *winner;
    }

    if (artifact) return false;
    if (manually_selected != 0) return manually_selected == thread_id;
    return !primed_ || hook_code == selected_hook_;
  }

  void Reset() {
    stats_.clear();
    selected_hook_.clear();
    primed_ = false;
  }

 private:
  struct Stats {
    uint64_t clean = 0;
    uint64_t dirty = 0;
  };
  std::map<std::wstring, Stats> stats_;
  std::wstring selected_hook_;
  bool primed_ = false;
};

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_TEXT_SELECTOR_H_

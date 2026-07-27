#ifndef HIBIKI_LUNA_TEXT_SELECTOR_H_
#define HIBIKI_LUNA_TEXT_SELECTOR_H_

#include <cstring>
#include <cstdint>
#include <map>
#include <string>

namespace hibiki_voice_hook {

// 一个完整句的最小字符数。低于它不做前缀折叠，避免把「ああ」这类叠字噪声
// （交给 LunaTextIsArtifact 判）或短感叹句误截。
constexpr int kLunaMinFoldedLineChars = 4;

// Some KiriKiri/Luna hook paths concatenate an already complete line with an
// exact second copy.  Preserve a view of the first complete line instead of
// discarding the event as an artifact.  A one-character doubled string remains
// untouched so the artifact filter can continue rejecting single-character
// repetition noise.
//
// BUG-1163：旧实现只认「整串恰好二倍」（前半 == 后半）。带 ruby 的台词会被
// KiriKiriZ 分别以 base（汉字）和 ruby（假名）两种形式送进同一个 hook 点，再叠上
// 本 hook 面固有的完整行双写，实际收到的是 `A A B B A A`（A=汉字版、B=注音版）——
// 前半 `AAB` != 后半 `BAA`，整串判据一条都不命中，整串原样入环，于是浮窗/台词列表/
// 制卡内容里一句话出现六遍。
//
// 改为「**开头**二倍即取第一份」：找最小的 k（k >= kLunaMinFoldedLineChars 且
// 2k <= len）使 text[0,k) == text[k,2k)，返回 k。语义仍是注释开头说的
// 「preserve a view of the first complete line」，只是不再要求这份重复铺满整串——
// 真身是第一个完整句，后面跟的是同句的哪种变体都不影响该结论。
// 「整串恰好二倍」是本判据在 2k == len 时的特例，故旧行为被完整覆盖。
inline int LunaNormalizedTextLength(const wchar_t* text, int len) {
  if (text == nullptr || len < kLunaMinFoldedLineChars * 2) return len;
  for (int k = kLunaMinFoldedLineChars; k * 2 <= len; ++k) {
    bool doubled = true;
    for (int i = 0; i < k && doubled; ++i) {
      if (text[i] != text[k + i]) doubled = false;
    }
    if (doubled) return k;
  }
  return len;
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

// 手动/记忆选定的线程是否应放行本行（纯函数，便于单测）。
//
// BUG-1159：`selected_text_thread_id` 存的是一个具体的 `TextSlot::thread_id`，而
// thread_id = FNV1a(processId, addr, **ctx, ctx2**, hookcode, hookname) —— 含调用上下文。
// 同一个 hook 面（同 addr + 同 hookcode/hookname）在不同调用路径下 ctx/ctx2 会变，
// thread_id 随之变，旧的 `manually_selected == thread_id` 精确匹配就把整段台词丢掉：
// 真机实测中 textseq83 之后连续 16 句语音资源（间隔规整 5~8s）全部没有对应文本，
// 文本环没有候选 → 资源配对 kExpired → 写成无标记文件 → 消费端只剩 200ms 时间窗
// 兜底 → 兜不住 → 整段降级成 system_loopback。
//
// ctx 参与 thread_id 是**有意的**（诊断/区分同 hook 的并行调用点），所以这里不改
// thread_id 的算法，只把**过滤粒度**放宽到 hook 面：选定线程的 face 与本行 face 相同
// 即放行。face 未知（还没见过选定线程的行）时退回精确匹配，语义与旧实现一致。
inline bool LunaSelectedThreadAccepts(uint64_t manually_selected,
                                      uint64_t thread_id,
                                      uint64_t selected_face,
                                      uint64_t face_id) {
  if (manually_selected == thread_id) return true;
  return selected_face != 0 && selected_face == face_id;
}

class LunaTextSelector {
 public:
  // [face_id] 是不含 ctx/ctx2 的 hook 面 id（见 LunaSelectedThreadAccepts）。传 0 表示
  // 调用方无法提供，此时手动选择退化为精确 thread_id 匹配。
  bool ShouldWrite(const std::wstring& hook_code, uint64_t thread_id,
                   bool artifact, uint64_t manually_selected,
                   uint64_t face_id = 0) {
    if (face_id != 0 && thread_id != 0) thread_face_[thread_id] = face_id;
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
    if (manually_selected != 0) {
      return LunaSelectedThreadAccepts(manually_selected, thread_id,
                                       FaceOf(manually_selected), face_id);
    }
    return !primed_ || hook_code == selected_hook_;
  }

  // 已登记的 thread_id → hook 面 id；未见过返回 0。
  uint64_t FaceOf(uint64_t thread_id) const {
    const auto it = thread_face_.find(thread_id);
    return it == thread_face_.end() ? 0 : it->second;
  }

  void Reset() {
    stats_.clear();
    thread_face_.clear();
    selected_hook_.clear();
    primed_ = false;
  }

 private:
  struct Stats {
    uint64_t clean = 0;
    uint64_t dirty = 0;
  };
  std::map<std::wstring, Stats> stats_;
  // thread_id → hook 面 id。只增不删：一次会话内 hook 面数量有界（每个 hook 的每个
  // 调用上下文一条），且必须跨「用户选定线程」之前/之后都能查到。
  std::map<uint64_t, uint64_t> thread_face_;
  std::wstring selected_hook_;
  bool primed_ = false;
};

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_TEXT_SELECTOR_H_

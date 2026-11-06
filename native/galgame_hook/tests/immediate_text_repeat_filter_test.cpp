// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <string>

#include "immediate_text_repeat_filter.h"

namespace {

bool Repeat(fushi_voice_hook::ImmediateTextRepeatFilter& filter,
            uint64_t thread, const std::wstring& text, uint64_t at_ms) {
  return filter.IsRepeat(thread, text.c_str(), static_cast<int>(text.size()),
                         at_ms);
}

}  // namespace

int main() {
  using fushi_voice_hook::ImmediateTextRepeatFilter;
  const std::wstring line = L"「合成テスト用の一行」";
  const std::wstring next = L"「合成テスト用の次の行」";

  // Unity setter re-assigned with the same value every frame (feedback
  // bfaVEbHL_s): only the first assignment is a line, for as long as the
  // re-assignment keeps going — every event refreshes the reference.
  {
    ImmediateTextRepeatFilter filter;
    assert(!Repeat(filter, 7, line, 10000));
    for (uint64_t t = 10016; t <= 15000; t += 16) {
      assert(Repeat(filter, 7, line, t));
    }
    // The text actually changes: a new line, then its own per-frame repeats.
    assert(!Repeat(filter, 7, next, 15016));
    assert(Repeat(filter, 7, next, 15032));
    // Going back to the previous text is a change, not a repeat.
    assert(!Repeat(filter, 7, line, 15048));
  }

  // A line the player sees twice in a row needs a click in between: once the
  // setter has been quiet longer than the window, the same text is kept.
  {
    ImmediateTextRepeatFilter filter;
    assert(!Repeat(filter, 7, line, 1000));
    assert(!Repeat(filter, 7, line,
                   1000 + fushi_voice_hook::kImmediateTextRepeatWindowMs +
                       1));
  }

  // Per thread: another component showing the same text is its own line.
  {
    ImmediateTextRepeatFilter filter;
    assert(!Repeat(filter, 7, line, 1000));
    assert(!Repeat(filter, 8, line, 1001));
    assert(Repeat(filter, 7, line, 1002));
  }

  // Prefix growth (typewriter reveal) is never a repeat.
  {
    ImmediateTextRepeatFilter filter;
    assert(!Repeat(filter, 7, line.substr(0, 3), 1000));
    assert(!Repeat(filter, 7, line.substr(0, 4), 1016));
    assert(!Repeat(filter, 7, line, 1032));
  }

  // Empty / null input is ignored and does not become a reference; a clock
  // that went backwards never counts; Reset forgets.
  {
    ImmediateTextRepeatFilter filter;
    assert(!filter.IsRepeat(7, nullptr, 3, 1000));
    assert(!filter.IsRepeat(7, line.c_str(), 0, 1000));
    assert(!Repeat(filter, 7, line, 5000));
    assert(!Repeat(filter, 7, line, 4000));
    filter.Reset();
    assert(!Repeat(filter, 7, line, 4010));
  }
  return 0;
}

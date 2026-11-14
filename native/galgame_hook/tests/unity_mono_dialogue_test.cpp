// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unity Mono 对白面判定（unity_mono_dialogue_core.h）的离线单测。三种真机证据形状用
// 合成文本重放（不含任何游戏台词）：
//   * TMP 作品：~50 条 set_text UI 标签各出现一次 + 对白在一条 SetText(string,bool)
//     道上、首句出现时也只有一次；
//   * TMP 3.2 作品：设置页打字机预览逐字增长并循环同一句（观测数最多的道），对白在
//     SetText(string) 道上逐字增长；
//   * UI.Text 作品：只有一条 UI.Text 道出叙述，外加一个计时器式标签。
// 另测：名牌与对白平局不提升、名牌先于正文一帧不抢标记、自动模式（无输入）不提升、
// 隐藏组件不提升、错误领先者被对白反超、组件离开候选表后标记清除，以及纯函数（富文本
// 剥离、增长判定、上屏判定、输入消息、lane 映射）。
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "adapters/unity_mono_dialogue_core.h"

namespace ud = fushi_voice_hook::unity_mono_dialogue;
namespace ul = fushi_voice_hook::unity_mono_lookup;
using fushi_voice_hook::MonoTextHookId;

namespace {

constexpr uint8_t kLaneSetText = 1u;
constexpr uint8_t kLaneSetTextBool = 2u;
constexpr uint8_t kLaneUiText = 4u;
constexpr uint8_t kLaneSetTextSingle = 8u;

// The main thread's view (unity_mono_lookup.inc): one track per candidate,
// the current dialogue surface, the advance-input counter.  Setters run
// first; the canvas update then samples every written candidate (shown or
// not) and the surface is evaluated once at the end of the frame.
struct Table {
  explicit Table(size_t count) : tracks(count) {}

  void Text(size_t index, const std::wstring& raw, uint8_t lane,
            bool shown = true) {
    wchar_t clean[ud::kMaxTrackedUnits];
    const size_t length =
        ud::StripRichText(raw.data(), raw.size(), clean, ud::kMaxTrackedUnits);
    last = ud::NoteSurfaceText(&tracks[index], clean, length, lane, inputs);
    sampled.push_back({index, shown});
  }

  void Frame() {
    for (const auto& sample : sampled) {
      ud::NoteSurfaceShown(&tracks[sample.first], sample.second);
    }
    sampled.clear();
    current = ud::NextDialogueSurface(tracks.data(), tracks.size(), current);
  }

  // Text + Frame.
  void Show(size_t index, const std::wstring& raw, uint8_t lane,
            bool shown = true) {
    Text(index, raw, lane, shown);
    Frame();
  }

  // A typewriter that calls the setter with every prefix of `line`, one per
  // frame.
  void Typewriter(size_t index, const std::wstring& line, uint8_t lane,
                  bool shown = true) {
    for (size_t n = 1; n <= line.size(); ++n) {
      Show(index, line.substr(0, n), lane, shown);
    }
  }

  void Input() { ++inputs; }

  void Evict(size_t index) {
    tracks[index] = ud::SurfaceTrack();
    Frame();
  }

  std::vector<ud::SurfaceTrack> tracks;
  std::vector<std::pair<size_t, bool>> sampled;
  size_t current = ud::kNoSurface;
  uint32_t inputs = 0u;
  ud::TextOutcome last;
};

std::wstring Line(int n) {
  // Synthetic lines (never game text): distinct, none a prefix of another.
  return L"「合成の台詞その" + std::to_wstring(n) + L"です」";
}

void TestPureHelpers() {
  wchar_t out[16] = {};
  const std::wstring rich = L"<color=#fff>あ</color>い<b>う";
  const size_t n = ud::StripRichText(rich.data(), rich.size(), out, 16);
  assert(n == 3 && out[0] == L'あ' && out[1] == L'い' && out[2] == L'う');
  assert(ud::StripRichText(rich.data(), rich.size(), out, 2) == 2);

  const std::wstring a = L"あい";
  const std::wstring b = L"あいう";
  const std::wstring c = L"あえ";
  assert(ud::ClassifyTextStep(a.data(), 2, a.data(), 2) ==
         ud::TextStep::kSame);
  assert(ud::ClassifyTextStep(a.data(), 2, b.data(), 3) ==
         ud::TextStep::kGrowth);
  // A restart (shorter prefix) and a different line both replace.
  assert(ud::ClassifyTextStep(b.data(), 3, a.data(), 2) ==
         ud::TextStep::kReplaced);
  assert(ud::ClassifyTextStep(a.data(), 2, c.data(), 2) ==
         ud::TextStep::kReplaced);

  ul::GlyphCell cells[2];
  cells[0].x0 = 10.0f;
  cells[0].x1 = 30.0f;
  cells[0].y0 = 10.0f;
  cells[0].y1 = 30.0f;
  cells[0].visible = 0u;
  assert(!ud::CellsShownOnScreen(cells, 1, 640, 480));  // not revealed
  cells[0].visible = 1u;
  assert(ud::CellsShownOnScreen(cells, 1, 640, 480));
  assert(!ud::CellsShownOnScreen(cells, 1, 0, 480));
  assert(!ud::CellsShownOnScreen(nullptr, 1, 640, 480));
  cells[1] = cells[0];
  cells[0].x0 = 700.0f;
  cells[0].x1 = 720.0f;  // right of the screen
  cells[1].y0 = -60.0f;
  cells[1].y1 = -20.0f;  // below the screen
  assert(!ud::CellsShownOnScreen(cells, 2, 640, 480));
  cells[1].y1 = 5.0f;  // partly inside
  assert(ud::CellsShownOnScreen(cells, 2, 640, 480));

  assert(ud::IsAdvanceInputMessage(0x0201u));   // WM_LBUTTONDOWN
  assert(ud::IsAdvanceInputMessage(0x0203u));   // WM_LBUTTONDBLCLK
  assert(ud::IsAdvanceInputMessage(0x0100u));   // WM_KEYDOWN
  assert(ud::IsAdvanceInputMessage(0x020Au));   // WM_MOUSEWHEEL
  assert(ud::IsAdvanceInputMessage(0x0246u));   // WM_POINTERDOWN
  assert(ud::IsAdvanceInputMessage(0x0240u));   // WM_TOUCH
  assert(!ud::IsAdvanceInputMessage(0x0202u));  // WM_LBUTTONUP
  assert(!ud::IsAdvanceInputMessage(0x0200u));  // WM_MOUSEMOVE
  assert(!ud::IsAdvanceInputMessage(0x0204u));  // WM_RBUTTONDOWN

  MonoTextHookId id = MonoTextHookId::kCount;
  assert(ud::MonoTextHookIdForLane(kLaneSetText, &id) &&
         id == MonoTextHookId::kTmpSetText);
  assert(ud::MonoTextHookIdForLane(kLaneSetTextBool, &id) &&
         id == MonoTextHookId::kTmpSetTextBool);
  assert(ud::MonoTextHookIdForLane(kLaneUiText, &id) &&
         id == MonoTextHookId::kUiTextSetText);
  assert(ud::MonoTextHookIdForLane(kLaneSetTextSingle, &id) &&
         id == MonoTextHookId::kTmpSetTextSingle);
  assert(!ud::MonoTextHookIdForLane(3u, &id));
  assert(!ud::MonoTextHookIdForLane(0u, &id));

  ud::SurfaceChange change;
  assert(!change.changed());
  change.cleared_object = 1u;
  assert(change.changed());
}

// TMP build: ~50 UI labels written once each (scene load), then the dialogue
// on one SetText(string,bool) lane, observed once when the first line shows.
void TestManyLabelsAndOneDialogue() {
  constexpr size_t kLabels = 50;
  Table t(kLabels + 1);
  for (size_t i = 0; i < kLabels; ++i) {
    t.Text(i, L"ラベル" + std::to_wstring(i), kLaneSetText);
  }
  t.Frame();
  t.Input();  // "New game"
  const size_t dialogue = kLabels;
  t.Show(dialogue, Line(1), kLaneSetTextBool);
  assert(t.current == ud::kNoSurface);  // one line proves nothing
  t.Input();
  t.Show(dialogue, Line(2), kLaneSetTextBool);
  assert(t.last.verdict == ud::CommitVerdict::kCounted);
  t.Input();
  t.Show(dialogue, Line(3), kLaneSetTextBool);
  assert(t.current == ud::kNoSurface);  // score 2 < kPromotionCommits
  t.Input();
  t.Show(dialogue, Line(4), kLaneSetTextBool);
  assert(t.current == dialogue);
  assert(t.tracks[dialogue].lane == kLaneSetTextBool);
  assert(t.tracks[dialogue].score == ud::kPromotionCommits);
  for (size_t i = 0; i < kLabels; ++i) assert(t.tracks[i].score == 0u);
  // The labels being rewritten later (scene re-entry: one counted commit
  // each at most) do not move the mark.
  for (size_t i = 0; i < kLabels; ++i) {
    t.Text(i, L"別ラベル" + std::to_wstring(i), kLaneSetText);
  }
  t.Frame();
  assert(t.current == dialogue);
}

// TMP 3.2 build: a settings-page typewriter preview that grows one unit at a
// time and restarts the same sentence (the most observed lane), while the
// player clicks around the settings; the dialogue grows per unit too.
void TestLoopingPreviewIsNotDialogue() {
  const size_t preview = 0;
  const size_t dialogue = 1;
  const std::wstring sentence = L"プレビュー用の合成文です";
  Table t(2);
  size_t events = 0;
  for (int cycle = 0; cycle < 90; ++cycle) {
    if (cycle % 3 == 0) t.Input();  // the player changes a setting
    t.Typewriter(preview, sentence, kLaneUiText);
    events += sentence.size();
  }
  assert(events > 1000u);
  assert(t.tracks[preview].score <= 1u);  // one distinct sentence at most
  assert(t.current == ud::kNoSurface);
  // Settings closed: the preview keeps looping on a hidden page.
  for (int line = 1; line <= 4; ++line) {
    t.Input();
    t.Typewriter(dialogue, Line(line), kLaneSetTextSingle);
    t.Typewriter(preview, sentence, kLaneUiText, /*shown=*/false);
  }
  assert(t.current == dialogue);
  assert(t.tracks[dialogue].lane == kLaneSetTextSingle);
  assert(t.tracks[preview].score <= 1u);

  // Same story with the preview still visible and looping all along.
  Table v(2);
  for (int line = 1; line <= 4; ++line) {
    v.Input();
    v.Typewriter(preview, sentence, kLaneUiText);
    v.Typewriter(dialogue, Line(line), kLaneSetTextSingle);
  }
  assert(v.tracks[preview].score <= 1u);
  assert(v.current == dialogue);
}

// UI.Text build: one UI.Text lane carries the narration; a timer-driven label
// (clock / ticker) changes on its own between the clicks.
void TestSingleUiTextNarrationAndTimerLabel() {
  Table t(2);
  const size_t narration = 0;
  const size_t clock = 1;
  t.Show(narration, Line(1), kLaneUiText);
  for (int step = 2; step <= 6; ++step) {
    for (int tick = 0; tick < 3; ++tick) {
      t.Show(clock, L"時刻" + std::to_wstring(step * 10 + tick), kLaneUiText);
    }
    t.Input();
    t.Show(narration, Line(step), kLaneUiText);
  }
  assert(t.current == narration);
  assert(t.tracks[clock].score <= 1u);
}

// A name plate changes on every advance while the speakers alternate: a tie
// promotes nothing; two lines of the same speaker break it.
void TestNamePlateTie() {
  Table t(2);
  const size_t body = 0;
  const size_t plate = 1;
  const wchar_t* speakers[] = {L"甲", L"乙"};
  for (int line = 1; line <= 6; ++line) {
    if (line > 1) t.Input();
    t.Text(body, Line(line), kLaneSetTextBool);
    t.Text(plate, speakers[line % 2], kLaneSetText);
    t.Frame();
  }
  assert(t.tracks[body].score == 5u && t.tracks[plate].score == 5u);
  assert(t.current == ud::kNoSurface);
  t.Input();
  t.Show(body, Line(7), kLaneSetTextBool);  // same speaker: plate unchanged
  assert(t.current == ud::kNoSurface);       // one ahead is not a lead
  t.Input();
  t.Show(body, Line(8), kLaneSetTextBool);
  assert(t.current == body);
  // The plate following the next speaker changes keeps it one behind.
  t.Input();
  t.Text(body, Line(9), kLaneSetTextBool);
  t.Text(plate, speakers[1], kLaneSetText);
  t.Frame();
  assert(t.current == body);
}

// The plate is written one frame before its body text: for that frame the
// plate is one commit ahead -- not enough to take the mark.
void TestPlateOneFrameAhead() {
  Table t(2);
  const size_t body = 0;
  const size_t plate = 1;
  const wchar_t* speakers[] = {L"甲", L"乙"};
  for (int line = 1; line <= 8; ++line) {
    if (line > 1) t.Input();
    t.Show(plate, speakers[line % 2], kLaneSetText);
    assert(t.current != plate);
    t.Show(body, Line(line), kLaneSetTextBool);
    assert(t.current != plate);
  }
  assert(t.current == ud::kNoSurface);
}

// Auto mode: lines change with no input: nothing is proven.  Clicking again
// proves it after kPromotionCommits input-caused commits.
void TestAutoModeProvesNothing() {
  Table t(1);
  for (int line = 1; line <= 10; ++line) t.Show(0, Line(line), kLaneSetText);
  assert(t.current == ud::kNoSurface && t.tracks[0].score == 0u);
  for (int line = 11; line <= 13; ++line) {
    t.Input();
    t.Show(0, Line(line), kLaneSetText);
  }
  assert(t.current == 0u);
  // A timed line without input resets the score but keeps the mark (no
  // rival).
  t.Show(0, Line(14), kLaneSetText);
  assert(t.last.verdict == ud::CommitVerdict::kUnprompted);
  assert(t.tracks[0].score == 0u && t.current == 0u);
}

// A component that is never shown (inactive / culled / off screen) never
// counts, whatever the inputs.
void TestHiddenSurfaceNeverCounts() {
  Table t(1);
  for (int line = 1; line <= 8; ++line) {
    t.Input();
    t.Show(0, Line(line), kLaneSetTextBool, /*shown=*/false);
  }
  assert(t.tracks[0].score == 0u && t.current == ud::kNoSurface);
  assert(t.last.verdict == ud::CommitVerdict::kUnseen);
}

// A wrong early leader (a menu description changed by keyboard navigation)
// loses the mark once the dialogue catches up and the dialogue takes it once
// it leads; a surface leaving the table loses the mark.
void TestOvertakeAndEviction() {
  Table t(2);
  const size_t menu = 0;
  const size_t dialogue = 1;
  for (int item = 0; item <= 3; ++item) {
    t.Input();
    t.Show(menu, L"項目の説明" + std::to_wstring(item), kLaneSetText);
  }
  assert(t.current == menu);
  t.Show(dialogue, Line(1), kLaneSetTextBool);
  for (int line = 2; line <= 3; ++line) {
    t.Input();
    t.Show(dialogue, Line(line), kLaneSetTextBool);
    assert(t.current == menu);  // dialogue 1, 2 < 3
  }
  t.Input();
  t.Show(dialogue, Line(4), kLaneSetTextBool);
  assert(t.current == ud::kNoSurface);  // tie at 3: no proof either way
  t.Input();
  t.Show(dialogue, Line(5), kLaneSetTextBool);
  assert(t.current == ud::kNoSurface);  // 4 vs 3: not a lead
  t.Input();
  t.Show(dialogue, Line(6), kLaneSetTextBool);
  assert(t.current == dialogue);  // 5 vs 3
  t.Evict(dialogue);
  assert(t.current == menu);  // the menu leads again (3 vs nothing)
  t.Evict(menu);
  assert(t.current == ud::kNoSurface);
}

// Pending-line bookkeeping: growth keeps the shown evidence, the first text
// is no commit, a looping sentence counts once.
void TestCommitBookkeeping() {
  Table t(1);
  t.Show(0, L"あ", kLaneSetText);
  assert(t.last.step == ud::TextStep::kGrowth &&
         t.last.verdict == ud::CommitVerdict::kNone);
  t.Show(0, L"あい", kLaneSetText, /*shown=*/false);
  assert(t.last.step == ud::TextStep::kGrowth);
  assert(t.tracks[0].pending_shown);  // shown while it was "あ"
  t.Show(0, L"あい", kLaneSetText);
  assert(t.last.step == ud::TextStep::kSame);
  t.Input();
  t.Show(0, L"う", kLaneSetText);
  assert(t.last.verdict == ud::CommitVerdict::kCounted);
  t.Input();
  t.Show(0, L"あい", kLaneSetText);  // commits "う": differs from "あい"
  assert(t.last.verdict == ud::CommitVerdict::kCounted);
  assert(t.tracks[0].score == 2u);

  Table loop(1);
  loop.Show(0, L"繰り返し", kLaneSetText);
  loop.Input();
  loop.Show(0, L"繰", kLaneSetText);  // restart: commits "繰り返し"
  assert(loop.last.verdict == ud::CommitVerdict::kCounted);
  loop.Show(0, L"繰り返し", kLaneSetText);
  assert(loop.last.step == ud::TextStep::kGrowth);
  loop.Input();
  loop.Show(0, L"繰", kLaneSetText);  // the same sentence again
  assert(loop.last.verdict == ud::CommitVerdict::kRepeated);
  assert(loop.tracks[0].score == 1u);
}

}  // namespace

int main() {
  TestPureHelpers();
  TestManyLabelsAndOneDialogue();
  TestLoopingPreviewIsNotDialogue();
  TestSingleUiTextNarrationAndTimerLabel();
  TestNamePlateTie();
  TestPlateOneFrameAhead();
  TestAutoModeProvesNothing();
  TestHiddenSurfaceNeverCounts();
  TestOvertakeAndEviction();
  TestCommitBookkeeping();
  std::printf("unity_mono_dialogue_test: ok\n");
  return 0;
}

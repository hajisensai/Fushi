// BUG-1593：整句语音窗口下界的不变量测试。
//
// fixture 全部是**真机采到的**时间轴（フタマタ恋愛 / KiriKiriZ，x86，2026-08-13，
// injector 早注入 pid=189452，只读探针从共享内存 dump 出的 VoiceClip 索引），不是编的：
// 每句语音一个新建的 DirectSound buffer，Play 前把整个缓冲一次灌满（1000ms 静音底 +
// 4×125ms 人声，全落在同一个 tick），提交时刻比文本 hook 早 219ms。
//
// 不用 assert：本目录的测试目标没有关掉 NDEBUG，Release 配置下 assert 会被整条编掉，
// 那样的「测试」永远绿。这里用显式检查 + 非零退出码。
#include <cstdint>
#include <cstdio>
#include <vector>

#include "voice_hook_utterance_window.h"

using fushi_voice_hook::UtteranceClipTiming;
using fushi_voice_hook::UtteranceLowerBoundMs;

namespace {

int g_failures = 0;

void Expect(bool ok, const char* what, int64_t got, int64_t want) {
  if (ok) {
    return;
  }
  ++g_failures;
  printf("FAIL %s: got %lld want %lld\n", what, static_cast<long long>(got),
         static_cast<long long>(want));
}

void ExpectEq(int64_t got, int64_t want, const char* what) {
  Expect(got == want, what, got, want);
}

// 真机时间轴：一句语音（新建 buffer）。第一段是整缓冲灌入，随后 125ms 一段流式补。
std::vector<UtteranceClipTiming> RealUtterance(int64_t t0) {
  return {
      {t0, 1000},      {t0, 125},       {t0, 125},       {t0, 125},
      {t0, 125},       {t0 + 62, 125},  {t0 + 109, 125}, {t0 + 172, 125},
      {t0 + 234, 125}, {t0 + 297, 125}, {t0 + 359, 125}, {t0 + 422, 125},
      {t0 + 484, 125}, {t0 + 547, 125}, {t0 + 609, 125}, {t0 + 672, 125},
  };
}

}  // namespace

int main() {
  // ① 真机主用例：文本时刻比整块灌入晚 219ms —— 旧的固定 -200ms 下界会把这 1500ms
  //    整块丢掉；下界必须回退到灌入时刻本身。
  {
    const int64_t t0 = 519155031;
    const int64_t text_ts = t0 + 219;  // 真机实测 519155250
    const auto clips = RealUtterance(t0);
    ExpectEq(UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts), t0,
             "fill-ahead burst recovered");
  }

  // ② 上一版判据翻车的边缘用例：突发块与其后第一段流式段之间是 63ms（另一句是
  //    62ms），逐对阈值会在 GetTickCount64 的 15ms 粒度噪声上二选一。聚合判据必须
  //    对两者都成立。
  for (const int64_t first_gap : {62, 63}) {
    const int64_t t0 = 519148640;
    const int64_t text_ts = t0 + 219;
    std::vector<UtteranceClipTiming> clips{
        {t0, 1000},   {t0, 125},
        {t0, 125},    {t0, 125},
        {t0, 125},    {t0 + first_gap, 125},
        {t0 + first_gap + 47, 125}, {t0 + first_gap + 109, 125},
        {t0 + first_gap + 172, 125}, {t0 + first_gap + 234, 125},
    };
    ExpectEq(UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts), t0,
             first_gap == 62 ? "burst boundary gap=62" : "burst boundary gap=63");
  }

  // ③ 实时写入的混音 / BGM 源：125ms 音频约每 120ms 写一次，判据不成立，下界必须
  //    原样是 ts-200（对这类源逐字节等价于旧行为——真机实测差异 0 字节）。
  {
    const int64_t t0 = 519000000;
    std::vector<UtteranceClipTiming> clips;
    for (int i = 0; i < 200; ++i) {
      clips.push_back({t0 + i * 120, 125});
    }
    const int64_t text_ts = t0 + 100 * 120;
    ExpectEq(UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts),
             text_ts - fushi_voice_hook::kUtteranceBackMs,
             "realtime stream unchanged");
  }

  // ④ 上一句的段不许被拼进来：两句之间隔着 3.4s 空档（真机实测值），下界只能停在
  //    本句的灌入块，不能穿到上一句。
  {
    const int64_t prev_t0 = 519148640;
    const int64_t t0 = prev_t0 + 6391;  // 真机：519155031
    std::vector<UtteranceClipTiming> clips = RealUtterance(prev_t0);
    for (const auto& c : RealUtterance(t0)) {
      clips.push_back(c);
    }
    const int64_t text_ts = t0 + 219;
    ExpectEq(UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts), t0,
             "previous utterance not spliced");
  }

  // ⑤ 回看上限：即便判据一路成立，也不许超过 kUtteranceMaxBackMs。
  {
    const int64_t t0 = 519000000;
    std::vector<UtteranceClipTiming> clips;
    for (int i = 0; i < 400; ++i) {
      clips.push_back({t0 + i * 30, 1000});  // 30ms 写一次 1000ms：一路都是提前灌入
    }
    const int64_t text_ts = t0 + 399 * 30;
    const int64_t lower =
        UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts);
    Expect(text_ts - lower <= fushi_voice_hook::kUtteranceMaxBackMs,
           "max back cap", text_ts - lower, fushi_voice_hook::kUtteranceMaxBackMs);
  }

  // ⑥ 边界：空输入 / 全部段都已在窗口内 —— 下界恒为 ts-200，且永不晚于 ts-200。
  {
    const int64_t text_ts = 1000000;
    ExpectEq(UtteranceLowerBoundMs(nullptr, 0, text_ts),
             text_ts - fushi_voice_hook::kUtteranceBackMs, "empty input");
    std::vector<UtteranceClipTiming> clips{
        {text_ts - 100, 125}, {text_ts - 20, 125}, {text_ts + 60, 125}};
    ExpectEq(UtteranceLowerBoundMs(clips.data(), clips.size(), text_ts),
             text_ts - fushi_voice_hook::kUtteranceBackMs, "all inside window");
  }

  if (g_failures != 0) {
    printf("utterance_window_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("utterance_window_test: ok\n");
  return 0;
}

#ifndef FUSHI_VOICE_HOOK_SOURCE_WINDOW_H_
#define FUSHI_VOICE_HOOK_SOURCE_WINDOW_H_

#include <cstdint>

// 自动选语音源的两段采样窗口（相对文本时刻 ts 的毫秒偏移，闭区间）。
//
// 判据是「文本时刻平均能量 − 说话前平均能量」最大者，即**从静音跳到有声**的那个源。
// 两段窗口之间留有一条守卫带：落在带内的段既不算「说话前」也不算「文本时刻」，
// 免得同一段既抬高 at 又抬高 before、把差值抹平。
//
// 为什么要分两套窗口：
//   * 旧窗口（kLegacy…）是 DirectSound / KiriKiri / Siglus / Unity 等**全部既有引擎**
//     实测标定出来的。它们的语音提交时刻与文本时刻几乎同拍，at 窗前界 -150ms 之外
//     的东西基本只可能是 UI 音效。
//   * 分类器感知的引擎（当前是 SGRE 的 xWMA）实测在 UserHook1 文本前约 156ms 就把
//     整句一次性提交，-150ms 会**仅差数毫秒**选不出已经通过 role-voice 分类的源。
//
// 放宽只能给已声明分类能力的引擎。无条件放宽会让文本前 200ms 的 UI 音效被算成
// 「从静音跳到有声」抢赢真语音源，而那正是旧窗口那条 100ms 守卫带在挡的东西。
// 分类器未生效时本头必须逐字节退回旧窗口——native 测试钉住这条不变量。
namespace fushi_voice_hook {

struct VoiceSourceSelectionWindow {
  int64_t at_begin_ms;      // 文本时刻窗口下界
  int64_t at_end_ms;        // 文本时刻窗口上界
  int64_t before_begin_ms;  // 说话前窗口下界
  int64_t before_end_ms;    // 说话前窗口上界
};

// 既有引擎的标定窗口。守卫带 = (before_end_ms, at_begin_ms) = (-250, -150)，宽 99ms。
constexpr VoiceSourceSelectionWindow kLegacyVoiceSourceSelectionWindow{
    -150, 450, -900, -250};

// 分类器感知引擎的窗口：at 前界放宽到 -250ms 兜住调度抖动 + 实测 156ms 提前量；
// before 上界随之退到 -251ms，保证两窗仍不重叠。
constexpr VoiceSourceSelectionWindow kClassifiedVoiceSourceSelectionWindow{
    -250, 450, -900, -251};

constexpr VoiceSourceSelectionWindow SelectVoiceSourceWindow(
    bool role_classifier_active) {
  return role_classifier_active ? kClassifiedVoiceSourceSelectionWindow
                                : kLegacyVoiceSourceSelectionWindow;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_SOURCE_WINDOW_H_

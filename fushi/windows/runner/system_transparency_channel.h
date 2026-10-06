#ifndef RUNNER_SYSTEM_TRANSPARENCY_CHANNEL_H_
#define RUNNER_SYSTEM_TRANSPARENCY_CHANNEL_H_

#include <flutter/binary_messenger.h>

namespace fushi {

// 读取「设置 → 个性化 → 颜色 → 透明效果」开关：
// HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize
//   EnableTransparency (DWORD)，0 = 关闭透明效果。
// 返回 true 表示用户关闭了透明效果（即应「降低透明度」）。读不到值时按系统默认
// （透明效果开启）返回 false。
bool ReadReduceTransparency();

}  // namespace fushi

// 在 [messenger] 上注册 `app.fushi/system_transparency`：
//   Dart → 原生 `getReduceTransparency` 返回 bool；
//   原生 → Dart `reduceTransparencyChanged`(bool) 在值变化时推送。
// channel 对象存活到进程结束；只在主窗口 OnCreate 调用一次。
void RegisterSystemTransparencyChannel(flutter::BinaryMessenger* messenger);

// 主窗口收到 WM_SETTINGCHANGE("ImmersiveColorSet") 时调用：重读注册表，值与上次
// 推送不同才 InvokeMethod 给 Dart。channel 未注册前调用为 no-op。必须在 platform
// 线程（WndProc）调用。
void NotifySystemTransparencySettingChanged();

#endif  // RUNNER_SYSTEM_TRANSPARENCY_CHANNEL_H_

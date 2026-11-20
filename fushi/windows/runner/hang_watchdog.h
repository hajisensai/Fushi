#ifndef RUNNER_HANG_WATCHDOG_H_
#define RUNNER_HANG_WATCHDOG_H_

// BUG-2588 / 反馈 JjjCk58rPZ：主线程停泵看门狗 + 卡顿计量。
//
// 为什么需要：卡死 / 卡顿不是崩溃——没有异常、`SetUnhandledExceptionFilter`
// 不会触发、WER 不留 dump；Dart 侧也看不到平台线程当时卡在哪个 native 帧。
// BUG-2588（视频页查词整机卡死）与 BUG-4046 复测（反馈 JjjCk58rPZ：制卡关窗后
// 查词表面约 13.7 s 不恢复，期间 hibiki_glookup.log 整段空白、4 次点击在恢复
// 那一刻同 tick 一起处理）都卡在「平台线程不泵消息」这一层，根因要看调用栈。
//
// 旧判据 `IsHungAppWindow` 自带「连续 5 s 没取消息」的门槛，再叠 10 s 连续采样，
// 实际要卡满约 15 s 才抓 dump——13.7 s 那次刚好落在门槛下，什么都没留下；
// 5 s 以内的卡顿更是完全量不到。
//
// 现在的做法：旁路线程往主窗 Post 一条心跳消息（RegisterWindowMessage 注册的
// 私有消息，带序号），主线程任何一个消息泵（主循环、模态循环、拖窗循环）派发到
// 主窗时由 [HandleHangWatchdogHeartbeat] 记下应答时刻；旁路线程每 100 ms 看一次
// 「心跳发出多久还没被应答」。同一时刻只有一条心跳在途，卡顿期间不会堆消息。
// 计时用 `QueryUnbiasedInterruptTime`（不含系统睡眠），合盖睡眠不会被当成卡顿。
//
//  - 停泵 >= kStallLogThresholdMs：恢复时往 hibiki_glookup.log 写一行
//    `main-thread stall: ms=<时长> …`（反馈日志「game lookup diagnostics」一节
//    的白名单前缀，与 gal-attached 状态时间线并排可对照）。
//  - 停泵 >= kStallDumpThresholdMs：当场从旁路线程抓一份全线程栈 minidump
//    （`crashdumps\hang-<pid>-<tick>.dmp`，诊断区「崩溃转储」页自动列出、可
//    分享），并往同目录 hang_watchdog.log 追加一行（下次启动由 Dart
//    `HangWatchdogLog` 折进错误日志）；恢复时再补一行实际时长。每进程最多抓
//    kMaxHangDumpsPerProcess 份，目录里 hang-*.dmp 最多留 kMaxHangDumpsKept 份。
//
// 不会误报：原生模态对话框 / 拖窗循环自己泵消息，心跳照常被应答；调试器附着时
// 不记不抓；窗口关闭 / 消息循环退出后先 `StopHangWatchdog()` 再拆窗口。

#include <windows.h>

namespace fushi
{
  // 卡顿达到这个时长就在恢复时写一行 `main-thread stall:`（毫秒）。
  constexpr ULONGLONG kStallLogThresholdMs = 500;

  // 卡顿达到这个时长就当场抓 dump（毫秒）。同步 FFI 查词实测最长 1.7 s，在此之下。
  constexpr ULONGLONG kStallDumpThresholdMs = 3000;

  // 每个进程最多抓几份 hang dump：持续卡死只要一份；反复卡顿留前几次就够看规律。
  constexpr int kMaxHangDumpsPerProcess = 3;

  // crashdumps 目录里 hang-*.dmp 最多保留几份（抓完新的再删最旧的），防止长期
  // 反复卡顿把磁盘塞满。崩溃 dump（hibiki-*.dmp）不受影响。
  constexpr int kMaxHangDumpsKept = 5;

  // 启动看门狗线程。[main_window] 是 Flutter 主窗口（必须属于调用线程，看门狗
  // 用调用线程 id 标记 dump 的「出事线程」）。重复调用无效果；失败静默降级。
  void StartHangWatchdog(HWND main_window);

  // 停止看门狗线程并等它退出（最多等 2 s）。在消息循环退出后、窗口拆除前调用，
  // 否则退出期窗口不再泵消息会被当成卡死抓一份无意义的 dump。
  void StopHangWatchdog();

  // 主窗窗口过程最先调用：[message] 是看门狗心跳时记下应答并返回 true（调用方
  // 直接 return 0），否则返回 false、什么都不做。
  bool HandleHangWatchdogHeartbeat(UINT message, WPARAM wparam);
}

#endif  // RUNNER_HANG_WATCHDOG_H_

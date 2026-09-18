#ifndef RUNNER_HANG_WATCHDOG_H_
#define RUNNER_HANG_WATCHDOG_H_

// BUG-2588：主线程停泵看门狗。
//
// 为什么需要：用户报「视频页 Shift 查词换词那一刻整个 app 卡死」（键鼠全无
// 响应，只能强杀）。卡死不是崩溃——没有异常、`SetUnhandledExceptionFilter`
// 不会触发、WER 不会留 dump；Dart 侧的查词面包屑只能在下次启动记下「上次某
// 查词栈层活跃期间进程没有正常退出」（`Lookup.crashRecovered`），既分不清崩溃
// 与卡死，更看不到主线程当时卡在哪个 native 帧。BUG-2572 同一家族（Windows
// 视频页键鼠失灵、小内存模式可规避）两轮离屏探针都没复现，报告人也拿不出任何
// 二进制证据，根因至今悬置。
//
// 做法：一条旁路线程每秒查一次 `IsHungAppWindow(主窗口)`（系统判据：该线程
// 连续 5 s 没取消息）；连续命中达到阈值（默认 10 s）且没有调试器附着，就从
// 旁路线程调 `WriteProcessMinidump(L"hang", 主线程 id, nullptr, …)` 抓一份
// 全线程栈的 minidump（`MiniDumpWriteDump` 会挂起所有线程，主线程当时的栈原样
// 进 dump），落在与崩溃 dump 同一目录（诊断区「崩溃转储」页自动列出、可分享），
// 并在同目录 `hang_watchdog.log` 追加一行「什么时候、卡了多久、dump 在哪」供
// Dart 侧下次启动折进错误日志。每个进程最多抓一次——卡死通常一直卡到被强杀，
// 一份就够，也避免同一次卡死连写多份把磁盘塞满。
//
// 不会误报的几种正常情形：原生模态对话框（file_picker / MessageBox）自己泵消息，
// 窗口不算 hung；同步 FFI 查词最长实测 1.7 s，远低于阈值；调试器断点时跳过；
// 窗口关闭 / 消息循环退出后先 `StopHangWatchdog()` 再拆窗口。

#include <windows.h>

namespace fushi
{
  // 主线程连续停泵多久才抓 dump（毫秒）。`IsHungAppWindow` 自身已有 5 s 门槛，
  // 这里再叠加连续采样数，实际触发点约为 5 s + 阈值。
  constexpr DWORD kHangDumpThresholdMs = 10000;

  // 启动看门狗线程。[main_window] 是 Flutter 主窗口（必须属于调用线程，看门狗
  // 用调用线程 id 标记 dump 的「出事线程」）。重复调用无效果；失败静默降级。
  void StartHangWatchdog(HWND main_window);

  // 停止看门狗线程并等它退出（最多等 2 s）。在消息循环退出后、窗口拆除前调用，
  // 否则退出期窗口不再泵消息会被当成卡死抓一份无意义的 dump。
  void StopHangWatchdog();
}

#endif  // RUNNER_HANG_WATCHDOG_H_

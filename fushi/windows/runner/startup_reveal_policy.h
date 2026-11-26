#ifndef RUNNER_STARTUP_REVEAL_POLICY_H_
#define RUNNER_STARTUP_REVEAL_POLICY_H_

#include <windows.h>
#include <dwmapi.h>

// 主窗「隐藏建窗、Dart 首帧后才显窗」的两条原生判据（反馈：Surface Pro 7+ 升级 3.4
// 后进程常驻后台、窗口永远不出，重启多次无效）。纯函数，随每次 Windows runner 构建
// 由 tests/startup_reveal_policy_test.cpp 执行。
//
// 1. 启动期限：普通启动主窗一直藏着，直到 Dart 把首页 / 错误页的第一帧送上屏再
//    windowManager.show()。Dart 里任何一步 await 不返回、或第一帧永远光栅化不出来，
//    进程就成了没有窗口的后台进程，且握着单实例互斥量——之后每次点图标都只是把请求
//    转给它然后退出，用户除了重启电脑无路可走，也不留任何证据（主线程照常泵消息，
//    停泵看门狗不响；Dart 心跳照常，失联检测也不响）。看门狗线程在主窗建好
//    kStartupRevealDeadlineMs 后仍从未显示过时抓一份全线程栈 dump、记一行
//    hang_watchdog.log，并 PostMessageW(ForceStartupRevealMessage()) 投递给主窗线程
//    撤隐身 + 显窗（用户至少能看见、能关掉它；投递式，看门狗线程不跟着阻塞）。
//    Dart 侧 lib/src/startup/startup_stall_deadline.dart 在更早一点（40 s）把已走到的
//    启动阶段写进同一个日志，两条合起来就是「卡在哪个 await」+「各线程在干什么」。
//
// 2. 二次启动对已有实例的分类：主窗不可见有两种完全不同的含义——首实例**正在启动**
//    （从没显示过）或**正在退出**（退出链第一步 windowManager.hide()）。旧判据把
//    「不可见」一律当退出，启动中的首实例会让第二个进程白等 kPreviousInstanceWaitMs
//    再把请求转给隐藏窗口。主窗第一次可见时由看门狗线程挂上 kMainWindowShownProp，
//    第二个进程（跨进程 GetPropW）据此区分两种不可见。
//    第三种不可见是「关闭到托盘」（tray_icon.h 的 kTrayHiddenWindowProp）：首实例
//    照常运行，只是主窗藏着，要转交 + 把主窗找回来，不能当退出白等。退出链在隐藏
//    主窗前先摘掉这个属性（托盘通道 `exiting`），所以托盘里点「退出」仍判成退出中。
namespace fushi {

// 主窗显示过一次后挂上的窗口属性（值恒为 1）。只增不删：退出链隐藏窗口后它仍在。
inline constexpr wchar_t kMainWindowShownProp[] = L"FushiMainWindowShown";

// 主窗建好后多久仍未显示就判定启动卡死。正常冷启动 1~3 s；最慢的合法路径是裸加载
// 看门狗（main.dart `_loadingWatchdogTimeout`，20 s）到点放出首帧，再加 present
// 看门狗（30 s）自动重启的那一轮之前——45 s 留足余量，又不至于让用户对着空桌面等。
inline constexpr ULONGLONG kStartupRevealDeadlineMs = 45000;

enum class ExistingInstanceState {
  // 没找到首实例主窗：首实例还没建窗，或已经走干净。
  kNoWindow,
  // 主窗存在、从没显示过：首实例正在启动（或卡在启动里，由它自己的启动期限显窗）。
  kStarting,
  // 主窗可见：首实例正常运行。
  kShown,
  // 主窗被关闭到托盘藏着：首实例正常运行，转交后要把主窗重新显示出来。
  kInTray,
  // 主窗显示过、现在不可见：首实例正在退出。
  kExiting,
};

inline ExistingInstanceState ClassifyExistingInstance(bool window_found,
                                                      bool visible,
                                                      bool ever_shown,
                                                      bool hidden_to_tray) {
  if (!window_found) return ExistingInstanceState::kNoWindow;
  if (visible) return ExistingInstanceState::kShown;
  if (hidden_to_tray) return ExistingInstanceState::kInTray;
  return ever_shown ? ExistingInstanceState::kExiting
                    : ExistingInstanceState::kStarting;
}

// 看门狗每轮问一次：主窗从没显示过、还没强制显示过、且已过期限 → 抓证据并强制显窗。
inline bool ShouldForceStartupReveal(ULONGLONG elapsed_ms, bool ever_shown,
                                     bool already_forced) {
  return !ever_shown && !already_forced &&
         elapsed_ms >= kStartupRevealDeadlineMs;
}

// 3. 启动期主窗从建窗起就隐身（BUG-5491）：Dart 显窗前，启动阶段的某些窗口操作会
//    顺带把隐藏的主窗显出来——上次最大化关掉时 applyInitialPlacement 的
//    windowManager.maximize() 投的是 SC_MAXIMIZE，最大化一个隐藏窗口必然连带显示
//    （实测这条路径不发 WM_SHOWWINDOW，没法在「显示那一刻」再拦）。那时 Flutter
//    还没出首帧，用户对着原生兜底底色（#1F4959 青绿）干等好几秒。
//    所以普通启动（隐藏建窗）的主窗建好就上 DWM 隐身（DWMWA_CLOAK）：窗口照常最大化、
//    照常合成、首帧按最终尺寸光栅化，只是不呈现给用户；Dart 首帧上屏后的显窗点
//    （`showStartupWindow`：撤隐身 + 显示 + 前置，一次往返）或看门狗的强制显窗
//    撤掉隐身。集成测试窗口（FUSHI_TEST_HIDDEN）建窗即可见、要被截图，不隐身。
inline bool ShouldCloakAtCreation(bool test_hidden_mode) {
  return !test_hidden_mode;
}

// DWMWA_CLOAKED 读回的是隐身来源位掩码。只有 DWM_CLOAKED_APP（本进程自己
// DWMWA_CLOAK 上的启动隐身）算「还没显示」；DWM_CLOAKED_SHELL 是窗口在别的虚拟
// 桌面等外壳原因，DWM_CLOAKED_INHERITED 是继承所有者的隐身——这些都不是启动没
// 显窗，当成未显示会让看门狗在用户切走桌面时误抓 dump、误强制显窗、迟迟不挂
// kMainWindowShownProp。
inline bool IsStartupCloaked(DWORD cloaked_flags) {
  return (cloaked_flags & DWM_CLOAKED_APP) != 0;
}

// 「用户真的看得见」= Win32 可见且没被启动隐身。隐身中的主窗 IsWindowVisible 为真，
// 但用户什么也看不到：看门狗不能据此挂 kMainWindowShownProp，也不能因此放弃强制显窗。
inline bool IsWindowUserVisible(bool win32_visible, bool startup_cloaked) {
  return win32_visible && !startup_cloaked;
}

// 看门狗（另一线程）请主窗线程完成启动显窗：撤隐身 + ShowWindow。用注册消息而不是
// 裸 ShowWindowAsync——已最大化（Win32 可见）但隐身的窗口，SW_SHOW 什么也不改。
inline UINT ForceStartupRevealMessage() {
  static const UINT message = RegisterWindowMessageW(L"FushiForceStartupReveal");
  return message;
}

}  // namespace fushi

#endif  // RUNNER_STARTUP_REVEAL_POLICY_H_

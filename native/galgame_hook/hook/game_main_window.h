// 游戏主窗口的唯一判据。hook DLL（lookup_overlay_window.inc 的 FindGameMainWindow 转发）
// 与 CTest（tests/game_main_window_test.cpp，真 Win32 窗口）共用这一份，两边不得各抄一套。
//
// 判据：本进程里**客户区面积最大**的可见顶层窗口。启动器 / 控制台 / 工具窗 / 我们自己那个
// 1x1 的 overlay 都比它小。
//
// owner 只排除「被一个**自身也是候选**（可见且客户区非空）的窗口 own」的窗口——那才是对话框 /
// 工具提示 / 子浮窗的形状。Borland VCL（KiriKiri2 2.x 全系、BCB 构建）把每个 TForm 都建成
// `Application.Handle` 的 owned window，而那个 TApplication 窗**可见但 0x0**（Fate/stay
// night[Realta Nua] 真机实测：cls=TApplication vis=True client=0x0，任务栏按钮就挂在它上面，
// 这是 MainFormOnTaskBar 之前的老 VCL 形状）。旧判据「GetWindow(GW_OWNER) != nullptr 就跳过」
// 和中间版本「owner 可见就跳过」在这类引擎上都一个主窗都选不出，下游三处——查词安装的引擎
// 主线程解析（ResolveKirikiriEngineMainThreadId）、exe 直取 exporter 的静态初始化门
// （BUG-2118）、overlay owner——全部静默失败，症状与「这个引擎不支持」完全同形（BUG-2121）。
#pragma once

#include <windows.h>

namespace fushi_voice_hook {

struct GameMainWindowSearch {
  DWORD pid = 0;
  HWND best = nullptr;
  long best_area = 0;
};

inline long WindowClientArea(HWND window) {
  RECT rect = {};
  if (!GetClientRect(window, &rect)) return 0;
  return static_cast<long>(rect.right - rect.left) *
         static_cast<long>(rect.bottom - rect.top);
}

// 「被一个可见且客户区非空的窗口 own」= 对话框 / 工具提示 / overlay，不是主窗候选。
// 隐藏 owner、或可见但 0x0 的 owner（VCL TApplication）都不算：它们不可能是用户看见的那个
// 主窗，被它们 own 的窗口自己才是。
inline bool IsOwnedByVisibleWindow(HWND window) {
  const HWND owner = GetWindow(window, GW_OWNER);
  return owner != nullptr && IsWindowVisible(owner) && WindowClientArea(owner) > 0;
}

inline BOOL CALLBACK GameMainWindowEnumProc(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<GameMainWindowSearch*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid) return TRUE;
  if (!IsWindowVisible(window)) return TRUE;
  if (IsOwnedByVisibleWindow(window)) return TRUE;
  const long area = WindowClientArea(window);
  if (area > search->best_area) {
    search->best_area = area;
    search->best = window;
  }
  return TRUE;
}

inline HWND FindGameMainWindowOfProcess(DWORD pid) {
  GameMainWindowSearch search;
  search.pid = pid;
  EnumWindows(&GameMainWindowEnumProc, reinterpret_cast<LPARAM>(&search));
  return search.best;
}

inline HWND FindGameMainWindow() {
  return FindGameMainWindowOfProcess(GetCurrentProcessId());
}

}  // namespace fushi_voice_hook

// 游戏主窗口的唯一判据。hook DLL（lookup_overlay_window.inc 的 FindGameMainWindow 转发）
// 与 CTest（tests/game_main_window_test.cpp，真 Win32 窗口）共用这一份，两边不得各抄一套。
//
// 判据：本进程里**客户区面积最大**的可见顶层窗口。启动器 / 控制台 / 工具窗 / 我们自己那个
// 1x1 的 overlay 都比它小。
//
// owner 只排除「被一个**可见**窗口 own」的窗口——那才是对话框 / 工具提示 / 子浮窗的形状。
// owner 本身不可见的窗口照常参选：Borland VCL（KiriKiri2 2.x 全系、BCB 构建）把每个 TForm
// 都建成 `Application.Handle` 的 owned window，而那个 TApplication 窗永远隐藏、0x0。旧判据
// 「GetWindow(GW_OWNER) != nullptr 就跳过」在这类引擎上一个主窗都选不出，下游三处——查词安装
// 的引擎主线程解析（ResolveKirikiriEngineMainThreadId）、exe 直取 exporter 的静态初始化门
// （BUG-2118）、overlay owner——全部静默失败，症状与「这个引擎不支持」完全同形（BUG-2121，
// Fate/stay night[Realta Nua] KiriKiri2 2.31 真机：lookup_diag 整局零 sensor 位）。
#pragma once

#include <windows.h>

namespace fushi_voice_hook {

struct GameMainWindowSearch {
  DWORD pid = 0;
  HWND best = nullptr;
  long best_area = 0;
};

// 「被可见窗口 own」= 对话框 / 工具提示 / overlay，不是主窗候选。隐藏 owner（VCL TApplication）
// 不算 owner：它不可能是用户看见的那个主窗，被它 own 的窗口自己才是。
inline bool IsOwnedByVisibleWindow(HWND window) {
  const HWND owner = GetWindow(window, GW_OWNER);
  return owner != nullptr && IsWindowVisible(owner);
}

inline BOOL CALLBACK GameMainWindowEnumProc(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<GameMainWindowSearch*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid) return TRUE;
  if (!IsWindowVisible(window)) return TRUE;
  if (IsOwnedByVisibleWindow(window)) return TRUE;
  RECT rect = {};
  if (!GetClientRect(window, &rect)) return TRUE;
  const long area = static_cast<long>(rect.right - rect.left) *
                    static_cast<long>(rect.bottom - rect.top);
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

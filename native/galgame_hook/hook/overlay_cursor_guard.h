// 游戏光标不得盖过 Fushi 浮层的光标（BUG-2864）。hook DLL（overlay_cursor_guard.inc 的
// SetCursor detour）与 CTest（tests/overlay_cursor_guard_test.cpp，真 Win32 窗口）共用这一份
// 判据，两边不得各抄一套。
//
// 根因：自定义鼠标指针的引擎不在 WM_SETCURSOR 里设光标，而是每帧
// `GetCursorPos → ScreenToClient → 点在自己客户区矩形内 → SetCursor(自定义帧)`。这个判断
// 只看几何，不看客户区上面是否盖着别的窗口（CLANNAD Steam / SiglusEngine 实测：
// `+0x281680` 起的光标函数，动画光标按 tick 换帧，`GetCursor() != 目标` 才调 SetCursor）。
// 查词卡正好盖在游戏客户区上，而且 runner 把它的 owner 设成了游戏 HWND
// （global_lookup_window.cpp 的 GWLP_HWNDPARENT；z 序与 SGRE 护盾契约都依赖它）。跨线程的
// owner/owned 关系会让系统隐式 AttachThreadInput：卡片线程与游戏线程共用一个输入队列，
// 也就共用同一份「当前光标」。卡片在 WM_SETCURSOR / WebView2 CursorChanged 里设系统光标，
// 游戏下一帧又在同一个队列上设回自己的——用户看到的就是光标在系统指针与游戏指针之间
// 来回闪。没有 owner 的跨线程浮窗不受影响（各自队列，系统只显示光标所在窗口那一份），
// 这一点由装置对照证实：同一假游戏 + 同一浮窗，有 owner 3 秒 72 次切换，无 owner 0 次。
//
// Win32 契约本来就是「窗口只在光标位于其客户区、或它持有鼠标捕获时才设光标」
// （SetCursor 文档）。所以这里只把游戏违反契约的那一种调用扣下：鼠标此刻归属的根窗口
// （有捕获时是捕获窗，否则是光标下的窗口）是**别的线程**的 Fushi 浮层。其余一律原样放行
// ——光标回到游戏画面上，游戏下一次 SetCursor 立刻恢复它自己的指针。
//
// 只认 Fushi 自己的窗口类（类名前缀 "Fushi"：runner 的 FushiGlobalLookupWindow /
// FushiAttachedTextSurfaceWindow / FushiHookToolbarWindow …，注入侧的 FushiLookupOverlay
// / FushiLookupHoverHighlight）；第三方覆盖窗口的光标归属不归本 DLL 管。
#pragma once

#include <windows.h>

#include <cwchar>

namespace fushi_voice_hook {

inline constexpr wchar_t kFushiOverlayWindowClassPrefix[] = L"Fushi";

inline bool IsFushiOverlayWindowClass(const wchar_t* class_name) {
  if (class_name == nullptr) return false;
  const size_t prefix_length =
      sizeof(kFushiOverlayWindowClassPrefix) / sizeof(wchar_t) - 1;
  return std::wcsncmp(class_name, kFushiOverlayWindowClassPrefix,
                      prefix_length) == 0;
}

// mouse_root：鼠标此刻归属的根窗口（见 MouseOwningRootWindow）。caller_thread_id：调
// SetCursor 的线程。游戏线程自己持有捕获（拖拽中）时 mouse_root 就是游戏窗口，自然放行。
inline bool ShouldWithholdGameCursor(HWND mouse_root, DWORD caller_thread_id) {
  if (mouse_root == nullptr) return false;
  const DWORD owner_thread_id = GetWindowThreadProcessId(mouse_root, nullptr);
  // 自己线程的窗口（含游戏自己的子窗 / 弹窗）照常设光标；取不到线程说明窗口已销毁。
  if (owner_thread_id == 0 || owner_thread_id == caller_thread_id) return false;
  wchar_t class_name[64] = {};
  if (GetClassNameW(mouse_root, class_name,
                    static_cast<int>(sizeof(class_name) / sizeof(wchar_t))) ==
      0) {
    return false;
  }
  return IsFushiOverlayWindowClass(class_name);
}

// 鼠标此刻归属的根窗口。GetCapture 返回的是**调用线程输入队列**上的捕获：队列被 owner
// 关系挂接后，卡片线程的捕获（卡内拖滚动条 / 选字）在游戏线程上也看得见，此时鼠标归卡片，
// 必须以捕获窗为准，否则拖拽期间游戏光标又会盖回来。没有捕获时取光标下的窗口：
// WindowFromPoint 只对**调用线程自己**的窗口同步发 WM_NCHITTEST，跨线程 / 跨进程的浮层只按
// 窗口区域与样式判定，不会因浮层线程忙而阻塞游戏线程；分层 + WS_EX_TRANSPARENT 的点击穿透
// 窗口会被它跳过，本就不该接管光标。
inline HWND MouseOwningRootWindow() {
  HWND window = GetCapture();
  if (window == nullptr) {
    POINT cursor = {};
    if (!GetCursorPos(&cursor)) return nullptr;
    window = WindowFromPoint(cursor);
    if (window == nullptr) return nullptr;
  }
  const HWND root = GetAncestor(window, GA_ROOT);
  return root != nullptr ? root : window;
}

inline bool ShouldWithholdGameCursorNow() {
  return ShouldWithholdGameCursor(MouseOwningRootWindow(), GetCurrentThreadId());
}

}  // namespace fushi_voice_hook

#ifndef RUNNER_LOW_LEVEL_MOUSE_HOOK_H_
#define RUNNER_LOW_LEVEL_MOUSE_HOOK_H_

// BUG-1048 — 进程级 WH_MOUSE_LL 承载线程。
//
// 低级鼠标钩子是**同步**钩子：系统把每一个鼠标输入事件（含高频 WM_MOUSEMOVE）投递到
// 安装钩子的那条线程的消息队列，并等它返回或超时（LowLevelHooksTimeout，默认 300ms）
// 才继续分发给前台程序。把它装在 Flutter 的 platform 线程上，等于让「全系统鼠标输入」
// 排在 Dart/Flutter 的渲染与 platform channel 之后：查词浮窗一出现，游戏里的鼠标移动
// 就跟着主线程的忙闲一卡一卡（用户实测「点击查词后鼠标移动都会变卡，不查就没事」）。
//
// 根因修复是让钩子跑在一条**只做钩子**的线程上：这里的线程除了 GetMessage 什么都不做，
// 回调只读 HWND 几何并 PostMessage（异步）回窗口线程，永远不会被 Flutter 的帧阻塞。
//
// 线程常驻（首次 Arm 时懒创建），Arm/Disarm 只是让它装/卸钩子——查词是高频操作，
// 每次都建销线程反而制造无谓的竞态窗口。
//
// BUG-1077 — 两条补强，针对「嵌套查词瞬间鼠标卡一下」：
//   ① 钩子线程跑在 TIME_CRITICAL 优先级：嵌套查词的瞬间进程内 CPU 风暴（同步 FFI
//      词典查询 + 整栈 JSON 序列化 + WebView2 COM + 窗口区域重建）会把 NORMAL
//      优先级的钩子线程抢占几十毫秒，而系统同步等它返回才分发输入——全系统鼠标
//      跟着卡一下。
//   ② Disarm 延迟真卸：嵌套/连续查词路径每次都是 Hide(Disarm) → 百毫秒 →
//      Reveal(Arm)，立卸立装 = 每次两回全局钩子表变更（又各是一次输入停顿）。
//      Disarm 先清目标（回调立即纯放行，语义等同已卸载），宽限期内无新 Arm 才
//      真正 UnhookWindowsHookEx。

#include <windows.h>

namespace fushi {

// 钩子命中时 PostMessage 给目标窗口的消息（WM_APP 段，进程内私有）：
//   wparam = 打包的屏幕物理坐标 ((uint32)x << 32) | (uint32)y
//   lparam = 1 表示点击落在目标窗口 rect 内，0 表示在外
// 窗口线程自己决定「转发给 host / 关闭浮窗」——钩子线程不碰任何 C++ 对象。
constexpr UINT kLowLevelMouseClickMessage = WM_APP + 0x51;

// BUG-1166 — 落在目标窗口内的滚轮：钩子**吞掉**它（回调返回非 0，事件不再进入
// 输入流），改投这条消息让窗口线程自己消化。
//   wparam = 打包的屏幕物理坐标（同上）
//   lparam = 打包的滚轮载荷（见 MouseHookWheel / PackMouseHookWheel）
// 窗口线程再按「有没有按 Ctrl/Alt」分流：裸滚轮走原生子窗 PostMessage，带修饰键的
// 走 host JS 合成事件（修饰键过不了 PostMessage 那道边界，见 MouseHookWheel 注释）。
// 为什么必须吞：查词卡是 WS_EX_NOACTIVATE 的非激活窗（design §5 保证 3 — 查词
// 不许动前台程序的键盘焦点），而 WM_MOUSEWHEEL 是投给**焦点窗口**的。焦点留在
// galgame 上，滚轮就照样喂给游戏（滚出履历/推进文本）；Win10 的「悬停滚动非活动
// 窗口」只是个可关的用户选项，靠不住。只要不吞，卡片滚不滚都改不了游戏在动。
constexpr UINT kLowLevelMouseWheelMessage = WM_APP + 0x52;

// 打包/解包屏幕坐标（x64 下 WPARAM 为 64 位；坐标可为负，故按 uint32 位模式搬运）。
WPARAM PackMouseHookPoint(int x, int y);
POINT UnpackMouseHookPoint(WPARAM wparam);

// 滚轮载荷。
//
// ⚠️ 修饰键**不能**靠 wparam 的 MK_* 位过 WebView2 这道边界（这是本 PR 复审推翻的
// 一条原始假设，别再改回去）：windowed 模式下窗口线程 PostMessage 的是一条**合成的**
// WM_MOUSEWHEEL，而 Chromium 取修饰键走 KeyStateFlagsFromNative() → GetKeyState()，
// **不读 wparam 的 MK_ 位**。GetKeyState 只随**硬件输入消息**出队才更新该线程的键
// 状态表；PostMessage 是非输入消息，加上查词卡是 WS_EX_NOACTIVATE、WebView2 的线程
// 不在前台输入队列里 —— 于是 e.ctrlKey 恒 false，PR#462 的 Ctrl+滚轮缩放会静默失效。
// 所以 ctrl / alt 改走**另一条显式携带修饰键的路**（GlobalLookupWindow::HandleGlobalWheel
// → ForwardGlobalWheelToHost → host JS 合成带显式 flag 的 WheelEvent）。
// keys 里的 MK_* 只服务**裸滚轮 / 仅 Shift** 那条原生 PostMessage 快路，不承担修饰键真值。
struct MouseHookWheel {
  int delta = 0;         // 有符号 WHEEL_DELTA 倍数
  UINT keys = 0;         // MK_* 位（仅供原生快路，非修饰键真值）
  bool horizontal = false;  // true = WM_MOUSEHWHEEL
  bool ctrl = false;        // 物理 Ctrl（GetAsyncKeyState）——分流判据
  // Alt 既没有 MK_ 位，COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS 也没有 ALT —— 结构上
  // 无法随 WM_MOUSEWHEEL 过界，只能靠这个字段单独带走。
  bool alt = false;         // 物理 Alt（VK_MENU）——分流判据
};
LPARAM PackMouseHookWheel(const MouseHookWheel& wheel);
MouseHookWheel UnpackMouseHookWheel(LPARAM lparam);

// 装钩子并把命中事件投递给 |target|。重复调用只是替换目标窗口（幂等）。
void ArmLowLevelMouseHook(HWND target);
// 卸钩子：目标窗口立即清空（回调纯放行）；真正的 UnhookWindowsHookEx 延迟一段
// 宽限期（见 .cpp 的 kDisarmGraceMs），期间再次 Arm 则取消卸载。未装时是 no-op。
void DisarmLowLevelMouseHook();

}  // namespace fushi

#endif  // RUNNER_LOW_LEVEL_MOUSE_HOOK_H_

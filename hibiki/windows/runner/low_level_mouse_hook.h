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

namespace hibiki {

// 钩子命中时 PostMessage 给目标窗口的消息（WM_APP 段，进程内私有）：
//   wparam = 打包的屏幕物理坐标 ((uint32)x << 32) | (uint32)y
//   lparam = 1 表示点击落在目标窗口 rect 内，0 表示在外
// 窗口线程自己决定「转发给 host / 关闭浮窗」——钩子线程不碰任何 C++ 对象。
constexpr UINT kLowLevelMouseClickMessage = WM_APP + 0x51;

// 打包/解包屏幕坐标（x64 下 WPARAM 为 64 位；坐标可为负，故按 uint32 位模式搬运）。
WPARAM PackMouseHookPoint(int x, int y);
POINT UnpackMouseHookPoint(WPARAM wparam);

// 装钩子并把命中事件投递给 |target|。重复调用只是替换目标窗口（幂等）。
void ArmLowLevelMouseHook(HWND target);
// 卸钩子：目标窗口立即清空（回调纯放行）；真正的 UnhookWindowsHookEx 延迟一段
// 宽限期（见 .cpp 的 kDisarmGraceMs），期间再次 Arm 则取消卸载。未装时是 no-op。
void DisarmLowLevelMouseHook();

}  // namespace hibiki

#endif  // RUNNER_LOW_LEVEL_MOUSE_HOOK_H_

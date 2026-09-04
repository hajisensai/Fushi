#ifndef RUNNER_GLOBAL_MOUSE_TRIGGER_H_
#define RUNNER_GLOBAL_MOUSE_TRIGGER_H_

// TODO-1066 — app 外全局查词的**鼠标侧键**触发源。
//
// 为什么是 Raw Input 而不是 WH_MOUSE_LL：
//
// 本仓已经有一条低级鼠标钩子（low_level_mouse_hook.cpp），但它是**同步**钩子：
// 系统把每一个鼠标事件投递到装钩子的线程并**等它返回或超时**才继续分发给前台
// 程序。那条钩子因此被严格限制在「查词卡显示期间」Arm、Hide 即 Disarm，
// BUG-1077 更把这条写成了明文契约——「不查词不留全局钩子」。
// 全局侧键触发要求的是「任何时候按下都能收到」，把那条钩子改成常驻就等于把
// BUG-1048 的原始症状（用户实测「点击查词后鼠标移动变卡，不查就没事」）从
// 查词期间扩大到永远。
//
// Raw Input + RIDEV_INPUTSINK 提供同样的「窗口不在前台也收得到」，但是**异步**
// 投递 WM_INPUT：它不插进系统输入分发的关键路径，没有 LowLevelHooksTimeout 那
// 套「回调慢了就被系统静默摘钩」的风险。
//
// 代价是 Raw Input 只能监听、不能拦截。这**正是**本功能要的语义：侧键在浏览器
// 里是前进/后退，在别的程序里也可能有绑定，吞掉就是破坏用户的正常使用。所以
// 「不能拦截」在这里不是限制，是需求。
//
// 常驻代价的纪律沿用 BUG-1077 的精神：**只在用户真的绑了侧键时才注册**
// （Dart 侧 GlobalLookupController._registerMouseTriggerFromRegistry 按绑定推
// 送，没绑就推 0 注销）。不用这个功能的用户，一个系统级监听都不留。

#include <windows.h>

namespace fushi {

// DOM `MouseEvent.button` 号（与 Dart 侧 MouseBinding.button 同一编码）。
// 只有侧键可以当全局触发：右键/中键有全系统级的默认语义（上下文菜单 /
// 自动滚动），而本触发**不拦截**原事件，绑上去等于两件事同时发生。
constexpr int kGlobalMouseTriggerNone = 0;
constexpr int kGlobalMouseTriggerBack = 3;     // XBUTTON1
constexpr int kGlobalMouseTriggerForward = 4;  // XBUTTON2

// 注册（[dom_button] = 3/4）或注销（0 / 任何其它值）全局侧键监听。
// [host] 是接收 WM_INPUT 的窗口，必须在监听期间保持有效（用主窗）。
// 返回是否成功；重复注册同一按钮是幂等的。
bool SetGlobalMouseTrigger(HWND host, int dom_button);

// 在 WM_INPUT 里调用。返回 true 表示「用户按下了已注册的侧键，且这一下不属于
// 本进程自己的窗口」——也就是应当去开一次全局查词。
//
// 调用方**仍须**把 WM_INPUT 交给 DefWindowProc（系统要靠它做清理）。
bool HandleGlobalMouseTriggerRawInput(LPARAM lparam);

}  // namespace fushi

#endif  // RUNNER_GLOBAL_MOUSE_TRIGGER_H_

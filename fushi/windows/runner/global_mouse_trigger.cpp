#include "global_mouse_trigger.h"

#include <atomic>

namespace fushi {

namespace {

// 当前已注册的 DOM 按钮号；0 = 未注册。WM_INPUT 在 UI 线程读，注册也在 UI 线程
// 写，用 atomic 只为把「注册/注销与消息处理交错」这件事写明白。
std::atomic<int> g_dom_button{0};

// Raw Input 的鼠标按钮位。注意编号与 DOM 差一：Windows 的 "button 4/5" 就是
// XBUTTON1/XBUTTON2，而 DOM 把它们叫 3(back)/4(forward)。
USHORT DownFlagForDomButton(int dom_button) {
  switch (dom_button) {
    case kGlobalMouseTriggerBack:
      return RI_MOUSE_BUTTON_4_DOWN;
    case kGlobalMouseTriggerForward:
      return RI_MOUSE_BUTTON_5_DOWN;
    default:
      return 0;
  }
}

// 这一下侧键是不是按在 Fushi 自己的窗口上？
//
// 是的话就**不**触发全局查词。理由不是"避免打扰"，是消除一整类双触发：本进程的
// 窗口各自已经有自己的鼠标路径——gal hook 台词浮窗有它自己的侧键查词
// （floating_lyric_window.cpp 的 lookup_trigger_ == 2，走它自己的 WndProc），
// 主窗有 Flutter 侧的 mouse binding 派发，查词卡有低级钩子的命中转发。不排除
// 的话，在台词浮窗的文字上按一次侧键会**同时**走浮窗查词和全局查词，出两张卡、
// 做两次词典 FFI 查询。
//
// 按进程而不是按窗口列表判断，是为了不给每个新窗口类型打一次补丁——「这是
// Fushi 自己的 UI，Fushi 自己会处理」是一条完整的规则，而本功能名字就叫
// app-external lookup（globalExternal），语义上本来就只服务"别的程序"。
//
// 用 GetCursorPos 而不是 raw input 的坐标：raw mouse 报的是相对位移
// （MOUSE_MOVE_ABSOLUTE 只在平板/远程桌面等少数设备上出现），拿不到屏幕点；
// 而按下这一刻光标就在那儿，误差可忽略。
bool PointIsOwnedByThisProcess() {
  POINT pt{};
  if (!GetCursorPos(&pt)) {
    // 拿不到光标位置就当作"不属于本进程"——宁可多触发一次查词，也不要让功能
    // 在某些远程/受限会话下静默失效。
    return false;
  }
  const HWND under = WindowFromPoint(pt);
  if (under == nullptr) {
    return false;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(under, &pid);
  return pid == GetCurrentProcessId();
}

}  // namespace

bool SetGlobalMouseTrigger(HWND host, int dom_button) {
  const USHORT flag = DownFlagForDomButton(dom_button);

  if (flag == 0) {
    // 注销。已经是未注册状态就直接返回成功（幂等）——RIDEV_REMOVE 在没有注册过
    // 的情况下会失败，那不是错误。
    if (g_dom_button.load() == kGlobalMouseTriggerNone) {
      return true;
    }
    RAWINPUTDEVICE rid{};
    rid.usUsagePage = 0x01;  // Generic Desktop Controls
    rid.usUsage = 0x02;      // Mouse
    rid.dwFlags = RIDEV_REMOVE;
    // RIDEV_REMOVE 要求 hwndTarget 必须为 NULL，否则调用失败。
    rid.hwndTarget = nullptr;
    const bool ok =
        RegisterRawInputDevices(&rid, 1, sizeof(RAWINPUTDEVICE)) != FALSE;
    g_dom_button.store(kGlobalMouseTriggerNone);
    return ok;
  }

  if (host == nullptr) {
    return false;
  }
  // 重复注册同一按钮：仍然重新 Register 一次（宿主 HWND 可能变了），但这是
  // 幂等操作——同一 usage 再注册会覆盖上一次的登记，不会叠加。
  RAWINPUTDEVICE rid{};
  rid.usUsagePage = 0x01;
  rid.usUsage = 0x02;
  // INPUTSINK = 即使 host 不在前台也投递 WM_INPUT。这正是"用户在别的程序里按
  // 侧键"能被收到的原因，也是本功能存在的前提。
  rid.dwFlags = RIDEV_INPUTSINK;
  rid.hwndTarget = host;
  if (!RegisterRawInputDevices(&rid, 1, sizeof(RAWINPUTDEVICE))) {
    return false;
  }
  g_dom_button.store(dom_button);
  return true;
}

bool HandleGlobalMouseTriggerRawInput(LPARAM lparam) {
  const int dom_button = g_dom_button.load();
  if (dom_button == kGlobalMouseTriggerNone) {
    return false;
  }
  const USHORT want = DownFlagForDomButton(dom_button);
  if (want == 0) {
    return false;
  }

  // 鼠标 RAWINPUT 是固定大小，可以直接栈上接。注册的 usage 只有 Mouse，所以
  // 这里不会收到变长的 HID/键盘包。
  RAWINPUT raw{};
  UINT size = sizeof(raw);
  const UINT read =
      GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, &raw,
                      &size, sizeof(RAWINPUTHEADER));
  if (read == static_cast<UINT>(-1) || raw.header.dwType != RIM_TYPEMOUSE) {
    return false;
  }
  // 绝大多数 WM_INPUT 是移动事件，usButtonFlags 为 0 —— 这一行就是热路径的出口。
  if ((raw.data.mouse.usButtonFlags & want) == 0) {
    return false;
  }
  if (PointIsOwnedByThisProcess()) {
    return false;
  }
  return true;
}

}  // namespace fushi

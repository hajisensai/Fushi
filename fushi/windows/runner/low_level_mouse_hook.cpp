#include "low_level_mouse_hook.h"

#include "../../../native/galgame_hook/include/voice_hook_ipc.h"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

namespace fushi {

namespace {

// 钩子线程私有的控制消息（PostThreadMessage）。
constexpr UINT kThreadArm = WM_APP + 0x60;
constexpr UINT kThreadDisarm = WM_APP + 0x61;
constexpr UINT kThreadBarrier = WM_APP + 0x62;

// BUG-1077 — Disarm 的宽限期（毫秒）。嵌套查词的 reset(Hide) → RevealStack 间隔
// 只有百毫秒级，立卸立装等于每次嵌套做两次全局钩子表变更（桌面级钩子链更新要与
// Raw Input 线程串行，本身就是一次全系统输入短暂停顿）。宽限期内 g_target 已清空、
// 回调纯放行，语义与已卸载等价；超过宽限期仍无新 Arm 才真正 UnhookWindowsHookEx，
// 维持「不查词不留全局钩子」的承诺。
constexpr UINT kDisarmGraceMs = 3000;
constexpr DWORD kArmAckTimeoutMs = 2000;

// BUG-1286 — 钩子存活性核对间隔（毫秒）。
//
// WH_MOUSE_LL 不是「装上就永远有效」的资源：回调若超过 HKCU\Control Panel\Desktop
// 的 LowLevelHooksTimeout（默认 300ms）没返回，**系统会直接把这个钩子从链上摘掉**，
// 既不通知也不让 HHOOK 失效。旧实现只在 Arm 时装一次，之后 `hook != nullptr` 永远为
// 真，于是被摘掉之后再也不会重装——查词卡从此收不到任何点击，而台词照常更新（那条路
// 走 IPC→ExecuteScript，与钩子无关），表现成「浮窗看得见、点不动，只能重启」。玩 gal
// 时进程内同时有词典 FFI、WebView2 COM、语音捕获与转码在抢核，超时是现实会发生的。
constexpr UINT kLivenessIntervalMs = 1000;
// A synchronous direct reveal may reuse the hook during the 3s disarm grace.
// A recent callback proves that handle is still in the chain. If callbacks have
// been silent for two liveness periods, refresh the handle before acknowledging
// the reveal instead of trusting the non-null HHOOK value (Windows can silently
// remove a timed-out low-level hook without invalidating that value).
constexpr ULONGLONG kSynchronousArmFreshnessMs =
    static_cast<ULONGLONG>(kLivenessIntervalMs) * 2;

// 钩子线程与调用线程共享的唯一可变状态：目标窗口。回调只读它，故用 atomic 而不是锁——
// 钩子回调必须尽快返回，任何可能阻塞（锁竞争、堆分配）的东西都不该出现在这条路径上。
std::atomic<HWND> g_target{nullptr};

// BUG-1882 — direct galCard 的消费范围绑定在专用目标 HWND 上，而不是再放一个
// 独立 relaxed atomic。修改属性前 ArmAndWait 会先清 g_target，再等钩子线程 ack
//（它也是 callback barrier）；因此已取旧 target 的回调必已退出，之后的新回调只会
// 看到 null，直到属性和 target 按此顺序发布。
constexpr wchar_t kConsumeOutsideOwnerProperty[] =
    L"Fushi.LowLevelMouseHook.ConsumeOutsideOwner";

constexpr uint32_t kSwallowedLeftButton = 1u << 0;
constexpr uint32_t kSwallowedRightButton = 1u << 1;
constexpr uint32_t kSwallowedMiddleButton = 1u << 2;
constexpr uint32_t kSwallowedX1Button = 1u << 3;
constexpr uint32_t kSwallowedX2Button = 1u << 4;

// 吞掉 down 后，窗口线程会异步 Hide -> Disarm，而 up 往往在那之后才到。
// 所以这份事务状态不能随 g_target 立即清空；回调必须先收掉配对 up，再看
// target 是否还在。只有宽限期后真正卸钩才清理残留位。
std::atomic<uint32_t> g_swallowed_buttons{0};

// SGRE helper ready 时，game HWND 的 Window property 指向当前 direct popup。
// 与 g_swallowed_buttons 分开：卡片内部点击要继续交给 WebView2，但 DirectInput
// 同样必须看不见它；若这次点击恰好关闭卡片，也要把 publication 留到真实 up。
std::atomic<HWND> g_direct_input_shield_game{nullptr};
std::atomic<HWND> g_direct_input_shield_popup{nullptr};
std::atomic<uint32_t> g_direct_input_shield_buttons{0};

// BUG-1286 — 回调最近一次被调用的时刻。存活性判据的一半（另一半是光标是否移动过）。
// 只在回调里写、只在钩子线程的定时器里读，relaxed 足够：判据比较的是「有没有变化」，
// 不依赖它与其他内存的顺序关系。
std::atomic<ULONGLONG> g_callback_tick{0};

std::mutex g_thread_mutex;
// 只串行 Arm/Disarm 的发布与 direct cold-arm ack；钩子回调绝不碰这把锁。
std::mutex g_binding_mutex;
std::atomic<DWORD> g_thread_id{0};
// 线程 id 发布完成的信号（进程生命周期常驻，不关闭）。
HANDLE g_thread_ready = nullptr;
// direct galCard 上屏前的安装确认。generation 防止一个陈旧 kThreadArm 的 SetEvent
// 被误认成当前请求；事件只负责唤醒，generation 才是完成真值。
std::atomic<uint32_t> g_arm_requested_generation{0};
std::atomic<uint32_t> g_arm_applied_generation{0};
std::atomic<bool> g_hook_active{false};
HANDLE g_arm_applied_event = nullptr;

uint32_t ButtonBitForMessage(WPARAM message, DWORD mouse_data) {
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONUP:
      return kSwallowedLeftButton;
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_NCRBUTTONDOWN:
    case WM_NCRBUTTONUP:
      return kSwallowedRightButton;
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_NCMBUTTONDOWN:
    case WM_NCMBUTTONUP:
      return kSwallowedMiddleButton;
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
    case WM_NCXBUTTONDOWN:
    case WM_NCXBUTTONUP:
      if (HIWORD(mouse_data) == XBUTTON1) return kSwallowedX1Button;
      if (HIWORD(mouse_data) == XBUTTON2) return kSwallowedX2Button;
      return 0;
    default:
      return 0;
  }
}

bool IsButtonDownMessage(WPARAM message) {
  return message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN ||
         message == WM_MBUTTONDOWN || message == WM_XBUTTONDOWN ||
         message == WM_NCLBUTTONDOWN || message == WM_NCRBUTTONDOWN ||
         message == WM_NCMBUTTONDOWN || message == WM_NCXBUTTONDOWN;
}

bool IsButtonUpMessage(WPARAM message) {
  return message == WM_LBUTTONUP || message == WM_RBUTTONUP ||
         message == WM_MBUTTONUP || message == WM_XBUTTONUP ||
         message == WM_NCLBUTTONUP || message == WM_NCRBUTTONUP ||
         message == WM_NCMBUTTONUP || message == WM_NCXBUTTONUP;
}

uint32_t ReconcileSwallowedButtonsWithPhysicalState() {
  const uint32_t swallowed =
      g_swallowed_buttons.load(std::memory_order_relaxed);
  uint32_t still_held = 0;
  if ((swallowed & kSwallowedLeftButton) != 0 &&
      (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedLeftButton;
  }
  if ((swallowed & kSwallowedRightButton) != 0 &&
      (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedRightButton;
  }
  if ((swallowed & kSwallowedMiddleButton) != 0 &&
      (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedMiddleButton;
  }
  if ((swallowed & kSwallowedX1Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0) {
    still_held |= kSwallowedX1Button;
  }
  if ((swallowed & kSwallowedX2Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0) {
    still_held |= kSwallowedX2Button;
  }
  // A device switch can lose the up callback. Drop only bits whose physical
  // button is already up; a real long hold must keep its paired-up transaction.
  g_swallowed_buttons.fetch_and(still_held, std::memory_order_relaxed);
  return still_held;
}

uint32_t PhysicalButtonsStillHeld(uint32_t buttons) {
  uint32_t still_held = 0;
  if ((buttons & kSwallowedLeftButton) != 0 &&
      (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedLeftButton;
  }
  if ((buttons & kSwallowedRightButton) != 0 &&
      (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedRightButton;
  }
  if ((buttons & kSwallowedMiddleButton) != 0 &&
      (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedMiddleButton;
  }
  if ((buttons & kSwallowedX1Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0) {
    still_held |= kSwallowedX1Button;
  }
  if ((buttons & kSwallowedX2Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0) {
    still_held |= kSwallowedX2Button;
  }
  return still_held;
}

void RequestDirectInputShieldFinalize() {
  const HWND popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  // A matching up from an older click must not revoke a newly revealed card
  // that reuses the same HWND.  Conversely, an unrelated desktop/global lookup
  // target must not keep the hidden gal publication alive forever.
  if (popup != nullptr && IsWindow(popup) &&
      g_target.load(std::memory_order_acquire) != popup) {
    PostMessage(popup, kLowLevelMouseShieldReleaseMessage, 0, 0);
  }
}

uint32_t ReconcileDirectInputShieldButtonsWithPhysicalState() {
  const uint32_t shield_buttons =
      g_direct_input_shield_buttons.load(std::memory_order_relaxed);
  const uint32_t still_held = PhysicalButtonsStillHeld(shield_buttons);
  g_direct_input_shield_buttons.fetch_and(still_held,
                                           std::memory_order_relaxed);
  if (still_held == 0 && shield_buttons != 0) {
    RequestDirectInputShieldFinalize();
  }
  return still_held;
}

bool IsSgreDirectInputShieldContractReady(HWND game) {
  return reinterpret_cast<uintptr_t>(GetPropW(
             game,
             fushi_voice_hook::kSgreDirectInputShieldRequiredProperty)) ==
             fushi_voice_hook::kSgreDirectInputShieldRequiredValue &&
         reinterpret_cast<uintptr_t>(GetPropW(
             game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty)) ==
             fushi_voice_hook::kSgreDirectInputShieldReadyValue;
}

bool PublishDirectInputShieldIfReady(HWND popup, HWND game) {
  const uintptr_t required = reinterpret_cast<uintptr_t>(GetPropW(
      game, fushi_voice_hook::kSgreDirectInputShieldRequiredProperty));
  if (required != fushi_voice_hook::kSgreDirectInputShieldRequiredValue) {
    return true;  // Other engines retain the existing WH_MOUSE_LL-only path.
  }
  const uintptr_t ready = reinterpret_cast<uintptr_t>(GetPropW(
      game, fushi_voice_hook::kSgreDirectInputShieldReadyProperty));
  if (ready != fushi_voice_hook::kSgreDirectInputShieldReadyValue) {
    // Exact SGRE declared DirectInput protection mandatory, but its detour is
    // not ready. Fail closed instead of silently falling back to the HHOOK-only
    // route already disproved on the real game.
    return false;
  }
  const uint32_t pending =
      g_direct_input_shield_buttons.load(std::memory_order_acquire);
  const HWND previous_game =
      g_direct_input_shield_game.load(std::memory_order_acquire);
  const HWND previous_popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  if (pending != 0 &&
      (previous_game != game || previous_popup != popup)) {
    return false;
  }
  // Cross-process SetProp can be denied by UIPI (normal Fushi -> elevated
  // game). Fail closed before the popup is shown; HHOOK alone is known not to
  // suppress SGRE's DirectInput immediate state.
  if (!SetPropW(game,
                fushi_voice_hook::kSgreDirectInputShieldWindowProperty,
                reinterpret_cast<HANDLE>(popup))) {
    return false;
  }
  // Close the Ready -> Window TOCTOU with the helper's health worker: it may
  // revoke the contract between our first Ready read and SetProp.  Re-read both
  // commit properties and our exact Window value before exposing the popup.
  // The injected side, in turn, defers routine main-window migration while this
  // live publication exists.
  if (!IsSgreDirectInputShieldContractReady(game) ||
      reinterpret_cast<HWND>(GetPropW(
          game, fushi_voice_hook::kSgreDirectInputShieldWindowProperty)) !=
          popup) {
    if (reinterpret_cast<HWND>(GetPropW(
            game, fushi_voice_hook::kSgreDirectInputShieldWindowProperty)) ==
        popup) {
      RemovePropW(game,
                  fushi_voice_hook::kSgreDirectInputShieldWindowProperty);
    }
    return false;
  }
  g_direct_input_shield_game.store(game, std::memory_order_release);
  g_direct_input_shield_popup.store(popup, std::memory_order_release);
  return true;
}

void RevokeDirectInputShieldIfIdle(HWND expected_popup) {
  const HWND popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  const HWND game =
      g_direct_input_shield_game.load(std::memory_order_acquire);
  if (popup == nullptr || game == nullptr || popup != expected_popup) return;
  if (g_target.load(std::memory_order_acquire) == popup ||
      g_direct_input_shield_buttons.load(std::memory_order_acquire) != 0) {
    return;
  }
  if (IsWindow(game) &&
      reinterpret_cast<HWND>(GetPropW(
          game, fushi_voice_hook::kSgreDirectInputShieldWindowProperty)) ==
          popup) {
    RemovePropW(game,
                fushi_voice_hook::kSgreDirectInputShieldWindowProperty);
  }
  g_direct_input_shield_popup.store(nullptr, std::memory_order_release);
  g_direct_input_shield_game.store(nullptr, std::memory_order_release);
}

bool PointInWindowClient(HWND window, POINT point) {
  if (window == nullptr || !IsWindow(window) || IsIconic(window)) return false;
  RECT client{};
  POINT top_left{};
  POINT bottom_right{};
  if (!GetClientRect(window, &client)) return false;
  top_left.x = client.left;
  top_left.y = client.top;
  bottom_right.x = client.right;
  bottom_right.y = client.bottom;
  if (!ClientToScreen(window, &top_left) ||
      !ClientToScreen(window, &bottom_right)) {
    return false;
  }
  const RECT screen_client{top_left.x, top_left.y, bottom_right.x,
                           bottom_right.y};
  return PtInRect(&screen_client, point) != FALSE;
}

bool ShouldConsumeGameClientClick(HWND target, HWND game, POINT point) {
  if (game == nullptr || !IsWindow(game) || !PointInWindowClient(game, point)) {
    return false;
  }

  // WindowFromPoint 认 SetWindowRgn/子窗：查词栈的 bbox 中间可能有透明缝隙，
  // 只用 GetWindowRect 会把缝隙错当成卡内。真正命中 popup 时必须放行，交给
  // WebView2 处理按钮/嵌套查词。
  const HWND hit = WindowFromPoint(point);
  if (hit == target || (hit != nullptr && IsChild(target, hit))) return false;
  if (hit == nullptr) return false;

  // 只吞绑定的这一个游戏 HWND（或它的渲染子窗）。不能只比 PID：同进程的
  // 启动器/设置窗可能刚好盖在游戏坐标上，用户点它时必须正常收到点击。
  const bool hit_game = hit == game || IsChild(game, hit);
  if (!hit_game) return false;

  // 查词窗是 NOACTIVATE，正常情况下前台仍是 game。再锁一次前台可避免游戏
  // 已经失焦、别的窗口正接管输入时吞掉一次用于切回游戏的点击。
  return GetForegroundWindow() == game;
}

LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam) {
  // BUG-1286 — 存活证据必须记在最前面：**移动事件**才是每秒都有的那类，用它证明
  // 钩子还在链上；记在过滤分支之后就只剩点击/滚轮能刷新，判据立刻失效。
  // GetTickCount64 是读共享页的纯计算，没有系统调用开销。
  g_callback_tick.store(GetTickCount64(), std::memory_order_relaxed);
  // 只关心「按键」和「滚轮」：移动直接放行（这条分支每秒会跑上千次，在任何系统
  // 调用之前必须先被纯比较挡掉）。BUG-1882 需要看 up，但 up 仍只是
  // 按键频率，不会把系统调用放进高频 move 路径。
  const bool is_button_down = IsButtonDownMessage(wparam);
  const bool is_button_up = IsButtonUpMessage(wparam);
  const bool is_wheel =
      (wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL);
  if (code < 0 || (!is_button_down && !is_button_up && !is_wheel)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const MSLLHOOKSTRUCT* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
  const uint32_t button_bit =
      (is_button_down || is_button_up)
          ? ButtonBitForMessage(wparam, info->mouseData)
          : 0;

  // 这道闸故意在 g_target 之前。外部 down 被吞后，PostMessage 会让窗口线程
  // 立刻 Hide/Disarm；配对 up 到来时 target 通常已空，若先看 target 就会漏半个
  // 点击给那些在 button-up 推进的游戏。
  if (is_button_up) {
    const uint32_t bit = button_bit;
    if (bit != 0) {
      const uint32_t previous = g_direct_input_shield_buttons.fetch_and(
          ~bit, std::memory_order_relaxed);
      if ((previous & bit) != 0 && (previous & ~bit) == 0) {
        RequestDirectInputShieldFinalize();
      }
    }
    if (bit != 0 &&
        (g_swallowed_buttons.fetch_and(~bit, std::memory_order_relaxed) & bit) !=
            0) {
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  if (is_button_down) {
    const uint32_t bit = button_bit;
    if (bit != 0) {
      // A fresh down proves any older transaction for this same physical
      // button has already ended, even if its low-level up was lost (device
      // switch / hook replacement). Drop that stale bit before deciding the
      // new transaction; otherwise an inside-popup click can leave the bit set
      // and have its unrelated up swallowed seconds later.
      g_swallowed_buttons.fetch_and(~bit, std::memory_order_relaxed);
    }
  }
  const HWND target = g_target.load(std::memory_order_acquire);
  if (target == nullptr || !IsWindow(target)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  if (is_button_down) {
    RECT rc{};
    // GetWindowRect 是跨线程安全的只读查询；命中判定留在这里，是为了让窗口线程
    // 拿到的消息自带结论，不必在忙碌时再回头查几何。
    const BOOL inside = GetWindowRect(target, &rc) && PtInRect(&rc, info->pt);
    const HWND consume_owner = reinterpret_cast<HWND>(
        GetPropW(target, kConsumeOutsideOwnerProperty));
    const uint32_t bit = button_bit;
    const HWND shield_game =
        g_direct_input_shield_game.load(std::memory_order_acquire);
    const HWND shield_popup =
        g_direct_input_shield_popup.load(std::memory_order_acquire);
    if (bit != 0 && shield_game == consume_owner && shield_popup == target &&
        reinterpret_cast<HWND>(GetPropW(
            shield_game,
            fushi_voice_hook::kSgreDirectInputShieldWindowProperty)) ==
            target) {
      // Track both outside and popup-internal downs. WebView2 still receives an
      // internal click, while the injected DirectInput detour hides it from the
      // game and retains the publication if that click closes the popup.
      g_direct_input_shield_buttons.fetch_or(bit,
                                              std::memory_order_relaxed);
    }
    const bool consume_click =
        bit != 0 &&
        ShouldConsumeGameClientClick(target, consume_owner, info->pt);
    if (consume_click) {
      // Freeze the paired-up transaction BEFORE notifying the window thread.
      // That thread may process PostMessage immediately and Hide/Disarm, clearing
      // g_target before the physical up arrives.
      g_swallowed_buttons.fetch_or(bit, std::memory_order_relaxed);
    }
    PostMessage(target, kLowLevelMouseClickMessage,
                PackMouseHookPoint(info->pt.x, info->pt.y), inside ? 1 : 0);
    if (consume_click) {
      // 返回非 0 = 这次 down 不进入游戏的输入队列。窗口线程已经收到
      // 异步 dismiss 消息；这里绝不同步等它，否则又把 Flutter/WebView2 忙闲
      // 拽回全系统输入路径（BUG-1048）。
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  // BUG-1166 — 滚轮落在查词卡上：吞掉，改投给窗口线程。
  //
  // 命中判定**不能**用 GetWindowRect：级联查词的窗口是整叠卡片的包围盒，
  // TODO-1345 的「保留地板」窗更是横跨大半个工作区，真正可见的只有 ApplyRoundedRegion
  // 用 SetWindowRgn 裁出来的那几块卡片（BUG-749）。按 rect 判，等于卡片一开就把
  // 半个屏幕的滚轮全吞了——用户在游戏画面上滚也会被吃掉。
  // WindowFromPoint 认窗口区域，答的正是「光标此刻真的压在卡片上吗」；卡片之间的
  // 透明缝隙判为「不在」，滚轮照常归游戏，这也正是用户在那儿看到的东西。
  const HWND hit = WindowFromPoint(info->pt);
  if (hit == nullptr || (hit != target && !IsChild(target, hit))) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  MouseHookWheel wheel;
  wheel.delta = static_cast<short>(HIWORD(info->mouseData));
  wheel.horizontal = (wparam == WM_MOUSEHWHEEL);
  // 修饰键必须现取：MSLLHOOKSTRUCT 不带键状态，而钩子线程的 GetKeyState 是它自己
  // 那份从不更新的输入状态。GetAsyncKeyState 读的是物理按键，跨线程有效；只在滚轮
  // 事件上跑（每秒几十次量级），不会拖慢移动事件那条纯比较的快路。
  //
  // 这里取到的是**唯一可信的修饰键真值**：过了 PostMessage 那道边界就再也拿不回来
  // （Chromium 读 GetKeyState，而合成消息不更新键状态表）。ctrl/alt 因此单独成字段
  // 随载荷带走，供窗口线程分流；MK_* 位只是给裸滚轮那条原生快路捎带的。
  const bool ctrl_down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool alt_down = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  if (ctrl_down) wheel.keys |= MK_CONTROL;
  if (shift_down) wheel.keys |= MK_SHIFT;
  wheel.ctrl = ctrl_down;
  wheel.alt = alt_down;
  PostMessage(target, kLowLevelMouseWheelMessage,
              PackMouseHookPoint(info->pt.x, info->pt.y),
              PackMouseHookWheel(wheel));
  // 返回非 0 = 事件到此为止：不进入任何线程的输入队列，前台的 galgame 也就收不到
  // WM_MOUSEWHEEL。这是整个修复的落点，改成 CallNextHookEx 就等于没修。
  return 1;
}

void HookThreadMain() {
  // BUG-1077 — WH_MOUSE_LL 是同步钩子：系统等这条线程被调度并返回才把输入分发给
  // 前台程序。嵌套查词的瞬间，进程内同时有同步 FFI 词典查询、整栈 JSON 序列化、
  // WebView2 COM 与窗口区域重建在抢核；NORMAL 优先级的钩子线程被抢占几十毫秒，
  // 全系统鼠标就跟着卡一下。TIME_CRITICAL 是 LL 钩子承载线程的标准做法——回调
  // 每个事件只做两次整数比较，高优先级不会饿着任何人。
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  // 线程必须有消息队列钩子事件才会被投递过来；PeekMessage 强制系统建队列，之后
  // Arm/Disarm 的 PostThreadMessage 才不会丢。
  MSG msg{};
  PeekMessage(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_thread_id.store(GetCurrentThreadId(), std::memory_order_release);
  SetEvent(g_thread_ready);

  HHOOK hook = nullptr;
  // 宽限期卸载定时器（线程定时器，WM_TIMER 走本线程消息队列）。0 = 未挂起。
  UINT_PTR disarm_timer = 0;
  // BUG-1286 — 存活性核对定时器：常驻，不随 Arm/Disarm 起停。armed 状态的真值是
  // g_target，Arm/Disarm 消息只是「立刻生效」的快路径；让这只定时器周期性地把实际
  // 钩子状态收敛到 g_target，SetWindowsHookEx 失败、PostThreadMessage 丢失、系统
  // 摘钩这三类静默失败就都只是「下一拍自动补上」，不再各需一套特例分支。
  UINT_PTR liveness_timer = SetTimer(nullptr, 0, kLivenessIntervalMs, nullptr);
  POINT last_cursor{};
  GetCursorPos(&last_cursor);
  ULONGLONG last_seen_tick = g_callback_tick.load(std::memory_order_relaxed);
  while (GetMessage(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == kThreadArm) {
      const uint32_t ack_generation = static_cast<uint32_t>(msg.wParam);
      // A re-arm normally cancels deferred unload. The exception is a swallowed
      // down still waiting for up: that timer also reconciles a device-switch
      // lost-up against physical button state, so cancelling it would leave a
      // stale bit that later eats an unrelated up in the new popup.
      // Do NOT reconcile against GetAsyncKeyState here. The physical button may
      // already read as up while its WH_MOUSE_LL up callback is still queued on
      // this same thread; clearing now would let that queued up reach the game.
      // Keep/schedule the timer and reconcile only after the 3s grace.
      const bool has_pending_button =
          g_swallowed_buttons.load(std::memory_order_relaxed) != 0 ||
          g_direct_input_shield_buttons.load(std::memory_order_relaxed) != 0;
      if (disarm_timer != 0 && !has_pending_button) {
        KillTimer(nullptr, disarm_timer);
        disarm_timer = 0;
      } else if (disarm_timer == 0 && has_pending_button) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
      }
      if (ack_generation != 0 && hook != nullptr && !has_pending_button) {
        const ULONGLONG callback_tick =
            g_callback_tick.load(std::memory_order_relaxed);
        const ULONGLONG now = GetTickCount64();
        if (callback_tick == 0 ||
            now - callback_tick > kSynchronousArmFreshnessMs) {
          UnhookWindowsHookEx(hook);
          hook = nullptr;
          g_hook_active.store(false, std::memory_order_release);
        }
      }
      if (hook == nullptr) {
        hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                GetModuleHandle(nullptr), 0);
      }
      g_hook_active.store(hook != nullptr, std::memory_order_release);
      if (ack_generation != 0 && g_arm_applied_event != nullptr) {
        g_arm_applied_generation.store(ack_generation,
                                       std::memory_order_release);
        SetEvent(g_arm_applied_event);
      }
    } else if (msg.message == WM_TIMER && liveness_timer != 0 &&
               msg.wParam == liveness_timer) {
      POINT cursor{};
      const BOOL got_cursor = GetCursorPos(&cursor);
      const ULONGLONG seen_tick =
          g_callback_tick.load(std::memory_order_relaxed);
      if (g_target.load(std::memory_order_relaxed) != nullptr) {
        if (hook == nullptr) {
          // armed 但没有钩子：Arm 那次 SetWindowsHookEx 失败，或 kThreadArm 根本没
          // 送达（PostThreadMessage 会失败，旧实现没检查返回值）。补装。
          hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                  GetModuleHandle(nullptr), 0);
          g_hook_active.store(hook != nullptr, std::memory_order_release);
        } else if (got_cursor &&
                   (cursor.x != last_cursor.x || cursor.y != last_cursor.y) &&
                   seen_tick == last_seen_tick) {
          // 判据零误报：光标位置变了，说明这一秒里系统一定投递过 WM_MOUSEMOVE；
          // 而我们的回调一次都没跑，那它只可能已经不在钩子链上了（被系统摘掉，或被
          // 链上更靠前的钩子吞掉——后者重装排到链首同样是正解）。
          // 反向不成立的那半（光标没动 → 本就无事件）已被 cursor 比较排除，因此
          // 「用户只是没动鼠标」永远不会触发重装。
          UnhookWindowsHookEx(hook);
          hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                  GetModuleHandle(nullptr), 0);
          g_hook_active.store(hook != nullptr, std::memory_order_release);
        }
      }
      if (got_cursor) {
        last_cursor = cursor;
      }
      last_seen_tick = seen_tick;
    } else if (msg.message == kThreadDisarm) {
      // g_target 已由 Disarm 侧清空（回调此刻起纯放行）；这里只安排宽限期后的
      // 真正卸载。已有挂起定时器就沿用原先的到期时间。
      if (hook != nullptr && disarm_timer == 0) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
      }
    } else if (msg.message == kThreadBarrier) {
      // PostThreadMessage is serialized with HookProc on this installing
      // thread.  Reaching this message proves every callback that could have
      // snapshotted the previous direct HWND has returned.
      const uint32_t generation = static_cast<uint32_t>(msg.wParam);
      if (generation != 0 && g_arm_applied_event != nullptr) {
        g_arm_applied_generation.store(generation,
                                       std::memory_order_release);
        SetEvent(g_arm_applied_event);
      }
      const HWND finalize_target = reinterpret_cast<HWND>(msg.lParam);
      if (finalize_target != nullptr && IsWindow(finalize_target)) {
        // Also queue the UI-thread finalizer after the barrier.  Normally the
        // waiting Disarm path has already revoked synchronously; if that wait
        // timed out, this delayed message prevents a hidden live HWND from
        // retaining the game property indefinitely.
        PostMessage(finalize_target, kLowLevelMouseShieldReleaseMessage, 0, 0);
      }
    } else if (msg.message == WM_TIMER && disarm_timer != 0 &&
               msg.wParam == disarm_timer) {
      KillTimer(nullptr, disarm_timer);
      disarm_timer = 0;
      // 被吞的 down 可能被用户长按超过宽限期。此时绝不能卸钩：窗口早已
      // Hide/Disarm，但游戏仍可能在稍后的 button-up 推进台词。保留钩子并
      // 重新排一次检查；up 会在 HookProc 的 g_target 闸门之前清掉对应位。
      const uint32_t still_held =
          ReconcileSwallowedButtonsWithPhysicalState();
      const uint32_t shield_still_held =
          ReconcileDirectInputShieldButtonsWithPhysicalState();
      if (still_held != 0 || shield_still_held != 0) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
        continue;
      }
      // 宽限期内没有新的 Arm（有的话定时器早被杀掉）——真正闲置，卸钩子。
      // 再核一次 g_target 防御 Arm 消息尚在队列里的窗口期。
      if (hook != nullptr &&
          g_target.load(std::memory_order_relaxed) == nullptr) {
        UnhookWindowsHookEx(hook);
        hook = nullptr;
        g_hook_active.store(false, std::memory_order_release);
        // 所有配对 up 都已收齐后才会走到这里。清零是防御式收尾，避免未来
        // 新增按钮位时遗漏某条释放路径。
        g_swallowed_buttons.store(0, std::memory_order_relaxed);
      }
    }
  }
  if (liveness_timer != 0) {
    KillTimer(nullptr, liveness_timer);
  }
  if (hook != nullptr) {
    UnhookWindowsHookEx(hook);
  }
  g_hook_active.store(false, std::memory_order_release);
}

// 返回钩子线程 id（必要时懒创建并等它把 id 发布出来）。0 表示创建失败。
DWORD EnsureHookThread() {
  const DWORD existing = g_thread_id.load(std::memory_order_acquire);
  if (existing != 0) return existing;
  std::lock_guard<std::mutex> guard(g_thread_mutex);
  const DWORD after_lock = g_thread_id.load(std::memory_order_acquire);
  if (after_lock != 0) return after_lock;
  // BUG-1077 — 等待 id 发布用事件而不是逐毫秒睡眠自旋：这里跑在 platform 线程上，
  // 毫秒级睡眠在默认定时器精度下单次可睡 ~15ms，首次查词会白白卡 UI。事件在线程
  // 建好消息队列、发布 id 之后立即置位，实测微秒级；2s 上限只防线程创建失败。
  if (g_thread_ready == nullptr) {
    g_thread_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_thread_ready == nullptr) return 0;
  }
  if (g_arm_applied_event == nullptr) {
    g_arm_applied_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_arm_applied_event == nullptr) return 0;
  }
  std::thread(&HookThreadMain).detach();
  if (WaitForSingleObject(g_thread_ready, 2000) != WAIT_OBJECT_0) {
    return 0;
  }
  return g_thread_id.load(std::memory_order_acquire);
}

bool WaitForHookThreadBarrier(DWORD thread_id, HWND finalize_target) {
  if (thread_id == 0 || g_arm_applied_event == nullptr) return false;
  ResetEvent(g_arm_applied_event);
  const uint32_t generation =
      g_arm_requested_generation.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (!PostThreadMessage(thread_id, kThreadBarrier, generation,
                         reinterpret_cast<LPARAM>(finalize_target))) {
    return false;
  }
  const ULONGLONG deadline = GetTickCount64() + kArmAckTimeoutMs;
  while (g_arm_applied_generation.load(std::memory_order_acquire) !=
         generation) {
    ResetEvent(g_arm_applied_event);
    if (g_arm_applied_generation.load(std::memory_order_acquire) == generation) {
      break;
    }
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) return false;
    if (WaitForSingleObject(g_arm_applied_event,
                            static_cast<DWORD>(deadline - now)) !=
        WAIT_OBJECT_0) {
      return false;
    }
  }
  return true;
}

}  // namespace

WPARAM PackMouseHookPoint(int x, int y) {
  return (static_cast<WPARAM>(static_cast<uint32_t>(x)) << 32) |
         static_cast<WPARAM>(static_cast<uint32_t>(y));
}

POINT UnpackMouseHookPoint(WPARAM wparam) {
  POINT pt{};
  pt.x = static_cast<LONG>(static_cast<int32_t>(
      static_cast<uint32_t>((wparam >> 32) & 0xFFFFFFFFull)));
  pt.y = static_cast<LONG>(
      static_cast<int32_t>(static_cast<uint32_t>(wparam & 0xFFFFFFFFull)));
  return pt;
}

// 滚轮载荷位布局（LPARAM 在 x64 下 64 位）：
//   [15:0]  MK_* 修饰键位（仅供原生快路）
//   [31:16] 有符号 delta
//   [32]    水平滚轮标志
//   [33]    物理 Ctrl（分流判据）
//   [34]    物理 Alt（分流判据；WM_MOUSEWHEEL 没有 MK_ALT，只能走这里）
LPARAM PackMouseHookWheel(const MouseHookWheel& wheel) {
  return static_cast<LPARAM>(
      (static_cast<uint64_t>(wheel.alt ? 1u : 0u) << 34) |
      (static_cast<uint64_t>(wheel.ctrl ? 1u : 0u) << 33) |
      (static_cast<uint64_t>(wheel.horizontal ? 1u : 0u) << 32) |
      (static_cast<uint64_t>(static_cast<uint16_t>(
           static_cast<int16_t>(wheel.delta)))
       << 16) |
      static_cast<uint64_t>(wheel.keys & 0xFFFFu));
}

MouseHookWheel UnpackMouseHookWheel(LPARAM lparam) {
  const auto raw = static_cast<uint64_t>(lparam);
  MouseHookWheel wheel;
  wheel.keys = static_cast<UINT>(raw & 0xFFFFull);
  wheel.delta =
      static_cast<int>(static_cast<int16_t>((raw >> 16) & 0xFFFFull));
  wheel.horizontal = ((raw >> 32) & 0x1ull) != 0;
  wheel.ctrl = ((raw >> 33) & 0x1ull) != 0;
  wheel.alt = ((raw >> 34) & 0x1ull) != 0;
  return wheel;
}

void ArmLowLevelMouseHook(HWND target) {
  if (target == nullptr) {
    return;
  }
  const DWORD thread_id = EnsureHookThread();
  if (thread_id == 0) return;
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  // Desktop/global lookup owns a different GlobalLookupWindow instance from the
  // dedicated gal card, so this HWND never receives the consume-owner property.
  // Do not mutate properties here: async Arm has no callback barrier.
  g_target.store(target, std::memory_order_release);
  PostThreadMessage(thread_id, kThreadArm, 0, 0);
}

bool ArmLowLevelMouseHookAndWait(HWND target, HWND consume_outside_owner) {
  if (target == nullptr || consume_outside_owner == nullptr) return false;
  const DWORD thread_id = EnsureHookThread();
  if (thread_id == 0 || g_arm_applied_event == nullptr) return false;

  std::lock_guard<std::mutex> guard(g_binding_mutex);
  // Keep the already-created off-screen renderer non-consuming while the hook
  // thread installs/acknowledges HHOOK. Only after that succeeds do we publish
  // the direct target; Reveal moves it on-screen immediately after this returns.
  g_target.store(nullptr, std::memory_order_release);

  ResetEvent(g_arm_applied_event);
  const uint32_t generation =
      g_arm_requested_generation.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (!PostThreadMessage(thread_id, kThreadArm, generation, 0)) return false;

  const ULONGLONG deadline = GetTickCount64() + kArmAckTimeoutMs;
  while (g_arm_applied_generation.load(std::memory_order_acquire) !=
         generation) {
    ResetEvent(g_arm_applied_event);
    if (g_arm_applied_generation.load(std::memory_order_acquire) == generation) {
      break;
    }
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) return false;
    const DWORD remaining = static_cast<DWORD>(deadline - now);
    if (WaitForSingleObject(g_arm_applied_event, remaining) != WAIT_OBJECT_0) {
      return false;
    }
  }
  if (!g_hook_active.load(std::memory_order_acquire)) return false;
  // The ack is also a hook-thread barrier: every callback that could have read
  // the old target has completed, while newer callbacks see target == nullptr.
  // It is now safe to replace this dedicated HWND's game binding.
  if (!SetPropW(target, kConsumeOutsideOwnerProperty,
                 reinterpret_cast<HANDLE>(consume_outside_owner))) {
    return false;
  }
  if (!PublishDirectInputShieldIfReady(target, consume_outside_owner)) {
    return false;
  }
  g_target.store(target, std::memory_order_release);
  return true;
}

void FinalizeLowLevelMouseDirectInputShield(HWND target) {
  if (target == nullptr) return;
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  RevokeDirectInputShieldIfIdle(target);
}

void DisarmLowLevelMouseHook(HWND expected_target) {
  if (expected_target == nullptr) return;
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  const HWND current = g_target.load(std::memory_order_acquire);
  const bool owns_binding = current == expected_target;
  const bool clean_uncommitted_arm = current == nullptr;
  if (owns_binding) {
    g_target.store(nullptr, std::memory_order_release);
  }
  const DWORD thread_id = g_thread_id.load(std::memory_order_acquire);
  const bool owns_direct_publication =
      g_direct_input_shield_popup.load(std::memory_order_acquire) ==
      expected_target;
  // A callback can snapshot target immediately before the exchange above and
  // set the held-button bit after the UI thread reaches this function.  Do not
  // remove the cross-process property until the installing thread has crossed
  // a callback barrier.  If the synchronous wait times out, the queued barrier
  // itself posts a delayed popup-thread finalizer once it is eventually crossed.
  const bool callbacks_drained =
      !owns_direct_publication ||
      WaitForHookThreadBarrier(thread_id, expected_target);
  if (callbacks_drained) {
    RevokeDirectInputShieldIfIdle(expected_target);
  }
  if ((owns_binding || clean_uncommitted_arm) && thread_id != 0) {
    PostThreadMessage(thread_id, kThreadDisarm, 0, 0);
  }
}

}  // namespace fushi

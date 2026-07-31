#include "low_level_mouse_hook.h"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

namespace hibiki {

namespace {

// 钩子线程私有的控制消息（PostThreadMessage）。
constexpr UINT kThreadArm = WM_APP + 0x60;
constexpr UINT kThreadDisarm = WM_APP + 0x61;

// BUG-1077 — Disarm 的宽限期（毫秒）。嵌套查词的 reset(Hide) → RevealStack 间隔
// 只有百毫秒级，立卸立装等于每次嵌套做两次全局钩子表变更（桌面级钩子链更新要与
// Raw Input 线程串行，本身就是一次全系统输入短暂停顿）。宽限期内 g_target 已清空、
// 回调纯放行，语义与已卸载等价；超过宽限期仍无新 Arm 才真正 UnhookWindowsHookEx，
// 维持「不查词不留全局钩子」的承诺。
constexpr UINT kDisarmGraceMs = 3000;

// BUG-1286 — 钩子存活性核对间隔（毫秒）。
//
// WH_MOUSE_LL 不是「装上就永远有效」的资源：回调若超过 HKCU\Control Panel\Desktop
// 的 LowLevelHooksTimeout（默认 300ms）没返回，**系统会直接把这个钩子从链上摘掉**，
// 既不通知也不让 HHOOK 失效。旧实现只在 Arm 时装一次，之后 `hook != nullptr` 永远为
// 真，于是被摘掉之后再也不会重装——查词卡从此收不到任何点击，而台词照常更新（那条路
// 走 IPC→ExecuteScript，与钩子无关），表现成「浮窗看得见、点不动，只能重启」。玩 gal
// 时进程内同时有词典 FFI、WebView2 COM、语音捕获与转码在抢核，超时是现实会发生的。
constexpr UINT kLivenessIntervalMs = 1000;

// 钩子线程与调用线程共享的唯一可变状态：目标窗口。回调只读它，故用 atomic 而不是锁——
// 钩子回调必须尽快返回，任何可能阻塞（锁竞争、堆分配）的东西都不该出现在这条路径上。
std::atomic<HWND> g_target{nullptr};

// BUG-1286 — 回调最近一次被调用的时刻。存活性判据的一半（另一半是光标是否移动过）。
// 只在回调里写、只在钩子线程的定时器里读，relaxed 足够：判据比较的是「有没有变化」，
// 不依赖它与其他内存的顺序关系。
std::atomic<ULONGLONG> g_callback_tick{0};

std::mutex g_thread_mutex;
std::atomic<DWORD> g_thread_id{0};
// 线程 id 发布完成的信号（进程生命周期常驻，不关闭）。
HANDLE g_thread_ready = nullptr;

LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam) {
  // BUG-1286 — 存活证据必须记在最前面：**移动事件**才是每秒都有的那类，用它证明
  // 钩子还在链上；记在过滤分支之后就只剩点击/滚轮能刷新，判据立刻失效。
  // GetTickCount64 是读共享页的纯计算，没有系统调用开销。
  g_callback_tick.store(GetTickCount64(), std::memory_order_relaxed);
  // 只关心「按下」和「滚轮」：移动直接放行（这条分支每秒会跑上千次，在任何系统
  // 调用之前必须先被纯比较挡掉）。
  const bool is_click =
      (wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
       wparam == WM_NCLBUTTONDOWN);
  const bool is_wheel =
      (wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL);
  if (code < 0 || (!is_click && !is_wheel)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const HWND target = g_target.load(std::memory_order_relaxed);
  if (target == nullptr || !IsWindow(target)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const MSLLHOOKSTRUCT* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
  if (is_click) {
    RECT rc{};
    // GetWindowRect 是跨线程安全的只读查询；命中判定留在这里，是为了让窗口线程
    // 拿到的消息自带结论，不必在忙碌时再回头查几何。
    const BOOL inside = GetWindowRect(target, &rc) && PtInRect(&rc, info->pt);
    PostMessage(target, kLowLevelMouseClickMessage,
                PackMouseHookPoint(info->pt.x, info->pt.y), inside ? 1 : 0);
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
      if (disarm_timer != 0) {
        KillTimer(nullptr, disarm_timer);
        disarm_timer = 0;
      }
      if (hook == nullptr) {
        hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                GetModuleHandle(nullptr), 0);
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
    } else if (msg.message == WM_TIMER && disarm_timer != 0 &&
               msg.wParam == disarm_timer) {
      KillTimer(nullptr, disarm_timer);
      disarm_timer = 0;
      // 宽限期内没有新的 Arm（有的话定时器早被杀掉）——真正闲置，卸钩子。
      // 再核一次 g_target 防御 Arm 消息尚在队列里的窗口期。
      if (hook != nullptr &&
          g_target.load(std::memory_order_relaxed) == nullptr) {
        UnhookWindowsHookEx(hook);
        hook = nullptr;
      }
    }
  }
  if (liveness_timer != 0) {
    KillTimer(nullptr, liveness_timer);
  }
  if (hook != nullptr) {
    UnhookWindowsHookEx(hook);
  }
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
  std::thread(&HookThreadMain).detach();
  if (WaitForSingleObject(g_thread_ready, 2000) != WAIT_OBJECT_0) {
    return 0;
  }
  return g_thread_id.load(std::memory_order_acquire);
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
    DisarmLowLevelMouseHook();
    return;
  }
  g_target.store(target, std::memory_order_relaxed);
  const DWORD thread_id = EnsureHookThread();
  if (thread_id != 0) {
    PostThreadMessage(thread_id, kThreadArm, 0, 0);
  }
}

void DisarmLowLevelMouseHook() {
  g_target.store(nullptr, std::memory_order_relaxed);
  const DWORD thread_id = g_thread_id.load(std::memory_order_acquire);
  if (thread_id != 0) {
    PostThreadMessage(thread_id, kThreadDisarm, 0, 0);
  }
}

}  // namespace hibiki

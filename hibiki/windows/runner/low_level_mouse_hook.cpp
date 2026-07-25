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

// 钩子线程与调用线程共享的唯一可变状态：目标窗口。回调只读它，故用 atomic 而不是锁——
// 钩子回调必须尽快返回，任何可能阻塞（锁竞争、堆分配）的东西都不该出现在这条路径上。
std::atomic<HWND> g_target{nullptr};

std::mutex g_thread_mutex;
std::atomic<DWORD> g_thread_id{0};
// 线程 id 发布完成的信号（进程生命周期常驻，不关闭）。
HANDLE g_thread_ready = nullptr;

LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam) {
  // 只关心「按下」：移动/滚轮直接放行（这条分支每秒会跑上千次，必须是纯比较）。
  if (code >= 0 &&
      (wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
       wparam == WM_NCLBUTTONDOWN)) {
    const HWND target = g_target.load(std::memory_order_relaxed);
    if (target != nullptr && IsWindow(target)) {
      const MSLLHOOKSTRUCT* info =
          reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
      RECT rc{};
      // GetWindowRect 是跨线程安全的只读查询；命中判定留在这里，是为了让窗口线程
      // 拿到的消息自带结论，不必在忙碌时再回头查几何。
      const BOOL inside =
          GetWindowRect(target, &rc) && PtInRect(&rc, info->pt);
      PostMessage(target, kLowLevelMouseClickMessage,
                  PackMouseHookPoint(info->pt.x, info->pt.y),
                  inside ? 1 : 0);
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
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

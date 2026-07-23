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

// 钩子线程与调用线程共享的唯一可变状态：目标窗口。回调只读它，故用 atomic 而不是锁——
// 钩子回调必须尽快返回，任何可能阻塞（锁竞争、堆分配）的东西都不该出现在这条路径上。
std::atomic<HWND> g_target{nullptr};

std::mutex g_thread_mutex;
std::thread g_thread;
std::atomic<DWORD> g_thread_id{0};

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
  // 线程必须有消息队列钩子事件才会被投递过来；PeekMessage 强制系统建队列，之后
  // Arm/Disarm 的 PostThreadMessage 才不会丢。
  MSG msg{};
  PeekMessage(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_thread_id.store(GetCurrentThreadId(), std::memory_order_release);

  HHOOK hook = nullptr;
  while (GetMessage(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == kThreadArm) {
      if (hook == nullptr) {
        hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                GetModuleHandle(nullptr), 0);
      }
    } else if (msg.message == kThreadDisarm) {
      if (hook != nullptr) {
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
  g_thread = std::thread(&HookThreadMain);
  g_thread.detach();
  // 线程 id 是线程自己发布的，这里必须等到它可用后才能 PostThreadMessage（否则
  // Arm 会静默丢失）。发布只隔着 PeekMessage 一步，实测微秒级。
  for (int spin = 0; spin < 2000; ++spin) {
    const DWORD id = g_thread_id.load(std::memory_order_acquire);
    if (id != 0) return id;
    Sleep(1);
  }
  return 0;
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

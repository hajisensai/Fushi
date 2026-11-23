#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_FRAME_CLOCK_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_FRAME_CLOCK_H_

#include <windows.h>
#include <dwmapi.h>

#include <cstdio>
#include <functional>

namespace flutter_inappwebview_plugin
{
  // BUG-4114：取帧线程的节拍。首选合成器时钟（DCompositionWaitForCompositorClock，
  // Windows 11 起有），它在 DWM 每一帧开始时返回，可以和停止事件一起等、可超时；
  // 没有这个导出（Windows 10）时退回高精度可等待定时器，周期取 DWM 刷新间隔。
  //
  // 单独成头文件是为了让节拍判定能脱离 WGC / WinRT 单测（windows/test/frame_clock_test.cpp）。
  typedef DWORD(WINAPI* WaitForCompositorClockFn)(UINT, const HANDLE*, DWORD);

  // 合成器时钟等待的超时：桌面静止时 DWM 不出节拍，超时后照常检查一次停止信号。
  constexpr DWORD kCompositorClockTimeoutMs = 100;

  inline WaitForCompositorClockFn ResolveCompositorClock()
  {
    static const WaitForCompositorClockFn fn = []() -> WaitForCompositorClockFn {
      HMODULE dcomp = LoadLibraryExW(L"dcomp.dll", nullptr,
        LOAD_LIBRARY_SEARCH_SYSTEM32);
      if (!dcomp) {
        return nullptr;
      }
      return reinterpret_cast<WaitForCompositorClockFn>(
        GetProcAddress(dcomp, "DCompositionWaitForCompositorClock"));
      }();
    return fn;
  }

  inline LONGLONG DwmFrameInterval100ns()
  {
    DWM_TIMING_INFO timing = {};
    timing.cbSize = sizeof(timing);
    if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &timing)) &&
      timing.rateRefresh.uiNumerator > 0 &&
      timing.rateRefresh.uiDenominator > 0) {
      return static_cast<LONGLONG>(
        10000000.0 * timing.rateRefresh.uiDenominator /
        timing.rateRefresh.uiNumerator);
    }
    return 166667;
  }

  // 一次合成器时钟等待的结果归类。
  enum class CompositorWaitOutcome {
    // 停止事件置位。
    kStop,
    // 合成器节拍（WAIT_OBJECT_0 + count）或超时：该取帧了。
    kTick,
    // 合成器时钟此刻没有在走：显示器关着 / 合成被遮挡时，函数立刻返回一个 NTSTATUS
    // （实测 STATUS_GRAPHICS_PRESENT_OCCLUDED = 0xC01E0006），既没等节拍、也没看停止
    // 事件——就算停止事件已经置位，返回值也还是它。
    kClockUnavailable,
    // WAIT_FAILED：这台机器上合成器时钟用不了，永久退回定时器。
    kFailed,
  };

  inline CompositorWaitOutcome ClassifyCompositorWait(DWORD result, UINT count)
  {
    if (result < WAIT_OBJECT_0 + count) {
      return CompositorWaitOutcome::kStop;
    }
    if (result == WAIT_OBJECT_0 + count || result == WAIT_TIMEOUT) {
      return CompositorWaitOutcome::kTick;
    }
    if (result == WAIT_FAILED) {
      return CompositorWaitOutcome::kFailed;
    }
    return CompositorWaitOutcome::kClockUnavailable;
  }

  class FrameClock {
  public:
    // [log] 收到事件名与细节（取帧线程把它接到 WgcLog）；可为空。
    using LogFn = std::function<void(const char* event, const char* detail)>;

    FrameClock(HANDLE stop_event, WaitForCompositorClockFn compositor_wait,
      LogFn log = nullptr)
      : stop_event_(stop_event), compositor_wait_(compositor_wait),
      log_(std::move(log))
    {
      interval_100ns_ = DwmFrameInterval100ns();
      if (!compositor_wait_) {
        StartTimerFallback();
      }
    }

    explicit FrameClock(HANDLE stop_event, LogFn log = nullptr)
      : FrameClock(stop_event, ResolveCompositorClock(), std::move(log))
    {
    }

    ~FrameClock()
    {
      if (timer_) {
        CloseHandle(timer_);
      }
    }

    FrameClock(const FrameClock&) = delete;
    FrameClock& operator=(const FrameClock&) = delete;

    const char* Name() const
    {
      return compositor_wait_ ? "compositor" : "timer";
    }

    // true = 该取帧了；false = 停止事件已置位（或等待本身失败且无法恢复）。
    bool Wait()
    {
      if (compositor_wait_) {
        const DWORD r = compositor_wait_(1, &stop_event_,
          kCompositorClockTimeoutMs);
        switch (ClassifyCompositorWait(r, 1)) {
        case CompositorWaitOutcome::kStop:
          return false;
        case CompositorWaitOutcome::kTick:
          if (clock_unavailable_) {
            clock_unavailable_ = false;
            Log("worker-clock-resumed", "");
          }
          return true;
        case CompositorWaitOutcome::kClockUnavailable:
          // 时钟没走时这次调用立刻返回、没等停止事件：自己按一个刷新间隔等停止事件，
          // 既不空转占满一个核，停止请求也在一个间隔内被看到（之前当成节拍直接
          // 返回 true，取帧线程忙等、永远看不到停止信号，平台线程 join 它就此卡死）。
          if (!clock_unavailable_) {
            clock_unavailable_ = true;
            char detail[64];
            std::snprintf(detail, sizeof(detail), "result=0x%08lX",
              static_cast<unsigned long>(r));
            Log("worker-clock-unavailable", detail);
          }
          return WaitStopFor(IntervalMs());
        case CompositorWaitOutcome::kFailed:
          Log("worker-clock-fallback", "reason=compositor_wait_failed");
          compositor_wait_ = nullptr;
          StartTimerFallback();
          break;
        }
      }
      if (!timer_) {
        // 连定时器都建不出来：只能按停止事件等一个刷新间隔。
        return WaitStopFor(IntervalMs());
      }
      HANDLE handles[2] = { stop_event_, timer_ };
      const DWORD r = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
      if (r != WAIT_OBJECT_0 + 1) {
        if (r != WAIT_OBJECT_0) {
          // 不是停止事件却退出：取帧线程就此结束、WebView 冻结在最后一帧，
          // 必须留一行日志说明原因。
          LogWaitFailed("timer_wait_failed", r);
        }
        return false;
      }
      ArmTimer();
      return true;
    }

  private:
    DWORD IntervalMs() const
    {
      const LONGLONG ms = interval_100ns_ / 10000;
      return ms > 0 ? static_cast<DWORD>(ms) : 1;
    }

    // 只等停止事件 [ms] 毫秒：超时 = 该取帧了（true），停止事件 = false。
    bool WaitStopFor(DWORD ms)
    {
      const DWORD r = WaitForSingleObject(stop_event_, ms);
      if (r == WAIT_TIMEOUT) {
        return true;
      }
      if (r != WAIT_OBJECT_0) {
        LogWaitFailed("sleep_wait_failed", r);
      }
      return false;
    }

    void Log(const char* event, const char* detail) const
    {
      if (log_) {
        log_(event, detail);
      }
    }

    void LogWaitFailed(const char* reason, DWORD result) const
    {
      const DWORD error = GetLastError();
      char detail[96];
      std::snprintf(detail, sizeof(detail), "reason=%s result=0x%08lX error=%lu",
        reason, static_cast<unsigned long>(result),
        static_cast<unsigned long>(error));
      Log("worker-clock-exit", detail);
    }

    void StartTimerFallback()
    {
      timer_ = CreateWaitableTimerExW(nullptr, nullptr,
        CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
      if (!timer_) {
        timer_ = CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);
      }
      if (timer_) {
        ArmTimer();
      }
    }

    void ArmTimer()
    {
      LARGE_INTEGER due;
      due.QuadPart = -interval_100ns_;
      SetWaitableTimer(timer_, &due, 0, nullptr, nullptr, FALSE);
    }

    HANDLE stop_event_;
    WaitForCompositorClockFn compositor_wait_ = nullptr;
    LogFn log_;
    HANDLE timer_ = nullptr;
    LONGLONG interval_100ns_ = 166667;
    // 正处在「合成器时钟没走」的一段里（只在进出时各记一行日志）。
    bool clock_unavailable_ = false;
  };
}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_FRAME_CLOCK_H_

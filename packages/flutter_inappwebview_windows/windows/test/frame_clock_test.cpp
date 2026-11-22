// 取帧线程节拍（FrameClock）的回归测试：不依赖 WGC / WinRT / gtest，cl 直接编。
// 跑法：powershell -ExecutionPolicy Bypass -File tool/run_webview_frame_clock_test.ps1
//
// BUG-5270：显示器关着时 DCompositionWaitForCompositorClock 立刻返回
// STATUS_GRAPHICS_PRESENT_OCCLUDED（0xC01E0006），不看停止事件。旧实现把它当节拍，
// 取帧线程空转、永远看不到停止信号，平台线程 join 它时整个 app 卡死。
#include "custom_platform_view/frame_clock.h"

#include <windows.h>

#include <atomic>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "dwmapi.lib")

using flutter_inappwebview_plugin::ClassifyCompositorWait;
using flutter_inappwebview_plugin::CompositorWaitOutcome;
using flutter_inappwebview_plugin::FrameClock;

namespace
{
  int g_failures = 0;
  int g_checks = 0;

  void Check(bool ok, const char* what)
  {
    ++g_checks;
    if (!ok) {
      ++g_failures;
      std::printf("FAIL: %s\n", what);
    }
  }

  constexpr DWORD kOccluded = 0xC01E0006;  // STATUS_GRAPHICS_PRESENT_OCCLUDED

  std::atomic<DWORD> g_fake_result{kOccluded};
  std::atomic<int> g_fake_calls{0};

  // 合成器时钟替身：按 g_fake_result 立刻返回，不等任何句柄（与时钟没走时的真实行为一致）。
  DWORD WINAPI FakeCompositorWait(UINT, const HANDLE*, DWORD)
  {
    ++g_fake_calls;
    return g_fake_result.load();
  }

  void TestClassify()
  {
    Check(ClassifyCompositorWait(WAIT_OBJECT_0, 1) == CompositorWaitOutcome::kStop,
      "WAIT_OBJECT_0 = stop");
    Check(ClassifyCompositorWait(WAIT_OBJECT_0 + 1, 1) == CompositorWaitOutcome::kTick,
      "WAIT_OBJECT_0 + count = tick");
    Check(ClassifyCompositorWait(WAIT_TIMEOUT, 1) == CompositorWaitOutcome::kTick,
      "WAIT_TIMEOUT = tick");
    Check(ClassifyCompositorWait(WAIT_FAILED, 1) == CompositorWaitOutcome::kFailed,
      "WAIT_FAILED = failed");
    Check(ClassifyCompositorWait(kOccluded, 1) ==
      CompositorWaitOutcome::kClockUnavailable,
      "STATUS_GRAPHICS_PRESENT_OCCLUDED = clock unavailable");
  }

  // 时钟没走、停止事件未置位：Wait 要按刷新间隔等（不空转），返回 true。
  void TestOccludedDoesNotSpin()
  {
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::vector<std::string> events;
    {
      g_fake_result = kOccluded;
      g_fake_calls = 0;
      FrameClock clock(stop, &FakeCompositorWait,
        [&events](const char* e, const char*) { events.emplace_back(e); });
      const ULONGLONG t0 = GetTickCount64();
      int ticks = 0;
      while (GetTickCount64() - t0 < 200) {
        if (clock.Wait()) {
          ++ticks;
        }
      }
      // 刷新间隔最短也有几毫秒（≤ 500 Hz）：200 ms 里空转会是成千上万次。
      Check(ticks > 0, "occluded: still ticks");
      Check(ticks < 120, "occluded: paced by the refresh interval, no busy spin");
      Check(events.size() == 1 && events[0] == "worker-clock-unavailable",
        "occluded: logs the episode once");

      // 时钟恢复：记一行 resumed。
      g_fake_result = WAIT_OBJECT_0 + 1;
      Check(clock.Wait(), "resumed: tick");
      Check(events.size() == 2 && events[1] == "worker-clock-resumed",
        "resumed: logged once");
    }
    CloseHandle(stop);
  }

  // 根因场景：时钟没走时置位停止事件，Wait 必须返回 false（取帧线程能退出、join 不卡）。
  void TestOccludedObservesStop()
  {
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_fake_result = kOccluded;
    FrameClock clock(stop, &FakeCompositorWait);
    SetEvent(stop);
    Check(!clock.Wait(), "occluded + stop set: Wait returns false");
    CloseHandle(stop);
  }

  // 端到端：与 RunFrameWorker 同形的取帧线程，在时钟没走时由另一线程置位停止事件后 join，
  // join 必须在几个刷新间隔内返回。
  void TestWorkerJoinsWhileOccluded()
  {
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_fake_result = kOccluded;
    std::atomic<bool> exited{false};
    std::thread worker([stop, &exited]() {
      FrameClock clock(stop, &FakeCompositorWait);
      while (clock.Wait()) {
      }
      exited = true;
    });
    Sleep(50);
    SetEvent(stop);
    const ULONGLONG t0 = GetTickCount64();
    while (!exited && GetTickCount64() - t0 < 2000) {
      Sleep(1);
    }
    Check(exited.load(), "worker exits within 2 s after stop while occluded");
    if (exited) {
      worker.join();
    } else {
      // 不 join：卡住的线程会让测试进程挂死，直接报失败退出。
      worker.detach();
      std::printf("FAIL: worker stuck; aborting\n");
      std::fflush(stdout);
      ExitProcess(1);
    }
    CloseHandle(stop);
  }

  // 真实时钟（若可用）：置位停止事件后 Wait 一定返回 false——无论此刻显示器开着
  // （等到事件）还是关着（立刻返回 OCCLUDED）。
  void TestRealClockObservesStop()
  {
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    FrameClock clock(stop);
    SetEvent(stop);
    Check(!clock.Wait(), "real clock + stop set: Wait returns false");
    CloseHandle(stop);
  }
}  // namespace

int main()
{
  TestClassify();
  TestOccludedDoesNotSpin();
  TestOccludedObservesStop();
  TestWorkerJoinsWhileOccluded();
  TestRealClockObservesStop();
  std::printf("frame_clock_test: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}

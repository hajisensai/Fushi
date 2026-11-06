#include "texture_bridge.h"

#include <dwmapi.h>
#include <windows.foundation.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <iostream>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include "util/direct3d11.interop.h"
#include "../utils/wgc_log.h"

#pragma comment(lib, "dwmapi.lib")

// BUG-4114：WGC 默认把交帧节流在约 60 Hz（144 Hz 屏上实测恒为 20.83 ms = 每 3 个
// 刷新周期一帧，48 帧/秒），页面自己 144 帧/秒也只能拿到 48。Windows 11 24H2
// 起会话多了 MinUpdateInterval 可以解除节流。本仓编译用的 SDK 10.0.22621 还没有
// 这个接口，按系统 Windows.Graphics.winmd 里的 IID 与方法顺序手写 ABI 声明
// （IInspectable 之后 get_MinUpdateInterval / put_MinUpdateInterval）；SDK 升到
// 26100 后改用头文件里的 ABI::Windows::Graphics::Capture::IGraphicsCaptureSession5。
MIDL_INTERFACE("67c0ea62-1f85-5061-925a-239be0ac09cb")
IFushiGraphicsCaptureSession5 : public IInspectable
{
public:
  virtual HRESULT STDMETHODCALLTYPE get_MinUpdateInterval(
    ABI::Windows::Foundation::TimeSpan* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_MinUpdateInterval(
    ABI::Windows::Foundation::TimeSpan value) = 0;
};

namespace flutter_inappwebview_plugin
{
  // BUG-4114：帧池至少 2 个缓冲。取帧线程每个合成器节拍都把帧取走、拷完立刻还回，
  // 第二个缓冲留给 DWM 在我们拷贝的那一小段时间里继续写下一帧——单缓冲时任何一次
  // 取帧晚到都让 DWM 无处可写、这一帧直接丢掉（旧实现取帧挂在 UI 线程定时器上，
  // Dart 一忙就晚）。
  const int kNumBuffers = 2;
  // 一次唤醒最多排空的帧数（只留最新一帧，其余立刻释放）。帧池只有 kNumBuffers 个
  // 缓冲，这里只是循环上界。
  const int kMaxFramesPerDrain = 8;
  // 合成器时钟等待的超时：桌面静止时 DWM 不出节拍，超时后照常检查一次停止信号。
  const DWORD kCompositorClockTimeoutMs = 100;

  // TODO-618 fix3: 进程级退出态总闸（详见 texture_bridge.h 声明处注释）。
  // 进程退出期间置位后，所有 TextureBridge::DeliverFrameLocked 的帧上报回调短路早返回。
  std::atomic<bool> g_process_exiting{false};

  void SetProcessExiting() noexcept
  {
    g_process_exiting.store(true, std::memory_order_release);
  }

  bool IsProcessExiting() noexcept
  {
    return g_process_exiting.load(std::memory_order_acquire);
  }

  // 平台线程上报的失活闸：取帧线程投递到平台线程的上报任务先看它，桥退役后一律
  // no-op（与旧定时器 tick 的同名状态同一语义）。
  struct WgcPumpCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    std::weak_ptr<WgcFramePoolLifetime> lifetime;
    uint64_t generation = 0;
    bool active = false;
    bool retiring = false;
    bool in_handler = false;
    bool late_noop_logged = false;
  };

  // BUG-4114：一个帧池的取帧线程要用到的全部东西。线程只持有这一份（共享指针），
  // 从不碰 TextureBridge 本身；桥在关帧池之前先置停止信号并 join，所以线程绝不会
  // 和 Close / 析构并发。
  struct WgcFrameWorkerShared {
    uint64_t generation = 0;
    const void* pool_for_log = nullptr;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue;
    Microsoft::WRL::ComPtr<WgcDeliverHandler> deliver_handler;
    // 本代已向平台线程投递、尚未被执行的上报任务（合并投递，不刷屏消息队列）。
    // 必须按代持有、和 deliver_handler 一一对应：若挂在桥共用的 mailbox 上，旧一代
    // 排队中的 handler 会吞掉新一代的投递——新一代首帧 exchange 见 true 不投，旧
    // handler 随后清标记再在失活闸上 no-op，新帧就再没人上报。handler 自己也捕获
    // 一份（共享指针），排队中的 handler 活得比本结构久也安全。
    std::shared_ptr<std::atomic<bool>> post_pending =
      std::make_shared<std::atomic<bool>>(false);
    std::shared_ptr<WgcFrameMailbox> mailbox;
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> device_context;
    // 手动复位事件：置位后线程在下一次等待返回时退出。
    HANDLE stop_event = nullptr;

    ~WgcFrameWorkerShared()
    {
      if (stop_event) {
        CloseHandle(stop_event);
      }
    }
  };

  struct WgcFramePoolLifetime {
    uint64_t generation = 0;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session;
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue;
    std::shared_ptr<WgcFrameWorkerShared> worker_shared;
    std::thread worker;
    std::shared_ptr<WgcPumpCallbackState> pump_state;
    ABI::Windows::Graphics::SizeInt32 size = { -1, -1 };
    bool registry_retired = false;
    bool inactive = false;
    bool retiring = false;
    bool worker_stopped = false;
    bool session_closed = false;
    bool pool_closed = false;
    bool first_frame_logged = false;
    bool noop_logged = false;

    const void* PoolForLog() const
    {
      return frame_pool.get();
    }

    // 正常路径一定先经 StopFrameWorkerLocked join 掉取帧线程；这里只防「漏了退役」
    // 时 std::thread 析构直接 std::terminate。走到这里会留一行日志，便于追查漏的路径。
    ~WgcFramePoolLifetime()
    {
      if (worker.joinable()) {
        WgcLog::Write("worker-join-in-dtor", frame_pool.get(), "");
        if (worker_shared && worker_shared->stop_event) {
          SetEvent(worker_shared->stop_event);
        }
        worker.join();
      }
    }
  };

  namespace
  {
    // BUG-4114：取帧线程的节拍。首选合成器时钟（DCompositionWaitForCompositorClock，
    // Windows 11 起有），它在 DWM 每一帧开始时返回，可以和停止事件一起等、可超时；
    // 没有这个导出（Windows 10）时退回高精度可等待定时器，周期取 DWM 刷新间隔。
    typedef DWORD(WINAPI* WaitForCompositorClockFn)(UINT, const HANDLE*, DWORD);

    WaitForCompositorClockFn ResolveCompositorClock()
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

    LONGLONG DwmFrameInterval100ns()
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

    class FrameClock {
    public:
      explicit FrameClock(HANDLE stop_event) : stop_event_(stop_event)
      {
        compositor_wait_ = ResolveCompositorClock();
        if (!compositor_wait_) {
          StartTimerFallback();
        }
      }

      ~FrameClock()
      {
        if (timer_) {
          CloseHandle(timer_);
        }
      }

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
          if (r == WAIT_OBJECT_0) {
            return false;
          }
          if (r != WAIT_FAILED) {
            return true;  // 节拍（WAIT_OBJECT_0 + 1）或超时
          }
          WgcLog::Write("worker-clock-fallback", nullptr,
            "reason=compositor_wait_failed");
          compositor_wait_ = nullptr;
          StartTimerFallback();
        }
        if (!timer_) {
          // 连定时器都建不出来：只能按停止事件等一个刷新间隔。
          const DWORD r = WaitForSingleObject(stop_event_,
            static_cast<DWORD>(interval_100ns_ / 10000));
          if (r == WAIT_TIMEOUT) {
            return true;
          }
          if (r != WAIT_OBJECT_0) {
            LogWaitFailed("sleep_wait_failed", r);
          }
          return false;
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
      static void LogWaitFailed(const char* reason, DWORD result)
      {
        const DWORD error = GetLastError();
        char detail[96];
        std::snprintf(detail, sizeof(detail), "reason=%s result=0x%08lX error=%lu",
          reason, static_cast<unsigned long>(result),
          static_cast<unsigned long>(error));
        WgcLog::Write("worker-clock-exit", nullptr, detail);
      }

      void StartTimerFallback()
      {
        interval_100ns_ = DwmFrameInterval100ns();
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
      HANDLE timer_ = nullptr;
      LONGLONG interval_100ns_ = 166667;
    };

    // 把一帧的有效内容拷进 mailbox 的私有纹理。调用方持有该帧对象，拷贝提交并
    // Flush 之后才释放它（释放 = 缓冲还给帧池），所以 DWM 不会在拷贝期间改写源。
    bool StageFrame(WgcFrameWorkerShared& shared,
      ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame* frame,
      bool& create_failure_logged)
    {
      winrt::com_ptr<ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;
      if (FAILED(frame->get_Surface(frame_surface.put())) || !frame_surface) {
        return false;
      }
      auto src = TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
      if (!src) {
        return false;
      }
      D3D11_TEXTURE2D_DESC desc;
      src->GetDesc(&desc);
      ABI::Windows::Graphics::SizeInt32 content = { 0, 0 };
      if (FAILED(frame->get_ContentSize(&content)) || content.Width <= 0 ||
        content.Height <= 0) {
        content = { static_cast<int32_t>(desc.Width),
          static_cast<int32_t>(desc.Height) };
      }
      content.Width = (std::min)(content.Width, static_cast<int32_t>(desc.Width));
      content.Height =
        (std::min)(content.Height, static_cast<int32_t>(desc.Height));

      WgcFrameMailbox& mailbox = *shared.mailbox;
      const std::lock_guard<std::mutex> lock(mailbox.mutex);
      if (!mailbox.staged || mailbox.staged_width != desc.Width ||
        mailbox.staged_height != desc.Height) {
        // 私有纹理：不共享句柄、不进引擎，引用计数在插件设备上平衡，按帧池尺寸
        // 重建不留残余（BUG-3913 的泄漏只出在共享句柄与帧池上）。
        D3D11_TEXTURE2D_DESC staged_desc = {};
        staged_desc.Width = desc.Width;
        staged_desc.Height = desc.Height;
        staged_desc.MipLevels = 1;
        staged_desc.ArraySize = 1;
        staged_desc.Format = desc.Format;
        staged_desc.SampleDesc.Count = 1;
        staged_desc.Usage = D3D11_USAGE_DEFAULT;
        winrt::com_ptr<ID3D11Texture2D> staged;
        const HRESULT hr =
          shared.device->CreateTexture2D(&staged_desc, nullptr, staged.put());
        if (FAILED(hr) || !staged) {
          if (!create_failure_logged) {
            create_failure_logged = true;
            char detail[64];
            std::snprintf(detail, sizeof(detail), "hr=0x%08lX",
              static_cast<unsigned long>(hr));
            WgcLog::Write("worker-stage-create-fail", shared.pool_for_log, detail);
          }
          return false;
        }
        mailbox.staged = std::move(staged);
        mailbox.staged_width = desc.Width;
        mailbox.staged_height = desc.Height;
      }
      const D3D11_BOX box = { 0, 0, 0, static_cast<UINT>(content.Width),
        static_cast<UINT>(content.Height), 1 };
      shared.device_context->CopySubresourceRegion(mailbox.staged.get(), 0, 0, 0,
        0, src.get(), 0, &box);
      shared.device_context->Flush();
      mailbox.content = content;
      ++mailbox.seq;
      return true;
    }

    void RunFrameWorker(std::shared_ptr<WgcFrameWorkerShared> shared)
    {
      SetThreadDescription(GetCurrentThread(), L"fushi-wgc-frames");
      // WinRT 对象（free-threaded 帧池）在 MTA 里调用。
      const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      FrameClock clock(shared->stop_event);
      {
        char detail[96];
        std::snprintf(detail, sizeof(detail), "generation=%llu clock=%s",
          static_cast<unsigned long long>(shared->generation), clock.Name());
        WgcLog::Write("worker-run", shared->pool_for_log, detail);
      }
      bool get_failure_logged = false;
      bool create_failure_logged = false;
      WgcFrameMailbox& mailbox = *shared->mailbox;
      while (clock.Wait()) {
        mailbox.probe.OnWake();
        winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
          latest;
        int drained = 0;
        for (int i = 0; i < kMaxFramesPerDrain; ++i) {
          winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
            frame;
          const HRESULT hr = shared->frame_pool->TryGetNextFrame(frame.put());
          if (FAILED(hr)) {
            if (!get_failure_logged) {
              get_failure_logged = true;
              char detail[64];
              std::snprintf(detail, sizeof(detail), "hr=0x%08lX",
                static_cast<unsigned long>(hr));
              WgcLog::Write("frame-getfail", shared->pool_for_log, detail);
            }
            break;
          }
          if (!frame) {
            break;
          }
          ++drained;
          ABI::Windows::Foundation::TimeSpan srt = {};
          if (SUCCEEDED(frame->get_SystemRelativeTime(&srt))) {
            mailbox.probe.OnFrame(srt.Duration);
          }
          // 赋值即释放上一份：排在前面的旧帧当场还给帧池，只拷最新一帧。
          latest = std::move(frame);
        }
        mailbox.probe.OnDrained(drained);
        if (!latest) {
          continue;
        }
        const bool staged =
          StageFrame(*shared, latest.get(), create_failure_logged);
        latest = nullptr;
        if (!staged) {
          continue;
        }
        if (!shared->post_pending->exchange(true, std::memory_order_acq_rel)) {
          boolean enqueued = false;
          if (FAILED(shared->dispatcher_queue->TryEnqueue(
            shared->deliver_handler.Get(), &enqueued)) || !enqueued) {
            // 平台线程的队列已关闭（进程退出）：不再上报，下一帧再试。
            shared->post_pending->store(false, std::memory_order_release);
          }
        }
      }
      // 本线程对 shared 里 COM 指针（frame_pool / dispatcher_queue / deliver_handler
      // / D3D 设备）的引用要在 CoUninitialize 之前放掉：释放 COM 对象必须发生在本线程
      // 的 COM 公寓仍然有效的时候。
      shared.reset();
      if (SUCCEEDED(co_hr)) {
        CoUninitialize();
      }
    }
  }  // namespace
  namespace
  {
    std::string HResultDetail(const char* label, HRESULT hr)
    {
      char buffer[64];
      std::snprintf(buffer, sizeof(buffer), "%s=0x%08lX", label,
        static_cast<unsigned long>(hr));
      return std::string(buffer);
    }

    std::string GenerationDetail(uint64_t generation)
    {
      char buffer[64];
      std::snprintf(buffer, sizeof(buffer), "generation=%llu",
        static_cast<unsigned long long>(generation));
      return std::string(buffer);
    }

    std::string PointerDetail(const char* label, const void* pointer)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=0x%llx", label,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(pointer)));
      return std::string(buffer);
    }

    std::string BoolDetail(const char* label, bool value)
    {
      return std::string(label) + (value ? "=1" : "=0");
    }

    std::string SizeDetail(const char* label,
      ABI::Windows::Graphics::SizeInt32 size)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=%dx%d", label,
        static_cast<int>(size.Width), static_cast<int>(size.Height));
      return std::string(buffer);
    }

    std::string SizeDetail(const char* label, size_t width, size_t height)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=%zux%zu", label, width, height);
      return std::string(buffer);
    }

    std::string JoinDetails(std::initializer_list<std::string> parts)
    {
      std::string detail;
      for (const auto& part : parts) {
        if (part.empty()) {
          continue;
        }
        if (!detail.empty()) {
          detail += ' ';
        }
        detail += part;
      }
      return detail;
    }

    ABI::Windows::Graphics::SizeInt32 CaptureItemSize(
      ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* capture_item)
    {
      ABI::Windows::Graphics::SizeInt32 size = { -1, -1 };
      if (capture_item) {
        capture_item->get_Size(&size);
      }
      return size;
    }

    std::string BridgeStateDetail(const TextureBridge* bridge,
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
      ABI::Windows::Graphics::SizeInt32 capture_item_size,
      bool is_running,
      bool needs_update)
    {
      const uint64_t generation = lifetime ? lifetime->generation : 0;
      ABI::Windows::Graphics::SizeInt32 pool_size = { -1, -1 };
      if (lifetime) {
        pool_size = lifetime->size;
      }
      return JoinDetails({
        GenerationDetail(generation),
        SizeDetail("pool_size", pool_size),
        SizeDetail("capture_item_size", capture_item_size),
        BoolDetail("running", is_running),
        BoolDetail("needs_update", needs_update),
        PointerDetail("bridge", bridge),
      });
    }

    std::string FrameHandlerDetail(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
      bool in_handler,
      bool retiring,
      bool has_frame,
      bool needs_update)
    {
      const uint64_t generation = lifetime ? lifetime->generation : 0;
      return JoinDetails({
        GenerationDetail(generation),
        BoolDetail("in_handler", in_handler),
        BoolDetail("retiring", retiring),
        BoolDetail("has_frame", has_frame),
        BoolDetail("needs_update", needs_update),
      });
    }

    std::string ReasonDetail(const char* reason)
    {
      return std::string("reason=") + (reason ? reason : "unknown");
    }

    std::string RegistryCountsDetail(size_t active_count, size_t retired_count)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "active=%zu retired=%zu",
        active_count, retired_count);
      return std::string(buffer);
    }

    // TODO-409: erase 回收后，registry 里驻留的 retired 数应趋近于 0（不再泄漏的
    // 可观测锚点）；retired_total 是单调累计退役次数（退役链确实在跑的锚点），
    // 不随回收下降，与查词/teardown 次数对照。
    std::string RegistryCountsDetail(size_t active_count, size_t retired_count,
      uint64_t retired_total)
    {
      char buffer[128];
      std::snprintf(buffer, sizeof(buffer),
        "active=%zu retired=%zu retired_total=%llu", active_count, retired_count,
        static_cast<unsigned long long>(retired_total));
      return std::string(buffer);
    }

    class FramePoolLifetimeRegistry {
    public:
      static FramePoolLifetimeRegistry& Instance()
      {
        static FramePoolLifetimeRegistry instance;
        return instance;
      }

      void Retain(const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
      {
        if (!lifetime) {
          return;
        }
        const std::lock_guard<std::mutex> lock(mutex_);
        lifetimes_.push_back(lifetime);
        WgcLog::Write("registry-size", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked()));
      }

      void MarkRetired(const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
      {
        if (!lifetime) {
          return;
        }
        const std::lock_guard<std::mutex> lock(mutex_);
        // 维持 FinalizeFramePoolLifetime 的幂等早返回（registry_retired==true
        // 即跳过重复退役链），即便随后从向量移除强引用。
        if (lifetime->registry_retired) {
          return;
        }
        lifetime->registry_retired = true;
        ++retired_total_;
        // TODO-409: 退役链 ①-⑦ 已在 mutex_ 锁外（RetireFramePoolLocked/
        // FinalizeFramePoolLifetime）跑完（pump 失效化→Stop→remove_Tick→Close
        // session→Close pool），此处只剩最后一步：从 lifetimes_ 真正移除这条
        // 强引用。当 registry 持最后一个强引用时，erase 触发
        // ~WgcFramePoolLifetime 释放壳内已 Close 的 COM 句柄，消除有界泄漏。
        // 在途 Tick 仍由 pump_state 弱引用 + 自身栈上的 shared_ptr 保护（非
        // free-threaded 帧池 + UI 线程串行 pump），不会 UAF。
        // 先在仍持有该条目时计算计数并写日志，保留 retired/retired_total 锚点，
        // 再 erase 移除引用（不手动 delete/reset，让引用计数自然定序析构）。
        WgcLog::Write("registry-size", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked(),
            retired_total_));
        for (auto it = lifetimes_.begin(); it != lifetimes_.end(); ++it) {
          if (it->get() == lifetime.get()) {
            lifetimes_.erase(it);
            break;
          }
        }
        // TODO-409 不变量（勿破坏）：erase 后这里仍解引用 lifetime->PoolForLog()
        // 是安全的，因为对象此刻靠 RetireFramePoolLocked 的栈局部 shared_ptr 存活
        // （erase 只把 registry 引用从「最后一个」降级为「非最后」，refcount 2→1）。
        // 若将来重构成「registry 直接独占唯一引用、erase 即析构」，这一行会立刻变
        // UAF——届时必须把日志移到 erase 之前，或保留一个本地强引用。
        WgcLog::Write("registry-reclaim", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked(),
            retired_total_));
      }

    private:
      FramePoolLifetimeRegistry() = default;

      size_t ActiveCountLocked() const
      {
        size_t count = 0;
        for (const auto& lifetime : lifetimes_) {
          if (lifetime && !lifetime->registry_retired) {
            ++count;
          }
        }
        return count;
      }

      size_t RetiredCountLocked() const
      {
        size_t count = 0;
        for (const auto& lifetime : lifetimes_) {
          if (lifetime && lifetime->registry_retired) {
            ++count;
          }
        }
        return count;
      }

      std::mutex mutex_;
      std::vector<std::shared_ptr<WgcFramePoolLifetime>> lifetimes_;
      // TODO-409: 单调累计退役次数（不随 erase 回收下降），真机用作退役链
      // 确实在跑的可观测锚点。
      uint64_t retired_total_ = 0;
    };

    void FinalizeFramePoolLifetime(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
  }  // namespace
  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context),
    mailbox_(std::make_shared<WgcFrameMailbox>(this))
  {
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_closed_handler_ =
      Microsoft::WRL::Callback<CaptureItemClosedHandler>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        });
    capture_item_->add_Closed(capture_item_closed_handler_.Get(),
      &on_closed_token_);
    WgcLog::Write("create-bridge", this);
  }

  TextureBridge::~TextureBridge()
  {
    WgcLog::Write("dtor-enter", this);
    InvalidatePumpCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
    capture_item_closed_handler_ = nullptr;
    WgcLog::Write("dtor-exit", this);
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    const auto lifetime = frame_pool_lifetime_;
    const auto capture_item_size = CaptureItemSize(capture_item_.get());
    const bool needs_update = needs_update_.load();
    if (is_running_) {
      WgcLog::Write("start-skip-running",
        lifetime ? lifetime->PoolForLog() : nullptr,
        BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
          needs_update));
      return false;
    }
    if (!capture_item_) {
      WgcLog::Write("start-skip-noitem", nullptr,
        BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
          needs_update));
      return false;
    }
    WgcLog::Write("start",
      lifetime ? lifetime->PoolForLog() : nullptr,
      BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
        needs_update));

    RetireFramePoolLocked("start");

    if (!CreateAndStartFramePoolLocked()) {
      is_running_ = false;
      return false;
    }
    return true;
  }

  ABI::Windows::Graphics::SizeInt32 TextureBridge::FramePoolSizeFor(
    ABI::Windows::Graphics::SizeInt32 item_size) const
  {
    // BUG-3913：每 Close 一个帧池、再按新尺寸 CreateFreeThreaded 一个，系统侧都留下
    // 约一份帧池缓冲永不归还（帧池已 Close、注册表已回收，插件侧无引用）。所以帧池
    // 按容量分配：容量内改尺寸时 WGC 照常交付 ContentSize 变化的帧（内容在帧纹理
    // 左上角），帧池本身不动。
    //
    // 容量是设备倍率下的物理像素；捕获源按捕获倍率栅格化（着色器链开着时只有设备
    // 倍率的一半），帧池要的是「捕获倍率下的容量」。直接拿设备倍率的容量会让着色器
    // 路径的帧池白占 4 倍面积。向上取整：捕获源 = 布局 × 捕获倍率，而容量 ≥
    // ceil(布局 × 设备倍率)，所以 ceil(容量 × 比值) 一定盖得住捕获源。
    const double ratio = capture_scale_ratio_ > 0.0f && capture_scale_ratio_ < 1.0f
      ? static_cast<double>(capture_scale_ratio_)
      : 1.0;
    const auto capture_capacity = [ratio](size_t device_pixels) -> size_t {
      return static_cast<size_t>(
        std::ceil(static_cast<double>(device_pixels) * ratio));
      };
    const size_t capacity_width = capture_capacity(capacity_.width);
    const size_t capacity_height = capture_capacity(capacity_.height);
    ABI::Windows::Graphics::SizeInt32 size = item_size;
    if (capacity_width > static_cast<size_t>((std::max)(size.Width, 0))) {
      size.Width = static_cast<int32_t>(capacity_width);
    }
    if (capacity_height > static_cast<size_t>((std::max)(size.Height, 0))) {
      size.Height = static_cast<int32_t>(capacity_height);
    }
    return size;
  }

  bool TextureBridge::CreateAndStartFramePoolLocked()
  {
    ABI::Windows::Graphics::SizeInt32 item_size = { 0, 0 };
    capture_item_->get_Size(&item_size);
    const ABI::Windows::Graphics::SizeInt32 size = FramePoolSizeFor(item_size);
    auto lifetime = std::make_shared<WgcFramePoolLifetime>();
    lifetime->generation = ++frame_pool_generation_;
    lifetime->size = size;
    lifetime->dispatcher_queue =
      graphics_context_->GetDispatcherQueueForCurrentThread();

    // BUG-4114：free-threaded 帧池——取帧在本帧池自己的取帧线程上，不经 UI 线程。
    // 不订阅 FrameArrived（BUG-209：迟到事件回调 UAF），取帧线程按合成器时钟拉。
    lifetime->frame_pool = graphics_context_->CreateFreeThreadedCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    assert(lifetime->frame_pool);

    WgcLog::Write("create-pool", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    FramePoolLifetimeRegistry::Instance().Retain(lifetime);
    WgcLog::Write("active-retain", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));

    frame_pool_lifetime_ = lifetime;

    if (FAILED(lifetime->frame_pool->CreateCaptureSession(capture_item_.get(),
      lifetime->capture_session.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      WgcLog::Write("createSession-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      RetireFramePoolLocked("createSession-fail");
      return false;
    }

    // BUG-4114：解除 WGC 的约 60 Hz 交帧节流（见文件头 IFushiGraphicsCaptureSession5）。
    // 1 ms = 不额外节流，交帧上限回到 DWM 合成频率（144 Hz 屏 144 帧/秒）；内容
    // 不变时 DWM 本来就不出帧，取帧线程每个节拍只是一次空的 TryGetNextFrame。
    // 24H2 之前的系统没有这个接口：QueryInterface 失败即保持系统默认节流，记一行
    // 日志说明本机能力，不是错误路径。
    {
      winrt::com_ptr<IFushiGraphicsCaptureSession5> session5;
      if (SUCCEEDED(lifetime->capture_session->QueryInterface(
            __uuidof(IFushiGraphicsCaptureSession5), session5.put_void()))) {
        ABI::Windows::Foundation::TimeSpan interval{};
        interval.Duration = 10000;  // 100 ns 为单位：1 ms。
        const HRESULT hr = session5->put_MinUpdateInterval(interval);
        WgcLog::Write(SUCCEEDED(hr) ? "min-update-interval-set"
                                    : "min-update-interval-fail",
          lifetime->PoolForLog(), GenerationDetail(lifetime->generation));
      } else {
        WgcLog::Write("min-update-interval-unsupported", lifetime->PoolForLog(),
          GenerationDetail(lifetime->generation));
      }
    }

    const bool started = SUCCEEDED(lifetime->capture_session->StartCapture());
    if (!started) {
      WgcLog::Write("startCapture-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      RetireFramePoolLocked("startCapture-fail");
      return false;
    }

    is_running_ = true;
    if (!StartFrameWorkerLocked(lifetime)) {
      RetireFramePoolLocked("worker-start-fail");
      is_running_ = false;
      return false;
    }
    return true;
  }

  bool TextureBridge::RecreateFramePoolLocked()
  {
    ABI::Windows::Graphics::SizeInt32 current_size = { 0, 0 };
    const auto lifetime = frame_pool_lifetime_;
    if (capture_item_ && SUCCEEDED(capture_item_->get_Size(&current_size)) &&
      lifetime && lifetime->frame_pool) {
      // BUG-3913：放得下就不重建（旧判据是「尺寸完全相等」，于是每次改尺寸都重建）。
      const auto wanted = FramePoolSizeFor(current_size);
      if (wanted.Width <= lifetime->size.Width &&
        wanted.Height <= lifetime->size.Height) {
        WgcLog::Write("recreate-skip-fits", lifetime->PoolForLog(),
          JoinDetails({
            GenerationDetail(lifetime->generation),
            SizeDetail("current_size", current_size),
            SizeDetail("lifetime_size", lifetime->size),
          }));
        return false;
      }
    }

    WgcLog::Write("recreate", lifetime ? lifetime->PoolForLog() : nullptr,
      lifetime ? JoinDetails({
        GenerationDetail(lifetime->generation),
        SizeDetail("lifetime_size", lifetime->size),
      }) : std::string());

    RetireFramePoolLocked("recreate");
    if (!CreateAndStartFramePoolLocked()) {
      is_running_ = false;
    }
    return true;
  }



  bool TextureBridge::StartFrameWorkerLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    if (!lifetime || !lifetime->dispatcher_queue || !lifetime->frame_pool) {
      WgcLog::Write("worker-start-fail",
        lifetime ? lifetime->PoolForLog() : nullptr,
        lifetime ? "dispatcher_queue_or_pool=0" : "lifetime=0");
      return false;
    }

    auto pump_state = std::make_shared<WgcPumpCallbackState>();
    {
      const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
      pump_state->bridge = this;
      pump_state->lifetime = lifetime;
      pump_state->generation = lifetime->generation;
      pump_state->active = true;
    }

    auto shared = std::make_shared<WgcFrameWorkerShared>();
    shared->generation = lifetime->generation;
    shared->pool_for_log = lifetime->PoolForLog();
    shared->frame_pool = lifetime->frame_pool;
    shared->dispatcher_queue = lifetime->dispatcher_queue;
    shared->mailbox = mailbox_;
    shared->device.copy_from(graphics_context_->d3d_device());
    shared->device_context.copy_from(graphics_context_->d3d_device_context());
    shared->stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!shared->stop_event) {
      WgcLog::Write("worker-start-fail", lifetime->PoolForLog(),
        HResultDetail("hr", HRESULT_FROM_WIN32(GetLastError())));
      return false;
    }

    // 平台线程上报任务。DispatcherQueueHandler 由取帧线程 TryEnqueue、在平台线程
    // 执行，委托必须 agile（聚合 FtmBase，与旧定时器 Tick 委托同理：非 agile 委托
    // 跨线程投递会被拒）。委托只捕获失活闸与 mailbox，从不持有桥的强引用；桥退役后
    // 迟到的投递在失活闸上 no-op。
    const auto post_pending = shared->post_pending;
    shared->deliver_handler = Microsoft::WRL::Callback<
      Microsoft::WRL::Implements<
        Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
        WgcDeliverHandler, Microsoft::WRL::FtmBase>>(
      [pump_state, post_pending]() -> HRESULT
      {
        // 先清本代的投递标记：上报期间取帧线程再拷好的帧会重新投递一次，不会被吞。
        post_pending->store(false, std::memory_order_release);
        TextureBridge* bridge = nullptr;
        std::shared_ptr<WgcFramePoolLifetime> lifetime;
        bool log_late_noop = false;
        uint64_t noop_generation = 0;
        {
          const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
          lifetime = pump_state->lifetime.lock();
          if (pump_state->active && !pump_state->retiring &&
            pump_state->bridge && lifetime) {
            pump_state->in_handler = true;
            bridge = pump_state->bridge;
          }
          else if (!pump_state->late_noop_logged) {
            pump_state->late_noop_logged = true;
            log_late_noop = true;
            noop_generation = pump_state->generation;
          }
        }
        if (log_late_noop) {
          WgcLog::Write("deliver-late-noop",
            lifetime ? lifetime->PoolForLog() : nullptr,
            GenerationDetail(noop_generation));
        }
        if (bridge && lifetime) {
          bridge->DeliverFrameLocked(lifetime);
        }
        {
          const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
          pump_state->in_handler = false;
        }
        return S_OK;
      });
    if (!shared->deliver_handler) {
      WgcLog::Write("worker-start-fail", lifetime->PoolForLog(),
        "deliver_handler=0");
      return false;
    }

    lifetime->pump_state = pump_state;
    lifetime->worker_shared = shared;
    try {
      lifetime->worker = std::thread(RunFrameWorker, shared);
    }
    catch (const std::system_error& e) {
      WgcLog::Write("worker-start-fail", lifetime->PoolForLog(),
        std::string("thread=") + e.what());
      lifetime->pump_state = nullptr;
      lifetime->worker_shared = nullptr;
      return false;
    }

    WgcLog::Write("worker-start", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    return true;
  }

  void TextureBridge::StopFrameWorkerLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime, const char* reason)
  {
    if (!lifetime) {
      return;
    }

    WgcLog::Write("worker-stop-start", lifetime->PoolForLog(),
      JoinDetails({ GenerationDetail(lifetime->generation), ReasonDetail(reason) }));
    // 先失活平台线程上报：已经排进 DispatcherQueue 的上报任务执行时一律 no-op。
    InvalidatePumpCallback(lifetime);

    // 再停取帧线程并等它退出。线程只拿 mailbox 锁、不拿桥的 mutex_（这里正持有），
    // 等待合成器时钟时也同时等停止事件，所以 join 在一个合成器节拍内返回、不会死锁。
    // join 之后才 Close session / pool：取帧线程与 Close / 析构之间有确定的先后。
    if (lifetime->worker_shared && lifetime->worker_shared->stop_event) {
      SetEvent(lifetime->worker_shared->stop_event);
    }
    if (lifetime->worker.joinable()) {
      lifetime->worker.join();
      lifetime->worker_stopped = true;
      WgcLog::Write("worker-stop-joined", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
    }

    lifetime->worker_shared = nullptr;
    lifetime->pump_state = nullptr;
    WgcLog::Write("worker-stop-done", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
  }

  void TextureBridge::PostDeliveryLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    if (!lifetime || !lifetime->worker_shared ||
      !lifetime->worker_shared->deliver_handler || !lifetime->dispatcher_queue) {
      return;
    }
    const auto& post_pending = lifetime->worker_shared->post_pending;
    if (post_pending->exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    boolean enqueued = false;
    if (FAILED(lifetime->dispatcher_queue->TryEnqueue(
      lifetime->worker_shared->deliver_handler.Get(), &enqueued)) || !enqueued) {
      post_pending->store(false, std::memory_order_release);
    }
  }

  TextureBridge::StagedFrame TextureBridge::AcquireStagedFrame()
  {
    StagedFrame staged;
    staged.lock = std::unique_lock<std::mutex>(mailbox_->mutex);
    staged.texture = mailbox_->staged.get();
    staged.content = mailbox_->content;
    return staged;
  }
  void TextureBridge::Stop()
  {
    InvalidatePumpCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::InvalidatePumpCallback(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    auto target = lifetime ? lifetime : frame_pool_lifetime_;
    if (!target || !target->pump_state) {
      return;
    }
    auto pump_state = target->pump_state;
    const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
    pump_state->active = false;
    pump_state->retiring = true;
    pump_state->bridge = nullptr;
    pump_state->generation = 0;
    target->inactive = true;
    target->retiring = true;
  }

  void TextureBridge::StopInternal()
  {
    auto lifetime = frame_pool_lifetime_;
    WgcLog::Write("stop", lifetime ? lifetime->PoolForLog() : nullptr);
    is_running_ = false;
    RetireFramePoolLocked("stop");
  }

  void TextureBridge::RetireFramePoolLocked(const char* reason)
  {
    auto lifetime = frame_pool_lifetime_;
    if (!lifetime) {
      return;
    }

    WgcLog::Write("retire", lifetime->PoolForLog(), ReasonDetail(reason));
    StopFrameWorkerLocked(lifetime, reason);
    WgcLog::Write("state-inactive", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    frame_pool_lifetime_ = nullptr;
    FinalizeFramePoolLifetime(lifetime);
  }

  namespace
  {
    void FinalizeFramePoolLifetime(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
    {
      if (!lifetime || lifetime->registry_retired) {
        return;
      }

      const void* pool_for_log = lifetime->PoolForLog();

      if (lifetime->capture_session) {
        WgcLog::Write("session-close-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        auto session_closable =
          lifetime->capture_session.try_as<ABI::Windows::Foundation::IClosable>();
        if (session_closable) {
          const HRESULT close_hr = session_closable->Close();
          WgcLog::Write(SUCCEEDED(close_hr) ? "session-close-done"
            : "session-close-fail", pool_for_log, HResultDetail("hr", close_hr));
          lifetime->session_closed = SUCCEEDED(close_hr);
        }
        else {
          WgcLog::Write("session-close-done", pool_for_log, "closable=0");
          lifetime->session_closed = true;
        }
        lifetime->capture_session = nullptr;
      }

      if (lifetime->frame_pool) {
        WgcLog::Write("pool-close-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        auto pool_closable =
          lifetime->frame_pool.try_as<ABI::Windows::Foundation::IClosable>();
        if (pool_closable) {
          const HRESULT close_hr = pool_closable->Close();
          WgcLog::Write(SUCCEEDED(close_hr) ? "pool-close-done"
            : "pool-close-fail", pool_for_log, HResultDetail("hr", close_hr));
          lifetime->pool_closed = SUCCEEDED(close_hr);
        }
        else {
          WgcLog::Write("pool-close-done", pool_for_log, "closable=0");
          lifetime->pool_closed = true;
        }
      }

      WgcLog::Write("retire-register-start", pool_for_log,
        GenerationDetail(lifetime->generation));
      FramePoolLifetimeRegistry::Instance().MarkRetired(lifetime);
      WgcLog::Write("retire-register-done", pool_for_log,
        GenerationDetail(lifetime->generation));
    }
  }  // namespace


  void TextureBridge::DeliverFrameLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_ || !lifetime || lifetime != frame_pool_lifetime_ ||
      lifetime->generation != frame_pool_generation_ || lifetime->retiring ||
      !lifetime->frame_pool) {
      if (lifetime && !lifetime->noop_logged) {
        lifetime->noop_logged = true;
        WgcLog::Write("frame-noop", lifetime->PoolForLog(),
          FrameHandlerDetail(lifetime, false, lifetime->retiring, false,
            needs_update_.load()));
      }
      return;
    }

    if (needs_update_) {
      WgcLog::Write("frame-needs-update", lifetime->PoolForLog(),
        FrameHandlerDetail(lifetime, true, lifetime->retiring, false, true));
      needs_update_ = false;
      if (RecreateFramePoolLocked()) {
        return;
      }
    }

    uint64_t seq = 0;
    {
      const std::lock_guard<std::mutex> mailbox_lock(mailbox_->mutex);
      seq = mailbox_->seq;
    }
    if (seq == delivered_seq_) {
      return;
    }
    if (ShouldDropFrame()) {
      // 限帧丢掉的这一帧不记为已上报：取帧线程下一次拷好新帧会再投递。
      return;
    }
    delivered_seq_ = seq;

    if (!lifetime->first_frame_logged) {
      lifetime->first_frame_logged = true;
      WgcLog::Write("frame-first-success", lifetime->PoolForLog(),
        FrameHandlerDetail(lifetime, true, lifetime->retiring, true,
          needs_update_.load()));
    }

    // TODO-618 fix3: 退出态总闸——进程退出期间不再向 Flutter 引擎推送帧，避免在
    // compositor/CustomPlatformView 下游对象拆解期触发 Unknown Hard Error。
    if (IsProcessExiting()) {
      return;
    }

    if (frame_available_) {
      frame_available_();
    }
  }

  bool TextureBridge::ShouldDropFrame()
  {
    if (!frame_duration_.has_value()) {
      return false;
    }
    auto now = std::chrono::high_resolution_clock::now();

    bool should_drop_frame = false;
    if (last_frame_timestamp_.has_value()) {
      auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - last_frame_timestamp_.value());
      should_drop_frame = diff < frame_duration_.value();
    }

    if (!should_drop_frame) {
      last_frame_timestamp_ = now;
    }
    return should_drop_frame;
  }

  void TextureBridge::NotifySurfaceSizeChanged(size_t width, size_t height)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    const bool before = needs_update_.load();
    needs_update_ = true;
    const auto lifetime = frame_pool_lifetime_;
    WgcLog::Write("surface-size-changed",
      lifetime ? lifetime->PoolForLog() : nullptr,
      JoinDetails({
        lifetime ? GenerationDetail(lifetime->generation) : GenerationDetail(0),
        SizeDetail("new_size", width, height),
        lifetime ? SizeDetail("pool_size", lifetime->size) : std::string(),
        BoolDetail("needs_update_before", before),
        BoolDetail("needs_update_after", true),
        PointerDetail("bridge", this),
      }));
    // 尺寸变化后即使取帧线程暂时没有新帧，也让平台线程尽快处理 needs_update_。
    PostDeliveryLocked(lifetime);
  }

  void TextureBridge::SetFpsLimit(std::optional<int> max_fps)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto value = max_fps.value_or(0);
    if (value != 0) {
      frame_duration_ = FrameDuration(1000.0 / value);
    }
    else {
      frame_duration_.reset();
      last_frame_timestamp_.reset();
    }
  }
}

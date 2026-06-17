#include "texture_bridge.h"

#include <windows.foundation.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <iostream>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "util/direct3d11.interop.h"
#include "../utils/wgc_log.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;

  struct WgcFrameArrivedCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    std::weak_ptr<WgcFramePoolLifetime> lifetime;
    uint64_t generation = 0;
    bool active = false;
    bool retiring = false;
    bool in_handler = false;
    bool late_noop_logged = false;
  };

  struct WgcFramePoolLifetime {
    uint64_t generation = 0;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session;
    Microsoft::WRL::ComPtr<WgcFrameArrivedHandler> frame_arrived_handler;
    EventRegistrationToken on_frame_arrived_token = {};
    std::shared_ptr<WgcFrameArrivedCallbackState> callback_state;
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue;
    ABI::Windows::Graphics::SizeInt32 size = { -1, -1 };
    bool registry_retired = false;
    bool inactive = false;
    bool retiring = false;
    bool finalize_posted = false;
    bool remove_done = false;
    bool remove_failed = false;
    bool handler_released = false;
    bool session_closed = false;
    bool pool_closed = false;

    const void* PoolForLog() const
    {
      return frame_pool.get();
    }
  };

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

    std::string ReasonDetail(const char* reason)
    {
      return std::string("reason=") + (reason ? reason : "unknown");
    }

    bool IsClosedFramePoolHResult(HRESULT hr)
    {
      return static_cast<unsigned long>(hr) == 0x80000013UL;
    }

    std::string RegistryCountsDetail(size_t active_count, size_t retired_count)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "active=%zu retired=%zu",
        active_count, retired_count);
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
        lifetime->registry_retired = true;
        WgcLog::Write("registry-size", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked()));
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
    };

    void FinalizeFramePoolLifetime(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
  }  // namespace

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_->add_Closed(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::GraphicsCaptureItem*,
      IInspectable*>>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        })
      .Get(),
          &on_closed_token_);
    WgcLog::Write("create-bridge", this);
  }

  TextureBridge::~TextureBridge()
  {
    WgcLog::Write("dtor-enter", this);
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
    WgcLog::Write("dtor-exit", this);
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    WgcLog::Write("start",
      frame_pool_lifetime_ ? frame_pool_lifetime_->PoolForLog() : nullptr,
      is_running_ ? "running=1" : "running=0");
    if (is_running_ || !capture_item_) {
      return false;
    }

    // BUG-209 第十修（扩展保活到 Start 重入路径）：CustomPlatformView::HandleMethodCall
    // 的 setSize 每次都调 texture_bridge_->Start()（custom_platform_view.cc:323），不止
    // 首帧。is_running_ 守卫只挡「已成功 StartCapture 后的重入」；但若上一轮 Start 在
    // CreateCaptureSession 失败（:179-183 return，不设 is_running_）或 StartCapture 失败
    // （:190 return，不设 is_running_）后早返回，frame_pool_ 已被赋值且已 add_FrameArrived
    // 注册了句柄，is_running_ 仍为 false。下一次 setSize -> Start 越过 is_running_ 守卫，
    // 直接在 :147 用新池**覆盖** frame_pool_ ComPtr——旧池最后强引用归零、内存 free，
    // 但旧池仍挂着已注册的 FrameArrived，其在途 deferred FirePresentEvent 在旧池 free 后
    // 才 fire -> 读 free 内存的 event 成员 -> null delegate -> 同一 0xf0d5 崩点。第九修的
    // 永久保活只覆盖 StopInternal，这条 Start 覆盖路径是它漏掉的池销毁路径之一（dump
    // 81504 的崩溃池 MEM_FREE 且不在 retired-list，正是非 StopInternal 路径释放的池）。
    // 修：覆盖前用与 StopInternal 同一个 RetireFramePoolLocked 不变量先 Close + 退役保活，
    // 绝不让任何挂着在途 deferral 的旧池被裸覆盖释放。
    RetireFramePoolLocked("start");

    if (!CreateAndStartFramePoolLocked()) {
      return false;
    }
    is_running_ = true;
    return true;
  }

  bool TextureBridge::CreateAndStartFramePoolLocked()
  {
    // BUG-209：帧池的创建 + FrameArrived 挂载 + CaptureSession 建立 + StartCapture 收敛进
    // 单一 helper（调用方持 mutex_），供首帧 Start() 与 resize 时的 RecreateFramePoolLocked()
    // 共用——两条路径用完全相同的 WGC 线程模型 / delegate 注册，resize 不再走 Recreate。
    // 进入前 frame_pool_lifetime_ 必为空（调用方已 RetireFramePoolLocked 退役旧池）。
    ABI::Windows::Graphics::SizeInt32 size;
    capture_item_->get_Size(&size);
    auto lifetime = std::make_shared<WgcFramePoolLifetime>();
    lifetime->generation = ++frame_pool_generation_;
    lifetime->size = size;
    lifetime->dispatcher_queue =
      graphics_context_->GetDispatcherQueueForCurrentThread();

    // BUG-163/BUG-209: 帧池必须用 CreateCaptureFramePool（UI 线程 DispatcherQueue
    // 派发，渲染管线线程模型与多年稳定版一致）。FreeThreaded 帧池（第四修）已实证
    // 在 Release 构建下纹理不更新（书籍文字全空，2026-06-10 用户验证 v1 无字 /
    // v2 revert 有字），禁止回潮。teardown 崩溃改由 RetireFramePoolLocked 的
    // 「open pool remove -> handler release -> Close -> lifetime registry」解决。
    lifetime->frame_pool = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    assert(lifetime->frame_pool);
    // TODO-439：active pool 也必须从 create 起进入进程级强保活。v0.9.0.5025 的复发
    // dump 显示崩溃池对应 create-pool 后没有 stop/retire/dtor，只有 running=1 与
    // same-size skip；因此保活不能等到 RetireFramePoolLocked 才发生。先 retain，再挂
    // FrameArrived，保证任何曾注册事件的 pool 都不会 MEM_FREE。
    WgcLog::Write("create-pool", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    FramePoolLifetimeRegistry::Instance().Retain(lifetime);
    WgcLog::Write("active-retain", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));

    auto callback_state = std::make_shared<WgcFrameArrivedCallbackState>();
    {
      const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
      callback_state->bridge = this;
      callback_state->lifetime = lifetime;
      callback_state->generation = lifetime->generation;
      callback_state->active = true;
    }
    lifetime->callback_state = callback_state;

    lifetime->frame_arrived_handler = Microsoft::WRL::Callback<FrameArrivedHandler>(
        [callback_state](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool,
          IInspectable* args) -> HRESULT
        {
          TextureBridge* bridge = nullptr;
          std::shared_ptr<WgcFramePoolLifetime> lifetime;
          bool log_late_noop = false;
          {
            const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
            lifetime = callback_state->lifetime.lock();
            if (callback_state->active && !callback_state->retiring &&
              callback_state->bridge && lifetime) {
              callback_state->in_handler = true;
              bridge = callback_state->bridge;
            }
            else if (!callback_state->late_noop_logged) {
              callback_state->late_noop_logged = true;
              log_late_noop = true;
            }
          }
          if (log_late_noop && lifetime) {
            WgcLog::Write("late-handler-noop", lifetime->PoolForLog(),
              GenerationDetail(lifetime->generation));
          }
          if (bridge && lifetime) {
            bridge->OnFrameArrived(lifetime);
          }
          {
            const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
            callback_state->in_handler = false;
          }
          return S_OK;
        });
    lifetime->frame_pool->add_FrameArrived(lifetime->frame_arrived_handler.Get(),
      &lifetime->on_frame_arrived_token);
    // 新池已 add_FrameArrived（自此挂在途 deferral 风险）。create-pool 与
    // active-retain 已在注册前记录，供崩溃取证对照「崩溃帧池指针」是否从创建起被保活。

    frame_pool_lifetime_ = lifetime;

    if (FAILED(lifetime->frame_pool->CreateCaptureSession(capture_item_.get(),
      lifetime->capture_session.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      // 静默早返回点（不设 is_running_，frame_pool_ 已赋值且已 add_FrameArrived）：
      // 记录可观测，下一次 Start() 入口的 RetireFramePoolLocked 会退役保活此残留池。
      WgcLog::Write("createSession-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      return false;
    }

    const bool started = SUCCEEDED(lifetime->capture_session->StartCapture());
    if (!started) {
      WgcLog::Write("startCapture-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
    }
    return started;
  }

  void TextureBridge::RecreateFramePoolLocked()
  {
    // TODO-428/420 兜底（native 尺寸短路）：即便上层 setSize 风暴穿过 Dart 去抖到达
    // 这里（NotifySurfaceSizeChanged -> needs_update_=true -> 本函数），只要 capture_item_
    // 的实际尺寸与当前帧池建池尺寸完全相等，就没有任何理由重建帧池。SizeInt32 是整数
    // （无浮点抖动），直接整数相等比较。相等则早返回：不退役、不重建（needs_update_ 已在
    // 调用方 OnFrameArrived 清掉），从而即便上层仍抖也不每帧 churn 帧池。尺寸真变（width
    // 或 height 任一不同）才走下面的退役 + 重建，保证 resize 后画面照常更新。
    ABI::Windows::Graphics::SizeInt32 current_size = { 0, 0 };
    const auto lifetime = frame_pool_lifetime_;
    if (capture_item_ && SUCCEEDED(capture_item_->get_Size(&current_size)) &&
      lifetime && lifetime->frame_pool &&
      current_size.Width == lifetime->size.Width &&
      current_size.Height == lifetime->size.Height) {
      WgcLog::Write("recreate-skip-samesize", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      return;
    }

    WgcLog::Write("recreate", lifetime ? lifetime->PoolForLog() : nullptr);
    // BUG-209 第十修（resize 路径替换 frame_pool_->Recreate）：调用方（OnFrameArrived）
    // 持 mutex_。原 Recreate 复用同一帧池只换 back buffer，但会拆掉旧池内部 present 基建，
    // 其在途 deferral 仍指向被拆状态 -> UAF。改为：退役保活旧池（先 remove，再 Close）+
    // 建全新池。旧 CaptureSession 绑在旧池上，随旧池 lifetime finalize 一并 Close。
    RetireFramePoolLocked("recreate");

    // 建新池并 StartCapture。失败则保持 frame_pool_ 为空（已退役旧池），下一次 setSize ->
    // Start() 会再尝试；与旧 Recreate 失败时同样不致崩（OnFrameArrived 开头读 frame_pool_
    // 前已无新帧投递）。注意：CreateAndStartFramePoolLocked 内部若 CreateCaptureSession
    // 失败会留下 frame_pool_ 非空但未启动——由下一次 Start() 入口的 RetireFramePoolLocked
    // 兜底退役保活，不裸释放。
    CreateAndStartFramePoolLocked();
  }

  void TextureBridge::Stop()
  {
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::InvalidateFrameArrivedCallback(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    auto target = lifetime ? lifetime : frame_pool_lifetime_;
    if (!target || !target->callback_state) {
      return;
    }
    auto callback_state = target->callback_state;
    const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
    callback_state->active = false;
    callback_state->retiring = true;
    callback_state->bridge = nullptr;
    target->inactive = true;
    target->retiring = true;
  }

  void TextureBridge::StopInternal()
  {
    auto lifetime = frame_pool_lifetime_;
    WgcLog::Write("stop", lifetime ? lifetime->PoolForLog() : nullptr);
    is_running_ = false;

    // BUG-209（退役帧池永久保活）：dump 决定性根因——已排进 UI 线程
    // CoreMessaging DispatcherQueue 的 deferred FirePresentEvent 不持帧池强引用，
    // 在帧池被释放后才 fire；GraphicsCapture.dll 内部 event::operator() 读已释放的
    // 帧池 event 成员（[framepool+0x60] 的 m_targets）-> 野 delegate 数组 -> null
    // TypedEventHandler -> c0000005（崩在我们 lambda 之前，前七修的 callback_state/
    // ComPtr-release/drain-hop 防线全部够不着；第八修代际释放也被 81504 dump 反证。
    //
    // 当前退役顺序集中在 WgcFramePoolLifetime finalize：
    //   1) inactive/retiring：迟到回调只读 callback_state 并 no-op。
    //   2) remove_FrameArrived(token)：在 frame pool 仍 open 时同步摘掉 event token。
    //   3) remove 成功后释放 handler；remove 异常则保留 token/handler/pool 作异常证据。
    //   4) Close capture session，再 Close frame pool。
    //   5) 同一个 lifetime 在 registry 中从 active 计数转为 retired 计数并永久保活。
    //
    // 因果不变量：任何曾 add_FrameArrived 的帧池都由 registry 保活到进程退出；正常路径
    // 不再 Close 后 remove，因此不再把 RO_E_CLOSED 当作常态；异常路径 fail closed 并留证。
    // StopInternal / Start 重入 / OnFrameArrived resize 三条丢弃/替换路径都走同一套不变量。
    RetireFramePoolLocked("stop");
  }

  void TextureBridge::RetireFramePoolLocked(const char* reason)
  {
    auto lifetime = frame_pool_lifetime_;
    if (!lifetime) {
      return;
    }

    WgcLog::Write("retire", lifetime->PoolForLog(), ReasonDetail(reason));
    WgcLog::Write("state-inactive", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    InvalidateFrameArrivedCallback(lifetime);
    frame_pool_lifetime_ = nullptr;

    bool in_handler = false;
    if (lifetime->callback_state) {
      const std::lock_guard<std::mutex> state_lock(
        lifetime->callback_state->mutex);
      in_handler = lifetime->callback_state->in_handler;
    }

    if (in_handler) {
      WgcLog::Write("retire-defer-in-handler", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      if (lifetime->dispatcher_queue && !lifetime->finalize_posted) {
        auto finalize_handler =
          Microsoft::WRL::Callback<ABI::Windows::System::IDispatcherQueueHandler>(
            [lifetime]() -> HRESULT
            {
              FinalizeFramePoolLifetime(lifetime);
              return S_OK;
            });
        boolean enqueued = false;
        const HRESULT enqueue_hr =
          lifetime->dispatcher_queue->TryEnqueue(finalize_handler.Get(),
            &enqueued);
        if (SUCCEEDED(enqueue_hr) && enqueued) {
          lifetime->finalize_posted = true;
          WgcLog::Write("retire-defer-posted", lifetime->PoolForLog(),
            GenerationDetail(lifetime->generation));
          return;
        }
        WgcLog::Write("retire-defer-keepalive", lifetime->PoolForLog(),
          HResultDetail("hr", enqueue_hr));
        return;
      }
      WgcLog::Write("retire-defer-keepalive", lifetime->PoolForLog(),
        lifetime->dispatcher_queue ? "finalize_posted=1" : "dispatcher_queue=0");
      return;
    }

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
      bool remove_succeeded = false;
      if (lifetime->frame_pool &&
        lifetime->on_frame_arrived_token.value != 0) {
        WgcLog::Write("remove-before-close-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        try {
          const HRESULT remove_hr =
            lifetime->frame_pool->remove_FrameArrived(lifetime->on_frame_arrived_token);
          if (SUCCEEDED(remove_hr)) {
            lifetime->remove_done = true;
            remove_succeeded = true;
            WgcLog::Write("remove-before-close-done", pool_for_log,
              HResultDetail("hr", remove_hr));
            lifetime->on_frame_arrived_token = {};
          }
          else if (IsClosedFramePoolHResult(remove_hr)) {
            lifetime->remove_failed = true;
            WgcLog::Write("remove-before-close-error", pool_for_log,
              HResultDetail("hr", remove_hr));
          }
          else {
            lifetime->remove_failed = true;
            WgcLog::Write("remove-before-close-error", pool_for_log,
              HResultDetail("hr", remove_hr));
          }
        }
        catch (const winrt::hresult_error& error) {
          const HRESULT remove_hr = error.code();
          lifetime->remove_failed = true;
          WgcLog::Write("remove-before-close-error", pool_for_log,
            HResultDetail("hr", remove_hr));
        }
      }
      else if (lifetime->on_frame_arrived_token.value == 0) {
        WgcLog::Write("remove-before-close-skipped", pool_for_log, "token=0");
      }
      else {
        lifetime->remove_failed = true;
        WgcLog::Write("remove-before-close-error", pool_for_log, "pool=0");
      }

      if (remove_succeeded && lifetime->frame_arrived_handler) {
        WgcLog::Write("handler-release-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        lifetime->frame_arrived_handler = nullptr;
        lifetime->handler_released = true;
        WgcLog::Write("handler-release-done", pool_for_log,
          GenerationDetail(lifetime->generation));
      }

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

  void TextureBridge::OnFrameArrived(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_ || !lifetime || lifetime != frame_pool_lifetime_ ||
      lifetime->generation != frame_pool_generation_ || lifetime->retiring ||
      !lifetime->frame_pool) {
      return;
    }

    bool has_frame = false;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    auto hr = lifetime->frame_pool->TryGetNextFrame(frame.put());
    if (FAILED(hr)) {
      // 仅失败时写（成功路径每帧 fire，禁止每帧刷盘）：取帧失败可能预示帧池
      // 状态异常，是观测帧池生命周期的低噪声信号。
      WgcLog::Write("frame-getfail", lifetime->PoolForLog(),
        HResultDetail("hr", hr));
    }
    if (SUCCEEDED(hr) && frame) {
      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;

      if (SUCCEEDED(frame->get_Surface(frame_surface.put()))) {
        last_frame_ =
          TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
        has_frame = !ShouldDropFrame();
      }
    }

    if (needs_update_) {
      // BUG-209 第十修（覆盖 resize 这条之前漏的帧池替换路径）：原先用帧池的 Recreate
      // 方法在 surface resize 时复用同一帧池 COM 对象、只换内部 back buffer。问题是
      // Recreate 会同步拆掉旧池的内部 present 基建（旧的 swap-chain / present 子对象），
      // 而此前已排进 UI 线程 CoreMessaging 队列、尚未 fire 的 deferred FirePresentEvent
      // 仍指向被拆的旧内部状态——它之后 fire 时读已释放的 event 成员 -> null delegate ->
      // 同一 0xf0d5 崩点。该方法不走退役保活，是 dump 81504 之外另一条
      // 「帧池（内部状态）被释放而在途 deferral 仍在途」的窗口。
      //
      // 改为：把旧帧池 lifetime 标成 inactive/retiring，在 open pool 上 remove token，
      // 成功后释放 handler，再 Close session/pool 并把同一个 lifetime 标成 retired 保活；
      // 如果当前就在 FrameArrived handler 栈内，finalize 投递到同一 DispatcherQueue 下一拍。
      needs_update_ = false;
      RecreateFramePoolLocked();
    }

    if (has_frame && frame_available_) {
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

  void TextureBridge::NotifySurfaceSizeChanged()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    needs_update_ = true;
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

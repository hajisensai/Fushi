#include "texture_bridge.h"

#include <windows.foundation.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>

#include "util/direct3d11.interop.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;

  // BUG-163 保序销毁：连续多少个「安静」的 Low 优先级 hop（期间没有任何
  // FrameArrived fire 过）之后才真正 Close+释放捕获资源。2 = PM 要求的
  // 「延迟两帧」保底：第 1 个 hop 覆盖 teardown 前已排队的全部
  // FirePresentEvent，第 2 个 hop 覆盖 teardown 与第 1 个 hop 之间由捕获
  // 通道线程迟到 post 的事件。
  constexpr int kCaptureTeardownQuietHops = 2;

  struct TextureBridge::FrameArrivedCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    bool active = false;
    // 每次 FrameArrived delegate 被 invoke（无论 active 与否）都自增；
    // 保序销毁 hop 用它判定「上一跳以来是否还有迟到帧 fire」。
    uint64_t frame_events = 0;
  };

  // BUG-163：teardown 时捕获资源的延迟销毁 holder。帧池、注册在它身上的
  // FrameArrived delegate、以及 delegate 捕获的回调状态必须作为一组整体
  // 活过所有已排队的 FirePresentEvent，之后才能 Close/释放。
  struct TextureBridge::PendingCaptureTeardown {
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    Microsoft::WRL::ComPtr<FrameArrivedHandler> frame_arrived_handler;
    std::shared_ptr<FrameArrivedCallbackState> callback_state;
  };

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
  }

  TextureBridge::~TextureBridge()
  {
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (is_running_ || !capture_item_) {
      return false;
    }

    ABI::Windows::Graphics::SizeInt32 size;
    capture_item_->get_Size(&size);

    // BUG-163: 帧池必须用 CreateCaptureFramePool（UI 线程 DispatcherQueue 派发，
    // 渲染管线线程模型与多年稳定版一致）。FreeThreaded 帧池（第四修）已实证
    // 在 Release 构建下纹理不更新（书籍文字全空，2026-06-10 用户验证 v1 无字 /
    // v2 revert 有字），禁止回潮。崩溃改由下方保序销毁解决。
    //
    // 同时捕获本线程的 DispatcherQueue：WGC 把 FirePresentEvent 作为 deferred
    // call 排进「调用 Create 时的当前线程队列」，teardown 的延迟释放 hop 必须
    // 排进同一个队列才有保序语义。
    dispatcher_queue_ = graphics_context_->GetDispatcherQueueForCurrentThread();

    frame_pool_ = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    assert(frame_pool_);

    auto callback_state = std::make_shared<FrameArrivedCallbackState>();
    {
      const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
      callback_state->bridge = this;
      callback_state->active = true;
    }
    frame_arrived_state_ = callback_state;

    frame_arrived_handler_ = Microsoft::WRL::Callback<FrameArrivedHandler>(
        [callback_state](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool,
          IInspectable* args) -> HRESULT
        {
          const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
          // 计数在 active 判定之前：teardown 后的迟到帧也要被保序销毁 hop
          // 观测到（见 EnqueueCaptureTeardownHop 的 quiet-hop 判定）。
          callback_state->frame_events++;
          if (callback_state->active && callback_state->bridge) {
            callback_state->bridge->OnFrameArrived();
          }
          return S_OK;
        });
    frame_pool_->add_FrameArrived(frame_arrived_handler_.Get(),
      &on_frame_arrived_token_);

    if (FAILED(frame_pool_->CreateCaptureSession(capture_item_.get(),
      capture_session_.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      return false;
    }

    if (SUCCEEDED(capture_session_->StartCapture())) {
      is_running_ = true;
      return true;
    }

    return false;
  }

  void TextureBridge::Stop()
  {
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::InvalidateFrameArrivedCallback()
  {
    auto callback_state = frame_arrived_state_;
    if (!callback_state) {
      return;
    }
    const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
    callback_state->active = false;
    callback_state->bridge = nullptr;
  }

  void TextureBridge::StopInternal()
  {
    is_running_ = false;
    if (capture_session_) {
      auto session_closable =
        capture_session_.try_as<ABI::Windows::Foundation::IClosable>();
      if (session_closable) {
        session_closable->Close();
      }
      capture_session_ = nullptr;
    }
    // BUG-113/BUG-163 (TODO-031 第五修): 保序销毁——teardown 当下绝不 Close/
    // 释放帧池，也不注销 FrameArrived 句柄。
    //
    // 崩溃机理（9:34 三防线构建 11:53 仍崩的 dump 实证）：WGC 把每个
    // FirePresentEvent 作为 deferred call 排进创建帧池线程（UI 线程）的
    // CoreMessaging DispatcherQueue（dump 栈 DeferredCall::Callback_Dispatch →
    // FirePresentEvent；CreateDispatcherQueueController 本身就是
    // CoreMessaging.dll 的导出，Windows.System.DispatcherQueue 与该队列同体）。
    // 一个已排队、持帧池强引用的 FirePresentEvent 会在 teardown 之后才 fire
    // （FirePresentEvent+0x62 本体跑通了，帧池对象还活着）；但 teardown 当下的
    // Close()/释放已撤销 WGC 内部 delegate 表/agile-ref，事件遍历到被撤销的
    // delegate → null TypedEventHandler → 直接 invoke → operator()+0x15 处
    // c0000005。崩溃点在我们 lambda body 之前，callback_state/持有 handler/
    // 析构顺序三防线全部够不着。
    //
    // 因此把 frame_pool_ / frame_arrived_handler_ / callback_state 的所有权
    // 整组移交 PendingCaptureTeardown holder，经同一 DispatcherQueue 以 Low
    // 优先级排释放 hop（ScheduleCaptureTeardown）：已排队事件先于释放执行，
    // 此时 active=false 安全返回。capture_session_ 已在上方 Close()，新帧
    // 必然停止，协议必然终止。FrameArrived 注册随帧池 Close 一起失效，
    // 全程不手动注销该句柄。
    ScheduleCaptureTeardown();
  }

  void TextureBridge::ScheduleCaptureTeardown()
  {
    if (!frame_pool_) {
      return;
    }
    auto pending = std::make_shared<PendingCaptureTeardown>();
    pending->frame_pool = std::move(frame_pool_);
    pending->frame_arrived_handler = std::move(frame_arrived_handler_);
    pending->callback_state = frame_arrived_state_;
    // std::move 已把成员置空；显式写出便于审计「帧池已离开 bridge，
    // bridge 析构不再触碰捕获资源」。
    frame_pool_ = nullptr;
    EnqueueCaptureTeardownHop(dispatcher_queue_, std::move(pending),
      kCaptureTeardownQuietHops);
  }

  // static
  uint64_t TextureBridge::ReadFrameEventCount(
    const std::shared_ptr<FrameArrivedCallbackState>& state)
  {
    if (!state) {
      return 0;
    }
    const std::lock_guard<std::mutex> state_lock(state->mutex);
    return state->frame_events;
  }

  // static
  void TextureBridge::EnqueueCaptureTeardownHop(
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue,
    std::shared_ptr<PendingCaptureTeardown> pending,
    int quiet_hops_remaining)
  {
    if (!dispatcher_queue) {
      // 理论上不可达：CreateCaptureFramePool 要求创建线程有 DispatcherQueue
      // （InAppWebViewManager 构造时已创建 controller）。没有队列就没有
      // deferred FirePresentEvent，立即释放是安全的。
      FinalizeCaptureTeardown(pending);
      return;
    }

    const uint64_t observed_events = ReadFrameEventCount(pending->callback_state);
    auto hop = Microsoft::WRL::Callback<ABI::Windows::System::IDispatcherQueueHandler>(
      [dispatcher_queue, pending, quiet_hops_remaining,
        observed_events]() -> HRESULT
      {
        const uint64_t now = ReadFrameEventCount(pending->callback_state);
        // 上一跳以来还有迟到帧 fire 过 → 重新从头计安静跳数；
        // 安静则倒数，归零才真正释放。session 已 Close，事件必然停止，
        // 计数必然收敛，无 sleep 无轮询。
        const int next_quiet_hops = now == observed_events
          ? quiet_hops_remaining - 1
          : kCaptureTeardownQuietHops;
        if (next_quiet_hops <= 0) {
          FinalizeCaptureTeardown(pending);
        }
        else {
          EnqueueCaptureTeardownHop(dispatcher_queue, pending, next_quiet_hops);
        }
        return S_OK;
      });

    // Low 优先级：文档保证队列 serially and in priority order 派发，Low 只在
    // 没有任何 Normal/High 待处理工作时运行、且会被新进 Normal/High 抢占——
    // 所以只要队列里还有（哪怕晚于本 hop 入队的）Normal 优先级的
    // FirePresentEvent，释放就不会执行。不依赖 WGC 用什么优先级 post。
    boolean enqueued = false;
    const HRESULT hr = dispatcher_queue->TryEnqueueWithPriority(
      ABI::Windows::System::DispatcherQueuePriority_Low, hop.Get(), &enqueued);
    if (FAILED(hr) || !enqueued) {
      // TryEnqueue 仅在队列 shutdown 后返回 false；shutdown 的队列不再派发
      // 任何任务（包括已排队的 FirePresentEvent），内联释放安全且不泄漏。
      FinalizeCaptureTeardown(pending);
    }
  }

  // static
  void TextureBridge::FinalizeCaptureTeardown(
    const std::shared_ptr<PendingCaptureTeardown>& pending)
  {
    if (!pending) {
      return;
    }
    if (pending->frame_pool) {
      auto pool_closable =
        pending->frame_pool.try_as<ABI::Windows::Foundation::IClosable>();
      if (pool_closable) {
        pool_closable->Close();
      }
      pending->frame_pool = nullptr;
    }
    pending->frame_arrived_handler = nullptr;
    pending->callback_state = nullptr;
  }

  void TextureBridge::OnFrameArrived()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_) {
      return;
    }

    bool has_frame = false;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    auto hr = frame_pool_->TryGetNextFrame(frame.put());
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
      ABI::Windows::Graphics::SizeInt32 size;
      capture_item_->get_Size(&size);
      frame_pool_->Recreate(
        graphics_context_->device(),
        static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
          kPixelFormat),
        kNumBuffers, size);
      needs_update_ = false;
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

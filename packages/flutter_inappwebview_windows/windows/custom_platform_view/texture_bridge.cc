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

  struct TextureBridge::FrameArrivedCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    bool active = false;
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
    // v2 revert 有字），禁止回潮。崩溃改由下方 ComPtr-release 销毁序解决。
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
          // teardown 后迟到 fire 的 deferred FirePresentEvent：active 已被
          // InvalidateFrameArrivedCallback 置 false，安全 no-op 返回，不触碰
          // 已失效的 bridge（revoke 前后窗口内万一 fire 的兜底防线）。
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

    // BUG-113/BUG-163 方向B（ComPtr-release 销毁序）：先同步断源，再释放我们
    // 持有的 ComPtr，**绝不对帧池显式调用 IClosable::Close()**。
    //
    // 崩溃机理（9:34 三防线构建、11:53 仍崩的 dump 实证）：WGC 把每个
    // FirePresentEvent 作为 deferred call 排进创建帧池线程（UI 线程）的
    // CoreMessaging DispatcherQueue（dump 栈 DeferredCall::Callback_Dispatch ->
    // FirePresentEvent；CreateDispatcherQueueController 是 CoreMessaging.dll 的
    // 导出，Windows.System.DispatcherQueue 与该队列同体）。一个已排队、持帧池
    // 强引用的 FirePresentEvent 会在 teardown 之后才 fire；旧修在 teardown 当下
    // Close()/释放，撤销了 WGC 内部 delegate 表/agile-ref，事件遍历到被撤销的
    // delegate -> null TypedEventHandler -> operator()+0x15 处 c0000005。崩点在
    // 我们 lambda body 之前，callback_state/持有 handler/析构顺序三防线全部够不着。
    //
    // 第五修（drain-hop）的缺陷：以 callback_state->frame_events 计数判定「在途
    // 帧已排空」，但 revoke 已把我们的 lambda 从 WGC 表移除，计数器对 revoke 后
    // 在途的 deferred FirePresentEvent 结构性失明 —— 它们不再 invoke 我们的
    // lambda，frame_events 不再自增，2 跳必然立刻 Close；且 deferred
    // FirePresentEvent 走 CoreMessaging deferral 轨道，不保证与 TryEnqueue 任务
    // FIFO 互序。存在「drain 收敛已 Close、仍有 deferral 在 Close 后才 fire」的
    // 非空窗口。git 史决定性反证：fork 引入前上游 StopInternal 做的正是「同步
    // remove_FrameArrived 紧跟同步 Close() 帧池」—— 它崩了（BUG-113），崩的是
    // 紧跟的显式 Close()，不是 revoke。
    //
    // ComPtr-release 把概率窗口变成因果不变量，三步：
    //   1) 先 Close session：停止产生新帧（同步）。
    //   2) frame_pool_->remove_FrameArrived(token)：同步从 WGC 内部 event delegate
    //      表移除我们这一项。返回后 WGC 不再向该 token 投递新的 FirePresentEvent。
    //      此时帧池仍存活、delegate 表内存有效 —— revoke 不留野指针，只把我们的项
    //      从有效表里摘掉（standard WinRT event 在 remove 时安全修改列表、fire 期
    //      用快照）。这是 null-delegate 崩溃的根除点。
    //   3) frame_pool_ = nullptr：仅释放我们这一份 ComPtr 强引用，**不显式 Close**。
    //      在途 deferred FirePresentEvent 对帧池持强引用（11:53 dump 实证
    //      「FirePresentEvent 本体跑通帧池还活着」+ WinRT 异步事件 raise 期对
    //      source 持引用）。因此帧池的真正析构（COM 引用计数归零 -> 内部自然 Close）
    //      只会发生在最后一个在途 deferral 跑完之后 —— 那一刻已无任何在途事件在
    //      迭代 delegate 表，不可能出现 Close-while-in-flight。
    //
    // 因果不变量：只要我们绝不显式 Close 帧池，「Close（=析构）发生」就在因果上
    // 必然晚于「所有在途 deferral 释放其强引用」，即所有在途事件已 fire 完。
    // 没有任何「2 跳已 Close 但仍有 deferral」的赌注窗口。
    if (capture_session_) {
      auto session_closable =
        capture_session_.try_as<ABI::Windows::Foundation::IClosable>();
      if (session_closable) {
        session_closable->Close();
      }
      capture_session_ = nullptr;
    }

    if (frame_pool_ && on_frame_arrived_token_.value != 0) {
      // 同步 revoke：返回后 WGC 不再向本 token 投递新 FirePresentEvent。
      // 帧池此刻仍存活，移除只动有效 delegate 表，不产生野指针。
      frame_pool_->remove_FrameArrived(on_frame_arrived_token_);
      on_frame_arrived_token_ = {};
    }

    // 仅释放我们的 ComPtr，绝不显式 Close 帧池：在途 deferral 的强引用会把真正
    // 析构（-> 自然 Close）延到它跑完。我们的 FrameArrived delegate ComPtr 同理
    // 只释放。frame_arrived_state_ 保留（active 已被 InvalidateFrameArrivedCallback
    // 置 false），让 revoke 前后窗口内万一 fire 的 lambda 安全 no-op。
    frame_pool_ = nullptr;
    frame_arrived_handler_ = nullptr;
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

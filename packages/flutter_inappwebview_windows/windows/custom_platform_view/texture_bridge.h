#pragma once

#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.system.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "graphics_context.h"

namespace flutter_inappwebview_plugin
{
  // TODO-618 fix3: 进程级退出态总闸。
  //
  // 退出（prepareForProcessExit / 关窗）期间，先于 webViews.clear 把此闸置位；之后所有
  // TextureBridge 的 WGC 帧上报回调（frame_available_）一律短路早返回，避免在 compositor /
  // CustomPlatformView 下游对象已开始拆解时再把帧推给 Flutter 引擎，触发退出期
  // Unknown Hard Error。纯防御早返回，不改既有 teardown 顺序。
  //
  // 声明在头文件（external linkage），供 in_app_webview_manager.cpp 在 prepareForProcessExit
  // 入口调用 SetProcessExiting()；定义在 texture_bridge.cc。
  void SetProcessExiting() noexcept;
  bool IsProcessExiting() noexcept;

  using WgcPumpTickHandler = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::System::DispatcherQueueTimer*, IInspectable*>;
  using WgcCaptureItemClosedHandler = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::Graphics::Capture::GraphicsCaptureItem*, IInspectable*>;

  struct WgcPumpCallbackState;
  struct WgcFramePoolLifetime;

  typedef struct {
    size_t width;
    size_t height;
  } Size;

  class TextureBridge {
  public:
    typedef std::function<void()> FrameAvailableCallback;
    typedef std::function<void(Size size, float capture_scale_factor,
      float device_scale_factor)>
      SurfaceSizeChangedCallback;
    typedef std::chrono::duration<double, std::milli> FrameDuration;

    TextureBridge(GraphicsContext* graphics_context,
      ABI::Windows::UI::Composition::IVisual* visual);
    virtual ~TextureBridge();

    bool Start();
    void Stop();

    void SetOnFrameAvailable(FrameAvailableCallback callback)
    {
      frame_available_ = std::move(callback);
    }

    void SetOnSurfaceSizeChanged(SurfaceSizeChangedCallback callback)
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      surface_size_changed_ = std::move(callback);
    }

    // Flutter 平台视图的逻辑尺寸与 DPI。GPU bridge 会原子记录换算后的目标物理
    // 像素尺寸，再用回调驱动 WebView2 surface；WGC 的尺寸通知不会反写目标尺寸。
    virtual void SetOutputSize(size_t width, size_t height, float scale_factor)
    {
      if (width == 0 || height == 0 || scale_factor <= 0.0f) {
        return;
      }

      SurfaceSizeChangedCallback callback;
      {
        const std::lock_guard<std::mutex> lock(mutex_);
        if (requested_surface_size_.width == width &&
          requested_surface_size_.height == height &&
          requested_scale_factor_ == scale_factor) {
          return;
        }
        requested_surface_size_ = { width, height };
        requested_scale_factor_ = scale_factor;
        callback = surface_size_changed_;
      }
      if (callback) {
        callback({ width, height }, scale_factor, scale_factor);
      }
    }

    void NotifySurfaceSizeChanged(size_t width, size_t height);
    void SetFpsLimit(std::optional<int> max_fps);

    // 计划 P2：mpv 用户着色器链（.glsl 文本，按序）。空 = 直通。只有 GPU 桥实现；
    // 回 true = 全部解析成功并已启用。
    virtual bool SetShaders(const std::vector<std::string>& shader_texts) { return false; }

  protected:
    typedef WgcPumpTickHandler PumpTickHandler;
    typedef WgcCaptureItemClosedHandler CaptureItemClosedHandler;

    bool is_running_ = false;

    const GraphicsContext* graphics_context_;
    std::mutex mutex_;
    std::optional<FrameDuration> frame_duration_ = std::nullopt;

    FrameAvailableCallback frame_available_;
    SurfaceSizeChangedCallback surface_size_changed_;
    Size requested_surface_size_ = { 0, 0 };
    float requested_scale_factor_ = 0.0f;
    std::atomic<bool> needs_update_ = false;
    winrt::com_ptr<ID3D11Texture2D> last_frame_;
    std::optional<std::chrono::high_resolution_clock::time_point>
      last_frame_timestamp_;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item_;
    Microsoft::WRL::ComPtr<CaptureItemClosedHandler>
      capture_item_closed_handler_;
    std::shared_ptr<WgcFramePoolLifetime> frame_pool_lifetime_;
    uint64_t frame_pool_generation_ = 0;

    EventRegistrationToken on_closed_token_ = {};

    void InvalidatePumpCallback(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime = nullptr);
    virtual void StopInternal();
    // Default WGC capture does not subscribe to FrameArrived. Every path that
    // drops/replaces a pool first stops the UI timer pump, removes Tick, clears
    // callback state, then closes the session/pool and retires the lifetime.
    void RetireFramePoolLocked(const char* reason);
    bool CreateAndStartFramePoolLocked();
    void RecreateFramePoolLocked();
    bool StartPumpLocked(const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
    void StopPumpLocked(const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
      const char* reason);
    void PumpFrameLocked(const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
    bool ShouldDropFrame();

    // corresponds to DXGI_FORMAT_B8G8R8A8_UNORM
    static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
  };
}

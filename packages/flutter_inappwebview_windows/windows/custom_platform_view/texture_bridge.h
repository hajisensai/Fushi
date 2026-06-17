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

#include "graphics_context.h"

namespace flutter_inappwebview_plugin
{
  using WgcFrameArrivedHandler = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::Graphics::Capture::Direct3D11CaptureFramePool*,
    IInspectable*>;

  struct WgcFrameArrivedCallbackState;
  struct WgcFramePoolLifetime;

  typedef struct {
    size_t width;
    size_t height;
  } Size;

  class TextureBridge {
  public:
    typedef std::function<void()> FrameAvailableCallback;
    typedef std::function<void(Size size)> SurfaceSizeChangedCallback;
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
      surface_size_changed_ = std::move(callback);
    }

    void NotifySurfaceSizeChanged();
    void SetFpsLimit(std::optional<int> max_fps);

  protected:
    typedef WgcFrameArrivedHandler FrameArrivedHandler;

    bool is_running_ = false;

    const GraphicsContext* graphics_context_;
    std::mutex mutex_;
    std::optional<FrameDuration> frame_duration_ = std::nullopt;

    FrameAvailableCallback frame_available_;
    SurfaceSizeChangedCallback surface_size_changed_;
    std::atomic<bool> needs_update_ = false;
    winrt::com_ptr<ID3D11Texture2D> last_frame_;
    std::optional<std::chrono::high_resolution_clock::time_point>
      last_frame_timestamp_;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item_;
    std::shared_ptr<WgcFramePoolLifetime> frame_pool_lifetime_;
    uint64_t frame_pool_generation_ = 0;

    EventRegistrationToken on_closed_token_ = {};

    void InvalidateFrameArrivedCallback(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime = nullptr);
    virtual void StopInternal();
    // BUG-209/TODO-439：所有「丢弃/替换 frame_pool_」的路径（StopInternal teardown、
    // Start 重入覆盖、OnFrameArrived resize）统一走这套退役保活不变量——
    // inactive/retiring -> open pool remove_FrameArrived -> release handler ->
    // Close session/pool -> 同一个 lifetime 从 active registry 标成 retired。
    // handler 回调栈内退役只标记/投递到同一 DispatcherQueue 下一拍 finalize，避免 event
    // 迭代重入；若投递失败则保留 token/handler/session/pool 存活作异常证据，不伪造闭合。
    // remove 异常同样保留 token/handler/pool 作证据。
    // 绝不裸释放任何曾经 add_FrameArrived 的帧池。调用方须持 mutex_。
    void RetireFramePoolLocked(const char* reason);
    // 创建帧池 + 挂 FrameArrived + 建 CaptureSession + StartCapture，Start 与
    // RecreateFramePoolLocked 共用；返回是否 StartCapture 成功。调用方须持 mutex_。
    bool CreateAndStartFramePoolLocked();
    // resize 时退役旧池 + 重建会话 + 建全新池，取代 frame_pool_->Recreate（其会拆掉旧池
    // 内部 present 基建而在途 deferral 仍指向旧状态 -> UAF）。调用方须持 mutex_。
    void RecreateFramePoolLocked();
    void OnFrameArrived(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
    bool ShouldDropFrame();

    // corresponds to DXGI_FORMAT_B8G8R8A8_UNORM
    static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
  };
}

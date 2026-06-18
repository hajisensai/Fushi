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

    void NotifySurfaceSizeChanged(size_t width, size_t height);
    void SetFpsLimit(std::optional<int> max_fps);

  protected:
    typedef WgcPumpTickHandler PumpTickHandler;
    typedef WgcCaptureItemClosedHandler CaptureItemClosedHandler;

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

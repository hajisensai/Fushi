#pragma once

#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.system.h>
#include <wrl.h>

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>

#include "graphics_context.h"

namespace flutter_inappwebview_plugin
{
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
    typedef ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::Direct3D11CaptureFramePool*,
      IInspectable*> FrameArrivedHandler;

    struct FrameArrivedCallbackState;

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
    Microsoft::WRL::ComPtr<FrameArrivedHandler> frame_arrived_handler_;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool_;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session_;

    // TODO-428/420 兜底：当前帧池建池时用的 capture_item_ 尺寸（SizeInt32 整数，无
    // 浮点抖动）。RecreateFramePoolLocked 据此短路——上层 setSize 风暴即便穿过 Dart
    // 去抖到达这里（NotifySurfaceSizeChanged -> needs_update_=true），若 capture_item_
    // 的实际尺寸与帧池现有尺寸相等就不重建，只消耗掉 needs_update_。仅 -1 视为「未建池」。
    ABI::Windows::Graphics::SizeInt32 frame_pool_size_ = { -1, -1 };

    EventRegistrationToken on_closed_token_ = {};
    EventRegistrationToken on_frame_arrived_token_ = {};
    std::shared_ptr<FrameArrivedCallbackState> frame_arrived_state_;

    void InvalidateFrameArrivedCallback();
    virtual void StopInternal();
    // BUG-209 第十修：所有「丢弃/替换 frame_pool_」的路径（StopInternal teardown、
    // Start 重入覆盖、OnFrameArrived resize）统一走这套退役保活不变量——
    // remove_FrameArrived 断源 -> Close 设 closed-flag -> 移交退役注册表永久保活，
    // 绝不裸释放任何曾经 add_FrameArrived 的帧池。调用方须持 mutex_。
    void RetireFramePoolLocked();
    // 创建帧池 + 挂 FrameArrived + 建 CaptureSession + StartCapture，Start 与
    // RecreateFramePoolLocked 共用；返回是否 StartCapture 成功。调用方须持 mutex_。
    bool CreateAndStartFramePoolLocked();
    // resize 时退役旧池 + 重建会话 + 建全新池，取代 frame_pool_->Recreate（其会拆掉旧池
    // 内部 present 基建而在途 deferral 仍指向旧状态 -> UAF）。调用方须持 mutex_。
    void RecreateFramePoolLocked();
    void OnFrameArrived();
    bool ShouldDropFrame();

    // corresponds to DXGI_FORMAT_B8G8R8A8_UNORM
    static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
  };
}

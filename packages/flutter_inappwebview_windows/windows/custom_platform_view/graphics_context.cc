#include "graphics_context.h"

#include <d3d11_4.h>

#include "util/d3dutil.h"
#include "util/direct3d11.interop.h"

namespace flutter_inappwebview_plugin
{
  GraphicsContext::GraphicsContext(rx::RoHelper* rohelper) : rohelper_(rohelper)
  {
    device_ = CreateD3DDevice();
    if (!device_) {
      return;
    }

    device_->GetImmediateContext(device_context_.put());
    // BUG-4079：WGC 取帧线程（每个帧池一条）与 Flutter 栅格线程都在这个立即上下文
    // 上提交拷贝。打开 D3D11 的多线程保护，让每次调用在设备内部串行化；取帧线程只
    // 发不依赖管线状态的 CopySubresourceRegion / Flush，不会和栅格线程的着色器管线
    // 状态互相踩。
    if (auto multithread = device_context_.try_as<ID3D11Multithread>()) {
      multithread->SetMultithreadProtected(TRUE);
    }
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(
      device_.try_as<IDXGIDevice>().get(),
      (IInspectable**)device_winrt_.put()))) {
      return;
    }

    valid_ = true;
  }

  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor>
    GraphicsContext::CreateCompositor()
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_UI_Composition_Compositor, &className,
      &classNameHeader))) {
      return nullptr;
    }

    winrt::com_ptr<IActivationFactory> af;
    if (FAILED(rohelper_->GetActivationFactory(
      className, __uuidof(IActivationFactory), af.put_void()))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor;
    if (FAILED(af->ActivateInstance(
      reinterpret_cast<IInspectable**>(compositor.put())))) {
      return nullptr;
    }

    return compositor;
  }

  winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
    GraphicsContext::CreateGraphicsCaptureItemFromVisual(
      ABI::Windows::UI::Composition::IVisual* visual) const
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem, &className,
      &classNameHeader))) {
      return nullptr;
    }

    ABI::Windows::Graphics::Capture::IGraphicsCaptureItemStatics*
      capture_item_statics;
    if (FAILED(rohelper_->GetActivationFactory(
      className,
      __uuidof(
        ABI::Windows::Graphics::Capture::IGraphicsCaptureItemStatics),
      (void**)&capture_item_statics))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item;
    if (FAILED(
      capture_item_statics->CreateFromVisual(visual, capture_item.put()))) {
      return nullptr;
    }

    return capture_item;
  }

  winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
    GraphicsContext::CreateCaptureFramePool(
      ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice* device,
      ABI::Windows::Graphics::DirectX::DirectXPixelFormat pixelFormat,
      INT32 numberOfBuffers, ABI::Windows::Graphics::SizeInt32 size) const
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
      &className, &classNameHeader))) {
      return nullptr;
    }

    ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics*
      capture_frame_pool_statics;
    if (FAILED(rohelper_->GetActivationFactory(
      className,
      __uuidof(ABI::Windows::Graphics::Capture::
        IDirect3D11CaptureFramePoolStatics),
      (void**)&capture_frame_pool_statics))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      capture_frame_pool;

    if (FAILED(capture_frame_pool_statics->Create(device, pixelFormat,
      numberOfBuffers, size,
      capture_frame_pool.put()))) {
      return nullptr;
    }

    return capture_frame_pool;
  }

  winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
    GraphicsContext::CreateFreeThreadedCaptureFramePool(
      ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice* device,
      ABI::Windows::Graphics::DirectX::DirectXPixelFormat pixelFormat,
      INT32 numberOfBuffers, ABI::Windows::Graphics::SizeInt32 size) const
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
      &className, &classNameHeader))) {
      return nullptr;
    }

    ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics2*
      capture_frame_pool_statics;
    if (FAILED(rohelper_->GetActivationFactory(
      className,
      __uuidof(ABI::Windows::Graphics::Capture::
        IDirect3D11CaptureFramePoolStatics2),
      (void**)&capture_frame_pool_statics))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      capture_frame_pool;

    if (FAILED(capture_frame_pool_statics->CreateFreeThreaded(
      device, pixelFormat, numberOfBuffers, size,
      capture_frame_pool.put()))) {
      return nullptr;
    }

    return capture_frame_pool;
  }

  winrt::com_ptr<ABI::Windows::System::IDispatcherQueue>
    GraphicsContext::GetDispatcherQueueForCurrentThread() const
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_System_DispatcherQueue, &className,
      &classNameHeader))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::System::IDispatcherQueueStatics>
      dispatcher_queue_statics;
    if (FAILED(rohelper_->GetActivationFactory(
      className,
      __uuidof(ABI::Windows::System::IDispatcherQueueStatics),
      dispatcher_queue_statics.put_void()))) {
      return nullptr;
    }

    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue;
    if (FAILED(dispatcher_queue_statics->GetForCurrentThread(
      dispatcher_queue.put()))) {
      return nullptr;
    }

    return dispatcher_queue;
  }
}
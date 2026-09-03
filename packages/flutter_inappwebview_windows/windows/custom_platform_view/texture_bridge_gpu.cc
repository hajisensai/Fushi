#include "texture_bridge_gpu.h"

#include <iostream>
#include <limits>

#include "util/direct3d11.interop.h"
#ifdef HAVE_LIBPLACEBO_HEADERS
#include "placebo_pass.h"
#endif

namespace flutter_inappwebview_plugin
{
  namespace
  {
    constexpr float kShaderUpscaleFactor = 2.0f;
  }

  TextureBridgeGpu::TextureBridgeGpu(
    GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : TextureBridge(graphics_context, visual)
  {
    surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    surface_descriptor_.format =
      kFlutterDesktopPixelFormatNone;  // no format required for DXGI surfaces
  }

  TextureBridgeGpu::~TextureBridgeGpu() = default;

  void TextureBridgeGpu::SetOutputSize(
    size_t width, size_t height, float scale_factor)
  {
    const double physical_width = width * static_cast<double>(scale_factor);
    const double physical_height = height * static_cast<double>(scale_factor);
    if (width == 0 || height == 0 || scale_factor <= 0.0f ||
      physical_width < 1.0 || physical_height < 1.0 ||
      physical_width > (std::numeric_limits<uint32_t>::max)() ||
      physical_height > (std::numeric_limits<uint32_t>::max)()) {
      return;
    }

    SurfaceSizeChangedCallback callback;
    float capture_scale_factor = scale_factor;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      const Size next_size = { static_cast<size_t>(physical_width),
        static_cast<size_t>(physical_height) };
      if (requested_surface_size_.width == width &&
        requested_surface_size_.height == height &&
        requested_scale_factor_ == scale_factor) {
        return;
      }
      requested_surface_size_ = { width, height };
      requested_scale_factor_ = scale_factor;
      if (output_size_.width != next_size.width ||
        output_size_.height != next_size.height) {
        output_size_ = next_size;
        scale_failure_logged_ = false;
      }
#ifdef HAVE_LIBPLACEBO_HEADERS
      if (placebo_ && placebo_->enabled()) {
        capture_scale_factor = scale_factor / kShaderUpscaleFactor;
      }
#endif
      callback = surface_size_changed_;
    }

    // 回调可能同步触发 InAppWebView::onSurfaceSizeChanged ->
    // NotifySurfaceSizeChanged（同一把 mutex_），必须在锁外调用。
    if (callback) {
      callback({ width, height }, capture_scale_factor, scale_factor);
    }
  }

  void TextureBridgeGpu::ProcessFrame(
    winrt::com_ptr<ID3D11Texture2D> src_texture)
  {
    D3D11_TEXTURE2D_DESC desc;
    src_texture->GetDesc(&desc);

    // BUG-1976 — output_size_ is allowed to differ from the WGC source only
    // while a shader chain is deliberately capturing below device DPR for an
    // upscale pass.  Flutter's texture callback and the method-channel layout
    // report can otherwise disagree by one physical pixel at fractional DPI
    // (for example 150%).  Treating that harmless rounding residue as an
    // upscale request sent every ordinary WebView — including dictionary text
    // — through libplacebo and softened the whole surface after 5d3feac4cd.
    //
    // With no shader, preserve the pre-upscale contract exactly: allocate the
    // destination at the captured texture's size and CopyResource 1:1.  Flutter
    // composites that native-density descriptor without a second filter pass.
    bool shader_enabled = false;
#ifdef HAVE_LIBPLACEBO_HEADERS
    shader_enabled = placebo_ && placebo_->enabled();
#endif
    const auto width = shader_enabled && output_size_.width > 0
      ? static_cast<uint32_t>(output_size_.width)
      : desc.Width;
    const auto height = shader_enabled && output_size_.height > 0
      ? static_cast<uint32_t>(output_size_.height)
      : desc.Height;

    if (!EnsureSurface(width, height)) {
      return;
    }

    auto device_context = graphics_context_->d3d_device_context();
    const bool same_size = desc.Width == width && desc.Height == height;

#ifdef HAVE_LIBPLACEBO_HEADERS
    // 只有显式启用 shader 时才允许重采样。空 hook 的 PlaceboPass 仍负责
    // 半分辨率 capture -> device-DPR output 的直通放大；普通 WebView 永不因
    // 1px 尺寸取整差而临时创建 PlaceboPass。
    if (shader_enabled) {
      if (placebo_ && placebo_->Render(src_texture.get(), surface_.get())) {
        scale_failure_logged_ = false;
        device_context->Flush();
        return;
      }
    }
#endif

    if (!shader_enabled && same_size) {
      device_context->CopyResource(surface_.get(), src_texture.get());
      device_context->Flush();
    }
    else {
      // shader 目标异尺寸时绝不能 CopyResource。libplacebo 渲染失败则保留当前
      // 目标纹理等下一帧重试；普通 WebView 的目标已取 src 尺寸，不会命中。
      if (!scale_failure_logged_) {
        std::cerr << "Scaling WebView texture failed; keeping previous target frame"
          << std::endl;
        scale_failure_logged_ = true;
      }
    }
  }

  bool TextureBridgeGpu::SetShaders(const std::vector<std::string>& shader_texts)
  {
#ifdef HAVE_LIBPLACEBO_HEADERS
    SurfaceSizeChangedCallback callback;
    Size logical_size = { 0, 0 };
    float device_scale_factor = 0.0f;
    float capture_scale_factor = 0.0f;
    bool ok = true;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      const bool was_enabled = placebo_ && placebo_->enabled();
      if (shader_texts.empty()) {
        if (placebo_) {
          placebo_->SetShaders({});
        }
      }
      else {
        if (!placebo_ && !placebo_unavailable_) {
          placebo_ = PlaceboPass::Create(graphics_context_->d3d_device());
          placebo_unavailable_ = !placebo_;
        }
        ok = placebo_ && placebo_->SetShaders(shader_texts);
      }

      const bool is_enabled = placebo_ && placebo_->enabled();
      if (was_enabled != is_enabled && requested_surface_size_.width > 0 &&
        requested_surface_size_.height > 0 && requested_scale_factor_ > 0.0f) {
        logical_size = requested_surface_size_;
        device_scale_factor = requested_scale_factor_;
        capture_scale_factor = is_enabled
          ? device_scale_factor / kShaderUpscaleFactor
          : device_scale_factor;
        callback = surface_size_changed_;
      }
    }

    // view->setSurfaceSize 会同步回 NotifySurfaceSizeChanged 并拿 mutex_；shader
    // 状态切换即使 logical/output 尺寸未变，也必须在锁外触发 source resize。
    if (callback) {
      callback(logical_size, capture_scale_factor, device_scale_factor);
    }
    return ok;
#else
    return false;
#endif
  }

  bool TextureBridgeGpu::EnsureSurface(uint32_t width, uint32_t height)
  {
    if (width == 0 || height == 0) {
      return false;
    }
    if (!surface_ || surface_size_.width != width ||
      surface_size_.height != height) {
      D3D11_TEXTURE2D_DESC dstDesc = {};
      dstDesc.ArraySize = 1;
      dstDesc.MipLevels = 1;
      dstDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      dstDesc.CPUAccessFlags = 0;
      dstDesc.Format = static_cast<DXGI_FORMAT>(kPixelFormat);
      dstDesc.Width = width;
      dstDesc.Height = height;
      dstDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
      dstDesc.SampleDesc.Count = 1;
      dstDesc.SampleDesc.Quality = 0;
      dstDesc.Usage = D3D11_USAGE_DEFAULT;

      surface_ = nullptr;
      dxgi_surface_ = nullptr;
      if (!SUCCEEDED(graphics_context_->d3d_device()->CreateTexture2D(
        &dstDesc, nullptr, surface_.put()))) {
        std::cerr << "Creating intermediate texture failed" << std::endl;
        return false;
      }

      HANDLE shared_handle = nullptr;
      surface_.try_as(dxgi_surface_);
      if (!dxgi_surface_ || FAILED(dxgi_surface_->GetSharedHandle(&shared_handle)) ||
        !shared_handle) {
        std::cerr << "Getting intermediate texture shared handle failed"
          << std::endl;
        surface_ = nullptr;
        dxgi_surface_ = nullptr;
        return false;
      }

      surface_descriptor_.handle = shared_handle;
      surface_descriptor_.width = surface_descriptor_.visible_width = width;
      surface_descriptor_.height = surface_descriptor_.visible_height = height;
      surface_descriptor_.release_context = surface_.get();
      surface_descriptor_.release_callback = [](void* release_context)
        {
          auto texture = reinterpret_cast<ID3D11Texture2D*>(release_context);
          texture->Release();
        };

      surface_size_ = { width, height };
    }
    return true;
  }

  const FlutterDesktopGpuSurfaceDescriptor*
    TextureBridgeGpu::GetSurfaceDescriptor(size_t width, size_t height)
  {
    const std::lock_guard<std::mutex> lock(mutex_);

    if (!is_running_) {
      return nullptr;
    }

    // Flutter engine 在 texture callback 给出的物理像素请求是最终合成目标；它可能
    // 比 method-channel 的布局上报晚一帧，故只校正 output，不回写 capture source。
    if (width > 0 && height > 0 &&
      width <= (std::numeric_limits<uint32_t>::max)() &&
      height <= (std::numeric_limits<uint32_t>::max)() &&
      (output_size_.width != width || output_size_.height != height)) {
      output_size_ = { width, height };
      scale_failure_logged_ = false;
    }

    if (last_frame_) {
      ProcessFrame(last_frame_);
    }

    if (!surface_) {
      return nullptr;
    }

    // Gets released in the SurfaceDescriptor's release callback.
    surface_->AddRef();
    return &surface_descriptor_;
  }

  void TextureBridgeGpu::StopInternal()
  {
    TextureBridge::StopInternal();

    // For some reason, the destination surface needs to be recreated upon
    // resuming. Force |EnsureSurface| to create a new one by resetting it here.
    surface_ = nullptr;
    dxgi_surface_ = nullptr;
    surface_size_ = { 0, 0 };
  }
}

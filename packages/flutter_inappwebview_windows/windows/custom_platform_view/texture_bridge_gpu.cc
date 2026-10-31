#include "texture_bridge_gpu.h"

#include <iostream>
#include <limits>

#include "util/direct3d11.interop.h"
#include "../utils/wgc_log.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#ifdef HAVE_LIBPLACEBO_HEADERS
#include "placebo_pass.h"
#endif

namespace flutter_inappwebview_plugin
{
  namespace
  {
    constexpr float kShaderUpscaleFactor = 2.0f;

    std::string SurfaceSizesDetail(Size surface, Size other)
    {
      char buffer[128];
      std::snprintf(buffer, sizeof(buffer), "surface=%zux%zu other=%zux%zu",
        surface.width, surface.height, other.width, other.height);
      return std::string(buffer);
    }

#ifdef HAVE_LIBPLACEBO_HEADERS
    // 着色器链的私有中间纹理：不共享句柄、不交给引擎，尺寸变了就地重建（插件自己的
    // 设备上引用计数平衡，重建不留残余；会漏的只有交给引擎的共享句柄）。
    bool EnsurePrivateTexture(ID3D11Device* device,
      winrt::com_ptr<ID3D11Texture2D>& texture, Size& texture_size, Size size,
      DXGI_FORMAT format)
    {
      if (size.width == 0 || size.height == 0) {
        return false;
      }
      if (texture && texture_size.width == size.width &&
        texture_size.height == size.height) {
        return true;
      }
      D3D11_TEXTURE2D_DESC desc = {};
      desc.ArraySize = 1;
      desc.MipLevels = 1;
      desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      desc.Format = format;
      desc.Width = static_cast<UINT>(size.width);
      desc.Height = static_cast<UINT>(size.height);
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_DEFAULT;
      texture = nullptr;
      texture_size = { 0, 0 };
      if (FAILED(device->CreateTexture2D(&desc, nullptr, texture.put()))) {
        return false;
      }
      texture_size = size;
      return true;
    }
#endif
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
    size_t width, size_t height, float scale_factor, Size capacity)
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
    FrameAvailableCallback refresh;
    float capture_scale_factor = scale_factor;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      const Size next_size = { static_cast<size_t>(physical_width),
        static_cast<size_t>(physical_height) };
      const bool capacity_changed = capacity_.width != capacity.width ||
        capacity_.height != capacity.height;
      if (requested_surface_size_.width == width &&
        requested_surface_size_.height == height &&
        requested_scale_factor_ == scale_factor && !capacity_changed) {
        return;
      }
      requested_surface_size_ = { width, height };
      requested_scale_factor_ = scale_factor;
      capacity_ = capacity;
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
      // 容量换档后，引擎缓存的上一张纹理（旧容量）不能再画进新尺寸的 Texture 盒子：
      // 标一次新帧让引擎下一帧重新取描述符（SelectSurfaceSize 给它对得上的那份）。
      if (capacity_changed && surface_) {
        refresh = frame_available_;
      }
    }

    // 回调可能同步触发 InAppWebView::onSurfaceSizeChanged ->
    // NotifySurfaceSizeChanged（同一把 mutex_），必须在锁外调用。
    if (callback) {
      callback({ width, height }, capture_scale_factor, scale_factor);
    }
    if (refresh) {
      refresh();
    }
  }

  bool TextureBridgeGpu::RequestMatches(Size surface, size_t request_width,
    size_t request_height) const
  {
    // 引擎把 Texture 盒子的尺寸（TextureLayer paint bounds，逻辑像素，截断成整数）当作
    // 请求尺寸传进 texture callback。Dart 把盒子摆成「容量 / 倍率」，所以请求 ≈
    // surface / scale；同时接受物理口径（倍率为 1 时两者相同），容差 1px 吸收截断。
    if (surface.width == 0 || surface.height == 0) {
      return false;
    }
    const auto close_to = [](double a, size_t b) {
      return std::abs(a - static_cast<double>(b)) <= 1.0;
      };
    const double scale = requested_scale_factor_ > 0.0f
      ? static_cast<double>(requested_scale_factor_)
      : 1.0;
    return (close_to(surface.width / scale, request_width) &&
      close_to(surface.height / scale, request_height)) ||
      (close_to(static_cast<double>(surface.width), request_width) &&
        close_to(static_cast<double>(surface.height), request_height));
  }

  Size TextureBridgeGpu::SelectSurfaceSize(size_t request_width,
    size_t request_height, Size content) const
  {
    // 旧协议（Dart 未给容量）：Texture 盒子就是 widget 本身，纹理必须与内容等大。
    if (capacity_.width == 0 || capacity_.height == 0) {
      return content;
    }
    Size target = capacity_;
    // 容量刚换档时，平台线程（收 setSize）与栅格线程（画上一帧布局）之间可能差一帧：
    // 引擎这一帧画的还是旧容量的盒子，就继续给旧容量的那张纹理，保证纹理尺寸永远
    // 等于它被画进的盒子——不出现一帧拉伸 / 压缩。
    if (surface_ && (surface_size_.width != target.width ||
      surface_size_.height != target.height) &&
      RequestMatches(surface_size_, request_width, request_height) &&
      !RequestMatches(target, request_width, request_height)) {
      target = surface_size_;
    }
    return target;
  }

  void TextureBridgeGpu::CopyIntoSurface(ID3D11Texture2D* src, Size visible)
  {
    auto device_context = graphics_context_->d3d_device_context();
    D3D11_TEXTURE2D_DESC src_desc;
    src->GetDesc(&src_desc);
    const UINT copy_width = static_cast<UINT>((std::min)({ visible.width,
      surface_size_.width, static_cast<size_t>(src_desc.Width) }));
    const UINT copy_height = static_cast<UINT>((std::min)({ visible.height,
      surface_size_.height, static_cast<size_t>(src_desc.Height) }));
    if (copy_width == 0 || copy_height == 0) {
      return;
    }
    // 容量里可见内容以外的部分必须透明：内容一缩小，右 / 下边会露出上一帧更大内容
    // 的残影；新纹理则是未初始化显存。只在内容尺寸变化（或新纹理）时整张清一次。
    if (cleared_for_content_.width != copy_width ||
      cleared_for_content_.height != copy_height) {
      if (surface_rtv_) {
        const float transparent[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        device_context->ClearRenderTargetView(surface_rtv_.get(), transparent);
      }
      cleared_for_content_ = { copy_width, copy_height };
    }
    const D3D11_BOX box = { 0, 0, 0, copy_width, copy_height, 1 };
    device_context->CopySubresourceRegion(surface_.get(), 0, 0, 0, 0, src, 0,
      &box);
    device_context->Flush();
  }

  void TextureBridgeGpu::ProcessFrame(
    winrt::com_ptr<ID3D11Texture2D> src_texture, size_t request_width,
    size_t request_height)
  {
    D3D11_TEXTURE2D_DESC desc;
    src_texture->GetDesc(&desc);

    // BUG-3895：帧池按容量分配后 WGC 帧纹理比内容大，有效内容是左上角的
    // ContentSize（不超过帧纹理本身）。
    Size content = { desc.Width, desc.Height };
    if (last_frame_content_size_.Width > 0 &&
      last_frame_content_size_.Height > 0) {
      content = {
        (std::min)(static_cast<size_t>(last_frame_content_size_.Width),
          static_cast<size_t>(desc.Width)),
        (std::min)(static_cast<size_t>(last_frame_content_size_.Height),
          static_cast<size_t>(desc.Height)) };
    }

    // BUG-1976 — output_size_ is allowed to differ from the WGC source only
    // while a shader chain is deliberately capturing below device DPR for an
    // upscale pass.  Treating a harmless rounding residue as an upscale request
    // sent every ordinary WebView — including dictionary text — through
    // libplacebo and softened the whole surface after 5d3feac4cd.
    //
    // With no shader, preserve the pre-upscale contract exactly: the visible
    // region is the captured content copied 1:1 (into the top-left of the
    // capacity-sized shared surface).
    bool shader_enabled = false;
#ifdef HAVE_LIBPLACEBO_HEADERS
    shader_enabled = placebo_ && placebo_->enabled();
#endif
    const Size visible = shader_enabled && output_size_.width > 0 &&
      output_size_.height > 0
      ? output_size_
      : content;

    const Size target =
      SelectSurfaceSize(request_width, request_height, visible);
    if (!EnsureSurface(static_cast<uint32_t>(target.width),
      static_cast<uint32_t>(target.height))) {
      return;
    }

#ifdef HAVE_LIBPLACEBO_HEADERS
    // 只有显式启用 shader 时才允许重采样。着色器在私有中间纹理上跑（输入 = 帧里的
    // 有效内容，输出 = 设备 DPR 的可见尺寸），再 1:1 拷进共享纹理左上角。普通
    // WebView 永不因 1px 取整差而临时创建 PlaceboPass。
    if (shader_enabled) {
      auto device = graphics_context_->d3d_device();
      const auto format = static_cast<DXGI_FORMAT>(kPixelFormat);
      if (!EnsurePrivateTexture(device, shader_src_, shader_src_size_, content,
        format) ||
        !EnsurePrivateTexture(device, shader_dst_, shader_dst_size_, visible,
          format)) {
        return;
      }
      auto device_context = graphics_context_->d3d_device_context();
      const D3D11_BOX box = { 0, 0, 0, static_cast<UINT>(content.width),
        static_cast<UINT>(content.height), 1 };
      device_context->CopySubresourceRegion(shader_src_.get(), 0, 0, 0, 0,
        src_texture.get(), 0, &box);
      if (placebo_->Render(shader_src_.get(), shader_dst_.get())) {
        scale_failure_logged_ = false;
        CopyIntoSurface(shader_dst_.get(), visible);
        return;
      }
      // libplacebo 渲染失败则保留当前目标纹理等下一帧重试。
      if (!scale_failure_logged_) {
        std::cerr << "Scaling WebView texture failed; keeping previous target frame"
          << std::endl;
        scale_failure_logged_ = true;
      }
      return;
    }
#endif

    CopyIntoSurface(src_texture.get(), content);
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

      if (surface_) {
        WgcLog::Write("surface-realloc", this,
          SurfaceSizesDetail(surface_size_, { width, height }));
      }
      surface_ = nullptr;
      dxgi_surface_ = nullptr;
      surface_rtv_ = nullptr;
      cleared_for_content_ = { 0, 0 };
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

      // 清屏用；建不出来只影响「容量里内容以外是否透明」，不影响内容本身。
      if (FAILED(graphics_context_->d3d_device()->CreateRenderTargetView(
        surface_.get(), nullptr, surface_rtv_.put()))) {
        surface_rtv_ = nullptr;
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

    // 引擎传进来的是 Texture 盒子的尺寸（TextureLayer paint bounds）。BUG-3895 起 Dart
    // 把盒子摆成「容量 / 倍率」，它不再等于可见内容，也就不能再拿来校正 output_size_
    // （旧代码在这里把它当物理目标尺寸写回 output_size_）；它只用于判断这一帧画的是
    // 哪份容量（SelectSurfaceSize）。
    if (last_request_.width != width || last_request_.height != height) {
      last_request_ = { width, height };
      WgcLog::Write("texture-request", this,
        SurfaceSizesDetail(surface_size_, { width, height }));
    }

    if (last_frame_) {
      ProcessFrame(last_frame_, width, height);
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
    surface_rtv_ = nullptr;
    surface_size_ = { 0, 0 };
    cleared_for_content_ = { 0, 0 };
  }
}

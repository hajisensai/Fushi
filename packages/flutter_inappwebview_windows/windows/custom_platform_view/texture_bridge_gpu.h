#pragma once

#include <flutter/texture_registrar.h>

#include <memory>

#include "texture_bridge.h"

namespace flutter_inappwebview_plugin
{
  class TextureBridgeGpu : public TextureBridge {
  public:
    TextureBridgeGpu(GraphicsContext* graphics_context,
      ABI::Windows::UI::Composition::IVisual* visual);
    // 定义在 .cc：PlaceboPass 只在那里是完整类型（unique_ptr 析构需要）。
    ~TextureBridgeGpu() override;

    const FlutterDesktopGpuSurfaceDescriptor* GetSurfaceDescriptor(size_t width,
      size_t height);

    void SetOutputSize(size_t width, size_t height, float scale_factor,
      Size capacity) override;
    bool SetShaders(const std::vector<std::string>& shader_texts) override;

  protected:
    void StopInternal() override;

  private:
    FlutterDesktopGpuSurfaceDescriptor surface_descriptor_ = {};
    Size surface_size_ = { 0, 0 };
    Size output_size_ = { 0, 0 };
    bool scale_failure_logged_ = false;
    winrt::com_ptr<ID3D11Texture2D> surface_{ nullptr };
    winrt::com_ptr<IDXGIResource> dxgi_surface_;
    winrt::com_ptr<ID3D11RenderTargetView> surface_rtv_;
    // 共享目标纹理里最近一次清成透明时对应的可见内容尺寸；内容尺寸一变就先清再拷，
    // 容量里内容以外的部分永远是透明而不是上一帧 / 未初始化的残留。
    Size cleared_for_content_ = { 0, 0 };
    // 引擎上一次纹理请求（Texture 盒子的尺寸），只为日志去重。
    Size last_request_ = { 0, 0 };
#ifdef HAVE_LIBPLACEBO_HEADERS
    // 着色器链的私有中间纹理（不共享、不进引擎），只在着色器开启时存在。
    winrt::com_ptr<ID3D11Texture2D> shader_src_;
    Size shader_src_size_ = { 0, 0 };
    winrt::com_ptr<ID3D11Texture2D> shader_dst_;
    Size shader_dst_size_ = { 0, 0 };
#endif

    Size SelectSurfaceSize(size_t request_width, size_t request_height,
      Size content) const;
    bool RequestMatches(Size surface, size_t request_width,
      size_t request_height) const;
    void ProcessFrame(winrt::com_ptr<ID3D11Texture2D> src_texture,
      size_t request_width, size_t request_height);
    void CopyIntoSurface(ID3D11Texture2D* src, Size visible);
#ifdef HAVE_LIBPLACEBO_HEADERS
    // 计划 P2：libplacebo 着色器通道，首次 SetShaders 非空时才加载 DLL / 建设备。
    std::unique_ptr<class PlaceboPass> placebo_;
    bool placebo_unavailable_ = false;
#endif
    bool EnsureSurface(uint32_t width, uint32_t height);
  };
}

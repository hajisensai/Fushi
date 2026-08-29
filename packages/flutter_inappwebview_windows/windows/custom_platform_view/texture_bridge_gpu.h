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

    bool SetShaders(const std::vector<std::string>& shader_texts) override;

  protected:
    void StopInternal() override;

  private:
    FlutterDesktopGpuSurfaceDescriptor surface_descriptor_ = {};
    Size surface_size_ = { 0, 0 };
    winrt::com_ptr<ID3D11Texture2D> surface_{ nullptr };
    winrt::com_ptr<IDXGIResource> dxgi_surface_;

    void ProcessFrame(winrt::com_ptr<ID3D11Texture2D> src_texture);
#ifdef HAVE_LIBPLACEBO_HEADERS
    // 计划 P2：libplacebo 着色器通道，首次 SetShaders 非空时才加载 DLL / 建设备。
    std::unique_ptr<class PlaceboPass> placebo_;
    bool placebo_unavailable_ = false;
#endif
    void EnsureSurface(uint32_t width, uint32_t height);
  };
}

#pragma once

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>

#include "../in_app_webview/in_app_webview.h"
#include "graphics_context.h"
#include "texture_bridge.h"

namespace flutter_inappwebview_plugin
{
  class CustomPlatformView {
  public:
    static inline const wchar_t* CLASS_NAME = L"CustomPlatformView";

    std::shared_ptr<flutter_inappwebview_plugin::InAppWebView> view;

    CustomPlatformView(flutter::BinaryMessenger* messenger,
      flutter::TextureRegistrar* texture_registrar,
      GraphicsContext* graphics_context,
      HWND hwnd,
      std::shared_ptr<flutter_inappwebview_plugin::InAppWebView> webView);
    ~CustomPlatformView();

    TextureBridge* texture_bridge() const { return texture_bridge_.get(); }

    int64_t texture_id() const { return texture_id_; }

    void UnregisterMethodCallHandler() const;
  private:
    // 引擎栅格线程上的纹理回调落点（定义在 .cc）：回调经它找桥、把描述符拷进它自己的
    // 存储；析构时先把桥摘掉，它与 flutter_texture_ 一起活到引擎确认注销为止。
    struct TextureEndpoint;

    HWND hwnd_;
    std::unique_ptr<TextureBridge> texture_bridge_;
    std::shared_ptr<TextureEndpoint> texture_endpoint_;
    // 共享给引擎的纹理（user_data 指向它内部），引擎在栅格线程注销之前随时可能回调。
    // 析构时移交给 UnregisterTexture 的完成回调，不在这里提前释放。
    std::unique_ptr<flutter::TextureVariant> flutter_texture_;
    // 插件自己的 D3D11 设备的立即上下文：本实例的共享纹理 / 帧池缓冲释放后由它 Flush
    // 才真正归还（D3D11 延迟销毁），见析构。
    winrt::com_ptr<ID3D11DeviceContext> d3d_device_context_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
    std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;

    flutter::TextureRegistrar* texture_registrar_;
    int64_t texture_id_;

    void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
    void RegisterEventHandlers();

    template <typename T>
    void EmitEvent(const T& value)
    {
      if (event_sink_) {
        event_sink_->Success(value);
      }
    }
  };
}

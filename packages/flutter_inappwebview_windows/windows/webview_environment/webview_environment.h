#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_ENVIRONMENT_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_ENVIRONMENT_H_

#include <functional>
#include <WebView2.h>
#include <wil/com.h>

#include "../flutter_inappwebview_windows_plugin.h"
#include "webview_environment_channel_delegate.h"
#include "webview_environment_settings.h"

namespace flutter_inappwebview_plugin
{
  class WebViewEnvironment
  {
  public:
    static inline const wchar_t* CLASS_NAME = L"WebViewEnvironment";
    static inline const std::string METHOD_CHANNEL_NAME_PREFIX = "com.pichillilorenzo/flutter_webview_environment_";
    static inline const std::string kWindowedHostingSentinel = "--fushi-windowed-hosting";

    const FlutterInappwebviewWindowsPlugin* plugin;
    std::string id;

    /// 窗口宿主模式（Fushi 网页播放器 4K 档）：本环境创建的 InAppWebView 用
    /// CreateCoreWebView2Controller 挂成真 HWND 子窗口（硬件 PlayReady 可用、画面不经
    /// WGC 捕获），而不是 composition controller + 纹理。开关由环境的
    /// additionalBrowserArguments 携带哨兵 `--fushi-windowed-hosting`（Chromium 忽略
    /// 未知开关）：宿主方式是环境级决定（与 DRM 相关的浏览器参数绑在一起），且
    /// platform-interface 的 settings 类在 pub-cache 里改不了。
    bool windowedHosting = false;

    std::unique_ptr<WebViewEnvironmentChannelDelegate> channelDelegate;

    WebViewEnvironment(const FlutterInappwebviewWindowsPlugin* plugin, const std::string& id);
    ~WebViewEnvironment();

    void create(const std::unique_ptr<WebViewEnvironmentSettings> settings, const std::function<void(HRESULT)> completionHandler);
    wil::com_ptr<ICoreWebView2Environment> getEnvironment()
    {
      return environment_;
    }
    wil::com_ptr<ICoreWebView2Controller> getWebViewController()
    {
      return webViewController_;
    }
    wil::com_ptr<ICoreWebView2> getWebView()
    {
      return webView_;
    }
  private:
    wil::com_ptr<ICoreWebView2Environment> environment_;
    wil::com_ptr<ICoreWebView2Controller> webViewController_;
    wil::com_ptr<ICoreWebView2> webView_;
    WNDCLASS windowClass_ = {};
  };
}
#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_ENVIRONMENT_H_
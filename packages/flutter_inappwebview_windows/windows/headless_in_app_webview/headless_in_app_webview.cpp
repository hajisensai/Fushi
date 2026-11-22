#include "../utils/log.h"
#include "headless_in_app_webview.h"

namespace flutter_inappwebview_plugin
{
  using namespace Microsoft::WRL;

  HeadlessInAppWebView::HeadlessInAppWebView(const FlutterInappwebviewWindowsPlugin* plugin, const HeadlessInAppWebViewCreationParams& params, const HWND parentWindow, std::unique_ptr<InAppWebView> webView)
    : plugin(plugin), id(params.id),
    webView(std::move(webView)),
    channelDelegate(std::make_unique<HeadlessWebViewChannelDelegate>(this, plugin->registrar->messenger()))
  {
    prepare(params);
    ShowWindow(parentWindow, SW_HIDE);
  }

  void HeadlessInAppWebView::prepare(const HeadlessInAppWebViewCreationParams& params)
  {
    if (!webView) {
      return;
    }
    webView->isHeadless = true;
    // Headless WebViews stay muted by default so background scrapers sharing
    // `--autoplay-policy=no-user-gesture-required` cannot emit ad audio.
    // Opt in with `allowBackgroundAudioPlaying: true` for audio-only headless
    // bridges such as Apple Music MusicKit playback.
    const bool allowAudio =
      webView->settings && webView->settings->allowBackgroundAudioPlaying;
    if (!allowAudio && webView->webView) {
      wil::com_ptr<ICoreWebView2_8> webView8;
      if (SUCCEEDED(webView->webView->QueryInterface(IID_PPV_ARGS(&webView8))) && webView8) {
        webView8->put_IsMuted(TRUE);
      }
    }
  }

  void HeadlessInAppWebView::setSize(const std::shared_ptr<Size2D> size) const
  {
    if (!webView) {
      return;
    }
    RECT rect = {
      0, 0, (LONG)size->width, (LONG)size->height
    };
    webView->webViewController->put_Bounds(rect);
  }

  std::shared_ptr<Size2D> HeadlessInAppWebView::getSize() const
  {
    if (!webView) {
      return std::make_shared<Size2D>(-1.0, -1.0);
    }
    RECT rect;
    webView->webViewController->get_Bounds(&rect);
    auto width = rect.right - rect.left;
    auto height = rect.bottom - rect.top;
    return std::make_shared<Size2D>((double)width, (double)height);
  }

  HeadlessInAppWebView::~HeadlessInAppWebView()
  {
    debugLog("dealloc HeadlessInAppWebView");
    HWND parentWindow = nullptr;
    if (webView && webView->webViewController) {
      webView->webViewController->get_ParentWindow(&parentWindow);
    }
    webView = nullptr;
    if (parentWindow) {
      DestroyWindow(parentWindow);
    }
  }
}
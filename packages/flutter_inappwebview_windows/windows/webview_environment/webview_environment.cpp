#include <objbase.h>
#include <windows.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/wrl.h>

#include "../utils/log.h"
#include "webview_environment.h"

#include "webview_environment_manager.h"

namespace flutter_inappwebview_plugin
{
  using namespace Microsoft::WRL;

  namespace
  {
    std::wstring OptionalEnvWide(const wchar_t* name)
    {
      const DWORD len = GetEnvironmentVariableW(name, nullptr, 0);
      if (len == 0) {
        return std::wstring();
      }
      std::wstring value(len, L'\0');
      const DWORD written = GetEnvironmentVariableW(name, value.data(), len);
      if (written == 0 || written >= len) {
        return std::wstring();
      }
      value.resize(written);
      return value;
    }
  }

  WebViewEnvironment::WebViewEnvironment(const FlutterInappwebviewWindowsPlugin* plugin, const std::string& id)
    : plugin(plugin), id(id),
    channelDelegate(std::make_unique<WebViewEnvironmentChannelDelegate>(this, plugin->registrar->messenger()))
  {}

  void WebViewEnvironment::create(const std::unique_ptr<WebViewEnvironmentSettings> settings, const std::function<void(HRESULT)> completionHandler)
  {
    if (!plugin) {
      if (completionHandler) {
        completionHandler(E_FAIL);
      }
      return;
    }

    auto hwnd = plugin->webViewEnvironmentManager->getHWND();
    if (!hwnd) {
      if (completionHandler) {
        completionHandler(E_FAIL);
      }
      return;
    }

    auto options = Make<CoreWebView2EnvironmentOptions>();
    if (settings) {
      if (settings->additionalBrowserArguments.has_value()) {
        options->put_AdditionalBrowserArguments(utf8_to_wide(settings->additionalBrowserArguments.value()).c_str());
      }
      if (settings->allowSingleSignOnUsingOSPrimaryAccount.has_value()) {
        options->put_AllowSingleSignOnUsingOSPrimaryAccount(settings->allowSingleSignOnUsingOSPrimaryAccount.value());
      }
      if (settings->language.has_value()) {
        options->put_Language(utf8_to_wide(settings->language.value()).c_str());
      }
      if (settings->targetCompatibleBrowserVersion.has_value()) {
        options->put_TargetCompatibleBrowserVersion(utf8_to_wide(settings->targetCompatibleBrowserVersion.value()).c_str());
      }
      wil::com_ptr<ICoreWebView2EnvironmentOptions4> options4;
      if (succeededOrLog(options->QueryInterface(IID_PPV_ARGS(&options4))) && settings->customSchemeRegistrations.has_value()) {
        std::vector<ICoreWebView2CustomSchemeRegistration*> registrations = {};
        for (auto& customSchemeRegistration : settings->customSchemeRegistrations.value()) {
          registrations.push_back(std::move(customSchemeRegistration->toWebView2CustomSchemeRegistration()));
        }
        options4->SetCustomSchemeRegistrations(static_cast<UINT32>(registrations.size()), registrations.data());
      }
    }

    // See in_app_webview.cpp: WebView2 needs COM initialized on the calling
    // thread; media_kit/libmpv (audiobook playback) can tear it down, yielding
    // CO_E_NOTINITIALIZED here. Idempotent, refcounted — restore the precondition.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const std::wstring browserExecutableFolder =
      settings && settings->browserExecutableFolder.has_value()
        ? utf8_to_wide(settings->browserExecutableFolder.value())
        : std::wstring();
    const std::wstring configuredUserDataFolder =
      settings && settings->userDataFolder.has_value()
        ? utf8_to_wide(settings->userDataFolder.value())
        : std::wstring();
    const std::wstring testUserDataFolder =
      configuredUserDataFolder.empty()
        ? OptionalEnvWide(L"HIBIKI_WEBVIEW2_USER_DATA_FOLDER")
        : std::wstring();
    const std::wstring& userDataFolder =
      configuredUserDataFolder.empty()
        ? testUserDataFolder
        : configuredUserDataFolder;
    auto hr = CreateCoreWebView2EnvironmentWithOptions(
      browserExecutableFolder.empty() ? nullptr : browserExecutableFolder.c_str(),
      userDataFolder.empty() ? nullptr : userDataFolder.c_str(),
      options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [this, hwnd, completionHandler](HRESULT result, wil::com_ptr<ICoreWebView2Environment> environment) -> HRESULT
        {
          if (succeededOrLog(result)) {
            environment_ = std::move(environment);

            auto hr = environment_->CreateCoreWebView2Controller(hwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [this, completionHandler](HRESULT result, wil::com_ptr<ICoreWebView2Controller> controller) -> HRESULT
              {
                if (succeededOrLog(result)) {
                  webViewController_ = std::move(controller);
                  webViewController_->get_CoreWebView2(&webView_);
                  webViewController_->put_IsVisible(false);
                }
                if (completionHandler) {
                  completionHandler(result);
                }
                return S_OK;
              }).Get());

            if (failedAndLog(hr) && completionHandler) {
              completionHandler(hr);
            }
          }
          else if (completionHandler) {
            completionHandler(result);
          }
          return S_OK;
        }).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler(hr);
    }
  }

  WebViewEnvironment::~WebViewEnvironment()
  {
    debugLog("dealloc WebViewEnvironment");
  }
}

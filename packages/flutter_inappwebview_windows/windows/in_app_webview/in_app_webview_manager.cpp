#include <DispatcherQueue.h>
#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <windows.graphics.capture.h>

#include "../in_app_webview/in_app_webview_settings.h"
#include "../types/url_request.h"
#include "../types/user_script.h"
#include "../utils/flutter.h"
#include "../utils/log.h"
#include "../utils/string.h"
#include "../utils/vector.h"
#include "../webview_environment/webview_environment_manager.h"
#include "in_app_webview_manager.h"

namespace flutter_inappwebview_plugin
{
  InAppWebViewManager::InAppWebViewManager(const FlutterInappwebviewWindowsPlugin* plugin)
    : plugin(plugin),
    ChannelDelegate(plugin->registrar->messenger(), InAppWebViewManager::METHOD_CHANNEL_NAME)
  {
    // BUG-255：登记一个存活实例。进程级共享单例（rohelper_/dispatcher_queue_
    // controller_/graphics_context_/compositor_）只由首个实例创建（下面 `if (!rohelper_)`），
    // 但必须在「最后一个」实例析构时受控释放，否则会落到 CRT atexit 触发 FailFast。
    ++instance_count_;

    if (!rohelper_) {
      rohelper_ = std::make_unique<rx::RoHelper>(RO_INIT_SINGLETHREADED);

      if (rohelper_->WinRtAvailable()) {
        DispatcherQueueOptions options{ sizeof(DispatcherQueueOptions),
                                       DQTYPE_THREAD_CURRENT, DQTAT_COM_STA };

        if (FAILED(rohelper_->CreateDispatcherQueueController(
          options, dispatcher_queue_controller_.put()))) {
          std::cerr << "Creating DispatcherQueueController failed." << std::endl;
          return;
        }

        if (!isGraphicsCaptureSessionSupported()) {
          std::cerr << "Windows::Graphics::Capture::GraphicsCaptureSession is not "
            "supported."
            << std::endl;
          return;
        }

        graphics_context_ = std::make_unique<GraphicsContext>(rohelper_.get());
        compositor_ = graphics_context_->CreateCompositor();
        valid_ = graphics_context_->IsValid();

        // BUG-289：在 root Flutter window 的 WM_DESTROY 受控时机释放共享单例。
        // dump 实证退出时 ~InAppWebViewManager() 不被调用（plugin registrar 不在进程退出
        // 时 tear down），单靠析构释放（BUG-255）失效，compositor_ 落到 CRT atexit ->
        // CoreMessaging 半拆 -> dcomp!Compositor::CleanupSession FailFast (e0464645)。
        // WM_DESTROY 在 LdrShutdownProcess 之前、UI 线程、CoreMessaging 仍完整时到达，
        // 是确定性的受控释放点。delegate 返回 std::nullopt 不拦截消息，仅借机释放。
        if (window_proc_delegate_id_ < 0) {
          window_proc_delegate_id_ = plugin->registrar->RegisterTopLevelWindowProcDelegate(
            [](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
              if (message == WM_DESTROY) {
                releaseSharedCompositionResources();
              }
              return std::nullopt;
            });
        }
      }
    }

    windowClass_.lpszClassName = CustomPlatformView::CLASS_NAME;
    windowClass_.lpfnWndProc = &DefWindowProc;

    RegisterClass(&windowClass_);
  }

  void InAppWebViewManager::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto& methodName = method_call.method_name();

    if (string_equals(methodName, "createInAppWebView")) {
      if (isSupported()) {
        createInAppWebView(arguments, std::move(result));
      }
      else {
        result->Error("0", "Creating an InAppWebView instance is not supported! Graphics Context is not valid!");
      }
    }
    else if (string_equals(methodName, "dispose")) {
      auto id = get_fl_map_value<int64_t>(*arguments, "id");
      if (map_contains(webViews, (uint64_t)id)) {
        auto platformView = webViews.at(id).get();
        if (platformView) {
          platformView->UnregisterMethodCallHandler();
        }
        webViews.erase(id);
      }
      result->Success();
    }
    else if (string_equals(methodName, "disposeKeepAlive")) {
      auto keepAliveId = get_fl_map_value<std::string>(*arguments, "keepAliveId");
      disposeKeepAlive(keepAliveId);
      result->Success();
    }
    else if (string_equals(methodName, "prepareForProcessExit")) {
      prepareForProcessExit();
      result->Success();
    }
    else {
      result->NotImplemented();
    }
  }

  void InAppWebViewManager::createInAppWebView(const flutter::EncodableMap* arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto result_ = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));

    if (!plugin) {
      result_->Error("0", "Cannot create the InAppWebView instance!");
      return;
    }

    auto settingsMap = get_fl_map_value<flutter::EncodableMap>(*arguments, "initialSettings");
    auto urlRequestMap = get_optional_fl_map_value<flutter::EncodableMap>(*arguments, "initialUrlRequest");
    auto initialFile = get_optional_fl_map_value<std::string>(*arguments, "initialFile");
    auto initialDataMap = get_optional_fl_map_value<flutter::EncodableMap>(*arguments, "initialData");
    auto initialUserScriptList = get_optional_fl_map_value<flutter::EncodableList>(*arguments, "initialUserScripts");
    auto webViewEnvironmentId = get_optional_fl_map_value<std::string>(*arguments, "webViewEnvironmentId");
    auto keepAliveId = get_optional_fl_map_value<std::string>(*arguments, "keepAliveId");
    auto windowId = get_optional_fl_map_value<int64_t>(*arguments, "windowId");

    RECT bounds;
    GetClientRect(plugin->registrar->GetView()->GetNativeWindow(), &bounds);

    auto hwnd = CreateWindowEx(0, windowClass_.lpszClassName, L"", 0, 0,
      0, bounds.right - bounds.left, bounds.bottom - bounds.top,
      plugin->registrar->GetView()->GetNativeWindow(),
      nullptr,
      windowClass_.hInstance, nullptr);

    if (keepAliveId.has_value() && map_contains(keepAliveWebViews, keepAliveId.value())) {
      auto webView = std::move(keepAliveWebViews.at(keepAliveId.value())->view);
      keepAliveWebViews.erase(keepAliveId.value());
      auto customPlatformView = std::make_unique<CustomPlatformView>(plugin->registrar->messenger(),
        plugin->registrar->texture_registrar(),
        graphics_context(),
        hwnd,
        std::move(webView));
      auto textureId = customPlatformView->texture_id();
      keepAliveWebViews.insert({ keepAliveId.value(), std::move(customPlatformView) });
      result_->Success(textureId);
      return;
    }

    auto webViewEnvironment = webViewEnvironmentId.has_value() && map_contains(plugin->webViewEnvironmentManager->webViewEnvironments, webViewEnvironmentId.value())
      ? plugin->webViewEnvironmentManager->webViewEnvironments.at(webViewEnvironmentId.value()).get() : nullptr;

    auto initialSettings = std::make_shared<InAppWebViewSettings>(settingsMap);

    InAppWebView::createInAppWebViewEnv(hwnd, true, webViewEnvironment, initialSettings,
      [=](wil::com_ptr<ICoreWebView2Environment> webViewEnv,
        wil::com_ptr<ICoreWebView2Controller> webViewController,
        wil::com_ptr<ICoreWebView2CompositionController> webViewCompositionController)
      {
        if (plugin && webViewEnv && webViewController && webViewCompositionController) {
          std::optional<std::vector<std::shared_ptr<UserScript>>> initialUserScripts = initialUserScriptList.has_value() ?
            functional_map(initialUserScriptList.value(), [](const flutter::EncodableValue& map) { return std::make_shared<UserScript>(std::get<flutter::EncodableMap>(map)); }) :
            std::optional<std::vector<std::shared_ptr<UserScript>>>{};

          InAppWebViewCreationParams params = {
            "",
            std::move(initialSettings),
            initialUserScripts
          };

          auto inAppWebView = std::make_unique<InAppWebView>(plugin, params, hwnd, std::move(webViewEnv), std::move(webViewController), std::move(webViewCompositionController));

          std::optional<std::shared_ptr<URLRequest>> urlRequest = urlRequestMap.has_value() ? std::make_shared<URLRequest>(urlRequestMap.value()) : std::optional<std::shared_ptr<URLRequest>>{};
          if (urlRequest.has_value()) {
            inAppWebView->loadUrl(urlRequest.value());
          }
          else if (initialFile.has_value()) {
            inAppWebView->loadFile(initialFile.value());
          }
          else if (initialDataMap.has_value()) {
            inAppWebView->loadData(get_fl_map_value<std::string>(initialDataMap.value(), "data"));
          }

          if (windowId.has_value() && map_contains(windowWebViews, windowId.value())) {
            auto windowWebViewArgs = windowWebViews.at(windowId.value()).get();
            windowWebViewArgs->args->put_NewWindow(inAppWebView->webView.get());
            windowWebViewArgs->args->put_Handled(TRUE);
            windowWebViewArgs->deferral->Complete();
            windowWebViews.erase(windowId.value());
          }

          auto customPlatformView = std::make_unique<CustomPlatformView>(plugin->registrar->messenger(),
            plugin->registrar->texture_registrar(),
            graphics_context(),
            hwnd,
            std::move(inAppWebView));

          auto textureId = customPlatformView->texture_id();

          if (keepAliveId.has_value()) {
            customPlatformView->view->initChannel(keepAliveId.value(), std::nullopt);
            keepAliveWebViews.insert({ keepAliveId.value(), std::move(customPlatformView) });
          }
          else {
            customPlatformView->view->initChannel(textureId, std::nullopt);
            webViews.insert({ textureId, std::move(customPlatformView) });
          }
          result_->Success(textureId);
        }
        else {
          result_->Error("0", "Cannot create the InAppWebView instance!");
        }
      }
    );
  }

  void InAppWebViewManager::disposeKeepAlive(const std::string& keepAliveId)
  {
    if (map_contains(keepAliveWebViews, keepAliveId)) {
      auto platformView = keepAliveWebViews.at(keepAliveId).get();
      if (platformView) {
        platformView->UnregisterMethodCallHandler();
      }
      keepAliveWebViews.erase(keepAliveId);
    }
  }

  void InAppWebViewManager::prepareForProcessExit()
  {
    debugLog("prepareForProcessExit InAppWebViewManager");
    webViews.clear();
    keepAliveWebViews.clear();
    windowWebViews.clear();
    releaseSharedCompositionResources();
  }

  bool InAppWebViewManager::isGraphicsCaptureSessionSupported()
  {
    HSTRING className;
    HSTRING_HEADER classNameHeader;

    if (FAILED(rohelper_->GetStringReference(
      RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
      &className, &classNameHeader))) {
      return false;
    }

    ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics*
      capture_session_statics;
    if (FAILED(rohelper_->GetActivationFactory(
      className,
      __uuidof(
        ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics),
      (void**)&capture_session_statics))) {
      return false;
    }

    boolean is_supported = false;
    if (FAILED(capture_session_statics->IsSupported(&is_supported))) {
      return false;
    }

    return !!is_supported;
  }

  InAppWebViewManager::~InAppWebViewManager()
  {
    debugLog("dealloc InAppWebViewManager");
    // 先释放本实例拥有的 WebView（消费 compositor 的下游），再判断是否到了释放
    // 进程级共享单例的时机。webViews 等通过 graphics_context() 持有对 compositor_
    // 的弱引用使用，必须先全部清空再动 compositor_。
    webViews.clear();
    keepAliveWebViews.clear();
    windowWebViews.clear();
    UnregisterClass(windowClass_.lpszClassName, nullptr);
    plugin = nullptr;

    // BUG-255 / TODO-313 Family B：受控退出时序，避免进程退出时的 dcomp
    // Compositor::CleanupSession FailFast。
    // 析构在 Flutter engine/window 受控 teardown 期发生（UI 线程，且
    // DispatcherQueueController 仍存活、CoreMessaging 尚未被 LdrShutdownProcess
    // 拆除）。只有当最后一个 InAppWebViewManager 析构时，才在这个受控时机显式释放
    // 进程级共享单例——而不是把它们留给 CRT atexit 表（execute_onexit_table）。
    // dump 证据（cdb 分析多个 .dmp）：ExceptionCode e0464645，栈为
    //   CoreMessaging!Abandonment::Fail
    //     <- dcomp!Compositor::CleanupSession+0x54
    //     <- CompositorCommon::Destroy <- OnFinalRelease
    //     <- flutter_inappwebview_windows_plugin onexit(atexit execute_onexit_table)
    //     <- ntdll!RtlExitUserProcess
    // 即 compositor_ 的最终 Release 跑在 CoreMessaging 已半拆之后。把这次 Release
    // 提前到受控时机后，CleanupSession 在 CoreMessaging 仍完整时运行，FailFast 窗口
    // 被确定性消除。
    if (--instance_count_ <= 0) {
      instance_count_ = 0;
      releaseSharedCompositionResources();
    }
  }

  // BUG-255：按依赖顺序释放进程级共享单例。释放顺序至关重要——
  // dcomp Compositor 依赖 WinRT DispatcherQueue/CoreMessaging，故 compositor_ 必须
  // 先于 dispatcher_queue_controller_ 释放，这样 CleanupSession 运行时
  // CoreMessaging 仍完整。graphics_context_（D3D 设备/上下文）夹在中间。
  void InAppWebViewManager::releaseSharedCompositionResources()
  {
    // BUG-289：幂等守卫。WM_DESTROY 钩子（首达，受控时机）与析构兜底可能都调到这里，
    // 但共享单例只能释放一次；compositor_ 等已置空后重复调用为安全 no-op。
    if (composition_released_) {
      return;
    }
    composition_released_ = true;
    // 1) DirectComposition Compositor：最终 Release 触发
    //    OnFinalRelease -> CompositorCommon::Destroy -> dcomp!Compositor::CleanupSession。
    //    此刻 dispatcher_queue_controller_ 仍持活，CoreMessaging 完整，不会 FailFast。
    compositor_ = nullptr;
    // 2) GraphicsContext（D3D11 device/context + WinRT IDirect3DDevice）。
    graphics_context_ = nullptr;
    // 3) WinRT DispatcherQueueController 最后释放：它背后的 CoreMessaging 必须
    //    存活到 compositor_ 的 CleanupSession 跑完为止。
    dispatcher_queue_controller_ = nullptr;
    // 4) RoHelper（WinRT 运行时入口包装）。
    rohelper_ = nullptr;
    valid_ = false;
  }
}

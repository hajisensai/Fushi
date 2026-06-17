#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_IN_APP_WEBVIEW_MANAGER_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_IN_APP_WEBVIEW_MANAGER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_message_codec.h>
#include <map>
#include <string>
#include <variant>
#include <wil/com.h>
#include <winrt/base.h>

#include "../custom_platform_view/custom_platform_view.h"
#include "../custom_platform_view/graphics_context.h"
#include "../custom_platform_view/util/rohelper.h"
#include "../flutter_inappwebview_windows_plugin.h"
#include "../types/channel_delegate.h"
#include "../types/new_window_requested_args.h"
#include "windows.ui.composition.h"

namespace flutter_inappwebview_plugin
{
  class InAppWebViewManager : public ChannelDelegate
  {
  public:
    static inline const std::string METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_inappwebview_manager";

    const FlutterInappwebviewWindowsPlugin* plugin;
    std::map<uint64_t, std::unique_ptr<CustomPlatformView>> webViews;
    std::map<std::string, std::unique_ptr<CustomPlatformView>> keepAliveWebViews;
    std::map<int64_t, std::unique_ptr<NewWindowRequestedArgs>> windowWebViews;
    int64_t windowAutoincrementId = 0;

    bool isSupported() const { return valid_; }
    bool isGraphicsCaptureSessionSupported();
    GraphicsContext* graphics_context() const
    {
      return graphics_context_.get();
    };
    rx::RoHelper* rohelper() const { return rohelper_.get(); }
    winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor() const
    {
      return compositor_;
    }

    InAppWebViewManager(const FlutterInappwebviewWindowsPlugin* plugin);
    ~InAppWebViewManager();

    void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    void createInAppWebView(const flutter::EncodableMap* arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
    void disposeKeepAlive(const std::string& keepAliveId);
  private:
    void prepareForProcessExit();

    // BUG-255 / TODO-313 Family B（进程退出时 dcomp Compositor::CleanupSession FailFast）：
    // 下面这组 inline static 成员是进程级共享单例（DirectComposition Compositor、
    // GraphicsContext、WinRT DispatcherQueueController、RoHelper），由首个
    // InAppWebViewManager 构造时一次性创建（构造里 `if (!rohelper_)` 守卫）。
    // 它们具有 static storage duration——若放任不管，其最终 COM Release 会落到
    // CRT atexit 表（execute_onexit_table / RtlExitUserProcess），此时
    // LdrShutdownProcess 已开始拆除 CoreMessaging/DispatcherQueue，compositor_ 的
    // OnFinalRelease -> CompositorCommon::Destroy -> dcomp!Compositor::CleanupSession
    // 会对半拆的 CoreMessaging 操作 -> CoreMessaging!Abandonment::Fail FailFast
    // (ExceptionCode e0464645)。见析构里的受控释放与 BUG-255 文档。
    // instance_count_：存活的 InAppWebViewManager 实例数（每个 Flutter engine/window 一个）。
    // 只在最后一个实例析构（受控 teardown：UI 线程、DispatcherQueue 仍存活）时释放共享单例。
    inline static int instance_count_ = 0;
    inline static std::shared_ptr<rx::RoHelper> rohelper_ = nullptr;
    inline static winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController>
      dispatcher_queue_controller_ = nullptr;
    inline static std::unique_ptr<GraphicsContext> graphics_context_ = nullptr;
    inline static winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor_ = nullptr;
    WNDCLASS windowClass_ = {};
    inline static bool valid_ = false;

    // BUG-289：dump 实证 BUG-255 的「靠 ~InAppWebViewManager() 受控释放」失效——退出时
    // 该析构根本不被调用（Flutter Windows 进程退出不 tear down plugin registrar），
    // compositor_ 这个 inline static com_ptr 持引用到 CRT atexit 才最终 Release，仍 FailFast。
    // 改为在 root Flutter window 的 WM_DESTROY（受控时机：UI 线程、CoreMessaging 完整、
    // LdrShutdownProcess 尚未开始）经 top-level window proc delegate 显式释放。
    // composition_released_ 保证释放只发生一次（WM_DESTROY 与析构两条路径任一先到都安全且幂等）。
    inline static bool composition_released_ = false;
    inline static int window_proc_delegate_id_ = -1;

    // BUG-255/BUG-289：在 DispatcherQueue 仍存活的受控时机（root window WM_DESTROY，
    // 或最后一个 manager 析构兜底）按 dcomp -> WinRT 依赖顺序显式释放进程级共享单例，
    // 避免落到 CRT atexit。幂等：重复调用为 no-op。
    static void releaseSharedCompositionResources();
  };
}
#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_IN_APP_WEBVIEW_MANAGER_H_

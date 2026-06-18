#include "../utils/log.h"
#include "../utils/wgc_log.h"
#include "custom_platform_view.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_result_functions.h>

#include <cstdio>
#include <string>

#ifdef HAVE_FLUTTER_D3D_TEXTURE
#include "texture_bridge_gpu.h"
#else
#include "texture_bridge_fallback.h"
#endif

namespace flutter_inappwebview_plugin
{
  constexpr auto kErrorInvalidArgs = "invalidArguments";

  constexpr auto kMethodSetSize = "setSize";
  constexpr auto kMethodSetPosition = "setPosition";
  constexpr auto kMethodSetCursorPos = "setCursorPos";
  constexpr auto kMethodSetPointerUpdate = "setPointerUpdate";
  constexpr auto kMethodSetPointerButton = "setPointerButton";
  constexpr auto kMethodSetScrollDelta = "setScrollDelta";
  constexpr auto kMethodSetFpsLimit = "setFpsLimit";

  constexpr auto kEventType = "type";
  constexpr auto kEventValue = "value";

  namespace
  {
    std::string CpvDetail(int64_t texture_id, const void* bridge)
    {
      char buffer[192];
      std::snprintf(buffer, sizeof(buffer), "texture_id=%lld bridge=0x%llx",
        static_cast<long long>(texture_id),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(bridge)));
      return std::string(buffer);
    }

    std::string SetSizeDetail(double width, double height, double scale_factor,
      int64_t texture_id, const void* bridge)
    {
      char buffer[256];
      std::snprintf(buffer, sizeof(buffer),
        "width=%.3f height=%.3f scale=%.3f texture_id=%lld bridge=0x%llx",
        width, height, scale_factor, static_cast<long long>(texture_id),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(bridge)));
      return std::string(buffer);
    }

    std::string SurfaceSizeDetail(size_t width, size_t height, int64_t texture_id,
      const void* bridge)
    {
      char buffer[256];
      std::snprintf(buffer, sizeof(buffer),
        "width=%zu height=%zu texture_id=%lld bridge=0x%llx", width, height,
        static_cast<long long>(texture_id),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(bridge)));
      return std::string(buffer);
    }
  }  // namespace

  static const std::optional<std::pair<double, double>> GetPointFromArgs(
    const flutter::EncodableValue* args)
  {
    const flutter::EncodableList* list =
      std::get_if<flutter::EncodableList>(args);
    if (!list || list->size() != 2) {
      return std::nullopt;
    }
    const auto x = std::get_if<double>(&(*list)[0]);
    const auto y = std::get_if<double>(&(*list)[1]);
    if (!x || !y) {
      return std::nullopt;
    }
    return std::make_pair(*x, *y);
  }

  static const std::optional<std::tuple<double, double, double>>
    GetPointAndScaleFactorFromArgs(const flutter::EncodableValue* args)
  {
    const flutter::EncodableList* list =
      std::get_if<flutter::EncodableList>(args);
    if (!list || list->size() != 3) {
      return std::nullopt;
    }
    const auto x = std::get_if<double>(&(*list)[0]);
    const auto y = std::get_if<double>(&(*list)[1]);
    const auto z = std::get_if<double>(&(*list)[2]);
    if (!x || !y || !z) {
      return std::nullopt;
    }
    return std::make_tuple(*x, *y, *z);
  }

  static const std::string& GetCursorName(const HCURSOR cursor)
  {
    // The cursor names correspond to the Flutter Engine names:
    // in shell/platform/windows/flutter_window_win32.cc
    static const std::string kDefaultCursorName = "basic";
    static const std::pair<std::string, const wchar_t*> mappings[] = {
        {"allScroll", IDC_SIZEALL},
        {kDefaultCursorName, IDC_ARROW},
        {"click", IDC_HAND},
        {"forbidden", IDC_NO},
        {"help", IDC_HELP},
        {"move", IDC_SIZEALL},
        {"none", nullptr},
        {"noDrop", IDC_NO},
        {"precise", IDC_CROSS},
        {"progress", IDC_APPSTARTING},
        {"text", IDC_IBEAM},
        {"resizeColumn", IDC_SIZEWE},
        {"resizeDown", IDC_SIZENS},
        {"resizeDownLeft", IDC_SIZENESW},
        {"resizeDownRight", IDC_SIZENWSE},
        {"resizeLeft", IDC_SIZEWE},
        {"resizeLeftRight", IDC_SIZEWE},
        {"resizeRight", IDC_SIZEWE},
        {"resizeRow", IDC_SIZENS},
        {"resizeUp", IDC_SIZENS},
        {"resizeUpDown", IDC_SIZENS},
        {"resizeUpLeft", IDC_SIZENWSE},
        {"resizeUpRight", IDC_SIZENESW},
        {"resizeUpLeftDownRight", IDC_SIZENWSE},
        {"resizeUpRightDownLeft", IDC_SIZENESW},
        {"wait", IDC_WAIT},
    };

    static std::map<HCURSOR, std::string> cursors;
    static bool initialized = false;

    if (!initialized) {
      initialized = true;
      for (const auto& pair : mappings) {
        HCURSOR cursor_handle = LoadCursor(nullptr, pair.second);
        if (cursor_handle) {
          cursors[cursor_handle] = pair.first;
        }
      }
    }

    const auto it = cursors.find(cursor);
    if (it != cursors.end()) {
      return it->second;
    }
    return kDefaultCursorName;
  }

  CustomPlatformView::CustomPlatformView(flutter::BinaryMessenger* messenger,
    flutter::TextureRegistrar* texture_registrar,
    GraphicsContext* graphics_context,
    HWND hwnd,
    std::shared_ptr<flutter_inappwebview_plugin::InAppWebView> webView)
    : hwnd_(hwnd), view(std::move(webView)), texture_registrar_(texture_registrar)
  {
#ifdef HAVE_FLUTTER_D3D_TEXTURE
    texture_bridge_ =
      std::make_unique<TextureBridgeGpu>(graphics_context, view->surface());

    flutter_texture_ =
      std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [bridge = static_cast<TextureBridgeGpu*>(texture_bridge_.get())](
          size_t width,
          size_t height) -> const FlutterDesktopGpuSurfaceDescriptor*
        {
          return bridge->GetSurfaceDescriptor(width, height);
        }));
#else
    texture_bridge_ = std::make_unique<TextureBridgeFallback>(
      graphics_context, webview_->surface());

    flutter_texture_ =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [bridge = static_cast<TextureBridgeFallback*>(texture_bridge_.get())](
          size_t width, size_t height) -> const FlutterDesktopPixelBuffer*
        {
          return bridge->CopyPixelBuffer(width, height);
        }));
#endif

    texture_id_ = texture_registrar->RegisterTexture(flutter_texture_.get());
    texture_bridge_->SetOnFrameAvailable(
      [this]() { texture_registrar_->MarkTextureFrameAvailable(texture_id_); });
    // texture_bridge_->SetOnSurfaceSizeChanged([this](Size size) {
    //  view->SetSurfaceSize(size.width, size.height);
    //});

    const auto method_channel_name = "com.pichillilorenzo/custom_platform_view_" + std::to_string(texture_id_);
    method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, method_channel_name,
        &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler([this](const auto& call, auto result)
      {
        HandleMethodCall(call, std::move(result));
      });

    const auto event_channel_name = "com.pichillilorenzo/custom_platform_view_" + std::to_string(texture_id_) + "_events";
    event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        messenger, event_channel_name,
        &flutter::StandardMethodCodec::GetInstance());

    auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [this](const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
          events)
        {
          event_sink_ = std::move(events);
          RegisterEventHandlers();
          return nullptr;
        },
        [this](const flutter::EncodableValue* arguments)
        {
          return nullptr;
        });

    event_channel_->SetStreamHandler(std::move(handler));
  }

  void CustomPlatformView::UnregisterMethodCallHandler() const
  {
    if (method_channel_) {
      method_channel_->SetMethodCallHandler(nullptr);
      if (view && view->channelDelegate) {
        view->channelDelegate->UnregisterMethodCallHandler();
      }
    }
  }

  CustomPlatformView::~CustomPlatformView()
  {
    debugLog("dealloc CustomPlatformView");
    WgcLog::Write("cpv-dtor-enter", nullptr,
      CpvDetail(texture_id_, texture_bridge_.get()));
    event_sink_ = nullptr;
    // BUG-163/TODO-061：teardown 第一步同步切断「WGC 生产者 -> Flutter texture
    // registrar 消费者」这条边。frame_available_ 捕获 texture_registrar_ 裸指针 +
    // texture_id_；若不切断，优雅引擎拆除（FlutterDesktopViewControllerDestroy）或
    // 中途弹窗销毁期，一个迟到的 WGC 帧仍会 MarkTextureFrameAvailable() 打进正在被
    // 引擎拆除的 registrar，命中 flutter_windows.dll c0000005（2026-06-11 退出 dump
    // 实证）。这是第七修「不显式 Close 帧池、靠在途 deferral 强引用收尾」唯一漏掉的
    // 消费者侧缺口：WGC 侧的 null-delegate 已根除，但消费者边从未断开。置空回调后，
    // Timer pump callback 里的 frame_available_ 守卫直接短路，任何迟到 tick
    // 都不再触碰 registrar。先切断、再 Stop（WGC 销毁序见 texture_bridge.cc）、最后
    // 注销 texture——三步单调缩小 teardown 竞态窗口。
    if (texture_bridge_) {
      texture_bridge_->SetOnFrameAvailable(nullptr);
      WgcLog::Write("stop-start", nullptr,
        CpvDetail(texture_id_, texture_bridge_.get()));
      texture_bridge_->Stop();
      WgcLog::Write("stop-done", nullptr,
        CpvDetail(texture_id_, texture_bridge_.get()));
    }
    WgcLog::Write("unregister-start", nullptr,
      CpvDetail(texture_id_, texture_bridge_.get()));
    texture_registrar_->UnregisterTexture(texture_id_, nullptr);
    WgcLog::Write("unregister-done", nullptr,
      CpvDetail(texture_id_, texture_bridge_.get()));
    WgcLog::Write("cpv-dtor-exit", nullptr,
      CpvDetail(texture_id_, texture_bridge_.get()));
  }

  void CustomPlatformView::RegisterEventHandlers()
  {
    if (!view) {
      return;
    }

    view->onSurfaceSizeChanged([this](size_t width, size_t height)
      {
        WgcLog::Write("surface-size-changed", nullptr,
          SurfaceSizeDetail(width, height, texture_id_, texture_bridge_.get()));
        texture_bridge_->NotifySurfaceSizeChanged(width, height);
      });

    view->onCursorChanged([this](const HCURSOR cursor)
      {
        const auto& name = GetCursorName(cursor);
        const auto event = flutter::EncodableValue(
          flutter::EncodableMap { {
              flutter::EncodableValue(kEventType),
                flutter::EncodableValue("cursorChanged")
            },
          { flutter::EncodableValue(kEventValue), name }});
        EmitEvent(event);
      });
  }

  void CustomPlatformView::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    const auto& method_name = method_call.method_name();

    // setCursorPos: [double x, double y]
    if (method_name.compare(kMethodSetCursorPos) == 0) {
      const auto point = GetPointFromArgs(method_call.arguments());
      if (point && view) {
        view->setCursorPos(point->first, point->second);
        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }

    // setPointerUpdate:
    // [int pointer, int event, double x, double y, double size, double pressure]
    if (method_name.compare(kMethodSetPointerUpdate) == 0) {
      const flutter::EncodableList* list =
        std::get_if<flutter::EncodableList>(method_call.arguments());
      if (!list || list->size() != 6) {
        return result->Error(kErrorInvalidArgs);
      }

      const auto pointer = std::get_if<int32_t>(&(*list)[0]);
      const auto event = std::get_if<int32_t>(&(*list)[1]);
      const auto x = std::get_if<double>(&(*list)[2]);
      const auto y = std::get_if<double>(&(*list)[3]);
      const auto size = std::get_if<double>(&(*list)[4]);
      const auto pressure = std::get_if<double>(&(*list)[5]);

      if (pointer && event && x && y && size && pressure && view) {
        view->setPointerUpdate(*pointer,
          static_cast<flutter_inappwebview_plugin::InAppWebViewPointerEventKind>(*event),
          *x, *y, *size, *pressure);
        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }

    // setScrollDelta: [double dx, double dy]
    if (method_name.compare(kMethodSetScrollDelta) == 0) {
      const auto delta = GetPointFromArgs(method_call.arguments());
      if (delta && view) {
        view->setScrollDelta(delta->first, delta->second);
        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }

    // setPointerButton: {"button": int, "isDown": bool}
    if (method_name.compare(kMethodSetPointerButton) == 0) {
      const auto& map = std::get<flutter::EncodableMap>(*method_call.arguments());

      const auto button = map.find(flutter::EncodableValue("button"));
      const auto isDown = map.find(flutter::EncodableValue("isDown"));
      if (button != map.end() && isDown != map.end()) {
        const auto buttonValue = std::get_if<int32_t>(&button->second);
        const auto isDownValue = std::get_if<bool>(&isDown->second);
        if (buttonValue && isDownValue && view) {
          view->setPointerButtonState(
            static_cast<flutter_inappwebview_plugin::InAppWebViewPointerButton>(*buttonValue), *isDownValue);
          return result->Success();
        }
      }
      return result->Error(kErrorInvalidArgs);
    }

    // setSize: [double width, double height, double scale_factor]
    if (method_name.compare(kMethodSetSize) == 0) {
      auto size = GetPointAndScaleFactorFromArgs(method_call.arguments());
      if (size && view) {
        const auto [width, height, scale_factor] = size.value();

        WgcLog::Write("set-size", nullptr,
          SetSizeDetail(width, height, scale_factor, texture_id_,
            texture_bridge_.get()));
        view->setSurfaceSize(static_cast<size_t>(width),
          static_cast<size_t>(height),
          static_cast<float>(scale_factor));

        texture_bridge_->Start();
        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }
    else if (method_name.compare(kMethodSetPosition) == 0) {
      auto position = GetPointAndScaleFactorFromArgs(method_call.arguments());
      if (position && view) {
        const auto [x, y, scale_factor] = position.value();

        view->setPosition(static_cast<size_t>(x),
          static_cast<size_t>(y),
          static_cast<float>(scale_factor));

        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }
    else if (method_name.compare(kMethodSetFpsLimit) == 0) {
      if (const auto value = std::get_if<int32_t>(method_call.arguments())) {
        texture_bridge_->SetFpsLimit(*value == 0 ? std::nullopt
          : std::make_optional(*value));
        return result->Success();
      }
    }

    result->NotImplemented();
  }
}

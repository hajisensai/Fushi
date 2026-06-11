import "dart:io";

import "package:flutter_test/flutter_test.dart";

/// BUG-113/BUG-163/BUG-209 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// flutter_inappwebview_windows）的 TextureBridge::StopInternal() 必须按 dump 实证
/// 的根因修复契约拆除：Close session -> remove_FrameArrived 断源 -> Close 帧池设
/// closed-flag -> 帧池 ComPtr 移交进程级退役注册表代际保活。
///
/// 根因（dump 决定性证据 hibiki.exe.8952.dmp / .99916.dmp，cdb analyze）：WGC 把
/// FirePresentEvent 作为 deferred call 排进 UI 线程 CoreMessaging 队列，已排队的
/// 事件会在 teardown 之后才 fire，且不持帧池强引用。当 teardown 释放帧池唯一强
/// 引用时帧池立即析构，迟到的 deferred FirePresentEvent 之后读已释放的帧池 event
/// 成员（framepool+0x60 的 m_targets）-> 野 delegate 数组 -> null TypedEventHandler
/// -> GraphicsCapture.dll c0000005（operator+0x15, rcx=0）。
///
/// 前七修共同盲点：都在判断或依赖在途 deferral 的时机或引用（drain-hop 判排空、
/// 赌 deferral 持强引用延后析构），dump 全部反证：deferral 不持强引用，帧池在
/// FirePresentEvent 运行期已被释放。根因修复用两层因果不变量：(1) teardown 显式
/// Close 帧池（同步设 closed-flag，让在途 FirePresentEvent 在开头 cmp 早返回
/// no-op，不读 event 成员）；(2) 帧池 ComPtr 移交 RetiredFramePoolRegistry 保活，
/// 按代延迟释放（只释放比当前 teardown 早 >=2 代的退役帧池），使帧池内存在可能有
/// 在途 deferral 的窗口内绝不释放。
void main() {
  test(
      "BUG-209: TextureBridge teardown closes pool and retires it to survive "
      "in-flight FrameArrived", () {
    final List<String> sourceCandidates = <String>[
      "packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc",
      "../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc",
    ];
    final List<String> headerCandidates = <String>[
      "packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h",
      "../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h",
    ];
    final List<String> platformViewSourceCandidates = <String>[
      "packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc",
      "../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc",
    ];
    final List<String> platformViewHeaderCandidates = <String>[
      "packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h",
      "../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h",
    ];
    final File? sourceFile = sourceCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    final File? headerFile = headerCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    final File? platformViewSourceFile = platformViewSourceCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    final File? platformViewHeaderFile = platformViewHeaderCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    expect(sourceFile, isNotNull, reason: "texture_bridge.cc 未找到");
    expect(headerFile, isNotNull, reason: "texture_bridge.h 未找到");
    expect(platformViewSourceFile, isNotNull,
        reason: "custom_platform_view.cc 未找到");
    expect(platformViewHeaderFile, isNotNull,
        reason: "custom_platform_view.h 未找到");

    final String src = sourceFile!.readAsStringSync();
    final String header = headerFile!.readAsStringSync();
    final String platformViewSrc = platformViewSourceFile!.readAsStringSync();
    final String platformViewHeader =
        platformViewHeaderFile!.readAsStringSync();

    expect(src.contains("BUG-209"), isTrue,
        reason: "修复说明注释应保留 BUG-209，标识 dump 实证的崩溃根因与修复契约");
    expect(src.contains("FrameArrivedCallbackState"), isTrue,
        reason: "FrameArrived 回调必须捕获独立状态，不能只捕获裸 this");
    expect(src.contains("InvalidateFrameArrivedCallback"), isTrue,
        reason: "Stop/dtor 必须先失效回调状态，再拆 frame pool");
    expect(src.contains("[callback_state]"), isTrue,
        reason: "FrameArrived lambda 应捕获 callback_state，迟到事件只读安全状态");
    expect(
        src.contains(
            "[this](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*"),
        isFalse,
        reason: "FrameArrived lambda 不能捕获裸 this；teardown 后迟到事件会 UAF");
    expect(header.contains("frame_arrived_handler_"), isTrue,
        reason: "TextureBridge 必须持有 FrameArrived delegate COM 对象本体");
    expect(src.contains("frame_arrived_handler_ = Microsoft::WRL::Callback"),
        isTrue,
        reason: "FrameArrived delegate 不能只用 add_FrameArrived 里的临时 Callback");
    expect(src.contains("frame_arrived_handler_.Get()"), isTrue,
        reason: "add_FrameArrived 必须注册由 TextureBridge 成员持有的 delegate");
    expect(
      RegExp(r"add_FrameArrived\s*\(\s*Microsoft::WRL::Callback", dotAll: true)
          .hasMatch(src),
      isFalse,
      reason: "禁止恢复成临时 add_FrameArrived Callback delegate",
    );
    final int handlerIndex = header.indexOf("frame_arrived_handler_");
    final int framePoolIndex = header.indexOf("frame_pool_");
    expect(handlerIndex, greaterThanOrEqualTo(0));
    expect(framePoolIndex, greaterThanOrEqualTo(0));
    expect(handlerIndex, lessThan(framePoolIndex),
        reason: "成员析构逆序执行；delegate 成员必须声明在 frame_pool_ 前");

    expect(src.contains("CreateFreeThreadedCaptureFramePool"), isFalse,
        reason: "禁止 FreeThreaded 帧池回潮：Release 下 WebView 纹理全空（书籍无字）");
    expect(src.contains("graphics_context_->CreateCaptureFramePool("), isTrue,
        reason: "必须保持 CreateCaptureFramePool（UI 线程 DispatcherQueue 派发）");

    final int stopInternalStart =
        src.indexOf("void TextureBridge::StopInternal()");
    expect(stopInternalStart, greaterThanOrEqualTo(0),
        reason: "TextureBridge::StopInternal 必须可审计");
    final int stopInternalEnd =
        src.indexOf("void TextureBridge::", stopInternalStart + 1);
    expect(stopInternalEnd, greaterThan(stopInternalStart),
        reason: "StopInternal 之后应还有其它 TextureBridge 方法定义");
    final String stopInternalBody =
        src.substring(stopInternalStart, stopInternalEnd);

    final int siSessionClose =
        stopInternalBody.indexOf("session_closable->Close()");
    expect(siSessionClose, greaterThanOrEqualTo(0),
        reason: "StopInternal 必须先 Close capture session 停止产生新帧");
    final int siRevoke = stopInternalBody
        .indexOf("remove_FrameArrived(on_frame_arrived_token_)");
    expect(siRevoke, greaterThan(siSessionClose),
        reason: "StopInternal 必须在 Close session 后同步 remove_FrameArrived 断源");
    final int siPoolClose = stopInternalBody.indexOf("pool_closable");
    expect(siPoolClose, greaterThan(siRevoke),
        reason: "StopInternal 必须在 remove_FrameArrived 之后显式 Close 帧池"
            "（IClosable）设 closed-flag：在途/迟到 deferred FirePresentEvent 据此"
            "早返回 no-op，不读 event 成员（dump 实证根因防线）");
    expect(RegExp(r"pool_closable\s*->\s*Close\(\)").hasMatch(stopInternalBody),
        isTrue,
        reason: "StopInternal 必须对帧池 IClosable 调用 Close 设 closed-flag");
    final int siRetire = stopInternalBody.indexOf(
        "RetiredFramePoolRegistry::Instance().Retire(std::move(frame_pool_))");
    expect(siRetire, greaterThan(siPoolClose),
        reason: "StopInternal 必须在 Close 帧池后把帧池 ComPtr move 进 "
            "RetiredFramePoolRegistry 保活：帧池内存在所有在途 deferral 跑完前绝不释放");
    final int siPoolNull =
        stopInternalBody.indexOf("frame_pool_ = nullptr", siRetire);
    expect(siPoolNull, greaterThan(siRetire),
        reason: "frame_pool_ 必须先 move 进退役注册表再置空：不得在 teardown 当下"
            "释放帧池最后强引用（第七修的赌注，已被 dump 反证）");

    expect(src.contains("TryEnqueueWithPriority"), isFalse,
        reason: "禁止回退到第五修的 Low 优先级押注模型");
    expect(src.contains("DispatcherQueuePriority_Low"), isFalse,
        reason: "禁止 Low 优先级押注（第五修被 dump 反证失败）");
    expect(src.contains("kCaptureTeardownQuietHops"), isFalse,
        reason: "quiet-hop 押注模型已被 Close + 退役保活取代");
    expect(src.contains("kCaptureTeardownDrainHops"), isFalse,
        reason: "drain-hop 延迟 Close 押注已被 Close + 退役保活取代");
    expect(src.contains("PendingCaptureTeardown"), isFalse,
        reason: "不再用延迟销毁 holder 判排空：Close 设 closed-flag + 退役注册表代际保活");
    expect(src.contains("RetiredFramePoolRegistry"), isTrue,
        reason: "必须有进程级退役帧池注册表保活已 Close 的帧池");
    expect(src.contains("kRetiredGenerationGap"), isTrue,
        reason: "退役注册表必须按代延迟释放（>=2 代跨完整消息循环才释放）");

    final int destructorStart =
        platformViewSrc.indexOf("CustomPlatformView::~CustomPlatformView()");
    final int nextMethodStart = platformViewSrc
        .indexOf("void CustomPlatformView::RegisterEventHandlers()");
    expect(destructorStart, greaterThanOrEqualTo(0),
        reason: "CustomPlatformView 析构路径必须可审计");
    expect(nextMethodStart, greaterThan(destructorStart),
        reason: "CustomPlatformView 析构路径必须可审计");
    final String destructorBody =
        platformViewSrc.substring(destructorStart, nextMethodStart);
    final int stopIndex = destructorBody.indexOf("texture_bridge_->Stop()");
    final int unregisterIndex =
        destructorBody.indexOf("texture_registrar_->UnregisterTexture");
    expect(stopIndex, greaterThanOrEqualTo(0),
        reason: "注销 Flutter texture 前必须显式 Stop WGC bridge");
    expect(unregisterIndex, greaterThanOrEqualTo(0),
        reason: "CustomPlatformView 析构应注销 Flutter texture");
    expect(stopIndex, lessThan(unregisterIndex),
        reason: "Stop 必须发生在 UnregisterTexture 前");
    final int severIndex =
        destructorBody.indexOf("SetOnFrameAvailable(nullptr)");
    expect(severIndex, greaterThanOrEqualTo(0),
        reason: "析构必须切断 frame_available_：置空后迟到帧不再打进正在拆除的 registrar");
    expect(severIndex, lessThan(stopIndex),
        reason: "SetOnFrameAvailable(nullptr) 必须在 texture_bridge_->Stop() 之前");
    final int textureBridgeMemberIndex =
        platformViewHeader.indexOf("texture_bridge_");
    final int flutterTextureMemberIndex =
        platformViewHeader.indexOf("flutter_texture_");
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(textureBridgeMemberIndex, lessThan(flutterTextureMemberIndex),
        reason: "成员析构逆序执行，应先销毁 flutter_texture_ 再销毁 texture_bridge_");
  });
}

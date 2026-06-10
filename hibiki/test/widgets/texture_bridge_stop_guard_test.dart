import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-113 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// `flutter_inappwebview_windows`）的 `TextureBridge::StopInternal()` 必须在拆除
/// 时 `Close()` 并置空 `frame_pool_`。否则未 Close 的 Direct3D11CaptureFramePool
/// 会在弹窗 WebView2 销毁后仍向 UI 线程派发迟到的一帧，打进已释放对象 →
/// GraphicsCapture.dll 内空指针解引用 c0000005（用户「查词点制卡」高频闪退，
/// 已由崩溃转储 + 调用栈确认）。
///
/// 真实的图形崩溃只能在 Windows 真机重编后复测；此守卫防止 Close() 和
/// FrameArrived delegate 生命周期防线被回退。
void main() {
  test('BUG-113: TextureBridge teardown makes late FrameArrived callbacks safe',
      () {
    final List<String> sourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ];
    final List<String> headerCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
    ];
    final List<String> platformViewSourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
    ];
    final List<String> platformViewHeaderCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h',
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
    expect(sourceFile, isNotNull, reason: 'texture_bridge.cc 未找到（路径变更？）');
    expect(headerFile, isNotNull, reason: 'texture_bridge.h 未找到（路径变更？）');
    expect(platformViewSourceFile, isNotNull,
        reason: 'custom_platform_view.cc 未找到（路径变更？）');
    expect(platformViewHeaderFile, isNotNull,
        reason: 'custom_platform_view.h 未找到（路径变更？）');

    final String src = sourceFile!.readAsStringSync();
    final String header = headerFile!.readAsStringSync();
    final String platformViewSrc = platformViewSourceFile!.readAsStringSync();
    final String platformViewHeader =
        platformViewHeaderFile!.readAsStringSync();
    expect(src.contains('BUG-113'), isTrue, reason: '修复说明注释应保留，标识此处的崩溃根因');
    expect(src.contains('FrameArrivedCallbackState'), isTrue,
        reason: 'FrameArrived 回调必须捕获独立状态，不能只捕获裸 this');
    expect(src.contains('InvalidateFrameArrivedCallback'), isTrue,
        reason: 'Stop/dtor 必须先失效回调状态，再拆 frame pool');
    expect(src.contains('[callback_state]'), isTrue,
        reason: 'FrameArrived lambda 应捕获 callback_state，迟到事件只读安全状态');
    expect(
        src.contains(
            '[this](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*'),
        isFalse,
        reason: 'FrameArrived lambda 不能捕获裸 this；teardown 后迟到事件会 UAF');
    expect(header.contains('frame_arrived_handler_'), isTrue,
        reason:
            'TODO-021 复发 dump 死在 GraphicsCapture 的空 TypedEventHandler，TextureBridge 必须持有 FrameArrived delegate COM 对象本体');
    expect(src.contains('frame_arrived_handler_ = Microsoft::WRL::Callback'),
        isTrue,
        reason: 'FrameArrived delegate 不能只用 add_FrameArrived 参数里的临时 Callback');
    expect(src.contains('frame_arrived_handler_.Get()'), isTrue,
        reason: 'add_FrameArrived 必须注册由 TextureBridge 成员持有的 delegate');
    expect(
      RegExp(r'add_FrameArrived\s*\(\s*Microsoft::WRL::Callback', dotAll: true)
          .hasMatch(src),
      isFalse,
      reason: '禁止恢复成 add_FrameArrived(Callback(...).Get()) 临时 delegate',
    );
    final int handlerIndex = header.indexOf('frame_arrived_handler_');
    final int framePoolIndex = header.indexOf('frame_pool_');
    expect(handlerIndex, greaterThanOrEqualTo(0));
    expect(framePoolIndex, greaterThanOrEqualTo(0));
    expect(handlerIndex, lessThan(framePoolIndex),
        reason: '成员析构逆序执行；delegate 成员必须声明在 frame_pool_ 前，让 frame_pool_ 先释放');
    expect(src.contains('remove_FrameArrived'), isFalse,
        reason: '已排队的 FirePresentEvent 会在 remove 后命中空 delegate；关闭并释放 pool 即可');
    expect(src.contains('pool_closable'), isTrue,
        reason: '帧池最终仍要取 IClosable 并 Close()（在保序销毁 hop 收敛后），不能只靠引用计数');
    expect(src.contains('frame_pool_ = nullptr'), isTrue,
        reason: 'teardown 必须把 frame_pool_ 移出 bridge 并置空，bridge 析构不再触碰捕获资源');
    final int destructorStart =
        platformViewSrc.indexOf('CustomPlatformView::~CustomPlatformView()');
    final int nextMethodStart = platformViewSrc
        .indexOf('void CustomPlatformView::RegisterEventHandlers()');
    expect(destructorStart, greaterThanOrEqualTo(0),
        reason: 'CustomPlatformView 析构路径必须可审计');
    expect(nextMethodStart, greaterThan(destructorStart),
        reason: 'CustomPlatformView 析构路径必须可审计');
    final String destructorBody =
        platformViewSrc.substring(destructorStart, nextMethodStart);
    final int stopIndex = destructorBody.indexOf('texture_bridge_->Stop()');
    final int unregisterIndex =
        destructorBody.indexOf('texture_registrar_->UnregisterTexture');
    expect(stopIndex, greaterThanOrEqualTo(0),
        reason: '注销 Flutter texture 前必须显式 Stop WGC bridge，避免消息泵中派发迟到帧');
    expect(unregisterIndex, greaterThanOrEqualTo(0),
        reason: 'CustomPlatformView 析构应注销 Flutter texture');
    expect(stopIndex, lessThan(unregisterIndex),
        reason:
            'Stop 必须发生在 UnregisterTexture 前；UnregisterTexture 期间可能处理 CoreMessaging 队列里的 WGC FirePresentEvent');
    final int textureBridgeMemberIndex =
        platformViewHeader.indexOf('texture_bridge_');
    final int flutterTextureMemberIndex =
        platformViewHeader.indexOf('flutter_texture_');
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(textureBridgeMemberIndex, lessThan(flutterTextureMemberIndex),
        reason:
            'TextureVariant 的回调捕获 TextureBridge 裸指针；成员析构逆序执行，应先销毁 flutter_texture_ 再销毁 texture_bridge_');

    // ---- TODO-031 第五修（BUG-163）：保序销毁，禁止 FreeThreaded 回潮 ----
    //
    // 第四修把帧池换成 CreateFreeThreadedCaptureFramePool 虽消灭崩溃路径，
    // 但 Release 构建下 WebView 纹理不再更新（书籍文字全部不显示），
    // 2026-06-10 用户实证 v1 无字 / v2 revert 有字后被退回。
    // 渲染管线必须保持 UI 线程 DispatcherQueue 派发的 CreateCaptureFramePool；
    // 崩溃改由「teardown 资源移交 holder + 同队列 Low 优先级延迟释放」解决：
    // 已排队的 FirePresentEvent 先于释放执行（队列 serially and in priority
    // order；Low 只在没有 Normal/High 待处理工作时运行），此时 active=false
    // 安全返回，之后才 Close+释放帧池/delegate。
    expect(src.contains('CreateFreeThreadedCaptureFramePool'), isFalse,
        reason: '禁止 FreeThreaded 帧池回潮：Release 构建下 WebView 纹理全空'
            '（书籍无字），已被用户实证退回；杀崩溃只能用保序销毁');
    expect(src.contains('graphics_context_->CreateCaptureFramePool('), isTrue,
        reason: '必须保持 CreateCaptureFramePool（UI 线程 DispatcherQueue 派发），'
            '渲染管线线程模型不得改变');
    expect(src.contains('PendingCaptureTeardown'), isTrue,
        reason: 'teardown 必须把帧池/delegate/回调状态整组移交延迟销毁 holder，'
            '让它们活过所有已排队的 FirePresentEvent');
    expect(src.contains('TryEnqueueWithPriority'), isTrue,
        reason: 'holder 释放必须经 WGC 派发 FirePresentEvent 的同一个 '
            'DispatcherQueue 排队，靠队列保序晚于已排队事件执行');
    expect(src.contains('DispatcherQueuePriority_Low'), isTrue,
        reason: '释放 hop 必须用 Low 优先级：只要队列里还有 Normal/High 的 '
            'FirePresentEvent（含晚于 hop 入队的），释放就不会执行');
    expect(src.contains('kCaptureTeardownQuietHops'), isTrue,
        reason: '必须保留「连续安静 hop 才释放、有迟到帧重新计数」的收敛协议，'
            '覆盖 session Close 后捕获通道迟到 post 的事件');
    final int stopInternalStart =
        src.indexOf('void TextureBridge::StopInternal()');
    expect(stopInternalStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::StopInternal 必须可审计');
    final int stopInternalEnd =
        src.indexOf('void TextureBridge::', stopInternalStart + 1);
    expect(stopInternalEnd, greaterThan(stopInternalStart),
        reason: 'StopInternal 之后应还有其它 TextureBridge 方法定义');
    final String stopInternalBody =
        src.substring(stopInternalStart, stopInternalEnd);
    expect(stopInternalBody.contains('ScheduleCaptureTeardown'), isTrue,
        reason: 'StopInternal 必须走 ScheduleCaptureTeardown 移交捕获资源');
    expect(stopInternalBody.contains('pool_closable'), isFalse,
        reason: 'StopInternal 不得当场 Close 帧池：已排队的 FirePresentEvent '
            '之后才 fire，会命中被撤销的 WGC delegate 表（11:53 dump 实证三防线'
            '够不着）；Close 只能发生在保序销毁 hop 收敛之后');
  });
}

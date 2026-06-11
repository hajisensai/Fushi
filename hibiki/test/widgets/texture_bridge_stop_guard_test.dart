import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-113/BUG-163 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// `flutter_inappwebview_windows`）的 `TextureBridge::StopInternal()` 必须按
/// 「先同步 `remove_FrameArrived` 断源、再仅释放我们的 `frame_pool_` ComPtr、
/// **绝不对帧池显式调用 `Close()`**」的 ComPtr-release 销毁序拆除。
///
/// 根因：WGC 把 `FirePresentEvent` 作为 deferred call 排进 UI 线程 CoreMessaging
/// 队列，已排队的事件会在 teardown 之后才 fire，且对帧池持强引用。任何在 teardown
/// 当下对帧池的显式 `Close()`（撤销 WGC 内部 delegate 表）都会让迟到事件遍历到
/// null `TypedEventHandler` → GraphicsCapture.dll c0000005（`operator()+0x15`,
/// `rcx=0`，已由 dump + 栈确认）。把帧池的析构（→ 自然 Close）交给在途 deferral
/// 的强引用收尾（引用计数归零），即可让 Close 在因果上必然晚于所有在途事件 fire，
/// 杜绝 Close-while-in-flight。
///
/// TODO-061 第八修补上前七修共同漏掉的**消费者侧**缺口：`frame_available_` 回调
/// 捕获 `texture_registrar_` 裸指针 + `texture_id_`，从不切断。2026-06-11 退出
/// dump 实证崩溃已从 GraphicsCapture.dll 移到 flutter_windows.dll!
/// FlutterDesktopViewControllerDestroy -> MarkExternalTextureFrameAvailable
/// （rcx=0）——迟到帧把 MarkTextureFrameAvailable() 打进正被引擎拆除的 registrar。
/// 故 `~CustomPlatformView` 析构第一步必须 `SetOnFrameAvailable(nullptr)`（在
/// `Stop()` 之前），物理切断「WGC 生产者 -> registrar 消费者」边。
///
/// 真实的图形崩溃只能在 Windows 真机重编后复测；此守卫锁「同步 revoke 断源 +
/// 不显式 Close 帧池 + 析构第一步切断 frame_available_」的契约，防止它被回退到
/// 显式 Close / drain-hop 押注模型，或丢掉消费者侧切断。
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
    // ---- TODO-061（BUG-163 方向B / ComPtr-release）：必须同步 revoke 断源 ----
    //
    // 第 1~5 修自 TODO-013 起删除了 remove_FrameArrived，赌延迟 Close/优先级仲裁
    // 让在途 deferred FirePresentEvent 先跑完，dump 反证仍崩。方向B 的根因修复是
    // 用同步原语 remove_FrameArrived 在帧池仍存活时把我们的 handler 从 WGC 内部
    // delegate 表摘掉（断源），再仅释放我们的 frame_pool_ ComPtr —— **绝不显式
    // Close 帧池**，把析构（→ 自然 Close）交给在途 deferral 强引用收尾。
    expect(src.contains('remove_FrameArrived(on_frame_arrived_token_)'), isTrue,
        reason: 'teardown 必须同步 remove_FrameArrived 断源：返回后 WGC 不再向本 '
            'token 投递新 FirePresentEvent，且帧池仍存活，移除只动有效 delegate 表');
    // 顺序契约：session 先 Close，再同步 revoke FrameArrived。
    final int sessionCloseIdx = src.indexOf('session_closable->Close()');
    final int revokeIdx =
        src.indexOf('remove_FrameArrived(on_frame_arrived_token_)');
    expect(sessionCloseIdx, greaterThanOrEqualTo(0),
        reason: 'teardown 必须先 Close capture session 停止产生新帧');
    expect(revokeIdx, greaterThan(sessionCloseIdx),
        reason: 'remove_FrameArrived 必须在 Close session 之后（先停新帧再断事件源）');
    // 契约核心：teardown 路径**不得**对帧池显式 Close。null-delegate c0000005 只在
    // Close 撤销 WGC delegate 表后才出现；ComPtr-release 把帧池析构（→ 自然 Close）
    // 延到所有在途 deferred FirePresentEvent 释放强引用之后，杜绝 Close-while-in-flight。
    expect(src.contains('pool_closable'), isFalse,
        reason: 'teardown 路径不得取帧池 IClosable 显式 Close：帧池析构必须靠在途 '
            'deferral 强引用 + ComPtr 引用计数自然收尾（不显式 Close）');
    expect(src.contains('frame_pool_ = nullptr'), isTrue,
        reason: 'teardown 必须仅释放 frame_pool_ ComPtr（置空），不显式 Close；'
            'bridge 析构不再触碰捕获资源');
    expect(src.contains('frame_arrived_handler_ = nullptr'), isTrue,
        reason: 'teardown 必须也释放我们持有的 FrameArrived delegate ComPtr（置空）');
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
    // ---- TODO-061 第八修（消费者侧切断）：析构第一步必须切断 frame_available_ ----
    //
    // 前七修只控制 WGC 生产者一侧（销毁序 / 不显式 Close 帧池）。2026-06-11 退出 dump
    // 实证崩溃已从 GraphicsCapture.dll 移到 flutter_windows.dll!
    // FlutterDesktopViewControllerDestroy -> MarkExternalTextureFrameAvailable
    // （rcx=0）：迟到的 WGC 帧经 frame_available_ -> MarkTextureFrameAvailable() 打进
    // 正被引擎拆除的 texture registrar。frame_available_ 捕获 texture_registrar_ 裸
    // 指针 + texture_id_，从不切断 = 唯一漏掉的消费者边。修复 = 析构第一步同步
    // SetOnFrameAvailable(nullptr)，且必须在 texture_bridge_->Stop() 之前（先断消费者
    // 边，再走 WGC 销毁序），Stop 仍在 UnregisterTexture 之前。
    final int severIndex =
        destructorBody.indexOf('SetOnFrameAvailable(nullptr)');
    expect(severIndex, greaterThanOrEqualTo(0),
        reason: '析构必须切断 frame_available_：置空后 OnFrameArrived 的 '
            '`if (has_frame && frame_available_)` 短路，迟到帧不再 '
            'MarkTextureFrameAvailable 打进正在拆除的 Flutter texture registrar');
    expect(severIndex, lessThan(stopIndex),
        reason: 'SetOnFrameAvailable(nullptr) 必须在 texture_bridge_->Stop() 之前：'
            '先物理切断「WGC 生产者 -> registrar 消费者」边，再走 WGC 销毁序');
    final int textureBridgeMemberIndex =
        platformViewHeader.indexOf('texture_bridge_');
    final int flutterTextureMemberIndex =
        platformViewHeader.indexOf('flutter_texture_');
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(textureBridgeMemberIndex, lessThan(flutterTextureMemberIndex),
        reason:
            'TextureVariant 的回调捕获 TextureBridge 裸指针；成员析构逆序执行，应先销毁 flutter_texture_ 再销毁 texture_bridge_');

    // ---- TODO-061（BUG-163 方向B / ComPtr-release）：同步 revoke + 不显式 Close ----
    //
    // 第四修把帧池换成 CreateFreeThreadedCaptureFramePool 虽消灭崩溃路径，
    // 但 Release 构建下 WebView 纹理不再更新（书籍文字全部不显示），
    // 2026-06-10 用户实证 v1 无字 / v2 revert 有字后被退回——渲染管线必须保持
    // UI 线程 DispatcherQueue 派发的 CreateCaptureFramePool。
    //
    // 第五修删 remove_FrameArrived，赌「Low 优先级 hop + quiet 计数」让在途
    // deferred FirePresentEvent 先跑完，dump 反证 deferred 事件不受 TryEnqueue
    // 优先级仲裁，仍崩。第六修（方向B 初版）补回同步 remove_FrameArrived，但仍
    // 保留 drain-hop 延迟 Close —— 复核判定 drain 计数对 revoke 后在途 deferral
    // 结构性失明（lambda 已被 revoke 不再自增计数），2 跳必然立刻 Close，仍是赌注。
    //
    // 本修（ComPtr-release）的根因修复：同步 remove_FrameArrived 断源后，**只
    // 释放我们的 frame_pool_ ComPtr，绝不显式 Close 帧池**。在途 deferred
    // FirePresentEvent 对帧池持强引用，帧池析构（→ 自然 Close）只在最后一个在途
    // deferral 跑完（引用计数归零）后发生，那一刻已无事件在迭代 delegate 表。
    // 因果不变量取代概率窗口——禁止回退到任何「延迟/优先级/drain 跳后再显式 Close」
    // 的押注模型。
    expect(src.contains('CreateFreeThreadedCaptureFramePool'), isFalse,
        reason: '禁止 FreeThreaded 帧池回潮：Release 构建下 WebView 纹理全空'
            '（书籍无字），已被用户实证退回');
    expect(src.contains('graphics_context_->CreateCaptureFramePool('), isTrue,
        reason: '必须保持 CreateCaptureFramePool（UI 线程 DispatcherQueue 派发），'
            '渲染管线线程模型不得改变');
    // 禁止回潮第五修 Low 优先级押注模型。
    expect(src.contains('TryEnqueueWithPriority'), isFalse,
        reason: '禁止回退到第五修的 Low 优先级押注模型：dump 反证 deferred '
            'FirePresentEvent 不受 TryEnqueue 优先级仲裁');
    expect(src.contains('DispatcherQueuePriority_Low'), isFalse,
        reason: '禁止 Low 优先级押注（第五修被 dump 反证失败）');
    expect(src.contains('kCaptureTeardownQuietHops'), isFalse,
        reason: 'quiet-hop 押注模型已被同步 revoke + ComPtr-release 取代');
    // 禁止回潮第六修初版的 drain-hop 押注模型（对 revoke 后在途 deferral 失明）。
    expect(src.contains('kCaptureTeardownDrainHops'), isFalse,
        reason: 'drain-hop 延迟 Close 押注已被 ComPtr-release 取代：drain 计数对 '
            'revoke 后在途 deferral 结构性失明，2 跳必然立刻 Close，仍是赌注');
    expect(src.contains('PendingCaptureTeardown'), isFalse,
        reason: '不再用延迟销毁 holder：同步 revoke + 仅释放 ComPtr，帧池靠在途 '
            'deferral 强引用收尾析构');
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
    expect(stopInternalBody.contains('pool_closable'), isFalse,
        reason: 'StopInternal 不得对帧池显式 Close：已排队的 FirePresentEvent 之后'
            '才 fire 且持帧池强引用，析构（→ 自然 Close）必须靠引用计数收尾');
    expect(stopInternalBody.contains('frame_pool_ = nullptr'), isTrue,
        reason: 'StopInternal 必须仅释放 frame_pool_ ComPtr（置空），不显式 Close');
    expect(
        stopInternalBody.contains('frame_arrived_handler_ = nullptr'), isTrue,
        reason: 'StopInternal 必须也释放 FrameArrived delegate ComPtr（置空）');
    // StopInternal 内部必须按 session Close -> remove_FrameArrived 顺序断源。
    final int siSessionClose =
        stopInternalBody.indexOf('session_closable->Close()');
    final int siRevoke = stopInternalBody
        .indexOf('remove_FrameArrived(on_frame_arrived_token_)');
    expect(siSessionClose, greaterThanOrEqualTo(0),
        reason: 'StopInternal 必须先 Close capture session');
    expect(siRevoke, greaterThan(siSessionClose),
        reason: 'StopInternal 必须在 Close session 之后同步 remove_FrameArrived 断源');
    // 释放 frame_pool_ ComPtr 的实际代码语句必须出现在 remove_FrameArrived 之后
    // （revoke 时帧池仍须存活）。用从 revoke 位置起的 indexOf，跳过注释里对
    // `frame_pool_ = nullptr` 的提及，只命中真正的代码语句。
    final int siPoolNull =
        stopInternalBody.indexOf('frame_pool_ = nullptr', siRevoke);
    expect(siPoolNull, greaterThan(siRevoke),
        reason: 'frame_pool_ 置空（代码语句）必须在 remove_FrameArrived 之后：'
            'revoke 时帧池仍须存活，移除才只动有效 delegate 表');
  });
}

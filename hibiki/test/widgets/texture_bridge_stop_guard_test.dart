import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-113/BUG-163/BUG-209 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// flutter_inappwebview_windows）的 TextureBridge::StopInternal() 必须按 dump 实证
/// 的根因修复契约拆除：Close session -> Close 帧池设 closed-flag ->
/// remove_FrameArrived 断源 -> 帧池 ComPtr 移交进程级退役注册表**永久保活**。
///
/// 根因（dump 决定性证据 hibiki.exe.8952.dmp / .99916.dmp，cdb analyze）：WGC 把
/// FirePresentEvent 作为 deferred call 排进 UI 线程 CoreMessaging 队列，已排队的
/// 事件会在 teardown 之后才 fire，且不持帧池强引用。当 teardown 释放帧池唯一强
/// 引用时帧池立即析构，迟到的 deferred FirePresentEvent 之后读已释放的帧池 event
/// 成员（framepool+0x60 的 m_targets）-> 野 delegate 数组 -> null TypedEventHandler
/// -> GraphicsCapture.dll c0000005（operator+0x15, rcx=0）。
///
/// 第八修（代际 retired-list，2 代后释放老帧池）被新 dump 反证：hibiki.exe.81504.dmp
/// （含第八修的包 a8ff069a7，2026-06-12 11:35 崩溃）仍崩同一偏移 0xf0d5，崩溃帧池
/// 内存 MEM_FREE + closed-flag=0（越过 FirePresentEvent 早返回）+ 崩溃栈无 hibiki
/// teardown 帧。即「2 代后释放」是会输的时机赌注：快速连续查词时老帧池在其在途
/// deferral 派发完之前就被代际逻辑 Release -> 内存 free -> deferral fire 读 free
/// 内存（closed-flag 字节随对象消失读到野值 0）-> 崩。closed-flag 双保险只在帧池
/// 内存有效期内成立，代际 Release 一旦释放帧池，双保险随内存消失。
///
/// 前八修共同盲点：都在判断或依赖在途 deferral 的时机或引用（drain-hop 判排空、
/// 赌 deferral 持强引用延后析构、代际 2 代后释放）。WGC 不暴露「deferral 已排空」
/// 的同步信号，故任何「在某时机释放退役帧池」都是赌注。唯一不依赖时机的因果不变量：
/// (1) teardown 显式 Close 帧池（同步设 closed-flag，让在途 FirePresentEvent 在开头
/// cmp 早返回 no-op，不读 event 成员）；(2) 帧池 ComPtr 移交 RetiredFramePoolRegistry
/// **永久保活，绝不主动释放** —— 帧池内存永久有效 -> closed-flag 永久 = 1 ->
/// 任何迟到 deferral 永久安全早返回。已 Close 帧池只剩小 COM 壳（GPU 资源随 Close
/// 释放），是有界小泄漏，换零时机赌注的根治。
///
/// 第九修（永久保活）仍崩（重开 BUG-209 第十修）：第九修只在 StopInternal 走退役保活，
/// 但帧池还有另两条**非 StopInternal** 的丢弃/替换路径漏网，正是 dump 81504 崩溃池
/// MEM_FREE 且不在 retired-list 的来源：
///   (A) Start() 重入覆盖：CustomPlatformView setSize 每次都调 texture_bridge_->Start()。
///       若上一轮 Start 在 CreateCaptureSession/StartCapture 失败后早返回（不设
///       is_running_，但 frame_pool_ 已赋值且已 add_FrameArrived），下一次 Start 越过
///       is_running_ 守卫直接覆盖 frame_pool_ ComPtr -> 旧池裸释放（挂着在途 deferral）。
///   (B) OnFrameArrived resize：原 frame_pool_->Recreate(...) 复用同一池只换 back buffer，
///       但拆掉旧池内部 present 基建，其在途 deferral 仍指向被拆状态 -> UAF。
/// 第十修把退役保活三步（remove_FrameArrived 断源 -> Close 设 closed-flag -> 永久保活）
/// 收敛进单一 RetireFramePoolLocked，StopInternal / Start 重入 / OnFrameArrived resize 三条
/// 路径全走它；resize 改为退役旧池 + 建全新池（RecreateFramePoolLocked），删除裸 Recreate。
/// TODO-453 后第十三修把 RetireFramePoolLocked 内部顺序改为先 Close 后 remove，并补
/// remove / Close / registry / handler release 前后日志：TODO-453 最后一轮日志停在
/// retire 后、retire-close 前，说明必须先设置 closed-flag，压住 remove 期间可能出现的
/// 迟到/重入 FirePresentEvent。
void main() {
  test(
      'BUG-209: TextureBridge teardown closes pool and retires it to survive '
      'in-flight FrameArrived', () {
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
    expect(sourceFile, isNotNull, reason: 'texture_bridge.cc 未找到');
    expect(headerFile, isNotNull, reason: 'texture_bridge.h 未找到');
    expect(platformViewSourceFile, isNotNull,
        reason: 'custom_platform_view.cc 未找到');
    expect(platformViewHeaderFile, isNotNull,
        reason: 'custom_platform_view.h 未找到');

    final String src = sourceFile!.readAsStringSync();
    final String header = headerFile!.readAsStringSync();
    final String platformViewSrc = platformViewSourceFile!.readAsStringSync();
    final String platformViewHeader =
        platformViewHeaderFile!.readAsStringSync();

    expect(src.contains('BUG-209'), isTrue,
        reason: '修复说明注释应保留 BUG-209，标识 dump 实证的崩溃根因与修复契约');
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
    expect(
        header.contains(
            'std::shared_ptr<WgcFramePoolLifetime> frame_pool_lifetime_'),
        isTrue,
        reason:
            'TextureBridge 只持当前 frame-pool lifetime，具体 COM 对象由 lifetime 聚合');
    expect(
        src.contains(
            'Microsoft::WRL::ComPtr<WgcFrameArrivedHandler> frame_arrived_handler'),
        isTrue,
        reason: 'FrameArrived delegate COM 对象本体必须属于 WgcFramePoolLifetime');
    expect(
        src.contains(
            'lifetime->frame_arrived_handler = Microsoft::WRL::Callback'),
        isTrue,
        reason: 'FrameArrived delegate 不能只用 add_FrameArrived 里的临时 Callback');
    expect(src.contains('lifetime->frame_arrived_handler.Get()'), isTrue,
        reason: 'add_FrameArrived 必须注册由 lifetime 持有的 delegate');
    expect(
      RegExp(r'add_FrameArrived\s*\(\s*Microsoft::WRL::Callback', dotAll: true)
          .hasMatch(src),
      isFalse,
      reason: '禁止恢复成临时 add_FrameArrived Callback delegate',
    );
    expect(header.contains('frame_arrived_handler_'), isFalse,
        reason:
            'TextureBridge 不应再直接持有 handler；handler/token/session/pool 必须聚合进 lifetime');
    expect(RegExp(r'\bframe_pool_\s*;').hasMatch(header), isFalse,
        reason: 'TextureBridge 不应再直接持有裸 frame_pool_；禁止裸覆盖/释放');

    expect(src.contains('CreateFreeThreadedCaptureFramePool'), isFalse,
        reason: '禁止 FreeThreaded 帧池回潮：Release 下 WebView 纹理全空（书籍无字）');
    expect(src.contains('graphics_context_->CreateCaptureFramePool('), isTrue,
        reason: '必须保持 CreateCaptureFramePool（UI 线程 DispatcherQueue 派发）');

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

    expect(stopInternalBody.contains('session_closable->Close()'), isFalse,
        reason: 'TODO-468：StopInternal 不能先 Close capture session；'
            '正常路径必须先在 open frame pool 上 remove event token，'
            '成功释放 handler 后再由 lifetime finalize 关闭 session/pool');
    // 第十五修：帧池 token/handler/session/close/registry 收敛进 RetireFramePoolLocked
    // 和 lifetime finalize；StopInternal 只请求退役，不内联拆资源。
    final int siRetireCall = stopInternalBody.indexOf('RetireFramePoolLocked(');
    expect(siRetireCall, greaterThanOrEqualTo(0),
        reason: 'StopInternal 必须请求 RetireFramePoolLocked 退役保活帧池，'
            'remove/handler release/session close/pool close 由 lifetime finalize 统一排序');
    expect(
        stopInternalBody.contains('frame_arrived_handler_ = nullptr'), isFalse,
        reason: 'handler 释放必须由 frame-pool lifetime finalize 在成功 remove 后完成；'
            'StopInternal 不能在不知道 remove 结果时裸释放 handler');

    // RetireFramePoolLocked 体内必须按 dump 实证顺序执行三步根因防线。
    final int retireStart =
        src.indexOf('void TextureBridge::RetireFramePoolLocked(');
    expect(retireStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::RetireFramePoolLocked 必须可审计');
    final int retireEnd = src.indexOf('void TextureBridge::', retireStart + 1);
    expect(retireEnd, greaterThan(retireStart),
        reason: 'RetireFramePoolLocked 之后应还有其它 TextureBridge 方法定义');
    final String retireBody = src.substring(retireStart, retireEnd);

    final int rInactive = retireBody.indexOf('WgcLog::Write("state-inactive"');
    expect(rInactive, greaterThanOrEqualTo(0),
        reason: '退役入口必须先把 callback_state 标成 inactive/retiring，迟到回调 no-op');
    final int rDetachState =
        retireBody.indexOf('InvalidateFrameArrivedCallback', rInactive);
    expect(rDetachState, greaterThan(rInactive),
        reason:
            '写 state-inactive 后必须断开 bridge/callback state，保护迟到 FrameArrived');
    final int rCurrentClear =
        retireBody.indexOf('frame_pool_lifetime_ = nullptr', rDetachState);
    expect(rCurrentClear, greaterThan(rDetachState),
        reason: 'active lifetime 退役后 TextureBridge 只清当前指针；pool 由 registry 保活');
    final int rInHandler = retireBody.indexOf('in_handler', rCurrentClear);
    expect(rInHandler, greaterThan(rCurrentClear),
        reason: 'RetireFramePoolLocked 必须检测当前是否位于 FrameArrived handler 调用栈');
    final int rDeferLog = retireBody.indexOf(
        'WgcLog::Write("retire-defer-in-handler"', rInHandler);
    expect(rDeferLog, greaterThan(rInHandler),
        reason: 'handler 调用栈内退役必须记录 retire-defer-in-handler');
    final int rTryEnqueue = retireBody.indexOf('TryEnqueue', rDeferLog);
    expect(rTryEnqueue, greaterThan(rDeferLog),
        reason: 'handler 调用栈内不得直接 remove；必须投递到同一 DispatcherQueue 下一拍');
    final int rFinalize =
        retireBody.indexOf('FinalizeFramePoolLifetime', rTryEnqueue);
    expect(rFinalize, greaterThan(rTryEnqueue),
        reason: '只有 DispatcherQueue 回调或非 handler 路径才能进入 finalize');

    final int finalizeStart = src.indexOf('void FinalizeFramePoolLifetime(');
    expect(finalizeStart, greaterThanOrEqualTo(0),
        reason: 'frame pool/session/token/handler 聚合对象必须有集中 finalize 逻辑');
    final int finalizeEnd =
        src.indexOf('void TextureBridge::OnFrameArrived', finalizeStart);
    expect(finalizeEnd, greaterThan(finalizeStart),
        reason: 'FinalizeFramePoolLifetime 后应接 TextureBridge 方法定义');
    final String finalizeBody = src.substring(finalizeStart, finalizeEnd);

    final int fRemoveStart =
        finalizeBody.indexOf('WgcLog::Write("remove-before-close-start"');
    expect(fRemoveStart, greaterThanOrEqualTo(0),
        reason: '正常退役必须在 frame pool open 时先 remove event token');
    final int fRemove = finalizeBody
        .indexOf('remove_FrameArrived(lifetime->on_frame_arrived_token)');
    expect(fRemove, greaterThan(fRemoveStart),
        reason: 'remove-before-close-start 后必须同步 remove_FrameArrived');
    final int fRemoveDone = finalizeBody.indexOf(
        'WgcLog::Write("remove-before-close-done"', fRemove);
    expect(fRemoveDone, greaterThan(fRemove),
        reason: 'remove 成功后必须记录 remove-before-close-done');
    final int fTokenClear = finalizeBody.indexOf(
        'lifetime->on_frame_arrived_token = {}', fRemoveDone);
    expect(fTokenClear, greaterThan(fRemoveDone),
        reason: '只有 remove 成功后才能清 token，remove 失败要保留异常证据');
    final int fHandlerRelease = finalizeBody.indexOf(
        'WgcLog::Write("handler-release-start"', fTokenClear);
    expect(fHandlerRelease, greaterThan(fTokenClear),
        reason: '只有 remove 成功后才能释放 handler');
    final int fHandlerNull = finalizeBody.indexOf(
        'lifetime->frame_arrived_handler = nullptr', fHandlerRelease);
    expect(fHandlerNull, greaterThan(fHandlerRelease),
        reason: 'handler release 必须发生在 remove-before-close-done 后');
    final int fHandlerDone = finalizeBody.indexOf(
        'WgcLog::Write("handler-release-done"', fHandlerNull);
    expect(fHandlerDone, greaterThan(fHandlerNull),
        reason: 'handler release 完成必须有 handler-release-done 日志');
    final int fSessionCloseStart = finalizeBody.indexOf(
        'WgcLog::Write("session-close-start"', fHandlerDone);
    expect(fSessionCloseStart, greaterThan(fHandlerDone),
        reason: 'capture_session Close 必须在成功 remove + handler release 之后');
    final int fPoolCloseStart = finalizeBody.indexOf(
        'WgcLog::Write("pool-close-start"', fSessionCloseStart);
    expect(fPoolCloseStart, greaterThan(fSessionCloseStart),
        reason:
            'frame_pool Close 必须晚于 remove-before-close-done 和 session Close');
    expect(finalizeBody.contains('WgcLog::Write("remove-before-close-fail"'),
        isTrue,
        reason: 'remove 失败必须记录 fail，而不是崩溃或假装释放 token/handler');
    expect(
        finalizeBody
            .contains('WgcLog::Write("remove-before-close-closed-unexpected"'),
        isTrue,
        reason: 'open pool 上 remove 若仍遇到 RO_E_CLOSED，必须标成异常而非正常路径');
    expect(finalizeBody.contains('lifetime->remove_failed = true'), isTrue,
        reason: 'remove 失败路径必须保留失败状态，后续不得假装 handler/token 已释放');
    final int fRegisterStart = finalizeBody.indexOf(
        'WgcLog::Write("retire-register-start"', fPoolCloseStart);
    final int fMarkRetired = finalizeBody.indexOf(
        'FramePoolLifetimeRegistry::Instance().MarkRetired(lifetime)',
        fRegisterStart);
    expect(fMarkRetired, greaterThan(fRegisterStart),
        reason: 'Close 完成后必须把同一个 lifetime 从 active 计入 retired registry');
    expect(src.contains('WgcLog::Write("retire-remove-closed"'), isFalse,
        reason: 'retire-remove-closed 是 Close 后 remove 的止血日志，不得作为正常路径保留');
    expect(src.contains('frame_pool_ = nullptr'), isFalse,
        reason: '禁止裸释放/覆盖 frame_pool_；当前指针应是聚合 lifetime，而非裸 pool 成员');

    // 第十修核心：扩展保活到所有「丢弃/替换帧池」的路径。
    // (A) Start() 重入覆盖 frame_pool_ 前必须先退役保活旧池——dump 81504 崩溃池
    //     MEM_FREE 且不在 retired-list，正是从这条路径裸覆盖释放。
    final int startStart = src.indexOf('bool TextureBridge::Start()');
    expect(startStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::Start 必须可审计');
    final int startEnd = src.indexOf('bool TextureBridge::Create', startStart);
    expect(startEnd, greaterThan(startStart),
        reason: 'Start 之后应还有 CreateAndStartFramePoolLocked 定义');
    final String startBody = src.substring(startStart, startEnd);
    expect(startBody.contains('RetireFramePoolLocked('), isTrue,
        reason: 'Start() 在覆盖 frame_pool_ 前必须先 RetireFramePoolLocked 退役旧池：'
            'setSize 每次都调 Start()，CreateCaptureSession/StartCapture 失败后早返回会'
            '留下已 add_FrameArrived 的旧池，下一次 Start 越过 is_running_ 守卫裸覆盖它');

    // (B) OnFrameArrived 的 resize 路径禁止 frame_pool_->Recreate（拆旧池内部 present
    //     基建而在途 deferral 仍指向旧状态 -> UAF），必须改走退役旧池 + 建全新池。
    expect(src.contains('frame_pool_->Recreate('), isFalse,
        reason: '禁止 frame_pool_->Recreate：resize 复用同一池会拆旧内部 present 基建，'
            '其在途 deferred FirePresentEvent 仍指向被拆状态 -> 同一 0xf0d5 null-delegate '
            'UAF。必须改走 RecreateFramePoolLocked（退役旧池保活 + 建全新池）');
    final int onFrameArrivedStart =
        src.indexOf('void TextureBridge::OnFrameArrived(');
    expect(onFrameArrivedStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::OnFrameArrived 必须可审计');
    final String onFrameArrivedBody = src.substring(onFrameArrivedStart);
    expect(onFrameArrivedBody.contains('RecreateFramePoolLocked()'), isTrue,
        reason: 'OnFrameArrived 的 needs_update_(resize) 分支必须走 '
            'RecreateFramePoolLocked 退役保活旧池 + 建全新池，不得裸 Recreate');

    // RecreateFramePoolLocked 必须先退役保活旧池再重建，绝不裸释放/裸 Recreate。
    final int recreateStart =
        src.indexOf('void TextureBridge::RecreateFramePoolLocked()');
    expect(recreateStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::RecreateFramePoolLocked 必须可审计');
    final int recreateEnd =
        src.indexOf('void TextureBridge::', recreateStart + 1);
    expect(recreateEnd, greaterThan(recreateStart),
        reason: 'RecreateFramePoolLocked 之后应还有其它 TextureBridge 方法定义');
    final String recreateBody = src.substring(recreateStart, recreateEnd);
    final int recRetire = recreateBody.indexOf('RetireFramePoolLocked(');
    final int recCreate =
        recreateBody.indexOf('CreateAndStartFramePoolLocked()');
    expect(recRetire, greaterThanOrEqualTo(0),
        reason: 'RecreateFramePoolLocked 必须先退役保活旧池');
    expect(recCreate, greaterThan(recRetire),
        reason: 'RecreateFramePoolLocked 必须在退役旧池后再建全新池（顺序不可换）');

    expect(src.contains('TryEnqueueWithPriority'), isFalse,
        reason: '禁止回退到第五修的 Low 优先级押注模型');
    expect(src.contains('DispatcherQueuePriority_Low'), isFalse,
        reason: '禁止 Low 优先级押注（第五修被 dump 反证失败）');
    expect(src.contains('kCaptureTeardownQuietHops'), isFalse,
        reason: 'quiet-hop 押注模型已被 Close + 退役保活取代');
    expect(src.contains('kCaptureTeardownDrainHops'), isFalse,
        reason: 'drain-hop 延迟 Close 押注已被 Close + 退役保活取代');
    expect(src.contains('PendingCaptureTeardown'), isFalse,
        reason: '不再用延迟销毁 holder 判排空：Close 设 closed-flag + 退役注册表永久保活');
    expect(src.contains('FramePoolLifetimeRegistry'), isTrue,
        reason: '必须有进程级 lifetime 注册表保活 active/retired WGC 帧池对象');
    expect(src.contains('WgcFramePoolLifetime'), isTrue,
        reason:
            'frame pool/session/event token/handler/callback_state 必须聚合进清晰 lifetime');

    // TODO-439：v0.9.0.5025 仍崩在 active/running 帧池。dump 中崩溃池能对应
    // captureLog 第二轮 create-pool，但没有 stop/retire/dtor，只有 start running=1
    // 与 recreate-skip-samesize；因此保活不能只发生在 RetireFramePoolLocked。任何
    // 已经创建并会 add_FrameArrived 的 active pool，必须从 create 起进入进程级强保活，
    // 让 running=1 早返回和同尺寸 skip 都不再是唯一生命周期边界。
    final int createStart =
        src.indexOf('bool TextureBridge::CreateAndStartFramePoolLocked()');
    expect(createStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::CreateAndStartFramePoolLocked 必须可审计');
    final int createEnd = src.indexOf(
        'void TextureBridge::RecreateFramePoolLocked()', createStart);
    expect(createEnd, greaterThan(createStart),
        reason: 'CreateAndStartFramePoolLocked 后应接 RecreateFramePoolLocked');
    final String createBody = src.substring(createStart, createEnd);
    final int cCreatePool =
        createBody.indexOf('graphics_context_->CreateCaptureFramePool(');
    expect(cCreatePool, greaterThanOrEqualTo(0),
        reason: 'CreateAndStartFramePoolLocked 必须创建 WGC frame pool');
    final int cCreatePoolLog =
        createBody.indexOf('WgcLog::Write("create-pool"', cCreatePool);
    expect(cCreatePoolLog, greaterThan(cCreatePool),
        reason: 'create-pool 日志必须记录新建 frame pool 指针，便于和 dump pool 对照');
    final int cActiveRetain = createBody.indexOf(
        'FramePoolLifetimeRegistry::Instance().Retain(lifetime)',
        cCreatePoolLog);
    expect(cActiveRetain, greaterThan(cCreatePoolLog),
        reason: 'TODO-439：create-pool 后必须立刻把 active frame_pool_ 放入进程级强保活；'
            '只在 retire 时保活会漏掉 running=1 / same-size skip 期间被裸释放的 active pool');
    final int cActiveRetainLog =
        createBody.indexOf('WgcLog::Write("active-retain"', cActiveRetain);
    expect(cActiveRetainLog, greaterThan(cActiveRetain),
        reason: 'active retain 必须有独立日志点；下一轮不能再只能靠缺失 retire/dtor 推断');
    final int cAddFrameArrived =
        createBody.indexOf('add_FrameArrived', cActiveRetainLog);
    expect(cAddFrameArrived, greaterThan(cActiveRetainLog),
        reason: 'active retain 必须发生在 add_FrameArrived 之前或同时：一旦注册事件，'
            '这个 pool 就可能已有在途 deferred FirePresentEvent，不能只靠 frame_pool_ 成员强引用');

    final int destructorBridgeStart =
        src.indexOf('TextureBridge::~TextureBridge()');
    expect(destructorBridgeStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge 析构路径必须可审计');
    final int destructorBridgeEnd =
        src.indexOf('bool TextureBridge::Start()', destructorBridgeStart);
    expect(destructorBridgeEnd, greaterThan(destructorBridgeStart),
        reason: 'TextureBridge 析构路径之后应为 Start 定义');
    final String bridgeDestructorBody =
        src.substring(destructorBridgeStart, destructorBridgeEnd);
    expect(bridgeDestructorBody.contains('WgcLog::Write("dtor-enter"'), isTrue,
        reason: '析构入口必须有 dtor-enter 日志，区分 bridge teardown 是否真的发生');
    expect(bridgeDestructorBody.contains('WgcLog::Write("dtor-exit"'), isTrue,
        reason: '析构出口必须有 dtor-exit 日志，下一轮可判断 StopInternal 是否完整跑完');

    // 第八修代际释放（kRetiredGenerationGap，2 代后释放老帧池）被 81504 dump 反证为
    // 会输的时机赌注。永久保活契约：退役注册表只 push、绝不主动释放，禁止任何代际/
    // 时机判断的释放逻辑回潮。
    expect(src.contains('kRetiredGenerationGap'), isFalse,
        reason: '禁止回潮第八修代际释放（2 代后释放）——81504 dump 反证它是会输的时机'
            '赌注，老帧池在其在途 deferral 派发完前被代际 Release -> UAF');
    expect(src.contains('generation_counter_'), isFalse,
        reason: '退役注册表永久保活，不需要代际计数器');
    expect(src.contains('std::remove_if'), isFalse,
        reason: '退役注册表不得用 remove_if 释放任何退役帧池（永久保活，只 push）');
    final int registryStart = src.indexOf('class FramePoolLifetimeRegistry');
    expect(registryStart, greaterThanOrEqualTo(0),
        reason: 'FramePoolLifetimeRegistry 必须可审计');
    final int registryEnd = src.indexOf('};', registryStart);
    expect(registryEnd, greaterThan(registryStart));
    final String registryBody = src.substring(registryStart, registryEnd);
    expect(registryBody.contains('.erase('), isFalse,
        reason: '退役注册表 Retire 不得 erase 任何条目：已 Close 帧池必须永久保活，'
            '内存永久有效使 closed-flag 永久=1，迟到 deferral 永久安全早返回');
    expect(registryBody.contains('push_back'), isTrue,
        reason: 'Retire 必须把帧池 push 进退役注册表保活');
    expect(registryBody.contains('Retain('), isTrue,
        reason: 'TODO-439：注册表必须提供 active retain 入口，覆盖尚未 retire 的 running pool');
    expect(registryBody.contains('MarkRetired('), isTrue,
        reason: 'TODO-468：退役时必须把同一个 lifetime 从 active 计数转为 retired 计数');
    expect(registryBody.contains('lifetimes_'), isTrue,
        reason: 'registry 应用单一 lifetime 列表保活对象，避免 active_/retired_ 双重堆引用');
    expect(registryBody.contains('active_'), isFalse,
        reason: '不要用无语义 active_ 堆列表重复持有同一 pool；active 应从 lifetime 状态计算');
    expect(registryBody.contains('retired_'), isFalse,
        reason: '不要用无语义 retired_ 堆列表重复持有同一 pool；retired 应从 lifetime 状态计算');
    expect(registryBody.contains('RegistryCountsDetail'), isTrue,
        reason: 'registry active/retired 计数必须可写入 registry-size 日志');

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
        reason: '注销 Flutter texture 前必须显式 Stop WGC bridge');
    expect(unregisterIndex, greaterThanOrEqualTo(0),
        reason: 'CustomPlatformView 析构应注销 Flutter texture');
    expect(stopIndex, lessThan(unregisterIndex),
        reason: 'Stop 必须发生在 UnregisterTexture 前');
    final int severIndex =
        destructorBody.indexOf('SetOnFrameAvailable(nullptr)');
    expect(severIndex, greaterThanOrEqualTo(0),
        reason: '析构必须切断 frame_available_：置空后迟到帧不再打进正在拆除的 registrar');
    expect(severIndex, lessThan(stopIndex),
        reason: 'SetOnFrameAvailable(nullptr) 必须在 texture_bridge_->Stop() 之前');
    final int textureBridgeMemberIndex =
        platformViewHeader.indexOf('texture_bridge_');
    final int flutterTextureMemberIndex =
        platformViewHeader.indexOf('flutter_texture_');
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(textureBridgeMemberIndex, lessThan(flutterTextureMemberIndex),
        reason: '成员析构逆序执行，应先销毁 flutter_texture_ 再销毁 texture_bridge_');
  });
}

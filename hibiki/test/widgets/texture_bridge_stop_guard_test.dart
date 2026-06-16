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
    expect(header.contains('frame_arrived_handler_'), isTrue,
        reason: 'TextureBridge 必须持有 FrameArrived delegate COM 对象本体');
    expect(src.contains('frame_arrived_handler_ = Microsoft::WRL::Callback'),
        isTrue,
        reason: 'FrameArrived delegate 不能只用 add_FrameArrived 里的临时 Callback');
    expect(src.contains('frame_arrived_handler_.Get()'), isTrue,
        reason: 'add_FrameArrived 必须注册由 TextureBridge 成员持有的 delegate');
    expect(
      RegExp(r'add_FrameArrived\s*\(\s*Microsoft::WRL::Callback', dotAll: true)
          .hasMatch(src),
      isFalse,
      reason: '禁止恢复成临时 add_FrameArrived Callback delegate',
    );
    final int handlerIndex = header.indexOf('frame_arrived_handler_');
    final int framePoolIndex = header.indexOf('frame_pool_');
    expect(handlerIndex, greaterThanOrEqualTo(0));
    expect(framePoolIndex, greaterThanOrEqualTo(0));
    expect(handlerIndex, lessThan(framePoolIndex),
        reason: '成员析构逆序执行；delegate 成员必须声明在 frame_pool_ 前');

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

    final int siSessionClose =
        stopInternalBody.indexOf('session_closable->Close()');
    expect(siSessionClose, greaterThanOrEqualTo(0),
        reason: 'StopInternal 必须先 Close capture session 停止产生新帧');
    // 第十修：帧池断源 + Close + 退役保活三步收敛进 RetireFramePoolLocked，
    // StopInternal 在 Close session 后调它（不再在 StopInternal 体内内联）。
    final int siRetireCall =
        stopInternalBody.indexOf('RetireFramePoolLocked()');
    expect(siRetireCall, greaterThan(siSessionClose),
        reason: 'StopInternal 必须在 Close session 后调 RetireFramePoolLocked '
            '退役保活帧池（断源 + Close + 永久保活的统一不变量）');
    final int siHandlerRelease = stopInternalBody.indexOf(
        'WgcLog::Write("handler-release"', siRetireCall);
    expect(siHandlerRelease, greaterThan(siRetireCall),
        reason: '释放 frame_arrived_handler_ 前必须写 handler-release 日志，'
            '下一轮取证可区分 handler 已释放与 pool 未 retire 的路径');
    final int siHandlerReleaseDone = stopInternalBody.indexOf(
        'WgcLog::Write("handler-release-done"', siHandlerRelease);
    expect(siHandlerReleaseDone, greaterThan(siHandlerRelease),
        reason: '释放 frame_arrived_handler_ 后必须写 handler-release-done 日志，'
            '下一轮取证可区分 release 前崩溃与 release 已完成');

    // RetireFramePoolLocked 体内必须按 dump 实证顺序执行三步根因防线。
    final int retireStart =
        src.indexOf('void TextureBridge::RetireFramePoolLocked()');
    expect(retireStart, greaterThanOrEqualTo(0),
        reason: 'TextureBridge::RetireFramePoolLocked 必须可审计');
    final int retireEnd = src.indexOf('void TextureBridge::', retireStart + 1);
    expect(retireEnd, greaterThan(retireStart),
        reason: 'RetireFramePoolLocked 之后应还有其它 TextureBridge 方法定义');
    final String retireBody = src.substring(retireStart, retireEnd);

    final int rCloseStart =
        retireBody.indexOf('WgcLog::Write("retire-close-start"');
    expect(rCloseStart, greaterThanOrEqualTo(0),
        reason: 'RetireFramePoolLocked 必须在调用 IClosable::Close 前写 '
            'retire-close-start，定位 Close 内部崩溃/卡死');
    final int rPoolClose = retireBody.indexOf('pool_closable');
    expect(rPoolClose, greaterThan(rCloseStart),
        reason: 'RetireFramePoolLocked 必须先显式 Close 帧池（IClosable）设 '
            'closed-flag，再 remove_FrameArrived；TODO-453 的缺口在 retire 后，'
            '提前 Close 可让 remove 期间任何重入/迟到 FirePresentEvent 先 no-op');
    expect(
        RegExp(r'pool_closable\s*->\s*Close\(\)').hasMatch(retireBody), isTrue,
        reason: 'RetireFramePoolLocked 必须对帧池 IClosable 调用 Close 设 closed-flag');
    final int rCloseLog =
        retireBody.indexOf('WgcLog::Write("retire-close"', rPoolClose);
    expect(rCloseLog, greaterThan(rPoolClose),
        reason: 'Close 帧池后必须写 retire-close 日志，明确 GPU 资源释放/closed-flag 已设置');
    final int rRevokeStart =
        retireBody.indexOf('WgcLog::Write("retire-remove-start"', rCloseLog);
    expect(rRevokeStart, greaterThan(rCloseLog),
        reason: 'remove_FrameArrived 前必须写 retire-remove-start，定位 revoke 内部崩溃');
    final int rRevoke =
        retireBody.indexOf('remove_FrameArrived(on_frame_arrived_token_)');
    expect(rRevoke, greaterThan(rRevokeStart),
        reason: 'RetireFramePoolLocked 必须在 Close 帧池后同步 remove_FrameArrived 断源');
    final int rRevokeLog =
        retireBody.indexOf('WgcLog::Write("retire-remove"', rRevoke);
    expect(rRevokeLog, greaterThan(rRevoke),
        reason: 'remove_FrameArrived 返回后必须写 retire-remove 日志，HRESULT 失败也要可见');
    final int rRetireStart =
        retireBody.indexOf('WgcLog::Write("retire-register-start"', rRevokeLog);
    expect(rRetireStart, greaterThan(rRevokeLog),
        reason: '移交 RetiredFramePoolRegistry 前必须写 retire-register-start');
    final int rRetire = retireBody.indexOf(
        'RetiredFramePoolRegistry::Instance().Retire(std::move(frame_pool_))');
    expect(rRetire, greaterThan(rRetireStart),
        reason: 'RetireFramePoolLocked 必须在 Close 帧池后把帧池 ComPtr move 进 '
            'RetiredFramePoolRegistry 保活：帧池内存在所有在途 deferral 跑完前绝不释放');
    final int rRetireLog =
        retireBody.indexOf('WgcLog::Write("retire-register"', rRetire);
    expect(rRetireLog, greaterThan(rRetire),
        reason: 'RetiredFramePoolRegistry::Retire 返回后必须写 retire-register 日志，'
            '定位 registry 移交是否完成');
    final int rPoolNull =
        retireBody.indexOf('frame_pool_ = nullptr', rRetireLog);
    expect(rPoolNull, greaterThan(rRetireLog),
        reason: 'frame_pool_ 必须先 move 进退役注册表再置空：不得在任何路径裸释放'
            '帧池最后强引用（第七修赌注已被 dump 反证）');

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
    expect(startBody.contains('RetireFramePoolLocked()'), isTrue,
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
        src.indexOf('void TextureBridge::OnFrameArrived()');
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
    final int recRetire = recreateBody.indexOf('RetireFramePoolLocked()');
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
    expect(src.contains('RetiredFramePoolRegistry'), isTrue,
        reason: '必须有进程级退役帧池注册表保活已 Close 的帧池');

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
        'RetiredFramePoolRegistry::Instance().RetainActive(frame_pool_)',
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
    final int registryStart = src.indexOf('class RetiredFramePoolRegistry');
    expect(registryStart, greaterThanOrEqualTo(0),
        reason: 'RetiredFramePoolRegistry 必须可审计');
    final int registryEnd = src.indexOf('};', registryStart);
    expect(registryEnd, greaterThan(registryStart));
    final String registryBody = src.substring(registryStart, registryEnd);
    expect(registryBody.contains('.erase('), isFalse,
        reason: '退役注册表 Retire 不得 erase 任何条目：已 Close 帧池必须永久保活，'
            '内存永久有效使 closed-flag 永久=1，迟到 deferral 永久安全早返回');
    expect(registryBody.contains('push_back'), isTrue,
        reason: 'Retire 必须把帧池 push 进退役注册表保活');
    expect(registryBody.contains('RetainActive('), isTrue,
        reason: 'TODO-439：注册表必须提供 active retain 入口，覆盖尚未 retire 的 running pool');
    expect(registryBody.contains('active_'), isTrue,
        reason: 'TODO-439：active pool 从 create 起也必须被 registry 强持有到进程退出');

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

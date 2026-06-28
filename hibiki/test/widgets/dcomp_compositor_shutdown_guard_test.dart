import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Dart 源码里的行注释（`//` 到行尾，含 `///` 文档注释），用于「先于 exit(0)
/// 调用 native pre-exit hook」这类**代码顺序**断言：源文件的文档注释里常出现
/// `` `exit(0)` `` 字面（如 desktop_lifecycle_service.dart 的方法说明），裸
/// `indexOf('exit(0)')` 会命中注释而非真实代码调用，造成顺序误判（TODO-950）。
/// 这些被守卫的源文件不含「字符串字面量里嵌 `//`」的情况，按行去尾注释即可。
String _stripDartLineComments(String src) {
  return src.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}

/// BUG-255 / TODO-313 Family B 源码守卫：vendored fork flutter_inappwebview_windows
/// 的进程级 DirectComposition Compositor 单例必须在**受控退出时机**释放，绝不能
/// 把最终 COM Release 留给 CRT atexit 表。
///
/// 根因（dump 决定性证据，cdb 分析多份 .dmp）：
///   ExceptionCode e0464645（CoreMessaging Abandonment FailFast），栈为
///     CoreMessaging!Abandonment::Fail
///       <- dcomp!Compositor::CleanupSession+0x54
///       <- CompositorCommon::Destroy <- OnFinalRelease
///       <- flutter_inappwebview_windows_plugin onexit(atexit execute_onexit_table)
///       <- ntdll!RtlExitUserProcess
///   compositor_ 等是 in_app_webview_manager.h 里的 inline static（static storage
///   duration），其最终 Release 落到 CRT atexit；此时 LdrShutdownProcess 已开始拆除
///   CoreMessaging/DispatcherQueue，dcomp Compositor::CleanupSession 对半拆的
///   CoreMessaging 操作 -> FailFast。这是退出时序崩溃，非 FrameArrived UAF（那是
///   Family A / BUG-209，已由 texture_bridge.cc 帧池永久保活覆盖）。
///
/// 修复不变量（受控退出时序，非吞异常）：
///   ① ~InAppWebViewManager() 用 instance_count_ 引用计数，只在最后一个实例析构
///      （受控 teardown：UI 线程、DispatcherQueue 仍存活）时释放共享单例；
///   ② releaseSharedCompositionResources() 按 dcomp -> WinRT 依赖顺序释放：
///      compositor_ 先于 dispatcher_queue_controller_（CleanupSession 跑时 CoreMessaging
///      必须仍完整）。
/// 本守卫扫源码钉死这两条，防回归把释放退回 atexit / 打乱释放顺序。
void main() {
  test(
      'BUG-255: InAppWebViewManager releases dcomp compositor on controlled '
      'shutdown (not CRT atexit), in dcomp->WinRT order', () {
    final List<String> sourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
    ];
    final List<String> headerCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
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
    expect(sourceFile, isNotNull, reason: 'in_app_webview_manager.cpp 未找到');
    expect(headerFile, isNotNull, reason: 'in_app_webview_manager.h 未找到');

    final String src = sourceFile!.readAsStringSync();
    final String header = headerFile!.readAsStringSync();

    // 修复说明注释必须保留 BUG-255 标识，钉住 dump 实证的退出时序根因。
    expect(src.contains('BUG-255'), isTrue,
        reason: '修复说明注释应保留 BUG-255，标识 dcomp 退出时序 FailFast 根因与修复契约');
    expect(header.contains('BUG-255'), isTrue,
        reason: '头文件应注释 inline static 落 atexit 的根因（BUG-255）');

    // ① 引用计数：构造 ++，析构 --，只在归零时释放共享单例。
    expect(header.contains('instance_count_'), isTrue,
        reason: '必须有 instance_count_ 统计存活的 InAppWebViewManager 实例数，'
            '只在最后一个实例析构时释放进程级共享单例');
    expect(src.contains('++instance_count_'), isTrue,
        reason: '构造函数必须登记存活实例（++instance_count_）');

    // 必须有受控释放函数，且不再把 compositor_ 留给 CRT atexit 默默 Release。
    expect(header.contains('releaseSharedCompositionResources'), isTrue,
        reason: '头文件必须声明 releaseSharedCompositionResources（受控释放共享单例）');
    expect(
        src.contains(
            'void InAppWebViewManager::releaseSharedCompositionResources'),
        isTrue,
        reason: '必须实现 releaseSharedCompositionResources');

    // ~InAppWebViewManager() 必须在计数归零时调用受控释放（不依赖 atexit）。
    final int dtorStart =
        src.indexOf('InAppWebViewManager::~InAppWebViewManager()');
    expect(dtorStart, greaterThanOrEqualTo(0),
        reason: '~InAppWebViewManager 必须可审计');
    final int dtorEnd =
        src.indexOf('releaseSharedCompositionResources()', dtorStart);
    // 析构体内必须出现 --instance_count_ 与受控释放调用。
    final int dtorReleaseGuard = src.indexOf('--instance_count_', dtorStart);
    expect(dtorReleaseGuard, greaterThan(dtorStart),
        reason: '~InAppWebViewManager 必须 --instance_count_ 注销实例');
    expect(dtorEnd, greaterThan(dtorReleaseGuard),
        reason:
            '~InAppWebViewManager 必须在计数归零时调用 releaseSharedCompositionResources，'
            '把 compositor_ 的最终 Release 提前到受控时机，而非留给 CRT atexit');

    // ② 释放顺序：compositor_ 必须先于 dispatcher_queue_controller_ 置空，
    //    使 dcomp Compositor::CleanupSession 在 CoreMessaging 仍完整时运行。
    final int relStart = src
        .indexOf('void InAppWebViewManager::releaseSharedCompositionResources');
    expect(relStart, greaterThanOrEqualTo(0));
    final int relEnd = src.indexOf('\n  }', relStart);
    expect(relEnd, greaterThan(relStart),
        reason: 'releaseSharedCompositionResources 必须有完整函数体');
    final String relBody = src.substring(relStart, relEnd);
    final int compositorNull = relBody.indexOf('compositor_ = nullptr');
    final int dqcNull =
        relBody.indexOf('dispatcher_queue_controller_ = nullptr');
    expect(compositorNull, greaterThanOrEqualTo(0),
        reason: 'releaseSharedCompositionResources 必须释放 compositor_');
    expect(dqcNull, greaterThanOrEqualTo(0),
        reason:
            'releaseSharedCompositionResources 必须释放 dispatcher_queue_controller_');
    expect(compositorNull, lessThan(dqcNull),
        reason:
            'compositor_ 必须先于 dispatcher_queue_controller_ 释放：dcomp Compositor 的 '
            'CleanupSession 依赖 CoreMessaging/DispatcherQueue，后者必须存活到前者跑完，'
            '否则在退出阶段重现 e0464645 FailFast');
    // graphics_context_ 也应在受控时机释放（夹在中间）。
    expect(relBody.contains('graphics_context_ = nullptr'), isTrue,
        reason: 'releaseSharedCompositionResources 必须释放 graphics_context_');

    // compositor_ 仍必须是进程级共享单例（inline static），由首个实例创建。
    expect(
        header.contains(
            'inline static winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor_'),
        isTrue,
        reason: 'compositor_ 仍是进程级 inline static 共享单例（修复不改这点，只改释放时机）');
  });

  test(
      'BUG-289: shared dcomp compositor released on root WM_DESTROY (controlled '
      'window-proc time), not solely on ~InAppWebViewManager (which is not '
      'called at process exit), with idempotent guard', () {
    final List<String> sourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
    ];
    final List<String> headerCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
    ];
    final File src =
        sourceCandidates.map(File.new).firstWhere((File f) => f.existsSync());
    final File header =
        headerCandidates.map(File.new).firstWhere((File f) => f.existsSync());
    final String s = src.readAsStringSync();
    final String h = header.readAsStringSync();

    // BUG-289 根因标识必须保留（dump 实证：退出时 ~InAppWebViewManager() 不被调用，
    // compositor_ 落到 CRT atexit 仍 FailFast e0464645，即 BUG-255 的析构释放失效）。
    expect(s.contains('BUG-289'), isTrue,
        reason: '修复说明应保留 BUG-289，标识「析构在进程退出不被调用」这一 BUG-255 失效根因');
    expect(h.contains('BUG-289'), isTrue,
        reason: '头文件应注释 BUG-289（WM_DESTROY 受控释放 + 幂等 flag）');

    // ① 必须经 top-level window proc delegate 在 WM_DESTROY 受控时机释放共享单例，
    //    不再仅依赖析构（dump 证明析构不被调用）。
    expect(s.contains('RegisterTopLevelWindowProcDelegate'), isTrue,
        reason:
            '必须注册 top-level window proc delegate，在 root window WM_DESTROY 受控时机'
            '释放 dcomp compositor，而不是只赌 ~InAppWebViewManager 被调用');
    final int regIdx = s.indexOf('RegisterTopLevelWindowProcDelegate');
    final int wmDestroyIdx = s.indexOf('WM_DESTROY');
    expect(wmDestroyIdx, greaterThanOrEqualTo(0),
        reason: 'delegate 必须在 WM_DESTROY 时触发释放');
    // delegate body 必须在 WM_DESTROY 分支里调用受控释放。
    final int releaseAfterWm =
        s.indexOf('releaseSharedCompositionResources', wmDestroyIdx);
    expect(releaseAfterWm, greaterThan(wmDestroyIdx),
        reason: 'WM_DESTROY 分支必须调用 releaseSharedCompositionResources');
    // delegate 必须在创建共享单例（compositor_ = ... CreateCompositor）之后注册，
    // 确保「先有 compositor_、才挂 WM_DESTROY 释放钩子」。
    final int createCompositorIdx = s.indexOf('CreateCompositor');
    expect(createCompositorIdx, greaterThanOrEqualTo(0));
    expect(regIdx, greaterThan(createCompositorIdx),
        reason: 'window proc delegate 必须在 compositor_ 创建之后注册');

    // ② 幂等守卫：WM_DESTROY 钩子与析构兜底任一先到都安全，只释放一次。
    expect(h.contains('composition_released_'), isTrue,
        reason: '必须有 composition_released_ 幂等 flag（WM_DESTROY 与析构两路径只释放一次）');
    final int relStart = s
        .indexOf('void InAppWebViewManager::releaseSharedCompositionResources');
    expect(relStart, greaterThanOrEqualTo(0));
    final int relEnd = s.indexOf('\n  }', relStart);
    final String relBody = s.substring(relStart, relEnd);
    expect(relBody.contains('composition_released_'), isTrue,
        reason:
            'releaseSharedCompositionResources 开头必须用 composition_released_ 做幂等早返回');
    final int guardIdx = relBody.indexOf('composition_released_');
    final int firstNullIdx = relBody.indexOf('compositor_ = nullptr');
    expect(guardIdx, lessThan(firstNullIdx),
        reason: '幂等早返回必须在真正释放（compositor_ = nullptr）之前');
  });

  test(
      'TODO-489: exit(0) paths run an idempotent native pre-exit hook before '
      'CRT atexit can release dcomp compositor', () {
    File? firstExisting(List<String> candidates) => candidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? file) => file != null && file.existsSync(),
            orElse: () => null);

    final File? nativePreExit = firstExisting(<String>[
      'hibiki/lib/src/platform/desktop/windows_native_pre_exit.dart',
      'lib/src/platform/desktop/windows_native_pre_exit.dart',
    ]);
    final File? lifecycle = firstExisting(<String>[
      'hibiki/lib/src/platform/desktop/desktop_lifecycle_service.dart',
      'lib/src/platform/desktop/desktop_lifecycle_service.dart',
    ]);
    final File? updater = firstExisting(<String>[
      'hibiki/lib/src/utils/misc/platform_updater.dart',
      'lib/src/utils/misc/platform_updater.dart',
    ]);
    final File? managerSource = firstExisting(<String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
    ]);
    final File? managerHeader = firstExisting(<String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h',
    ]);

    expect(nativePreExit, isNotNull,
        reason: 'Dart desktop exit paths need a shared native pre-exit hook.');
    expect(lifecycle, isNotNull);
    expect(updater, isNotNull);
    expect(managerSource, isNotNull);
    expect(managerHeader, isNotNull);

    final String preExitSrc = nativePreExit!.readAsStringSync();
    final String lifecycleSrc = lifecycle!.readAsStringSync();
    final String updaterSrc = updater!.readAsStringSync();
    final String managerSrc = managerSource!.readAsStringSync();
    final String managerHdr = managerHeader!.readAsStringSync();

    expect(preExitSrc.contains('WindowsNativePreExit'), isTrue);
    expect(
        preExitSrc.contains(
            "MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager')"),
        isTrue,
        reason:
            'The hook must target the native WebView manager that owns dcomp.');
    expect(preExitSrc.contains("'prepareForProcessExit'"), isTrue,
        reason: 'The Dart hook must call the native pre-exit method.');
    // TODO-618 fix1: 关窗路径与更新路径不再共享单一 `_prepared` 守卫（旧实现的根因 A1：
    // 走过更新预检置位后关窗静默跳过 native teardown）。改为 per-reason 一次性守卫——同一
    // 退出路径仍幂等，但两条路径互不短路。
    expect(preExitSrc.contains('static bool _prepared = false'), isFalse,
        reason:
            'TODO-618: close/update paths must not share a single one-shot guard.');
    expect(preExitSrc.contains('enum WindowsExitReason'), isTrue,
        reason:
            'Exit reason is the per-path guard key (update vs windowClose).');
    expect(preExitSrc.contains('_preparedReasons.add(reason)'), isTrue,
        reason:
            'Each exit reason is one-shot via a per-reason guard set, not a shared bool.');

    // TODO-950: 剥注释后再定位，避免命中文档注释里的 `exit(0)` 字面（935-E2 给
    // restartApp 加的 `///` 说明含该字面，曾导致顺序断言误判失败）。
    final String lifecycleCode = _stripDartLineComments(lifecycleSrc);
    final int lifecycleHook =
        lifecycleCode.indexOf('WindowsNativePreExit.prepareForExit(');
    final int lifecycleExit = lifecycleCode.indexOf('exit(0)');
    expect(lifecycleHook, greaterThanOrEqualTo(0),
        reason:
            'DesktopLifecycleService.exitApp must call the native pre-exit hook.');
    expect(lifecycleExit, greaterThanOrEqualTo(0));
    expect(lifecycleHook, lessThan(lifecycleExit),
        reason:
            'Native pre-exit must run before DesktopLifecycleService calls exit(0).');

    final String updaterCode = _stripDartLineComments(updaterSrc);
    final int updaterHook =
        updaterCode.indexOf('WindowsNativePreExit.prepareForExit(');
    final int updaterExit = updaterCode.indexOf('(exitProcess ?? exit)(0)');
    expect(updaterHook, greaterThanOrEqualTo(0),
        reason:
            'WindowsInstaller.runAndExit must share the same native pre-exit hook.');
    expect(updaterExit, greaterThanOrEqualTo(0));
    expect(updaterHook, lessThan(updaterExit),
        reason:
            'Update handoff must release native dcomp/WebView/WGC state before exit(0).');

    expect(managerHdr.contains('prepareForProcessExit'), isTrue,
        reason:
            'The native WebView manager must expose a pre-exit teardown entrypoint.');
    expect(managerSrc.contains('"prepareForProcessExit"'), isTrue,
        reason: 'The native method channel must accept prepareForProcessExit.');
    final int nativeMethod = managerSrc.indexOf(
      'void InAppWebViewManager::prepareForProcessExit()',
    );
    expect(nativeMethod, greaterThanOrEqualTo(0),
        reason: 'Native pre-exit teardown must be auditable.');
    final int nativeMethodEnd =
        managerSrc.indexOf('void InAppWebViewManager::', nativeMethod + 1);
    final String nativeBody = managerSrc.substring(
      nativeMethod,
      nativeMethodEnd > nativeMethod ? nativeMethodEnd : managerSrc.length,
    );
    expect(nativeBody.contains('webViews.clear()'), isTrue,
        reason:
            'Pre-exit must release active WebView platform views before dcomp.');
    expect(nativeBody.contains('keepAliveWebViews.clear()'), isTrue,
        reason: 'Pre-exit must release keep-alive WebViews before dcomp.');
    expect(nativeBody.contains('windowWebViews.clear()'), isTrue,
        reason: 'Pre-exit must release pending popup WebViews before dcomp.');
    expect(nativeBody.contains('releaseSharedCompositionResources()'), isTrue,
        reason:
            'Pre-exit must release shared DirectComposition/WinRT resources.');
  });
}

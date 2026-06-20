import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_logs/flutter_logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_intent/receive_intent.dart' as intents;
import 'package:stack_trace/stack_trace.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/popup_main.dart' as popup_entrypoint;
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/wgc_capture_log.dart';
import 'package:hibiki/src/utils/window_caption_channel.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/startup/desktop_window_placement.dart';
import 'package:hibiki/src/startup/webview_prewarm.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/sync/book_exit_sync_scope.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:hibiki/src/media/video/external_video.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:hibiki_core/hibiki_core.dart'
    show VideoBooksCompanion, VideoBookRow;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

Color? _savedSplashColor;

/// 桌面端「从 app 外打开视频文件」时，runner 经 `set_dart_entrypoint_arguments`
/// 把视频路径传进 `main(List<String> args)`；这里暂存，待 app 初始化完成后由
/// [_HoshiReaderAppState] 打开播放页并加入书架。null 表示本次启动不是外部打开视频。
String? _pendingExternalVideoPath;

/// Single source of truth for the status/navigation bar overlay style.
///
/// Maps an app [brightness] to the matching system bar icon brightness while
/// keeping both bars transparent + uncontrasted for edge-to-edge layout. Used
/// both at startup (keyed off the platform brightness, to avoid a white flash
/// before init) and at runtime via an [AnnotatedRegion] keyed off the live
/// theme brightness, so the system navigation bar follows in-app theme
/// switches instead of being frozen at the launch-time platform brightness.
SystemUiOverlayStyle hibikiSystemOverlayStyle(Brightness brightness) {
  // A dark app surface needs light (bright) bar icons; a light surface needs
  // dark icons. We set the icon brightnesses *explicitly* rather than reuse
  // SystemUiOverlayStyle.light/.dark, because both of those presets hardcode
  // systemNavigationBarIconBrightness: Brightness.light (they assume an opaque
  // black nav bar). With our transparent edge-to-edge nav bar that would leave
  // the gesture pill / buttons light on a light theme — invisible, and frozen
  // across theme switches.
  final iconBrightness =
      brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: iconBrightness,
    // iOS: statusBarBrightness is the *background* brightness behind the bar.
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: iconBrightness,
    systemNavigationBarContrastEnforced: false,
  );
}

@pragma('vm:entry-point')
void popupMain() {
  popup_entrypoint.popupMain();
}

/// Application execution starts here.
///
/// [args] are the Dart entrypoint arguments. On Windows the runner forwards the
/// process argv (minus the binary name) via `set_dart_entrypoint_arguments`, so
/// opening a video with Hibiki (file association / drag-onto-exe / CLI) lands the
/// video path here. We stash the first supported video path for the widget tree
/// to act on once the app has finished initialising.
void main([List<String> args = const <String>[]]) {
  // 桌面端：从 args 里挑出外部打开的视频路径（仅 Windows runner 会传 argv）。
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final String? videoArg = firstExternalVideoArg(args);
    if (videoArg != null && File(videoArg).existsSync()) {
      _pendingExternalVideoPath = videoArg;
    }
  }

  /// Run and handle an error zone to customise the action performed upon
  /// an error or exception. This allows for error logging for debug purposes
  /// as well as communicating errors to Crashlytics if enabled.
  runZonedGuarded<Future<void>>(() async {
    /// Necessary to initialise Flutter when running native code before
    /// starting the application.
    final binding = WidgetsFlutterBinding.ensureInitialized();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      await DesktopWindowPlacement.applyInitialPlacement();
      // Intercept the native window-close signal so we can tear down Bonsoir's
      // mDNS event sources (LAN broadcast + discovery) BEFORE the Flutter engine
      // exits. Without this, a queued mDNS event delivered to a torn-down
      // messenger crashes the process on exit (TODO-036, Windows). The actual
      // event-source cut + fast exit runs in
      // [_HoshiReaderAppState.onWindowClose] (TODO-086).
      await windowManager.setPreventClose(true);
      await hotKeyManager.unregisterAll(); // 热重载清理残留全局热键
    }
    JustAudioMediaKit.title = 'Hibiki';
    // 关闭 pitch-shift 控制（默认 true）。开启时 media_kit 的 setRate 会在每次调速时
    // 重写 mpv 的 `af` 音频滤镜图（scaletempo:scale=…）；在 Windows 上播放过程中反复
    // 重配滤镜图会触发 libmpv 进程级崩溃（有声书拖动倍速闪退，BUG-070）。本 app 从不
    // 调用 setPitch（无变调 UI），关掉后调速改走 mpv 原生 `speed` 属性（稳定，不重配
    // 滤镜图），mpv 默认 `audio-pitch-correction=yes` 仍保留音高 → 有声书加速不变调。
    JustAudioMediaKit.pitch = false;
    JustAudioMediaKit.ensureInitialized();
    MediaKit.ensureInitialized();

    /// Ensure no pop-in for the app icon. Precaching is a best-effort
    /// optimisation: if the decode fails (e.g. the CI software-GPU emulator
    /// can't decompress the PNG → "Could not decompress image", or low memory),
    /// it must NOT surface as an unhandled FlutterError — that would both spam
    /// error reporting on real devices and fail the appSmoke integration test.
    /// Swallow it via precacheImage's onError; the icon just falls back to a
    /// one-frame decode-on-demand later.
    binding.addPostFrameCallback((_) async {
      final context = binding.rootElement;
      if (context != null) {
        precacheImage(
          const AssetImage('assets/meta/icon.png'),
          context,
          onError: (Object error, StackTrace? stack) {
            debugPrint('[startup] app icon precache skipped: $error');
          },
        );
      }
    });

    /// Ensure wake prevention is disabled if not reverted from entering a
    /// media source.  WakelockPlus supports all desktop and mobile platforms,
    /// so clear it unconditionally; the try-catch handles unsupported targets.
    try {
      WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Hibiki] wakelock disable on startup failed: $e');
    }
    if (Platform.isAndroid || Platform.isIOS) {
      // Home/menu shell: hide the Android status bar (keep the nav bar) so the
      // always-on OS clock/battery strip stops crowding the top-right action
      // icons (TODO-097). iOS keeps edge-to-edge. Reader/video override this with
      // immersiveSticky on open and restore it via closeMedia on exit.
      unawaited(setHomeShellSystemUiMode());
    }

    // Match system bar overlays to the platform brightness immediately so the
    // status bar and navigation bar don't flash white on dark-mode devices.
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    SystemChrome.setSystemUIOverlayStyle(
      hibikiSystemOverlayStyle(platformBrightness),
    );

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final raw =
            await HibikiChannels.splash.invokeMethod<int>('getSplashColor');
        if (raw != null && raw != 0) _savedSplashColor = Color(raw);
      } catch (e) {
        debugPrint('[Hibiki] getSplashColor failed: $e');
      }

      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    /// Some packages propagate their [StackTrace] in an unusual format as
    /// opposed to the format generated by Dart. This function allows the
    /// Flutter framework to handle such formats so they can be displayed
    /// appropriately.
    FlutterError.demangleStackTrace = (stack) {
      if (stack is Trace) {
        return stack.vmTrace;
      }
      if (stack is Chain) {
        return stack.toTrace().vmTrace;
      }
      return stack;
    };

    /// Construct platform-specific service implementations once, before the
    /// provider container is created.  This value object is injected into both
    /// [platformServicesProvider] (for widget-layer access) and [AppModel]
    /// (via [appProvider]).
    final platformServices = PlatformServices.forCurrentPlatform();

    /// Create the provider container before running the app so the same
    /// [AppModel] instance is shared between the widget tree and the
    /// initialisation call below.
    final container = ProviderContainer(
      overrides: [
        platformServicesProvider.overrideWithValue(platformServices),
      ],
    );

    /// Start the application immediately so the user sees the loading page
    /// rather than a blank white screen while initialisation is in progress.
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const HoshiReaderApp(),
      ),
    );

    /// Initialise error log service.
    await ErrorLogService.instance.init();
    await DebugLogService.instance.init();
    // BUG-209 / TODO-398：把上次运行残留的 Windows WGC 帧捕获生命周期日志
    // 折进错误日志（仅 Windows），纳入现有上传链路，为 GraphicsCapture 延迟
    // UAF 崩溃提供可读的崩前生命周期证据。
    await WgcCaptureLog.foldIntoErrorLog();

    /// Initialise local file-based logging (mobile only).
    if (Platform.isAndroid || Platform.isIOS) {
      await FlutterLogs.initLogs(
        logLevelsEnabled: [
          LogLevel.INFO,
          LogLevel.WARNING,
          LogLevel.ERROR,
          LogLevel.SEVERE
        ],
        timeStampFormat: TimeStampFormat.DATE_FORMAT_1,
        directoryStructure: DirectoryStructure.FOR_DATE,
        logTypesEnabled: ['device', 'network', 'errors'],
        logFileExtension: LogFileExtension.LOG,
        logsRetentionPeriodInDays: 7,
      );
    }

    /// Run the heavy initialisation after the first frame has been scheduled.
    /// [AppModel.isInitialised] will flip to true and notify listeners when
    /// done, causing [HoshiReaderApp] to navigate from [LoadingPage] to
    /// [HomePage].
    await HoshiDicts.preloadTransforms();

    final appModel = container.read(appProvider);
    await appModel.initialise();

    // ── 预热 WebView 引擎 ──────────────────────────────────────────────
    // 用户还在看主页/书架时就把冷启动成本吃掉：~500-1500ms。
    // 移动端可直接预热；桌面端（WebView2）必须等首帧渲染、Flutter view
    // 已挂载后再构造 HeadlessInAppWebView，否则会崩 WebView2。
    final bool isMobilePlatform = Platform.isAndroid || Platform.isIOS;
    final bool isDesktopPlatform =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (shouldPrewarmWebView(
      isMobile: isMobilePlatform,
      isDesktop: isDesktopPlatform,
      lowMemory: appModel.lowMemoryMode,
    )) {
      unawaited(Future(() async {
        try {
          // 桌面端等首帧，保证 Flutter view 已 attach（WebView2 前提）。
          if (isDesktopPlatform) {
            await WidgetsBinding.instance.endOfFrame;
          }
          late final HeadlessInAppWebView warmup;
          warmup = HeadlessInAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('about:blank')),
            onLoadStop: (controller, url) async {
              await Future.delayed(const Duration(milliseconds: 100));
              await warmup.dispose();
              debugPrint('[Hibiki] WebView engine pre-warmed');
            },
          );
          await warmup.run();
        } catch (e) {
          debugPrint('[Hibiki] WebView warmup failed (non-fatal): $e');
        }
      }));
    }

    /// Capture Flutter framework errors with full details.
    FlutterError.onError = (details) {
      // Suppress known Flutter framework bug: RawTooltipState creates
      // multiple tickers from SingleTickerProviderStateMixin.
      final msg = details.exceptionAsString();
      if (msg.contains('SingleTickerProviderStateMixin') &&
          msg.contains('RawTooltipState')) {
        return;
      }
      FlutterError.presentError(details);
      // TODO-607 P0-1：FlutterError 是致命级，用同步 flush 落盘——若这条错误紧接着把
      // 进程带崩（如 build/layout 期的 native 回调异常），异步 append 来不及写盘。
      ErrorLogService.instance.logFatal(
        'FlutterError: ${details.context?.toString() ?? 'unknown'}',
        msg,
        details.stack,
      );
    };

    /// TODO-607 P0-1：平台/引擎层未捕获的异步错误（platform message handler、
    /// 原生回调、microtask 等）不经 [FlutterError.onError] 也不一定经
    /// [runZonedGuarded] 的 onError——它们走 [PlatformDispatcher.onError]。此前没装
    /// 这个钩子，这类错误对错误日志完全不可见（用户报「错误日志一片空白」的一类
    /// 来源）。装上后用同步 flush 落盘（致命级），返回 true 标记「已处理」，避免
    /// 引擎把它再当未处理崩溃上报。
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      ErrorLogService.instance.logFatal('PlatformDispatcher', error, stack);
      return true;
    };
  }, (exception, stack) {
    /// Print error details to the console.
    final details = FlutterErrorDetails(exception: exception, stack: stack);

    /// Log the error. UncaughtZone 是致命级（zone 顶层未捕获），同步 flush 落盘
    /// （TODO-607 P0-1）——这条之后进程往往就终止了，异步 append 来不及写盘。
    ErrorLogService.instance.logFatal('UncaughtZone', exception, stack);
    if (Platform.isAndroid || Platform.isIOS) {
      FlutterLogs.logError(
        'hoshi_reader',
        details.exceptionAsString(),
        stack.toString(),
      );
    }
  });
}

/// Encapsulates theming, spacing and other configurable options pertaining to
/// the entire app, with some parameters dependent on the [AppModel].
class HoshiReaderApp extends ConsumerStatefulWidget {
  /// Initialises an instance of the app.
  const HoshiReaderApp({super.key});

  @override
  ConsumerState<HoshiReaderApp> createState() => _HoshiReaderAppState();
}

class _HoshiReaderAppState extends ConsumerState<HoshiReaderApp>
    with WidgetsBindingObserver, WindowListener {
  final navigatorKey = GlobalKey<NavigatorState>();
  bool _isMainIntent = true;
  StreamSubscription? _intentsSubscription;

  /// 守卫：确保外部打开的视频只被打开一次（[build] 可能多次重建）。
  bool _externalVideoHandled = false;

  /// 守卫：退出清理（停 Bonsoir 事件源）只跑一次，避免 [onWindowClose] 与
  /// [didChangeAppLifecycleState] 的 `detached` 兜底重复触发。
  bool _shutdownStarted = false;

  /// 守卫：Windows 安装器 handoff reconcile 的 post-frame 调度只挂一个。
  bool _windowsUpdateHandoffScheduled = false;

  /// 守卫：Windows 安装器 handoff marker 只在拿到真实 Navigator 后 reconcile 一次。
  bool _windowsUpdateHandoffChecked = false;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    // 桌面端监听原生窗口关闭：配合 main() 里的 setPreventClose(true)，在引擎拆除前
    // 停掉 Bonsoir mDNS 事件源（TODO-036）。
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    HibikiToast.navigatorKey = ref.read(appProvider).navigatorKey;

    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        intents.ReceiveIntent.getInitialIntent().then(
          (intent) => handleIntent(
            intent: intent,
            isInitial: true,
          ),
        );
        _intentsSubscription =
            intents.ReceiveIntent.receivedIntentStream.listen(
          (intent) => handleIntent(
            intent: intent,
            isInitial: false,
          ),
        );
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(appProvider).refreshSystemPalette();
      return;
    }
    // `detached` = the app is about to be terminated (the engine is detaching
    // from the view). Tear down Bonsoir's mDNS event sources here as a fallback
    // for platforms/paths that don't go through window_manager's onWindowClose.
    // Best-effort (the callback isn't awaited by the framework): the primary,
    // guaranteed path on desktop is [onWindowClose] under setPreventClose(true).
    if (state == AppLifecycleState.detached) {
      unawaited(_shutdownSyncSources());
    }
  }

  /// 桌面原生窗口关闭信号（main() 已 setPreventClose(true) → 窗口不会自己关）。
  /// 退出期先切断 Bonsoir 事件源（TODO-036 防崩），flush 数据后 exit(0) 快杀，
  /// 不再同步拆引擎（TODO-086）。详见 [_flushAndExitForWindowClose]。
  @override
  void onWindowClose() async {
    await _flushAndExitForWindowClose();
  }

  @override
  void onWindowMoved() {
    DesktopWindowPlacement.rememberCurrentBounds();
  }

  @override
  void onWindowResized() {
    DesktopWindowPlacement.rememberCurrentBounds();
  }

  /// 桌面关闭快杀路径（TODO-086/BUG-191）。过去这里 await windowManager 的 destroy
  /// 触发原生 WM_DESTROY → 同步逐插件拆 Flutter 引擎（WebView2 / WGC 捕获 /
  /// libmpv），每个原生 teardown 几百 ms~秒级、串行叠加成几秒~十几秒卡死 UI 线程
  /// （用户「关闭要好久」）。改为：① 同步切断 Bonsoir 事件源（TODO-036 防崩）并把
  /// 原生 stop 后台化（根因B：Bonsoir 原生 stop 不归吃满超时）；② await flush 所有
  /// 活跃页面尚未落库的阅读位置/统计/观看时长（[ExitFlushRegistry]）；③ close
  /// database 做 WAL checkpoint，排空后台 isolate 的 pending 写——**这三步保证数据
  /// 完整性**；④ `exit(0)` 进程级终止，跳过 destroy() 的逐插件同步 teardown，由 OS
  /// 回收原生资源（WebView2/libmpv/socket），毫秒级返回。
  ///
  /// 不再调用 windowManager 的 destroy：exit(0) 是原子终止，没有「messenger 已拆但
  /// 进程仍在派发事件」的中间窗口，TODO-036 的崩溃前提随之消失。
  Future<void> _flushAndExitForWindowClose() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final AppModel appModel = ref.read(appProvider);
    try {
      await DesktopWindowPlacement.saveCurrentBoundsNow()
          .timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('[Hibiki] desktop window placement save on exit failed: $e');
    }
    // ① 切断 Bonsoir 事件源（事件订阅同步 cancel；原生 stop fire-and-forget）。
    //    收紧超时到 1.5s：cutEventSourceForExit 不再 await 原生 stop，正常瞬间返回。
    try {
      await appModel.syncServerController
          .shutdownForExitFast()
          .timeout(const Duration(milliseconds: 1500));
    } on TimeoutException {
      debugPrint(
          '[Hibiki] sync source fast shutdown timed out; exiting anyway');
    } catch (e) {
      debugPrint('[Hibiki] sync source fast shutdown failed: $e');
    }
    // ② flush 活跃页面 pending 进度/统计（缓存值落库，不碰退出期正在拆的 WebView）。
    try {
      await ExitFlushRegistry.instance.flushAll();
    } catch (e) {
      debugPrint('[Hibiki] exit flush failed: $e');
    }
    // ②' TODO-132 诉求B：有界 drain 退出书 fire-and-forget 触发的、仍在飞的 app-scope
    //    关书同步（[BookExitSyncScope]）。退出书 export 与页面生命周期解耦后会继续
    //    在后台跑；若用户「退出书后立刻杀应用」，给这些远端传输一个有上限的机会跑完，
    //    避免内容/统计 export 被进程终止打成半截（与 132A/BUG-201 baseline 原子化互补）。
    //    syncContent 默认关时只剩小 JSON，几乎瞬间返回；卡住也由 drain 上限放行，
    //    绝不无限拖住退出。drain 自身不抛（退出清理失败不阻止退出）。
    try {
      await BookExitSyncScope.instance
          .drain(timeout: const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[Hibiki] book-exit sync drain failed: $e');
    }
    // ③ close database：WAL checkpoint + 排空后台 isolate pending 写。退出最后一道
    //    数据完整性闸门——必须在 exit(0) 之前完成。
    try {
      await appModel.closeDatabase();
    } catch (e) {
      debugPrint('[Hibiki] database close on exit failed: $e');
    }
    // ④ 进程级快杀（desktop lifecycle = exit(0)），跳过 destroy() 的同步插件拆除。
    await appModel.platformServices.lifecycle.exitApp();
  }

  /// 停掉 Bonsoir 的 LAN 广播 + 发现（mDNS 事件源）。幂等：与桌面
  /// [onWindowClose] 共享 [_shutdownStarted]，只跑一次。
  ///
  /// 仅作 `detached` 生命周期兜底（移动端 / 不经 window_manager 的退出路径）。桌面
  /// 点 X 走 [_flushAndExitForWindowClose]（flush + closeDB + exit(0)），不再到这里。
  /// 超时上限收紧到 1.5s（TODO-086）：原生 stop 不归时放行，避免拖住退出。
  Future<void> _shutdownSyncSources() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    try {
      await ref
          .read(appProvider)
          .syncServerController
          .shutdownForExit()
          .timeout(const Duration(milliseconds: 1500));
    } on TimeoutException {
      debugPrint('[Hibiki] sync source shutdown on exit timed out; continuing');
    } catch (e) {
      // 退出清理失败不该阻止退出；记一笔即可（不吞静默）。
      debugPrint('[Hibiki] sync source shutdown on exit failed: $e');
    }
  }

  @override
  void dispose() {
    _intentsSubscription?.cancel();
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void handleIntent({
    required intents.Intent? intent,
    required bool isInitial,
  }) async {
    if (intent == null || !mounted) {
      return;
    }

    final String? data = intent.data;
    if (data != null && data.startsWith('hibiki://auth/')) {
      await _handleOAuthRedirect(data);
      return;
    }

    switch (intent.action) {
      case 'android.intent.action.MAIN':
        setState(() {
          _isMainIntent = true;
        });
        return;
    }
  }

  /// Completes a cloud-sync OAuth flow when the browser redirects back via
  /// `hibiki://auth/<provider>?code=...`. The pending PKCE verifier/repo were
  /// stored by the backend's `authenticate()` call before the browser opened.
  Future<void> _handleOAuthRedirect(String data) async {
    final Uri? uri = Uri.tryParse(data);
    if (uri == null || uri.host != 'auth' || uri.pathSegments.isEmpty) return;

    final String provider = uri.pathSegments.first;
    final String? code = uri.queryParameters['code'];
    final String? error = uri.queryParameters['error'];
    if (code == null) {
      HibikiToast.show(
          msg: t.sync_auth_error(message: error ?? 'missing code'));
      return;
    }

    try {
      switch (provider) {
        case 'onedrive':
          await OneDriveSyncBackend.instance.handleAuthCode(code);
        case 'dropbox':
          await DropboxSyncBackend.instance.handleAuthCode(code);
        default:
          return;
      }
      HibikiToast.show(msg: t.sync_signed_in);
    } on SyncAuthError catch (e) {
      HibikiToast.show(
          msg: t.sync_auth_error(message: friendlySyncErrorDetail(e)));
    } catch (e) {
      HibikiToast.show(msg: friendlySyncError(e));
    }
  }

  /// 处理「从 app 外用 Hibiki 打开视频」：建/取一条外部视频 VideoBook（videoPath
  /// 存外部绝对路径，不复制文件），然后用全局 navigator push [VideoHibikiPage]
  /// 播放。bookUid 用 [externalVideoBookUid]（全路径 sha1）派生，幂等——同一文件
  /// 重复打开复用同条记录、保留上次进度。入库后书架视频分区自动出现该条目。
  ///
  /// 字幕无需在此预解析：[VideoHibikiPage] 加载时若 [VideoBookRow.subtitleSource]
  /// 为空会自动探测同名 sidecar 字幕（见 `findSidecarSubtitle`）。
  Future<void> _openExternalVideo(String videoPath) async {
    final NavigatorState? navigator = appModel.navigatorKey.currentState;
    if (navigator == null) return;

    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final String bookUid = externalVideoBookUid(videoPath);

    try {
      final VideoBookRow? existing = await repo.getByBookUid(bookUid);
      if (existing == null) {
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: Value(bookUid),
          title: Value(p.basenameWithoutExtension(videoPath)),
          videoPath: Value(videoPath),
          importedAt: Value(DateTime.now()),
        ));
      }
    } catch (e) {
      debugPrint('[Hibiki] external video upsert failed: $e');
      return;
    }

    if (!mounted) return;
    await navigator.push(
      adaptivePageRoute<void>(
        builder: (_) =>
            VideoHibikiPage.neutralized(bookUid: bookUid, repo: repo),
      ),
    );
  }

  void _scheduleWindowsUpdateHandoffReconcile() {
    if (_windowsUpdateHandoffScheduled || _windowsUpdateHandoffChecked) {
      return;
    }
    _windowsUpdateHandoffScheduled = true;
    final String currentVersion = appModel.packageInfo.version;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _windowsUpdateHandoffScheduled = false;
      if (!mounted || _windowsUpdateHandoffChecked) return;
      final BuildContext? navigatorContext =
          appModel.navigatorKey.currentContext;
      if (navigatorContext == null ||
          !UpdateChecker.canShowDialogFromContext(navigatorContext)) {
        debugPrint(
          '[Hibiki] windows update handoff reconcile deferred: '
          'navigator context unavailable',
        );
        return;
      }
      _windowsUpdateHandoffChecked = true;
      unawaited(UpdateChecker.reconcilePendingWindowsInstallerHandoff(
        navigatorContext,
        currentVersion,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    // Fields like locales/targetLanguage/theme are late and only available
    // after initialise() completes. Return a minimal app while loading.
    // LoadingPage calls Spacing.of(context) via buildLoading(), so we must
    // not use it here — render the spinner directly instead.
    //
    // Use system brightness to match the native splash and avoid a white
    // flash when the user has dark mode enabled.
    // Downgrade protection: the on-disk DB was created by a newer build. Show a
    // dedicated, NON-retryable "update your app" notice (no Retry button —
    // retrying re-runs init and fails identically; the DB is intentionally left
    // untouched). Checked BEFORE the generic init-error screen.
    final downgrade = appModel.downgradeError;
    if (downgrade != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: brightness,
      );
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: cs),
          home: Scaffold(
            backgroundColor: _savedSplashColor,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.system_update, size: 48, color: cs.primary),
                    const SizedBox(height: 16),
                    Text(
                      t.db_downgrade_title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.db_downgrade_message(
                        dbVersion: downgrade.dbVersion,
                        appVersion: downgrade.appSchemaVersion,
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (appModel.initError != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: brightness,
      );
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: cs),
          home: Scaffold(
            backgroundColor: _savedSplashColor,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      t.initialization_failed,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      appModel.initError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                      selectionControls: HibikiTextSelectionControls(
                        shareAction: (text) => Share.share(text),
                        allowCopy: true,
                        allowCut: false,
                        allowPaste: false,
                        allowSelectAll: true,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(t.retry),
                          onPressed: () => appModel.retryInitialise(),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: Text(t.copy_error),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: appModel.initError!),
                            );
                            HibikiToast.show(msg: t.error_copied);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: brightness,
      );
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: cs),
          home: Scaffold(
            backgroundColor: _savedSplashColor,
            body: Center(
              child: CircularProgressIndicator(color: cs.primary),
            ),
          ),
        ),
      );
    }

    // app 已初始化完成（走到这里说明 home 即将渲染）：若本次启动是「从 app 外
    // 打开视频」，在首帧后建/取 VideoBook 并打开播放页。只触发一次。
    if (!_externalVideoHandled && _pendingExternalVideoPath != null) {
      _externalVideoHandled = true;
      final String videoPath = _pendingExternalVideoPath!;
      _pendingExternalVideoPath = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openExternalVideo(videoPath));
      });
    }

    return TranslationProvider(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: appModel.navigatorKey,
        home: home,
        locale: locale,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: appModel.locales.values,
        themeMode: themeMode,
        theme: appModel.theme,
        darkTheme: appModel.darkTheme,
        // This is responsible for the initialising the global spacing across
        // the entire project, making use of the [spaces] package.
        builder: (context, child) {
          _scheduleWindowsUpdateHandoffReconcile();
          final cs = Theme.of(context).colorScheme;
          // Keep the native Windows title bar in sync with the live app theme
          // (surface background + onSurface text). No-op on other platforms.
          // The channel de-dupes identical values so this is cheap per rebuild.
          WindowCaptionChannel.setCaptionColors(
            caption: cs.surface,
            text: cs.onSurface,
          );
          // Drive the status/navigation bar icon brightness from the *live*
          // theme so switching themes repaints the system bars. The builder
          // reruns on every theme change, so the AnnotatedRegion re-emits the
          // matching overlay style.
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: hibikiSystemOverlayStyle(cs.brightness),
            child: CupertinoTheme(
              data:
                  hibikiCupertinoTheme(cs, fontFamily: appModel.appFontFamily),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Size viewport = constraints.hasBoundedWidth &&
                          constraints.hasBoundedHeight
                      ? constraints.biggest
                      : MediaQuery.sizeOf(context);
                  final double uiScale = appModel.resolveAppUiScaleForViewport(
                    viewport: viewport,
                    platform: Theme.of(context).platform,
                  );
                  return HibikiAppUiScale(
                    scale: uiScale,
                    child: _wrapFocusNavigation(
                      enabled: appModel.experimentalFocusNavigationEnabled,
                      child: wrapWithGlobalNavigation(
                        navigatorKey: appModel.navigatorKey,
                        focusNavigationEnabled:
                            appModel.experimentalFocusNavigationEnabled,
                        // TODO-354 ①：常驻悬浮字幕查词宿主覆盖在导航之上，让书架/首页
                        // 开的悬浮字幕（无 reader）点词也能在主窗口弹查词。无挂起请求时
                        // 整层 IgnorePointer 透传，不抢任何页面的命中测试。
                        child: Stack(
                          children: <Widget>[
                            child!,
                            const FloatingLyricLookupHost(),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// Responsible for managing global app-wide state.
  AppModel get appModel => ref.watch(appProvider);

  /// The application will open to this page upon startup.
  Widget get home => _isMainIntent ? const HomePage() : const Scaffold();

  ThemeMode get themeMode => appModel.themeMode;

  /// The current app chrome locale, dependent on the display language.
  Locale get locale => appModel.appLocale;
}

/// 按实验开关决定是否包裹自定义焦点导航层（[HibikiFocusRoot] 焦点控制器 +
/// [HibikiFocusRing] 可见焦点环）。关闭（默认）时原样返回 [child]，App 走 Flutter
/// 原生焦点遍历——各组件在缺少 HibikiFocusRoot 时会自动降级到 FocusableActionDetector。
Widget _wrapFocusNavigation({required bool enabled, required Widget child}) {
  if (!enabled) return child;
  return HibikiFocusRoot(child: HibikiFocusRing(child: child));
}

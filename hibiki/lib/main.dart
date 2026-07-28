import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart'
    show MacosTheme, MacosWindow, WindowManipulator;
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
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/popup_main.dart' as popup_entrypoint;
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/misc/app_icon_preferences.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/present_watchdog.dart';
import 'package:hibiki/src/utils/misc/wgc_capture_log.dart';
import 'package:hibiki/src/utils/window_caption_channel.dart';
import 'package:hibiki/src/utils/adaptive/hibiki_macos_theme.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/lookup/clipboard_panel_controller.dart';
import 'package:hibiki/src/lookup/clipboard_text_overlay_controller.dart';
import 'package:hibiki/src/lookup/desktop_lookup_dispatcher.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:hibiki/src/startup/desktop_window_placement.dart';
import 'package:hibiki/src/storage/data_root_migration_view.dart';
import 'package:hibiki/src/startup/loading_watchdog_view.dart';
import 'package:hibiki/src/sync/backup_import_overlay_view.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart'
    show backupImportRestart, dataRootMigrationRestart;
import 'package:hibiki/src/startup/webview_prewarm.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/sync/book_exit_sync_scope.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/anki/ankimobile_repository.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:hibiki/src/platform/ios/ios_url_event_channel.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:hibiki/src/media/video/external_video.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart'
    show extractVideoCover;
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
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
      // TODO-959: 数据迁移成功后的自动重启会以 detached 模式拉新进程并带上重启标志。
      // 新进程的 Windows runner 见到标志会**隐藏建窗**（不带 WS_VISIBLE，见
      // win32_window.cpp 的 restarted_hidden 分支），把「旧进程 exit(0) → 新进程
      // Flutter 首帧」这段交接期挡在屏幕之外，避免空白/黑色错误窗。此处在首帧前
      // （runApp 之前）主动 show()+focus() 把已建好的隐藏主窗口顶到前台并显示出来。
      // 铁律：隐藏建窗的进程**必须**在这里成功显示，否则窗口永久不可见。因此 show()
      // 即使抛错也要在 catch 里再兜底强制 show 一次，绝不让任何路径停在不可见状态。
      if (args.contains(DesktopLifecycleService.restartMarkerArg)) {
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (e) {
          debugPrint('[Hibiki] restart window focus skipped: $e');
          // 兜底：上面的 focus() 抢前台失败不致命，但隐藏建窗的窗口若未 show 就会
          // 永久不可见。再尝试一次纯 show()，仍失败也只能记录（极端环境）。
          try {
            await windowManager.show();
          } catch (e2) {
            debugPrint('[Hibiki] restart window show fallback failed: $e2');
          }
        }
      }
      await hotKeyManager.unregisterAll(); // 热重载清理残留全局热键
      // 运行时按持久化偏好重应用窗口/任务栏图标（Windows exe 静态图标改不了，
      // 启动后由 setWindowIcon 覆盖成用户所选预设/自定义图）。失败静默降级。
      if (Platform.isWindows) {
        try {
          final String presetKey = await loadIconPresetKey();
          final String? iconPath = presetKey == customIconKey
              ? await loadCustomIconPath()
              : await exportPresetIconToFile(presetKey);
          if (iconPath != null && File(iconPath).existsSync()) {
            await WindowCaptionChannel.setWindowIcon(iconPath);
          }
        } catch (e) {
          debugPrint('[Hibiki] window icon restore failed: $e');
        }
      }
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

    // BUG-1015：just_audio_media_kit 首次平台激活会吞掉第一段播放输出，导致本次启动后
    // 「第一次查词自动发音没声音、点第二次才响」。这里静音预热查词播放器一次，把冷启动
    // 首帧空窗在无声中消耗掉，使首个真实自动发音即出声。fire-and-forget，不阻塞启动；
    // 失败内部吞掉。仅桌面走 media_kit 需要——平台门控在 warmUpLookupAudioPlayer
    // 内部（Android 原生 MediaPlayer 无此冷启动，no-op），本调用点自身不做门控。
    // 注意（BUG-1093）：本预热只保护 Dart/media_kit 播放路径（app 外浮窗自动发音 +
    // WebView 播放失败的兜底）；app 内自动发音的快路径是弹窗 WebView <audio>，其
    // 首次无声根因是 WebView2 autoplay 策略，修在 fork 的环境参数里，与本预热无关。
    unawaited(TtsChannel.instance.warmUpLookupAudioPlayer());

    // macOS native shell: initialise the macos_window_utils channel (paired with
    // MainFlutterWindowManipulator.start in MainFlutterWindow.swift) so the
    // MacosWindow transparent titlebar / sidebar vibrancy work. enableWindow
    // Delegate is required for fullscreen presentation options. macos_ui's ToolBar
    // adds a passthrough view constrained to the titlebar, which throws
    // `NSLayoutAttributeTop requires NSWindowStyleMaskFullSizeContentView` unless
    // the window has a full-size content view + transparent titlebar, so enable
    // those explicitly here (before runApp) so the style mask is correct before
    // any ToolBar mounts. No-op / not called on other platforms.
    if (Platform.isMacOS) {
      await WindowManipulator.initialize(enableWindowDelegate: true);
      await WindowManipulator.makeTitlebarTransparent();
      await WindowManipulator.enableFullSizeContentView();
    }

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
    // TODO-1232 A3：读一次 native 持久化的渲染后端选择（关 Impeller 实验开关），
    // 供设置项同步渲染。非 Android 静默降级为不支持。
    await RenderBackendService.instance.init();
    // BUG-209 / TODO-398：把上次运行残留的 Windows WGC 帧捕获生命周期日志
    // 折进错误日志（仅 Windows），纳入现有上传链路，为 GraphicsCapture 延迟
    // UAF 崩溃提供可读的崩前生命周期证据。
    await WgcCaptureLog.foldIntoErrorLog();
    // BUG-772：把上次运行 present 楔死取证（首帧从未 rasterize）折进错误日志（仅
    // Windows），纳入上传链路，为 raster/present 管线死锁提供可读崩前证据。
    await PresentStallLog.foldIntoErrorLog();

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

    // Windows/iOS 弹窗内联资产（popup.html/js/css ~300KB）异步预读：把 4 次
    // 同步读盘从「第一次查词」路径挪到启动空闲期（内部平台门控，其它平台 no-op）。
    unawaited(DictionaryPopupWebViewState.preloadInlinePopupAssets());

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

    // TODO-617: start the global lookup overlay trigger on desktop (Windows MVP).
    // After the first frame so the Flutter view / WebView2 host is attached.
    if (isDesktopPlatform) {
      unawaited(Future(() async {
        try {
          await WidgetsBinding.instance.endOfFrame;
          await GlobalLookupController.instance.start(appModel: appModel);
          // spec 2026-07-10 §4/§7 — 剪贴板监听 app 级启动（生命周期归 AppModel；
          // 覆盖窗控制器先启动，路由端 isAvailable 判定才准确）。dispatcher 先挂
          // 监听再启服务，防首个剪贴板事件竞态。面板控制器只接线+预热，窗口
          // 到首个 panel 分区请求才显示。
          if (ClipboardPanelController.isSupported) {
            await ClipboardPanelController.instance.start(appModel: appModel);
          }
          // 真透明剪切板文字窗控制器：只接线 native 点字回调，窗口到首个
          // textWindow 分区请求才显示。
          if (ClipboardTextOverlayController.isSupported) {
            await ClipboardTextOverlayController.instance
                .start(appModel: appModel);
          }
          if (GalHookTextOverlayController.isSupported) {
            await GalHookTextOverlayController.instance
                .start(appModel: appModel);
          }
          DesktopLookupDispatcher.instance.start(appModel: appModel);
          await appModel.applyDesktopClipboardLifecycle();
        } catch (e) {
          debugPrint('[Hibiki] global lookup start failed (non-fatal): $e');
        }
      }));
    }

    // BUG-1076：galgame helper 后台静默自更新。更新时机 = app 启动后台（宽松超时、无 UI），
    // 不再绑在「点启动游戏」那一刻抢 6s——游戏启动路径在安装完整时零网络。方法自身
    // Windows 早退 + 全静默，任何失败留到下次启动再试。
    unawaited(GalgameHelperInstaller.updateInstalledHelpersInBackground());
    // 同理，Magpie（窗口超分）的后台静默自更新。只做「已装 → 最新」：未安装/无装机
    // 标记/残缺一律不动（首装属于交互路径，要用户确认）。非 Windows 自身早退。
    unawaited(MagpieInstaller.updateInstalledMagpieInBackground());

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

  /// TODO-904 P0 回归：Windows 单实例守卫下，第二实例（文件关联 / 拖到 exe / CLI
  /// `hibiki.exe "%1"`）不会自己起窗口，而是把视频路径经 WM_COPYDATA 转交首实例
  /// （见 `windows/runner/external_video_handoff.*` + `flutter_window.cpp`）。首实例
  /// 经此 MethodChannel 收到 `openExternalVideo`，复用现有 [_openExternalVideo]
  /// 打开链路。仅 Windows 注册（其它桌面平台暂无单实例守卫，走首启 argv 路径）。
  static const MethodChannel _externalVideoChannel =
      MethodChannel('app.hibiki/external_video');

  /// TODO-1092: Windows 系统强调色/主题色实时变更通知 channel。runner 侧
  /// （`windows/runner/flutter_window.cpp` 的 MessageHandler）收到
  /// WM_DWMCOLORIZATIONCOLORCHANGED / WM_SETTINGCHANGE("ImmersiveColorSet") /
  /// WM_THEMECHANGED 后经此 channel 推 `onSystemColorChanged`，Dart 侧据此调
  /// [AppModel.refreshSystemPalette] 让动态取色实时刷新（不再等生命周期 resumed）。
  static const MethodChannel _systemThemeChannel =
      MethodChannel('app.hibiki/system_theme');

  /// 去抖：一次系统色变更常连发多条 Win32 广播（DWM + ImmersiveColorSet +
  /// THEMECHANGED），合并到一次 [AppModel.refreshSystemPalette]，避免同一变更重复
  /// 取色 + notifyListeners 抖动。
  Timer? _systemColorRefreshDebounce;

  /// 守卫：退出清理（停 Bonsoir 事件源）只跑一次，避免 [onWindowClose] 与
  /// [didChangeAppLifecycleState] 的 `detached` 兜底重复触发。
  bool _shutdownStarted = false;
  Future<void>? _androidBackgroundFlushInFlight;

  /// 守卫：Windows 安装器 handoff reconcile 的 post-frame 调度只挂一个。
  bool _windowsUpdateHandoffScheduled = false;

  /// TODO-1260：启动加载「看门狗」。裸 loading 分支（[!appModel.isInitialised]）此前只有
  /// 一个**无超时**的 [CircularProgressIndicator]——若 `initialise()` 因某早期 IO（掉线
  /// 数据根盘的 stat / 目录创建）永不返回，就无限转圈、无任何逃生口（TODO-1260「偶发
  /// 无限加载」根因之一）。看门狗在进入裸加载态时启动，超过 [_loadingWatchdogTimeout]
  /// 仍未初始化完成就翻 [_loadingTimedOut]，加载分支改渲染「耗时超预期 + 说明 + 重试」
  /// 逃生 UI，消除「无 escape」的结构缺陷（Layer 1/2 的数据根超时降级是主修，这层是
  /// 兜底：任何未预见的启动挂起都有可点的出口，而非死转圈）。
  static const Duration _loadingWatchdogTimeout = Duration(seconds: 20);
  Timer? _loadingWatchdog;
  bool _loadingTimedOut = false;

  /// BUG-772：present-watchdog 超时（比 20s 裸加载看门狗更长，确认是硬故障而非 IO 慢）。
  static const Duration _presentWatchdogTimeout = Duration(seconds: 30);

  /// BUG-772：present 层死锁兜底看门狗（仅 Windows arm）。UI-isolate 看门狗的逃生 UI 在
  /// raster/present 楔死时也送不上屏，故用「首帧是否 rasterize 过」这个不依赖 present 的
  /// 判据兜底。启动推进后置 null（只清一次 marker）。
  PresentWatchdog? _presentWatchdog;

  /// 守卫：Windows 安装器 handoff marker 只在拿到真实 Navigator 后 reconcile 一次。
  bool _windowsUpdateHandoffChecked = false;
  StreamSubscription<String>? _iosUrlSubscription;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    // BUG-772：仅 Windows 挂 present-watchdog——runApp 后 30s 仍无一帧 rasterize
    // （firstFrameRasterized==false）判定 raster/present 楔死（快速进出视频的
    // libmpv/ANGLE/WGC churn 污染进程共享 D3D device），落盘取证 + 一次性自动重启。
    // 这是 UI-isolate 看门狗（逃生 UI 同样送不上屏）够不着的 present 层兜底。
    if (Platform.isWindows) {
      _presentWatchdog = PresentWatchdog(
        timeout: _presentWatchdogTimeout,
        isFirstFrameRasterized: () =>
            WidgetsBinding.instance.firstFrameRasterized,
        onStall: _onPresentStall,
      )..arm();
    }
    // 桌面端监听原生窗口关闭：配合 main() 里的 setPreventClose(true)，在引擎拆除前
    // 停掉 Bonsoir mDNS 事件源（TODO-036）。
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    if (Platform.isWindows) {
      _externalVideoChannel.setMethodCallHandler(_handleExternalVideoChannel);
      _systemThemeChannel.setMethodCallHandler(_handleSystemThemeChannel);
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
    if (Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        IosUrlEventChannel.getInitialUrl().then(
          (url) => handleIncomingUrl(
            data: url,
            isInitial: true,
          ),
        );
        _iosUrlSubscription = IosUrlEventChannel.urls.listen(
          (url) => handleIncomingUrl(
            data: url,
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
    if (Platform.isAndroid) {
      switch (state) {
        case AppLifecycleState.inactive:
        case AppLifecycleState.paused:
        case AppLifecycleState.hidden:
          unawaited(_flushActivePagesForAndroidBackground());
          return;
        case AppLifecycleState.detached:
          unawaited(_flushAndCloseForLifecycleDetach());
          return;
        case AppLifecycleState.resumed:
          return;
      }
    }
    // `detached` = the app is about to be terminated (the engine is detaching
    // from the view). Tear down Bonsoir's mDNS event sources here as a fallback
    // for platforms/paths that don't go through window_manager's onWindowClose.
    // Best-effort (the callback isn't awaited by the framework): the primary,
    // guaranteed path on desktop is [onWindowClose] under setPreventClose(true).
    if (state == AppLifecycleState.detached) {
      unawaited(_flushAndCloseForLifecycleDetach());
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

  /// Android 退后台不是退出：只做保留式 flush，页面回前台后仍继续持有回调。
  ///
  /// 页面本身也会在 paused/hidden 尝试 flush，但那是 fire-and-forget；这里给
  /// Android 一个 app-level 汇聚点，确保 reader/video/audiobook 的 pending 位置写穿。
  Future<void> _flushActivePagesForAndroidBackground() async {
    final Future<void>? existing = _androidBackgroundFlushInFlight;
    if (existing != null) {
      return existing;
    }

    final Future<void> run = () async {
      try {
        await ExitFlushRegistry.instance.flushAll(clearCallbacks: false);
      } catch (e) {
        debugPrint('[Hibiki] android background flush failed: $e');
      }
    }();
    _androidBackgroundFlushInFlight = run;
    try {
      await run;
    } finally {
      if (identical(_androidBackgroundFlushInFlight, run)) {
        _androidBackgroundFlushInFlight = null;
      }
    }
  }

  /// 停掉 Bonsoir 的 LAN 广播 + 发现（mDNS 事件源），再 flush 活跃页面并 close DB。
  ///
  /// 仅作 `detached` 生命周期兜底（移动端 / 不经 window_manager 的退出路径）。桌面
  /// 点 X 走 [_flushAndExitForWindowClose]（flush + closeDB + exit(0)），不再到这里。
  /// 超时上限收紧到 1.5s（TODO-086）：原生 stop 不归时放行，避免拖住退出。
  Future<void> _flushAndCloseForLifecycleDetach() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final AppModel appModel = ref.read(appProvider);
    try {
      await appModel.syncServerController
          .shutdownForExit()
          .timeout(const Duration(milliseconds: 1500));
    } on TimeoutException {
      debugPrint('[Hibiki] sync source shutdown on exit timed out; continuing');
    } catch (e) {
      debugPrint('[Hibiki] sync source shutdown on exit failed: $e');
    }

    try {
      final Future<void>? pendingBackgroundFlush =
          _androidBackgroundFlushInFlight;
      if (pendingBackgroundFlush != null) {
        await pendingBackgroundFlush;
      }
      await ExitFlushRegistry.instance.flushAll();
    } catch (e) {
      debugPrint('[Hibiki] lifecycle detach flush failed: $e');
    }

    try {
      await appModel.closeDatabase();
    } catch (e) {
      debugPrint('[Hibiki] database close on lifecycle detach failed: $e');
    }
  }

  @override
  void dispose() {
    _intentsSubscription?.cancel();
    _iosUrlSubscription?.cancel();
    _systemColorRefreshDebounce?.cancel();
    _loadingWatchdog?.cancel();
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
    if (await handleIncomingUrl(data: data, isInitial: isInitial)) {
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

  Future<bool> handleIncomingUrl({
    required String? data,
    required bool isInitial,
  }) async {
    if (data == null || !mounted) return false;
    final String normalized = data.toLowerCase();
    if (normalized.startsWith('hibiki://auth/')) {
      await _handleOAuthRedirect(data);
      return true;
    }
    if (normalized.startsWith(hibikiAnkiFetchCallback.toLowerCase())) {
      await _handleAnkiMobileInfoCallback();
      return true;
    }
    if (normalized.startsWith(hibikiAnkiSuccessCallback.toLowerCase())) {
      return true;
    }
    return false;
  }

  Future<void> _handleAnkiMobileInfoCallback() async {
    final repo = ref.read(ankiRepositoryProvider);
    if (repo is! AnkiMobileRepository) return;
    final result = await repo.consumeInfoForAddingPasteboard();
    switch (result) {
      case AnkiFetchSuccess():
        await ref.read(ankiViewModelProvider.notifier).reloadSettings();
        HibikiToast.show(msg: 'AnkiMobile configuration imported.');
      case AnkiFetchError(:final message, :final code):
        HibikiToast.show(
          msg: AnkiViewModel.localizeAnkiFetchError(message, code),
        );
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

  /// TODO-904 P0 回归：首实例收到第二实例经 WM_COPYDATA 转交的外部视频路径
  /// （`windows/runner` → `app.hibiki/external_video` channel）。这里做与首启 argv
  /// 路径（[main]）等价的校验：扩展名白名单（[isSupportedVideoFile]）+ 存在性
  /// （`File.existsSync`），通过后复用 [_openExternalVideo] 打开。
  ///
  /// 若 app 尚未初始化完成（首实例还在 LoadingPage），无法立刻 push 播放页：把路径
  /// 暂存到 [_pendingExternalVideoPath] 并复位 [_externalVideoHandled]，由 [build]
  /// 在 `isInitialised` 后的一次性 post-frame 分支接手——与首启路径汇聚到同一出口。
  Future<dynamic> _handleExternalVideoChannel(MethodCall call) async {
    if (call.method != 'openExternalVideo') return null;
    final Object? raw = call.arguments;
    if (raw is! String) return null;
    final String videoPath = raw;
    if (videoPath.isEmpty) return null;
    if (!isSupportedVideoFile(videoPath)) return null;
    if (!File(videoPath).existsSync()) return null;

    if (!appModel.isInitialised || appModel.navigatorKey.currentState == null) {
      // 首实例尚未就绪：交还首启路径，build 完成后接手打开。
      _pendingExternalVideoPath = videoPath;
      _externalVideoHandled = false;
      if (mounted) setState(() {});
      return null;
    }
    await _openExternalVideo(videoPath);
    return null;
  }

  /// TODO-1092: Windows runner 报告「系统强调色/主题色已变」。经短去抖合并同一次
  /// 变更连发的多条广播，然后调 [AppModel.refreshSystemPalette] 让 `system-theme`
  /// 动态取色实时更新——修复「必须最小化/恢复/失焦触发生命周期 resumed 才刷新」。
  /// 与 [didChangeAppLifecycleState] 的 resumed 刷新共存：两者都只是重新取系统色，
  /// 幂等、互不冲突。
  Future<dynamic> _handleSystemThemeChannel(MethodCall call) async {
    if (call.method != 'onSystemColorChanged') return null;
    _systemColorRefreshDebounce?.cancel();
    _systemColorRefreshDebounce = Timer(
      const Duration(milliseconds: 150),
      () {
        if (!mounted) return;
        unawaited(ref.read(appProvider).refreshSystemPalette());
      },
    );
    return null;
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

    // ③ 存在性校验：冷启动 argv 路径虽在 main() 已 existsSync 过，但从那次检查到
    // 此处首帧入库之间文件可能被移动/删除（或检查与使用间的竞态），故再校验一次；
    // 文件不存在则不入库、不静默吞，给与既有失败路径一致的 toast 反馈（TODO-903）。
    if (!await File(videoPath).exists()) {
      HibikiToast.show(msg: t.video_file_not_found);
      return;
    }

    final VideoBookRepository repo = VideoBookRepository(appModel.database);

    String bookUid;
    try {
      // ② 去重：同一物理文件若已库内导入（`video/<basename>` 身份），复用其旧
      // bookUid，不再派生 `video/ext/<sha1>` 第二身份插第二行。按 videoPath 命中
      // 走仓库单一真相源 findByVideoPath（与 isDuplicateVideoPath 同比对语义）。
      final VideoBookRow? sameFile = await repo.findByVideoPath(videoPath);
      if (sameFile != null) {
        bookUid = sameFile.bookUid;
      } else {
        bookUid = externalVideoBookUid(videoPath);
        final VideoBookRow? existing = await repo.getByBookUid(bookUid);
        if (existing == null) {
          // ① 封面：复用库内导入同款 extractVideoCover（桌面 ffmpeg 抽帧；移动端无
          // ffmpeg 时返 null 留空占位）。仅新建外部条目时抽一次。
          final String? coverPath =
              await extractVideoCover(videoPath: videoPath, bookUid: bookUid);
          await repo.saveVideoBook(VideoBooksCompanion(
            bookUid: Value(bookUid),
            title: Value(p.basenameWithoutExtension(videoPath)),
            videoPath: Value(videoPath),
            coverPath: Value<String?>(coverPath),
            importedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        }
      }
    } catch (e) {
      debugPrint('[Hibiki] external video upsert failed: $e');
      return;
    }

    if (!mounted) return;
    // This process-level launch path owns a NavigatorState but has no themed
    // descendant BuildContext, so its route contract is explicitly Material.
    await navigator.push(
      MaterialPageRoute<void>(
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
      // Windows 与 macOS 运行时互斥；两个 reconcile 各自按平台自守（非本平台即早退），
      // 故并列调用只会有一个真正执行。共用同一 checked 旗标做一次性去重。
      unawaited(UpdateChecker.reconcilePendingWindowsInstallerHandoff(
        navigatorContext,
        currentVersion,
      ));
      unawaited(UpdateChecker.reconcilePendingMacInstallerHandoff(
        navigatorContext,
        currentVersion,
      ));
    });
  }

  /// TODO-1260：进入裸加载态时启动看门狗（只挂一个；已翻超时标记则不再重启）。
  void _startLoadingWatchdogIfNeeded() {
    if (_loadingWatchdog != null || _loadingTimedOut) return;
    _loadingWatchdog = Timer(_loadingWatchdogTimeout, () {
      if (mounted) setState(() => _loadingTimedOut = true);
    });
  }

  /// TODO-1260：离开裸加载态（初始化完成 / 落错误屏 / 迁移 / 备份导入遮罩）或用户手动
  /// 重试时取消看门狗并复位，让下一轮加载重新计时、避免过时 timer 空转触发无用 setState。
  void _cancelLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
    _loadingTimedOut = false;
  }

  /// BUG-772：present 楔死自愈动作（仅 Windows）——落盘取证 + 一次性自动重启。marker 不
  /// 存在（首次楔死）→ 认领并 restartApp（有验证过的桌面重启路径）；已存在（上次重启后
  /// 仍卡，疑驱动级 device-lost 跨进程）→ 不再重启，避免无限循环，取证已落盘供下次上传。
  /// restartApp 走 platform 线程起新进程 + 退本进程，不依赖已楔死的 raster 线程。
  void _onPresentStall() {
    final File? logFile = PresentStallLog.resolveStallLogFile();
    if (logFile != null) {
      PresentStallLog.appendStall(
        logFile,
        DateTime.now(),
        afterTimeout: _presentWatchdogTimeout,
      );
    }
    final File? marker = PresentStallLog.resolveMarkerFile();
    if (marker != null && PresentStallLog.claimRestart(marker)) {
      unawaited(ref.read(appProvider).platformServices.lifecycle.restartApp());
    }
  }

  @override
  Widget build(BuildContext context) {
    // TODO-1260：只要不再处于「裸加载」态（已初始化 / 已落错误屏 / 迁移或备份导入有自己
    // 的进度遮罩），就撤掉加载看门狗，避免它在这些态里事后空转触发一次无用重建。
    if (appModel.isInitialised ||
        appModel.initError != null ||
        appModel.dataRootMigrationActive ||
        appModel.backupImportActive) {
      _cancelLoadingWatchdog();
      // BUG-772：启动已推进（首帧早已 rasterize）→ 撤 present-watchdog 并清自动重启
      // marker（只跑一次：置 null 后不再进），让下次再遇 present 楔死还能自动重启一次。
      if (_presentWatchdog != null) {
        _presentWatchdog!.disarm();
        _presentWatchdog = null;
        final File? marker = PresentStallLog.resolveMarkerFile();
        if (marker != null) PresentStallLog.clearRestartMarker(marker);
      }
    }
    // Fields like locales/theme are late and only available
    // after initialise() completes. Return a minimal app while loading and
    // render the spinner directly instead of going through LoadingPage.
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
            backgroundColor: _savedSplashColor ?? cs.surface,
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
    // TODO-905: the DB could not be opened even after WAL/sidecar recovery —
    // the main hibiki.db is corrupt. Show an actionable notice (the recovery
    // ladder already ran inside the open path, so a plain Retry would loop
    // forever against the same un-openable file). Checked BEFORE the generic
    // init-error screen so the user gets the corrupt-DB guidance, not a raw
    // "disk I/O error" with a dead Retry loop.
    final unrecoverable = appModel.unrecoverableDbError;
    if (unrecoverable != null) {
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
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        size: 48, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      t.db_unrecoverable_title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.db_unrecoverable_message,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      appModel.initError!,
                      style: TextStyle(
                        fontSize: 12,
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
    // BUG-815: a custom data location IS configured on desktop but is currently
    // unreachable (slow/sleeping/disconnected drive). AppPaths.resolve threw
    // instead of SILENTLY opening the empty default location — that empty view
    // reads as catastrophic data loss even though the real data sits untouched
    // on the configured drive, and any content created in that empty session
    // would land in the WRONG place. Show a dedicated escape screen that NEVER
    // presents empty-as-real: default action is Retry (re-probe → use the real
    // DB once the drive wakes); an explicit, clearly-worded second button lets
    // the user consciously start with the default location (their data is NOT
    // touched) for the drive-truly-gone case. Checked BEFORE the loading branch.
    final dataRootUnavailable = appModel.dataRootUnavailable;
    if (dataRootUnavailable != null) {
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
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_off_outlined,
                        size: 48, color: cs.primary),
                    const SizedBox(height: 16),
                    Text(
                      t.data_root_unavailable_title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.data_root_unavailable_message(
                        path: dataRootUnavailable.configuredPath,
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
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
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: Text(t.data_root_use_default_button),
                          onPressed: () =>
                              appModel.retryInitialiseWithDefaultRoot(),
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
            backgroundColor: _savedSplashColor ?? cs.surface,
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
    // TODO-959: 桌面「数据存储位置」整目录迁移期间，迁移引擎会 closeDatabase()（置
    // isInitialised=false）以释放 Windows 文件锁。若直接落到下面的裸 loading 分支，背景
    // _savedSplashColor 可能为 null/深色 → 近黑 + 转圈，搬大库数秒~数分钟被误判死机。
    // 这里在 loading 分支之前拦截：改显一个带「请勿关闭」文案 + 进度条的迁移遮罩（明确
    // 主题色背景），并保证「遮罩已上屏 → closeDatabase → 搬文件」的顺序（见
    // _DataRootWidget._changeLocation 先调 beginDataRootMigration 再 migrate）。
    if (appModel.dataRootMigrationActive) {
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
          home: DataRootMigrationView(
            progress: appModel.dataRootMigrationProgress,
            background: _savedSplashColor,
            // TODO-1182：失败态在同一遮罩上改显「原因 + 建议 + 重启」，用户点重启回旧根。
            failure: appModel.dataRootMigrationFailure,
            onRestart: () => dataRootMigrationRestart(appModel),
          ),
        ),
      );
    }
    // TODO-1151: 本地备份「导入/恢复」期间会 closeDatabase() 置 isInitialised=false。
    // 若落到下面的裸 loading 分支，设置页会「突然消失」变近黑转圈，导入完再 exit(0)，
    // 用户误以为崩溃/失败。这里镜像上面的迁移遮罩：running 显「正在导入备份，请勿关闭」
    // + 进度条；done 显结果，导入成功后 ~1s 自动重启（backupImportRestart 走 restartApp 真
    // 拉新进程），「立即重启」按钮保留为手动兜底可提前点；失败态不自动、由用户读完原因手点。
    if (appModel.backupImportActive) {
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
          home: BackupImportOverlayView(
            phase: appModel.backupImportPhase!,
            message: appModel.backupImportMessage,
            background: _savedSplashColor,
            // TODO-1183: 确定进度条监听（只进度条重建，不整树重绘）。
            progress: appModel.backupImportProgress,
            onRestart: () => backupImportRestart(appModel),
            // TODO-1151: validating 相位的「取消」——作废 in-flight 校验 token 并退出
            // 遮罩回设置页（其它相位本视图不渲染取消按钮）。
            onCancel: appModel.cancelBackupValidating,
          ),
        ),
      );
    }
    if (!appModel.isInitialised) {
      // TODO-1260：进入裸加载态即挂看门狗；超时前显示转圈，超时后显示逃生 UI。
      _startLoadingWatchdogIfNeeded();
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
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: LoadingWatchdogView(
              timedOut: _loadingTimedOut,
              colorScheme: cs,
              onRetry: () {
                // 复位看门狗，让重试触发的新一轮加载重新计时。retryInitialise 先退回
                // 默认根（Layer 1 的 2s 超时降级）再重跑 init，通常即成功。
                _cancelLoadingWatchdog();
                appModel.retryInitialise();
              },
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

    // TODO-960: live UI-language switch on desktop. [setAppLocale] no longer
    // restarts the process there (it raced the Windows single-instance mutex
    // and killed the app); it mutates [LocaleSettings] + notifyListeners
    // instead. Most of the UI reads the global Method A `t`, which does NOT
    // rebuild on a [LocaleSettings] change on its own, so this locale-keyed
    // [KeyedSubtree] remounts the whole app subtree whenever the display
    // language changes, forcing every widget (incl. global-`t` readers) to
    // re-resolve its strings. (The generated [TranslationProvider] takes no
    // `key`, so the key lives on the enclosing [KeyedSubtree].) The remount
    // returns to [home]; this is acceptable (a real restart also dropped the
    // navigation stack) and only fires on an explicit language change, not on
    // ordinary [notifyListeners] ticks.
    return KeyedSubtree(
      key: ValueKey<String>('app-locale-${locale.toLanguageTag()}'),
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appModel.navigatorKey,
          // Resets the focus highlight to touch on every route push/pop so a ring
          // lit by keyboard/gamepad navigation on one page is not carried onto the
          // freshly-entered page (BUG-398).
          navigatorObservers: <NavigatorObserver>[
            appModel.focusHighlightObserver
          ],
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
                data: hibikiCupertinoTheme(cs,
                    fontFamily: appModel.appFontFamily),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Size viewport = constraints.hasBoundedWidth &&
                            constraints.hasBoundedHeight
                        ? constraints.biggest
                        : MediaQuery.sizeOf(context);
                    final double uiScale =
                        appModel.resolveAppUiScaleForViewport(
                      viewport: viewport,
                      platform: Theme.of(context).platform,
                    );
                    Widget navigation = wrapWithGlobalNavigation(
                      navigatorKey: appModel.navigatorKey,
                      focusNavigationEnabled:
                          appModel.experimentalFocusNavigationEnabled,
                      registry: appModel.shortcutRegistry,

                      // TODO-354 ①：常驻悬浮字幕查词宿主覆盖在导航之上，让书架/首页
                      // 开的悬浮字幕（无 reader）点词也能在主窗口弹查词。无挂起请求时
                      // 整层 IgnorePointer 透传，不抢任何页面的命中测试。
                      child: Stack(
                        children: <Widget>[
                          child!,
                          const FloatingLyricLookupHost(),
                        ],
                      ),
                    );
                    if (isMacosPlatform(context)) {
                      // macOS native shell (Approach B): the MacosWindow + Sidebar
                      // wrap the WHOLE navigator so every route — home tabs AND
                      // pushed routes (reader, settings detail, dialogs) — inherits
                      // a MacosWindowScope and can use native MacosScaffold/ToolBar.
                      // MacosTheme is derived from the SAME live ColorScheme as the
                      // rest of the app. The sidebar destinations come from the
                      // dynamic HomeTab list (video/games toggles) so they
                      // stay in lock-step with HomePage's rail; selection is shared
                      // via homeShellTabNotifier. Hide the sidebar while a media
                      // item (reader/video) is open so reading is full-width; the
                      // builder reruns when appModel notifies (openMedia/close).
                      // TODO-1375：sidebar 显隐由 appModel.mediaOpenNotifier 驱动，
                      // 不再直接读 appModel.isMediaOpen。根因：isMediaOpen 变化不
                      // notifyListeners，退出阅读器后本 builder 不重跑、sidebar 卡在
                      // stale null（永久消失→设置 tab 无出口→困死）。改用
                      // ValueListenableBuilder 监听可靠通知源：退出媒体必重建恢复
                      // sidebar。navigation（=整个 navigator）作为不变 child 透传，
                      // 只有 sidebar 参数随 mediaOpen 变，绝不重建 navigator 路由栈。
                      navigation = MacosTheme(
                        data:
                            hibikiMacosThemeFromColorScheme(cs, cs.brightness),
                        child: ValueListenableBuilder<bool>(
                          valueListenable: appModel.mediaOpenNotifier,
                          builder: (BuildContext context, bool mediaOpen,
                              Widget? child) {
                            return MacosWindow(
                              sidebar: mediaOpen
                                  ? null
                                  : buildHibikiMacosSidebar(
                                      activeTabs: homeActiveTabs(
                                        // 「视频」tab 已毕业为常驻（原
                                        // experimentalVideoEnabled 恒 true）。games
                                        // （galgame 库）仅 Windows；macOS 根侧栏此处
                                        // 恒 false（gamesEnabled 缺省），不显示。
                                        videoEnabled: true,
                                        // 浏览器扩展 tab「电脑才有」：此处为 macOS 根
                                        // 侧栏，macOS 即桌面 → 与底栏/rail 同一门控。
                                        browserExtensionEnabled:
                                            DesktopLookupService.isDesktop,
                                      ),
                                    ),
                              child: child!,
                            );
                          },
                          child: navigation,
                        ),
                      );
                    }
                    return HibikiAppUiScale(
                      scale: uiScale,
                      child: _wrapFocusNavigation(
                        enabled: appModel.experimentalFocusNavigationEnabled,
                        child: navigation,
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
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

/// 焦点导航层（[HibikiFocusRoot] 焦点控制器 + [HibikiFocusRing] 可见焦点环）
/// **恒定挂载，行为按实验开关门控**。禁用时 [HibikiFocusRoot.maybeControllerOf]
/// 返回 null（各组件据此走原生焦点遍历，语义与「未包裹」时代逐字节一致）、
/// 焦点环不绘制。
///
/// 用户实报（2026-07-22）：旧实现按开关插/拔这两层——切「键盘/手柄焦点导航」
/// 开关时整棵 app 子树因结构变化被重挂载，被切的 Switch 以新状态直接 mount，
/// 滑块动画消失（其余开关都有动画）。结构恒定后 Element 全保留，动画回归，
/// 顺带不再丢各页滚动位置。
Widget _wrapFocusNavigation({required bool enabled, required Widget child}) {
  return HibikiFocusRoot(
    enabled: enabled,
    child: HibikiFocusRing(enabled: enabled, child: child),
  );
}

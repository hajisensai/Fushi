import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/video/web_video_hosting.dart'
    show windowedHostingArguments;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// app 内浏览器（「浏览」标签页、漫画源登录 / Cloudflare 解题、音乐插件登录、无头抓取）与
/// 原生播放器页网页档（窗口宿主 4K 档）在 Windows 上共用的 WebView2 cookie 罐（BUG-2477 /
/// BUG-2478；2026-11 起播放器网页并进来）。
///
/// ## 为什么必须有一个显式环境
///
/// 这些页都靠 [CookieManager] 把浏览器里的会话导出给运行时。WebView2 的 cookie
/// 归**环境**（user data folder）所有；fork 里裸 `InAppWebView`（不传环境）走
/// 插件的默认建站点、裸 `CookieManager.instance()` 走 `WebViewEnvironmentManager`
/// 自己另建的默认环境——两处对着**同一个** user data folder 用**不同的**浏览器参数
/// 建环境，WebView2 拒绝第二个（`0x8007139F`），于是登录页明明已经登录，点「完成」
/// 却「没有捕获到会话 cookie」；Cloudflare 页同理永远轮询不到 `cf_clearance`。
///
/// 让 WebView 和 CookieManager 绑**同一个**显式环境，这类不一致就从结构上消失。
///
/// ## 播放器网页共用同一个罐（[obtainWindowedHosting]）
///
/// 窗口宿主档要 fork 的哨兵 `--fushi-windowed-hosting`；以前哨兵原样交给 WebView2，参数与
/// 浏览器不同 → 只能另开目录 → 播放器网页与浏览器登录态不共享（用户报）。现在 fork 在交给
/// WebView2 前剥掉哨兵（`WebViewEnvironment::StripWindowedHostingSentinel`），窗口宿主档用
/// **同一目录 + 同一套 Chromium 参数 + 哨兵**建自己的环境对象，WebView2 视之为同一套选项、
/// 接到同一个浏览器进程上：一个 cookie 罐，两边登录即时互通。
///
/// 代价：窗口宿主档需要 `--autoplay-policy=no-user-gesture-required`（原生播放控件经
/// `evaluateJavascript` 调 `video.play()`，那不是页面内的用户手势；从书架直开 `/watch/` 页
/// 也没有手势），同目录参数必须逐字一致，所以浏览器环境也带上它（[kAutoplayArgument]）：
/// 浏览器标签页里的有声自动播放不再被 Chromium 拦。无头抓取 WebView 在 fork 里整页静音
/// （`HeadlessInAppWebView::prepare`），不会在后台出声。
///
/// ## 代理
///
/// WebView2 默认跟系统代理，与 app 自己的代理设置无关（BUG-2478）。浏览器参数是
/// 唯一能把出口交给它的地方，且**只能在建环境时给**：所以按参数串缓存环境，参数
/// 变了（用户改了代理设置）就换一个环境——浏览器环境与窗口宿主档环境**一起**换（窗口宿主档
/// 跟着浏览器环境的目录与参数走）。同一 user data folder 不能被两套参数同时占着，故换环境时
/// 先 dispose 旧的两个（dispose 只释放环境对象和它的隐藏控件；已经打开的 WebView 各自持有
/// WebView2 环境的 COM 引用，照常工作，原生侧不留野指针）。WebView2 的浏览器进程在最后一个
/// 视图关闭后才退出，dispose 后立刻重建**同一目录**可能仍撞 `0x8007139F`，那时退到按参数
/// 派生的兄弟目录（登录态因此要重登一次——只在改代理后发生一次，可接受）。
///
/// 手动代理的 Basic 认证凭据**接不进去**：WebView2 的代理认证走
/// `BasicAuthenticationRequested`，本 fork 没有暴露它。局域网/本机代理绝大多数
/// 不要认证，先不为它引一层原生改动。
abstract final class MangaWebViewEnvironment {
  static Future<_SharedEnvironment?>? _pending;
  static _SharedEnvironment? _current;
  static String? _currentArguments;

  /// 窗口宿主档环境：建在 [_windowedFor]（当时的共享环境）的目录上。
  static Future<WebViewEnvironment>? _windowedPending;
  static _SharedEnvironment? _windowedFor;

  /// 测试 / 非 Windows 的旁路：返回 null = 让 `InAppWebView` 与 `CookieManager`
  /// 都走各自的平台默认（Android / iOS / macOS 那边 cookie 由系统 WebView 持有，
  /// 本来就是同一份）。
  @visibleForTesting
  static Future<WebViewEnvironment?> Function()? override;

  /// 测试旁路：[obtainWindowedHosting] 直接返回它。
  @visibleForTesting
  static Future<WebViewEnvironment> Function()? windowedHostingOverride;

  /// 允许无手势自动播放：窗口宿主档必需（见类注释），同目录参数要逐字一致，浏览器也带。
  static const String kAutoplayArgument =
      '--autoplay-policy=no-user-gesture-required';

  /// 本次应交给 WebView2 的代理参数；空串 = 跟系统代理（`auto` 且没查到代理）。
  ///
  /// 抽成纯函数以便直接断言：`direct` 必须显式 `--no-proxy-server`，否则「用户选了
  /// 直连、浏览器却偷用系统代理」和 [resolveAppProxyDirective] 的裁决相悖。
  static String proxyArguments({
    required String mode,
    required String? proxyHostPort,
  }) {
    if (mode == kProxyModeDirect) return '--no-proxy-server';
    if (proxyHostPort == null || proxyHostPort.isEmpty) return '';
    return '--proxy-server=$proxyHostPort';
  }

  /// 共享环境的完整浏览器参数：[kAutoplayArgument] + 代理参数（单空格分隔、无首尾空白）。
  /// 窗口宿主档的参数是它后面接哨兵（[windowedHostingArguments]），fork 剥掉哨兵后两者逐字相同。
  static String browserArguments({
    required String mode,
    required String? proxyHostPort,
  }) {
    final String proxy = proxyArguments(
      mode: mode,
      proxyHostPort: proxyHostPort,
    );
    return proxy.isEmpty ? kAutoplayArgument : '$kAutoplayArgument $proxy';
  }

  /// 共享 cookie 罐的 user data folder（纯函数，[environment] 即进程环境变量）：
  ///
  /// 1. `FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER`：网页视频 itest 的覆盖。硬件 PlayReady（MF CDM）
  ///    要求 profile 住在 `%LOCALAPPDATA%` 下（真机：profile 放在仓库目录的 itest 隔离根时
  ///    Netflix 报 D7702-1003），而窗口宿主档现在就住在共享罐里，所以覆盖整个共享罐——仍是
  ///    隔离的测试目录，不碰用户 profile。
  /// 2. `FUSHI_WEBVIEW2_USER_DATA_FOLDER`（itest 隔离根 / BUG-1483 只读安装回落）旁的 `-manga`。
  /// 3. 生产：`%LOCALAPPDATA%\Fushi\MangaWebView2`（目录名是历史名，沿用以保住已有登录）。
  ///
  /// [suffix] 是改代理后同目录被旧浏览器进程占着时的兄弟目录后缀。
  static String sharedUserDataFolder({
    required Map<String, String> environment,
    String suffix = '',
  }) {
    final String? webVideoOverride =
        environment['FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER'];
    if (webVideoOverride != null && webVideoOverride.isNotEmpty) {
      return '$webVideoOverride$suffix';
    }
    final String? testFolder = environment['FUSHI_WEBVIEW2_USER_DATA_FOLDER'];
    if (testFolder != null && testFolder.isNotEmpty) {
      return '$testFolder-manga$suffix';
    }
    final String base = environment['LOCALAPPDATA'] ?? '.';
    return '$base\\Fushi\\MangaWebView2$suffix';
  }

  /// 当前共享环境实际所在的目录（含改代理后的兄弟目录后缀）；还没建 / 建失败为 null。
  static String? get currentUserDataFolder => _current?.folder;

  /// 取当前代理设置下的环境；非 Windows 返回 null。
  static Future<WebViewEnvironment?> obtain() async {
    final Future<WebViewEnvironment?> Function()? injected = override;
    if (injected != null) return injected();
    return (await _obtainShared())?.environment;
  }

  static Future<_SharedEnvironment?> _obtainShared() {
    if (!Platform.isWindows) return Future<_SharedEnvironment?>.value();
    final String arguments = browserArguments(
      mode: appUserProxyModeReader(),
      proxyHostPort: resolveAppProxyHostPort(),
    );
    final Future<_SharedEnvironment?>? pending = _pending;
    if (pending != null && _currentArguments == arguments) return pending;
    final Future<_SharedEnvironment?> started = _create(arguments);
    _pending = started;
    _currentArguments = arguments;
    // 建不出来（0x8007139F 之类）不能把 null 钉进缓存：下一次打开页面要能重试，
    // 否则一次失败就是整个会话里所有登录页都退回默认环境。
    started.then((_SharedEnvironment? shared) {
      if (shared == null && identical(_pending, started)) {
        _pending = null;
        _currentArguments = null;
      }
    });
    return started;
  }

  /// 原生播放器页网页档（窗口宿主 4K 档）的环境：与 [obtain] 同一 user data folder、同一套
  /// Chromium 参数，外加 fork 的窗口宿主哨兵（fork 剥掉后交给 WebView2，故与浏览器共用同一个
  /// 浏览器进程与 cookie 罐）。按共享环境缓存：浏览器环境因代理变化重建时它跟着重建。
  ///
  /// 共享环境建不出来时抛 [StateError]（调用方落失败态）：不退回独立目录——那正是要修掉的
  /// 「登录态不共享」。非 Windows 抛 [UnsupportedError]（窗口宿主只有 Windows fork 有）。
  static Future<WebViewEnvironment> obtainWindowedHosting() async {
    final Future<WebViewEnvironment> Function()? injected =
        windowedHostingOverride;
    if (injected != null) return injected();
    if (!Platform.isWindows) {
      throw UnsupportedError('windowed hosting is Windows-only');
    }
    _SharedEnvironment? shared;
    // 等待期间代理变了、共享环境被换掉的话，拿最新那份（建在旧目录 / 旧参数上会被旧浏览器
    // 进程或新参数拒掉）。
    do {
      shared = await _obtainShared();
      if (shared == null) {
        throw StateError('shared WebView2 environment unavailable');
      }
    } while (!identical(shared, _current));
    final Future<WebViewEnvironment>? pending = _windowedPending;
    if (pending != null && identical(_windowedFor, shared)) return pending;
    final Future<WebViewEnvironment> started = WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: shared.folder,
        additionalBrowserArguments: windowedHostingArguments(shared.arguments),
      ),
    );
    _windowedPending = started;
    _windowedFor = shared;
    started.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaWebViewEnvironment.windowed',
          error,
          stack,
        );
        if (identical(_windowedPending, started)) {
          _windowedPending = null;
          _windowedFor = null;
        }
      },
    );
    return started;
  }

  /// 窗口宿主档环境的浏览器进程没了（WebView2 ProcessFailed）：丢掉缓存，下次
  /// [obtainWindowedHosting] 在同一目录 / 同一参数上重建（旧浏览器进程还活着就接回去）。
  /// 返回被换下的旧环境（调用方负责释放）。
  static Future<WebViewEnvironment>? discardWindowedHosting() {
    final Future<WebViewEnvironment>? old = _windowedPending;
    _windowedPending = null;
    _windowedFor = null;
    return old;
  }

  static Future<void> _disposeQuietly(
    Future<WebViewEnvironment?>? environment,
    String tag,
  ) async {
    if (environment == null) return;
    try {
      await (await environment)?.dispose();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(tag, error, stack);
    }
  }

  static Future<_SharedEnvironment?> _create(String arguments) async {
    final _SharedEnvironment? previous = _current;
    _current = null;
    // 窗口宿主档跟着共享环境走：它的隐藏控件也占着旧浏览器进程（旧参数），不放掉的话新参数
    // 在同一目录上永远建不出来。
    final Future<WebViewEnvironment>? previousWindowed =
        discardWindowedHosting();
    await _disposeQuietly(
      previousWindowed,
      'MangaWebViewEnvironment.disposeWindowed',
    );
    if (previous != null) {
      await _disposeQuietly(
        Future<WebViewEnvironment?>.value(previous.environment),
        'MangaWebViewEnvironment.dispose',
      );
    }
    for (final String suffix in <String>[
      '',
      '-${arguments.hashCode.toRadixString(16)}',
    ]) {
      final String folder = sharedUserDataFolder(
        environment: Platform.environment,
        suffix: suffix,
      );
      try {
        final WebViewEnvironment created = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: folder,
            additionalBrowserArguments: arguments,
          ),
        );
        final _SharedEnvironment shared = _SharedEnvironment(
          environment: created,
          folder: folder,
          arguments: arguments,
        );
        _current = shared;
        return shared;
      } on MissingPluginException {
        // 没有平台实现（widget 测试）：走默认。
        return null;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaWebViewEnvironment.create[$suffix]',
          error,
          stack,
        );
      }
    }
    return null;
  }
}

/// 一份建好的共享环境与它的目录 / 参数（窗口宿主档照抄这两样建自己的环境对象）。
class _SharedEnvironment {
  const _SharedEnvironment({
    required this.environment,
    required this.folder,
    required this.arguments,
  });

  final WebViewEnvironment environment;
  final String folder;
  final String arguments;
}

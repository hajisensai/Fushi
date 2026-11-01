// 网页站点视频的宿主会话（Windows WebView2）：两个宿主页共用的那一层。
//
// · 原生播放器页（VideoFushiPage 的网页档）：底层合成下的窗口宿主档——WebView2 子窗口垫在
//   Flutter 下面，硬件 PlayReady（Netflix 4K），播放控件 / 字幕 / 查词全是原生页自己的；
//   本会话只负责环境、注入脚本、登录 cookie、JS 消息分派、页面命令与输入归属。
// · 内置网页播放器（WebVideoFushiPage）：可捕获的 1080p 内置档，制卡队列重放的宿主；它仍持有
//   自己的 InAppWebView（DOM 字幕层 / 超分 / 截图都挂在那棵树上），只复用这里的环境、脚本
//   与 cookie 函数。
//
// 本文件不碰播放状态：播放态由页面 glue 上报（[WebVideoSession.onState]），交给
// [WebVideoPlatformPlayer] 变成 media_kit 的 player.state。
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_browser_settings.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_login_migration.dart';
import 'package:fushi/src/media/video/underlay_composition.dart'
    show UnderlayInputExclusion, underlayInputExclusions;
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/src/lookup/hover_lookup_modifier.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_permissions.dart';

/// JS→Dart 单一 handler 名（glue 的 `HANDLER`），载荷按 `type` 分派。
const String kWebVideoJsHandler = 'fushiWebVideo';

/// WebView2 持焦时截获视频快捷键交回 Dart 的桥 handler 名。
const String kWebVideoKeyBridgeHandler = 'fushiWebVideoKeys';

/// 流媒体书断点写库的最小位置（与视频页远端分支 `_persistRemotePosition` 的 BUG-996 阈值
/// 同口径）：播放头不足 5 秒不算「看过」，不覆盖已有进度。
const int kWebVideoMinPersistPositionMs = 5000;

// ── WebView2 环境 ─────────────────────────────────────────────────────────────

/// 可捕获 WebView2 环境单例：`--disable-direct-composition`。fork 的显示链路本身就是 WGC 捕获，
/// Chromium 把 DRM 视频放进 DComp overlay 时纹理里是黑的（真机：默认环境视频区纯黑、加该参数
/// 清晰可见）。environment 级参数不能运行期切换，且同 user data folder 的多个 env 参数必须逐字
/// 一致，故用独立目录（独立 cookie 罐）：登录态开页时从共享罐按需抄
/// （[copyWebVideoLoginCookies]），页面关掉时抄回（[syncWebVideoLoginToBrowser]）。
Future<WebViewEnvironment>? _capturableEnv;

/// 目录：测试 runner 给了 `FUSHI_WEBVIEW2_USER_DATA_FOLDER` 就放它旁边（隔离），否则
/// `%LOCALAPPDATA%\Fushi\WebVideoWebView2`（与 runner 的 OverlayUserDataFolder 命名法一致）。
String webVideoCapturableUserDataFolder() {
  final String? testFolder =
      Platform.environment['FUSHI_WEBVIEW2_USER_DATA_FOLDER'];
  if (testFolder != null && testFolder.isNotEmpty) {
    return '$testFolder-webvideo';
  }
  final String base = Platform.environment['LOCALAPPDATA'] ?? '.';
  return '$base\\Fushi\\WebVideoWebView2';
}

Future<WebViewEnvironment> webVideoCapturableEnvironment() {
  return _capturableEnv ??= WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(
      userDataFolder: webVideoCapturableUserDataFolder(),
      additionalBrowserArguments:
          '--autoplay-policy=no-user-gesture-required --disable-direct-composition',
    ),
  );
}

/// 窗口宿主档（4K）环境：**不带** `--disable-direct-composition`（硬件 PlayReady 的受保护输出
/// 要走 DComp overlay），带 fork 的窗口宿主哨兵。与 app 内浏览器**同一 user data folder、同一
/// 套 Chromium 参数**（fork 把哨兵剥掉再交给 WebView2），所以是同一个 cookie 罐：浏览器里登录
/// 的站点播放页直接是登录态，反之亦然。环境由 [MangaWebViewEnvironment.obtainWindowedHosting]
/// 统一提供（代理设置变化时随浏览器环境一起换）。
///
/// 首次调用时把旧版独立 4K profile 里的登录迁进共享罐（[migrateWebVideoLegacyLogin]，一次性，
/// 只补缺）。
Future<WebViewEnvironment> webVideoWindowedEnvironment() async {
  final WebViewEnvironment env =
      await MangaWebViewEnvironment.obtainWindowedHosting();
  final String? sharedFolder = MangaWebViewEnvironment.currentUserDataFolder;
  if (sharedFolder != null) {
    await migrateWebVideoLegacyLogin(
      shared: env,
      sharedFolder: sharedFolder,
      capturableFolder: webVideoCapturableUserDataFolder(),
    );
  }
  return env;
}

/// 窗口宿主档环境的浏览器进程没了（WebView2 ProcessFailed，fork 转成 onRenderProcessGone）：
/// 丢掉缓存，下次 [webVideoWindowedEnvironment] 在同一目录 / 同一参数上重建。同目录同参数的新
/// 环境在旧浏览器进程还活着时会直接接到它上面（WebView2 的环境共享规则），所以只是渲染进程死了
/// 也照样可用。返回被换下的旧环境（调用方负责释放）。
Future<WebViewEnvironment>? discardWebVideoWindowedEnvironment() =>
    MangaWebViewEnvironment.discardWindowedHosting();

// ── 注入脚本 / cookie ───────────────────────────────────────────────────────

/// WebView2 持焦期间截获视频作用域全部键盘绑定（token 直接取注册表序列化形式，
/// 用户改绑后重开页面即生效），交回 Dart 走同一份动作表。输入框里打字照常放行
/// （登录页要能输密码，见 [webViewKeyBridgeScript]）。
String webVideoKeyBridgeScript(FushiShortcutRegistry registry) {
  final Set<String> tokens = <String>{};
  for (final ShortcutAction action in <ShortcutAction>{
    ...ShortcutAction.actionsForScope(ShortcutScope.video),
    ShortcutAction.globalBack,
  }) {
    for (final InputBinding b
        in registry.bindingsFor(action).keyboardBindings) {
      tokens.add(b.serialize());
    }
  }
  return webViewKeyBridgeScript(
    handlerName: kWebVideoKeyBridgeHandler,
    keys: tokens.toList(growable: false),
    forwardRepeats: false,
    stopPropagation: true,
  );
}

/// document-start 注入脚本：垫片（可选）→ 全部站点 bridge（各自按当前文档 host 自判，见
/// [webVideoHostGuardedBridgeSource]：document-start 脚本建 WebView 时就定死，按起始页选 bridge
/// 的话换站后就没有 bridge）→ adapters → providers →（可选）原生字幕开关 → glue →（可选）DOM
/// 字幕层 → 键盘桥。资产读取失败直接抛（调用方落失败态）。
Future<UnmodifiableListView<UserScript>> loadWebVideoUserScripts({
  required bool softwareDrm,
  required bool domOverlay,
  required String keyBridgeScript,
  bool pageLookup = false,
  bool hideNativeSubtitles = false,
}) async {
  final List<String> sources = <String>[
    // 垫片必须排第一：站点脚本一跑就会抓走原始 EME 函数引用。
    if (softwareDrm) await rootBundle.loadString(kWebVideoEmeShimAsset),
    for (final (String asset, List<String> hosts) in kWebVideoSiteBridges)
      webVideoHostGuardedBridgeSource(
        await rootBundle.loadString(asset),
        hosts,
      ),
    await rootBundle.loadString(kWebVideoAdaptersAsset),
    await rootBundle.loadString(kWebVideoProvidersAsset),
    // 站点字幕在页面第一帧之前就藏（glue 装载即读这个开关），不等 onLoadStop。
    if (hideNativeSubtitles) kWebVideoHideNativeSubtitlesPrelude,
    await rootBundle.loadString(kWebVideoGlueAsset),
    if (domOverlay) await rootBundle.loadString(kWebVideoDomSubtitlesAsset),
    if (pageLookup) await rootBundle.loadString(kWebVideoPageLookupAsset),
    keyBridgeScript,
  ];
  return UnmodifiableListView<UserScript>(<UserScript>[
    for (final String src in sources)
      UserScript(
        source: src,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
  ]);
}

/// 登录 cookie 的来源：共享 cookie 罐（app 内浏览器 = 原生播放器页网页档，见
/// [MangaWebViewEnvironment]）。只有可捕获档（内置档）还是独立罐，开页时从这里按需抄一份；
/// 制卡队列在内置档里重放，用户在浏览器 / 播放页里登录的都在共享罐里。
const List<Future<WebViewEnvironment?> Function()> kWebVideoLoginCookieSources =
    <Future<WebViewEnvironment?> Function()>[MangaWebViewEnvironment.obtain];

/// 可捕获档是独立 cookie 罐（`--disable-direct-composition` 与共享罐参数不同 → 独立 user data
/// folder）：把 [sources]（默认 [kWebVideoLoginCookieSources]）里已登录的站点 cookie 复制到
/// [to]，用户不用登录两次。目标是共享罐（浏览器 / 窗口宿主档）时不要调——同一个罐。
/// 尽力而为：单个来源失败只记日志、不挡其它来源（最坏是站点要求登录）。返回 [to] 里原本
/// 没有、这次新加上的 cookie 名数（> 0 通常意味着目标从未登录变成已登录，调用方据此决定
/// 要不要刷新已打开的页面）。
Future<int> copyWebVideoLoginCookies({
  required Uri uri,
  required WebViewEnvironment to,
  List<Future<WebViewEnvironment?> Function()> sources =
      kWebVideoLoginCookieSources,
}) async {
  final WebUri url = WebUri('${uri.scheme}://${uri.host}/');
  final CookieManager dst = CookieManager.instance(webViewEnvironment: to);
  final Set<String> existing = <String>{};
  try {
    for (final Cookie c in await dst.getCookies(url: url)) {
      existing.add(c.name);
    }
  } catch (e) {
    ErrorLogService.instance.log('web_video', 'cookie read: $e');
  }
  final Set<String> added = <String>{};
  for (final Future<WebViewEnvironment?> Function() source in sources) {
    try {
      final WebViewEnvironment? from = await source();
      // 没有显式环境（非 Windows / 建不出来）或就是目标自己：没东西可抄。
      if (from == null || identical(from, to)) continue;
      final List<Cookie> cookies = await CookieManager.instance(
        webViewEnvironment: from,
      ).getCookies(url: url);
      for (final Cookie c in cookies) {
        final bool ok = await dst.setCookie(
          url: url,
          name: c.name,
          value: c.value.toString(),
          domain: c.domain,
          path: c.path ?? '/',
          // 会话 cookie 不带 expires（fork 已把 CDP 的秒转成毫秒、会话回 null）。
          expiresDate: c.isSessionOnly == true ? null : c.expiresDate,
          isSecure: c.isSecure,
          isHttpOnly: c.isHttpOnly,
        );
        if (ok && !existing.contains(c.name)) added.add(c.name);
      }
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'cookie copy: $e');
    }
  }
  return added.length;
}

/// 反方向：可捕获档（内置档）页里的站点登录态抄回共享 cookie 罐（[MangaWebViewEnvironment]）。
/// 用户也会在内置档页里登录；不抄回去的话浏览器与原生播放器页看同一个站点还是未登录
/// （BUG-3801）。**只在内置档页关掉时调**：窗口宿主档就住在共享罐里，没东西可抄，抄可捕获档
/// 反而会拿它开页时的旧值盖掉共享罐里的新值。返回共享罐新加的 cookie 名数（见
/// [copyWebVideoLoginCookies]）。非 Windows / 共享环境建不出来时返回 0。
Future<int> syncWebVideoLoginToBrowser(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return Future<int>.value(0);
  final Future<int> started = _syncWebVideoLoginToBrowser(uri);
  final Future<void> settled = started.then<void>((_) {}, onError: (_) {});
  _browserLoginSyncs[host] = settled;
  unawaited(
    settled.whenComplete(() {
      if (identical(_browserLoginSyncs[host], settled)) {
        _browserLoginSyncs.remove(host);
      }
    }),
  );
  return started;
}

/// 每个 host 正在进行的 [syncWebVideoLoginToBrowser]（播放页 dispose 发起的那次）。
final Map<String, Future<void>> _browserLoginSyncs = <String, Future<void>>{};

/// 等 [uri] 这个站点正在进行的回抄完成（没有就立刻完成）：浏览器标签页回到前台时先等它，
/// 再看自己的 cookie 有没有变。
Future<void> webVideoBrowserLoginSyncSettled(Uri uri) =>
    _browserLoginSyncs[uri.host.toLowerCase()] ?? Future<void>.value();

/// app 内浏览器里 [uri] 站点当前的 cookie 名（非 Windows / 读不到时为空集）。
Future<Set<String>> webBrowserSiteCookieNames(Uri uri) async {
  if (uri.host.isEmpty) return <String>{};
  try {
    final WebViewEnvironment? browser = await MangaWebViewEnvironment.obtain();
    if (browser == null) return <String>{};
    final List<Cookie> cookies = await CookieManager.instance(
      webViewEnvironment: browser,
    ).getCookies(url: WebUri('${uri.scheme}://${uri.host}/'));
    return <String>{for (final Cookie c in cookies) c.name};
  } catch (e) {
    ErrorLogService.instance.log('web_video', 'browser cookie names: $e');
    return <String>{};
  }
}

Future<int> _syncWebVideoLoginToBrowser(Uri uri) async {
  final WebViewEnvironment? browser;
  try {
    browser = await MangaWebViewEnvironment.obtain();
  } catch (e) {
    ErrorLogService.instance.log('web_video', 'browser env: $e');
    return 0;
  }
  if (browser == null) return 0;
  return copyWebVideoLoginCookies(
    uri: uri,
    to: browser,
    sources: const <Future<WebViewEnvironment?> Function()>[
      webVideoCapturableEnvironment,
    ],
  );
}

/// 浏览器扩展送来的站点会话（[BrowserCookieImportGate]，与漫画源登录同一条通道，即「从系统
/// 浏览器导入登录」）写进共享 cookie 罐（app 内浏览器 = 原生播放器页网页档）。可捕获档下次开页
/// 时从共享罐抄（[copyWebVideoLoginCookies]），不另写。逐条写、单条失败不中断（WebView2 会拒
/// 个别属性组合）；返回写进的条数。非 Windows / 共享环境建不出来时返回 0。
Future<int> importWebVideoBrowserCookies(
  List<BrowserSiteCookie> cookies,
) async {
  final WebViewEnvironment? shared;
  try {
    shared = await MangaWebViewEnvironment.obtain();
  } catch (e) {
    ErrorLogService.instance.log('web_video', 'browser cookie env: $e');
    return 0;
  }
  if (shared == null) return 0;
  return writeBrowserSiteCookies(
    CookieManager.instance(webViewEnvironment: shared),
    cookies,
  );
}

/// 页面地址是不是「正在看某一集」的播放页（自动进播放器档的判据）：Netflix 的
/// `/watch/<id>`、YouTube 的 `/watch` `/shorts` `/live` `/embed` 与 youtu.be 短链。浏览 /
/// 详情页上的预告片、悬停预览也是 `<video>`，但不算——那里用户是在选集。其它站点没有可靠的
/// 地址形状，有视频就算（与改动前一致）。
bool webVideoIsWatchPage(String href) {
  final Uri? uri = Uri.tryParse(href);
  if (uri == null) return false;
  final String host = uri.host.toLowerCase();
  bool on(String domain) => host == domain || host.endsWith('.$domain');
  final String path = uri.path;
  if (on('netflix.com')) return path.startsWith('/watch/');
  if (on('youtu.be')) return path.length > 1;
  if (on('youtube.com')) {
    return path == '/watch' ||
        path.startsWith('/shorts/') ||
        path.startsWith('/live/') ||
        path.startsWith('/embed/');
  }
  return true;
}

/// 网页档工具条（后退 / 前进 / 刷新 / 地址栏）要的导航态。
@immutable
class WebVideoNavState {
  const WebVideoNavState({
    this.url = '',
    this.canGoBack = false,
    this.canGoForward = false,
    this.loading = false,
  });

  final String url;
  final bool canGoBack;
  final bool canGoForward;
  final bool loading;

  WebVideoNavState copyWith({
    String? url,
    bool? canGoBack,
    bool? canGoForward,
    bool? loading,
  }) => WebVideoNavState(
    url: url ?? this.url,
    canGoBack: canGoBack ?? this.canGoBack,
    canGoForward: canGoForward ?? this.canGoForward,
    loading: loading ?? this.loading,
  );
}

/// 地址栏输入 → 要打开的地址：像网址的补 `https://`；不像网址的（没有点、带空格）当
/// 搜索词交给 Google。空串返回 null。
String? webVideoAddressBarTarget(String input) {
  final String s = input.trim();
  if (s.isEmpty) return null;
  final bool looksLikeUrl =
      s.contains('://') || (!s.contains(' ') && s.contains('.'));
  if (looksLikeUrl) {
    final String withScheme = s.contains('://') ? s : 'https://$s';
    final Uri? uri = Uri.tryParse(withScheme);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return uri.toString();
    }
  }
  return Uri.https('www.google.com', '/search', <String, String>{
    'q': s,
  }).toString();
}

// ── 会话（原生播放器页的网页档）──────────────────────────────────────────────

/// 一本网页站流媒体书在原生播放器页里的宿主会话：窗口宿主档 + 底层合成。
///
/// 生命周期：页面 [prepare] 成功后把 [WebVideoSurface] 挂进视频区最底层（同一棵子树、
/// 稳定 key，加载 / 就绪切换不重建），页面 dispose 时 [dispose]。WebView 自身随 widget 销毁。
class WebVideoSession {
  WebVideoSession({
    required this.bookUid,
    required this.pageUrl,
    this.onTrack,
    this.onState,
    this.onKeyToken,
    this.onPageLookup,
    this.hoverLookupModifier,
    this.onSeekDone,
    this.onTrackFailed,
    this.onCommandFailed,
    this.onNetflixMetadata,
    this.adblock,
    this.browserPrefs,
  });

  /// 浏览器的广告拦截服务（与 app 内浏览器标签页同一个，[webVideoSurfaceWiring]）；null = 不接
  /// （测试宿主）。
  final WebAdblockPolicy? adblock;

  /// 浏览器的偏好 / 网站设置所在的偏好库（网页深色、按站点权限，见
  /// `web_video_browser_settings.dart`）；null = 不接（测试宿主）。改了浏览器设置，已打开的本页
  /// 当场跟上（[_onBrowserPrefsChanged]）。
  final PreferencesRepository? browserPrefs;

  /// seek 回执（[WebVideoPlatformPlayer.applySeekDone]）。
  void Function(WebVideoSeekDone done)? onSeekDone;

  /// 站点整轨抓取失败（store key）。
  void Function(String key)? onTrackFailed;

  /// 页面命令异步失败（目前只有 play 被自动播放策略拒绝）。
  void Function(String command, String error)? onCommandFailed;

  /// Netflix metadata 接口回执：成功时 [text] 是原文，失败时为 null、[error] 是原因。
  void Function(String movieId, String? text, String error)? onNetflixMetadata;

  /// 书架流媒体书 uid（写进每条 cue 的 bookKey）；站内换集落成新书时由页面改写。
  String bookUid;

  /// 起始页（书的 `videoPath`）。
  final String pageUrl;

  /// 站点字幕轨（整轨；live 轨边看边长，同 key 重复投递）。
  void Function(WebVideoTrack track)? onTrack;

  /// 页面播放态快照（glue 每 250 ms 轮询、变化才投）。
  void Function(WebVideoPlaybackState state)? onState;

  /// WebView2 持焦时截获的快捷键 token（[InputBinding.serialize] 形式）。
  void Function(String token)? onKeyToken;

  /// 网页档 Shift 悬停在站点文字上（[kWebVideoPageLookupAsset]）。
  void Function(WebVideoLookupRequest request)? onPageLookup;

  /// 悬停查词按住的键（每次页面加载读一次，设置改了下一页即生效）；null = Shift。
  final HoverLookupModifier Function()? hoverLookupModifier;

  WebViewEnvironment? _environment;
  UnmodifiableListView<UserScript>? _userScripts;

  /// 浏览器广告拦截接线（[prepare] 里建；渲染进程死后重建 WebView 沿用同一份）。
  WebAdblockWiring? _adblock;

  /// 最近一次下发给页面的网页深色状态；null = 新建的 WebView 还没同步过。
  bool? _appliedPageDark;
  InAppWebViewController? _web;
  Object? _viewId;
  bool _disposed = false;

  /// 最近一次上报的播放态（制卡入队要 href / videoKey）。
  WebVideoPlaybackState? get lastState => _lastState;
  WebVideoPlaybackState? _lastState;

  /// 当前是不是播放器档（页面只留画面、输入归 Flutter）；否则是网页档（整页可点）。
  bool get playerMode => _playerMode;
  bool _playerMode = false;

  /// 工具条的导航态（地址 / 能否后退前进 / 是否在加载）。
  final ValueNotifier<WebVideoNavState> nav = ValueNotifier<WebVideoNavState>(
    const WebVideoNavState(),
  );

  /// WebView2 子窗口当前是否收输入；null = 新建的 WebView 还没同步过。
  bool? _inputEnabled;

  /// 本页被别的路由（对话框 / 菜单 / 底部面板 / 新页）盖住：那些都画在网页上面，网页
  /// 不能再收输入，否则点不到（[setCovered]）。
  bool _covered = false;

  /// 子窗口上挖掉的输入区（相对 WebView 左上角的逻辑 px，见 [setInputExclusions]）。
  List<UnderlayInputExclusion> _exclusions = const <UnderlayInputExclusion>[];

  /// 已下发给新建 WebView 的挖洞表；null = 还没同步过。
  List<UnderlayInputExclusion>? _sentExclusions;

  bool get isReady => _environment != null && _userScripts != null;

  /// WebView（重）建时打开的地址：首建是起始页；进程死后重建回到死前所在的页面
  /// （[recoverFromProcessGone]），不把用户甩回起始页。
  String get surfaceUrl => _surfaceUrl ?? pageUrl;
  String? _surfaceUrl;

  /// 渲染 / 浏览器进程死后、表面重建前（[WebViewDeathGuard] 的 flushBeforeRebuild）：换一个新的
  /// 窗口宿主档环境（浏览器进程没了旧环境就是废的；只是渲染进程没了新环境会接回同一个浏览器
  /// 进程），并记下重建后要回到的地址。登录态在共享罐里，不用抄。失败抛出由 death guard 记录——重建
  /// 照样进行，最坏是新 WebView 在旧环境里建不出来，与修复前一样停在死页面。
  Future<void> recoverFromProcessGone() async {
    if (_disposed) return;
    final String current = nav.value.url;
    if (current.isNotEmpty) _surfaceUrl = current;
    _web = null;
    _viewId = null;
    final Future<WebViewEnvironment>? old =
        discardWebVideoWindowedEnvironment();
    final WebViewEnvironment env = await webVideoWindowedEnvironment();
    if (_disposed) return;
    _environment = env;
    if (old != null) {
      try {
        final WebViewEnvironment stale = await old;
        if (!identical(stale, env)) await stale.dispose();
      } catch (e) {
        ErrorLogService.instance.log('web_video', 'stale env dispose: $e');
      }
    }
  }

  /// 建 WebView 之前的异步准备：注入脚本、窗口宿主档环境（与 app 内浏览器共享 cookie 罐，
  /// 登录态天然一致）。
  /// 资产缺失 / WebView2 Runtime 缺失会抛（调用方落失败态，不吞）。
  Future<void> prepare({required FushiShortcutRegistry shortcuts}) async {
    final UnmodifiableListView<UserScript> scripts =
        await loadWebVideoUserScripts(
          // 窗口宿主档就是为硬件 DRM 开的，不装软件 DRM 垫片。
          softwareDrm: false,
          // 字幕归 Flutter 叠层（底层合成下 Flutter 画在 WebView 上面）。
          domOverlay: false,
          keyBridgeScript: webVideoKeyBridgeScript(shortcuts),
          // 网页档（站点页面可点）里按住 Shift 悬停查任意文字。
          pageLookup: true,
          // 字幕归 Fushi 叠层：站点自己的字幕从第一帧起就藏（visibility，DOM 采样 live 轨照读）。
          hideNativeSubtitles: true,
        );
    final WebViewEnvironment env = await webVideoWindowedEnvironment();
    final WebAdblockPolicy? policy = adblock;
    _adblock = policy == null ? null : webVideoSurfaceWiring(policy: policy);
    _userScripts = scripts;
    _environment = env;
    browserPrefs?.addListener(_onBrowserPrefsChanged);
  }

  /// 建 WebView 用的设置：播放器必需项 + 浏览器广告拦截（[webVideoSurfaceWiring]）。
  InAppWebViewSettings _surfaceSettings() {
    final InAppWebViewSettings? shared = _adblock?.settings;
    if (shared != null) return shared;
    final InAppWebViewSettings settings = InAppWebViewSettings();
    enforceWebVideoRequiredSettings(settings);
    return settings;
  }

  /// 建 WebView 时的 document-start 脚本：播放器自己的排前面（垫片 / bridge / glue 的顺序
  /// 约束见 [loadWebVideoUserScripts]），浏览器共享的广告拦截 cosmetic 与页内样式接在后面。
  UnmodifiableListView<UserScript>? _surfaceUserScripts() {
    final UnmodifiableListView<UserScript>? own = _userScripts;
    if (own == null) return null;
    return UnmodifiableListView<UserScript>(<UserScript>[
      ...own,
      ...?_adblock?.userScripts,
      webBrowserPageStyleUserScript(
        platform: _platform,
        textZoom: 100,
        forceDark: _pageDark,
      ),
    ]);
  }

  TargetPlatform get _platform => defaultTargetPlatform;

  /// 当前该不该给页面套网页深色（浏览器偏好 × 网页档，[webVideoPageForceDark]）。
  bool get _pageDark {
    final PreferencesRepository? prefs = browserPrefs;
    return webVideoPageForceDark(
      browserForceDark: prefs != null && webVideoBrowserForceDark(prefs),
      playerMode: _playerMode,
    );
  }

  void _onBrowserPrefsChanged() {
    if (_disposed) return;
    _applyPageStyle();
  }

  /// 网页深色跟上当前状态（浏览器偏好变了 / 档位切了）：换掉以后每个文档的样式脚本并对当前
  /// 文档立即生效（[applyWebBrowserPageStyle]，与浏览器标签页同一段）。
  void _applyPageStyle() {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    final bool dark = _pageDark;
    if (_appliedPageDark == dark) return;
    _appliedPageDark = dark;
    unawaited(
      applyWebBrowserPageStyle(
        web,
        platform: _platform,
        textZoom: 100,
        forceDark: dark,
      ).catchError((Object e) {
        ErrorLogService.instance.log('web_video', 'page style: $e');
      }),
    );
  }

  /// 站点权限申请（摄像头 / 麦克风 / 通知 / 剪贴板……）：按浏览器的「网站设置」答，没记住的
  /// 弹同一个框（[resolveWebBrowserPermissionRequest]）；不接浏览器设置时一律拒绝（与 WebView2
  /// 插件在没有 Dart 回调时的默认行为一致）。
  Future<PermissionResponse> _onPermissionRequest(
    BuildContext context,
    PermissionRequest request,
  ) {
    final PreferencesRepository? prefs = browserPrefs;
    if (prefs == null || _disposed) {
      return Future<PermissionResponse>.value(
        PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
      );
    }
    return resolveWebBrowserPermissionRequest(
      context: context,
      settings: WebBrowserSiteSettings(prefs),
      request: request,
      platform: _platform,
    );
  }

  /// 在站点页面里执行一条 `window.__fushiWebVideo.*` 表达式（[WebVideoPlatformPlayer.evaluate]
  /// 的实现），返回表达式的值（命令的结果码）。glue 没装上 / WebView 还没建时返回 null；失败记
  /// 日志并返回 null——调用方把 null 当「命令没发出去」。
  Future<Object?> evaluate(String expression) async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return null;
    try {
      return await web.evaluateJavascript(
        source:
            '(function(){try{return window.__fushiWebVideo&&'
            '($expression);}catch(e){return String(e);}})()',
      );
    } catch (e) {
      ErrorLogService.instance.log(
        'web_video',
        'evaluateJavascript failed: $e',
      );
      return null;
    }
  }

  /// 原样求值（诊断 / 集成测试读页面状态），返回结果的字符串形式。
  Future<String?> evaluateRaw(String source) async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return null;
    final Object? r = await web.evaluateJavascript(source: source);
    return r?.toString();
  }

  /// 站内后退一步；没有可退的历史返回 false（调用方再往外退一级）。
  Future<bool> goBack() async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return false;
    if (!await web.canGoBack()) return false;
    await web.goBack();
    return true;
  }

  Future<void> goForward() async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    if (await web.canGoForward()) await web.goForward();
  }

  Future<void> reloadOrStop() async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    if (nav.value.loading) {
      await web.stopLoading();
    } else {
      await web.reload();
    }
  }

  Future<void> reload() async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    await web.reload();
  }

  Future<void> loadUrl(String url) async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _refreshHistory(String? url) async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    final bool back = await web.canGoBack();
    final bool forward = await web.canGoForward();
    if (_disposed) return;
    nav.value = nav.value.copyWith(
      url: url,
      canGoBack: back,
      canGoForward: forward,
    );
  }

  void _onLoading(bool loading, String? url) {
    if (_disposed) return;
    nav.value = nav.value.copyWith(loading: loading, url: url);
  }

  /// 已采到的字幕轨整轨重投（换了书身份后 cue 的 bookKey 要跟着换）。
  Future<void> replayCues() => evaluate('window.__fushiWebVideo.replayCues()');

  /// YouTube 画质目标高度（设置「YouTube 画质」，0 = 自动 = 可用最高档）。每次进只留画面
  /// 都随 [setVideoOnly] 带下去：整页导航后 glue 是新文档、状态从头来。
  int qualityTargetHeight = 0;

  Future<void> setVideoOnly(bool on) => evaluate(
    'window.__fushiWebVideo.setVideoOnly($on, $qualityTargetHeight)',
  );

  /// 播放中改画质目标：记下（之后的 [setVideoOnly] 带它），并让页面当场重选。
  Future<void> setQualityTarget(int height) {
    qualityTargetHeight = height < 0 ? 0 : height;
    return evaluate(
      'window.__fushiWebVideo.setQualityTarget($qualityTargetHeight)',
    );
  }

  Future<void> setPlayerChromeHidden(bool hidden) =>
      evaluate('window.__fushiWebVideo.setPlayerChromeHidden($hidden)');

  Future<void> setNativeSubtitlesHidden(bool hidden) =>
      evaluate('window.__fushiWebVideo.setNativeSubtitlesHidden($hidden)');

  /// 底层合成下的输入归属：播放器档时 WebView2 子窗口不收输入（命中测试跳过它，点击 / 滚轮 /
  /// 触摸落到上面的 Flutter 播放器），站点控制条藏起来、页面只留画面；网页档（登录、选人、
  /// 详情 / 选集页，或用户点了「回到网页」）时还给 WebView、整页原样。站内换集（SPA）可能换了
  /// video 元素：[videoChanged] 时重新标记。
  void syncInput({required bool playerMode, bool videoChanged = false}) {
    final bool changed = playerMode != _playerMode;
    _playerMode = playerMode;
    _applyInputEnabled();
    if (changed || (videoChanged && playerMode)) _applyPageMode();
    // 播放器档不套网页深色（受保护视频套滤镜可能变黑），回网页档再按浏览器偏好套回来。
    if (changed) _applyPageStyle();
  }

  /// 退出站点自己的元素全屏（网页档里点了站点的全屏钮 → 换成本页的播放器档 + 窗口全屏）。
  Future<void> exitPageFullscreen() =>
      evaluate('document.fullscreenElement&&document.exitFullscreen()');

  /// 本页路由是不是被别的路由盖住了（[_covered]）。
  void setCovered(bool covered) {
    if (covered == _covered) return;
    _covered = covered;
    _applyInputEnabled();
  }

  /// 画在网页上面、要自己接鼠标的 Flutter 区域（悬浮球等，相对 WebView 左上角的逻辑 px）：
  /// 从 WebView2 子窗口上挖掉，点击落到上面的 Flutter 控件。
  void setInputExclusions(List<UnderlayInputExclusion> exclusions) {
    if (listEquals(exclusions, _exclusions)) return;
    _exclusions = List<UnderlayInputExclusion>.unmodifiable(exclusions);
    _applyInputExclusions();
  }

  void _applyInputExclusions() {
    final Object? viewId = _viewId;
    if (viewId == null || _disposed) return;
    if (_sentExclusions != null && listEquals(_sentExclusions, _exclusions)) {
      return;
    }
    _sentExclusions = _exclusions;
    unawaited(
      MethodChannel('$kWebVideoPlatformViewChannelPrefix$viewId')
          .invokeMethod<bool>(
            kWebVideoSetWindowedInputExclusionsMethod,
            <List<double>>[
              for (final UnderlayInputExclusion e in _exclusions)
                <double>[
                  e.rect.left,
                  e.rect.top,
                  e.rect.right,
                  e.rect.bottom,
                  e.radius,
                ],
            ],
          )
          .catchError((Object e) {
            ErrorLogService.instance.log('web_video', 'input exclusions: $e');
            return false;
          }),
    );
  }

  void _applyInputEnabled() {
    final Object? viewId = _viewId;
    if (viewId == null || _disposed) return;
    final bool enabled = !_playerMode && !_covered;
    if (_inputEnabled == enabled) return;
    _inputEnabled = enabled;
    unawaited(
      MethodChannel('$kWebVideoPlatformViewChannelPrefix$viewId')
          .invokeMethod<bool>(kWebVideoSetWindowedInputEnabledMethod, enabled)
          .catchError((Object e) {
            ErrorLogService.instance.log('web_video', 'input passthrough: $e');
            return false;
          }),
    );
  }

  /// 页面模式（只留画面 + 藏站点控制条）跟随 [_playerMode]；`<style>` 属于当前文档，
  /// 整页导航后要重挂（[_onLoadStop]）。
  void _applyPageMode() {
    unawaited(setPlayerChromeHidden(_playerMode));
    unawaited(setVideoOnly(_playerMode));
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _web = controller;
    _viewId = controller.platform.id;
    // 新建（含渲染进程死亡后重建）的 WebView：输入状态从头同步。
    _inputEnabled = null;
    _applyInputEnabled();
    _sentExclusions = null;
    _applyInputExclusions();
    _adblock?.onWebViewCreated(controller);
    // 建时的样式脚本按建 WebView 那一刻的状态生成（[_surfaceUserScripts]）；之后的变化从这里跟。
    _appliedPageDark = _pageDark;
    controller.addJavaScriptHandler(
      handlerName: kWebVideoJsHandler,
      callback: limitWebPayload(
        kWebVideoJsHandler,
        kWebPayloadLargeMaxChars,
        _onJsMessage,
      ),
    );
    controller.addJavaScriptHandler(
      handlerName: kWebVideoKeyBridgeHandler,
      callback: limitWebPayload(
        kWebVideoKeyBridgeHandler,
        kWebPayloadTinyMaxChars,
        (List<dynamic> args) {
          if (args.isNotEmpty) onKeyToken?.call(args.first.toString());
          return null;
        },
      ),
    );
  }

  void _onLoadStop() {
    unawaited(
      evaluateRaw(
        hoverLookupModifierJs(
          hoverLookupModifier?.call() ?? HoverLookupModifier.shift,
        ),
      ).catchError((Object _) => null),
    );
    unawaited(evaluate('window.__fushiWebVideo.replayCues()'));
    if (_playerMode) _applyPageMode();
  }

  Future<Object?> _onJsMessage(List<dynamic> args) async {
    if (_disposed || args.isEmpty || args.first is! Map) return null;
    final Map<dynamic, dynamic> msg = args.first as Map<dynamic, dynamic>;
    switch (msg['type']) {
      case 'track':
        final WebVideoTrack? track = parseWebVideoTrackPayload(
          msg,
          bookUid: bookUid,
        );
        if (track != null) onTrack?.call(track);
      case 'pageLookup':
        final WebVideoLookupRequest? request = parseWebVideoLookupPayload(msg);
        if (request != null) onPageLookup?.call(request);
      case 'state':
        final WebVideoPlaybackState? state = parseWebVideoStatePayload(
          msg,
          webViewUrl: nav.value.url,
        );
        if (state != null) {
          _lastState = state;
          onState?.call(state);
        }
      case 'seekDone':
        final WebVideoSeekDone? done = parseWebVideoSeekDonePayload(msg);
        if (done != null) onSeekDone?.call(done);
      case 'trackFailed':
        final String? key = parseWebVideoTrackFailedKey(msg);
        if (key != null) {
          ErrorLogService.instance.log(
            'web_video',
            'site subtitle track capture failed: $key ${msg['err'] ?? ''}',
          );
          onTrackFailed?.call(key);
        }
      case 'cmdFailed':
        final String command = (msg['cmd'] ?? '').toString();
        final String error = (msg['err'] ?? '').toString();
        ErrorLogService.instance.log(
          'web_video',
          'page command $command failed: $error',
        );
        onCommandFailed?.call(command, error);
      case 'nfMeta':
        final String movieId = (msg['movieId'] ?? '').toString();
        if (msg['ok'] == true && msg['text'] is String) {
          onNetflixMetadata?.call(movieId, msg['text'] as String, '');
        } else {
          final String error = (msg['err'] ?? '').toString();
          ErrorLogService.instance.log(
            'web_video',
            'netflix metadata $movieId failed: $error',
          );
          onNetflixMetadata?.call(movieId, null, error);
        }
    }
    return null;
  }

  void dispose() {
    // 播放页里登录的站点会话抄回 app 内浏览器（登录入口主要在浏览器，BUG-3801）。
    if (!_disposed && isReady) {
      final String current = nav.value.url;
      unawaited(
        syncWebVideoLoginToBrowser(
          Uri.parse(current.isNotEmpty ? current : pageUrl),
        ),
      );
    }
    _disposed = true;
    browserPrefs?.removeListener(_onBrowserPrefsChanged);
    nav.dispose();
    _web = null;
    _viewId = null;
    onTrack = null;
    onState = null;
    onKeyToken = null;
    onPageLookup = null;
    onSeekDone = null;
    onTrackFailed = null;
    onCommandFailed = null;
    onNetflixMetadata = null;
  }
}

/// [WebVideoSession] 的 WebView：页面把它放在视频区最底层、给一个稳定 key（登录页在有视频
/// 之前就要能用，加载 / 就绪分支切换不能把它重建掉）。渲染进程死亡按 [WebViewDeathGuard]
/// 换代重建；会话没准备好时是空盒。
class WebVideoSurface extends StatefulWidget {
  const WebVideoSurface({required this.session, super.key});

  final WebVideoSession session;

  @override
  State<WebVideoSurface> createState() => _WebVideoSurfaceState();
}

class _WebVideoSurfaceState extends State<WebVideoSurface> {
  @override
  void initState() {
    super.initState();
    underlayInputExclusions.addListener(_syncExclusions);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 对话框 / 菜单 / 新页盖在本页上面时网页整个不收输入（它们画在网页上面）。
    widget.session.setCovered(!(ModalRoute.of(context)?.isCurrent ?? true));
  }

  @override
  void didUpdateWidget(WebVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _syncExclusions();
  }

  @override
  void dispose() {
    underlayInputExclusions.removeListener(_syncExclusions);
    super.dispose();
  }

  /// 全局区域 → 相对本 WebView 左上角（与原生 setPosition 同一套逻辑坐标），只留压在网页上的。
  void _syncExclusions() {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final Offset origin = box.localToGlobal(Offset.zero);
    final Rect bounds = Offset.zero & box.size;
    widget.session.setInputExclusions(<UnderlayInputExclusion>[
      for (final UnderlayInputExclusion e in underlayInputExclusions.value)
        if (e.rect.shift(-origin).overlaps(bounds))
          UnderlayInputExclusion(e.rect.shift(-origin), e.radius),
    ]);
  }

  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'web_video_underlay',
    flushBeforeRebuild: widget.session.recoverFromProcessGone,
    afterRebuild: () {
      if (mounted) setState(() {});
    },
    reporter: (String surface, String message) =>
        ErrorLogService.instance.log('web_video', '$surface: $message'),
  );

  @override
  Widget build(BuildContext context) {
    final WebVideoSession session = widget.session;
    // 本视图换了位置 / 尺寸（网页档 ↔ 播放器档的顶部让位）而全局区域没变时也要重算。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _syncExclusions();
    });
    if (!session.isReady) return const SizedBox.shrink();
    return KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        webViewEnvironment: session._environment,
        initialUrlRequest: URLRequest(url: WebUri(session.surfaceUrl)),
        // 播放器必需项 + 浏览器共享的站点设置（广告拦截 / 网页深色 / 网站设置权限，见
        // `web_video_browser_settings.dart`）。
        initialUserScripts: session._surfaceUserScripts(),
        initialSettings: session._surfaceSettings(),
        shouldInterceptRequest: session._adblock?.shouldInterceptRequest,
        onWebViewCreated: session._onWebViewCreated,
        onLoadStart: (InAppWebViewController _, WebUri? url) {
          session._adblock?.onLoadStart(url);
          session._onLoading(true, url?.toString());
        },
        onPermissionRequest:
            (InAppWebViewController _, PermissionRequest request) =>
                session._onPermissionRequest(context, request),
        onLoadStop: (InAppWebViewController _, WebUri? url) {
          session._onLoading(false, url?.toString());
          unawaited(session._refreshHistory(url?.toString()));
          session._onLoadStop();
        },
        onUpdateVisitedHistory:
            (InAppWebViewController _, WebUri? url, bool? __) {
              session._adblock?.onUpdateVisitedHistory(url);
              unawaited(session._refreshHistory(url?.toString()));
            },
        onWebContentProcessDidTerminate: (InAppWebViewController _) =>
            unawaited(_deathGuard.handleWebContentTerminated()),
        onRenderProcessGone:
            (InAppWebViewController _, RenderProcessGoneDetail detail) =>
                unawaited(
                  _deathGuard.handleDeath(
                    didCrash: detail.didCrash,
                    rendererPriorityAtExit: detail.rendererPriorityAtExit,
                  ),
                ),
      ),
    );
  }
}

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

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
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

/// JS→Dart 单一 handler 名（glue 的 `HANDLER`），载荷按 `type` 分派。
const String kWebVideoJsHandler = 'fushiWebVideo';

/// WebView2 持焦时截获视频快捷键交回 Dart 的桥 handler 名。
const String kWebVideoKeyBridgeHandler = 'fushiWebVideoKeys';

/// 流媒体书断点写库的最小位置（与视频页远端分支 `_persistRemotePosition` 的 BUG-996 阈值
/// 同口径）：播放头不足 5 秒不算「看过」，不覆盖已有进度。
const int kWebVideoMinPersistPositionMs = 5000;

// ── WebView2 环境（单例，按宿主档分目录）──────────────────────────────────────

/// 可捕获 WebView2 环境单例：`--disable-direct-composition`。fork 的显示链路本身就是 WGC 捕获，
/// Chromium 把 DRM 视频放进 DComp overlay 时纹理里是黑的（真机：默认环境视频区纯黑、加该参数
/// 清晰可见）。environment 级参数不能运行期切换，且同 user data folder 的多个 env 参数必须逐字
/// 一致，故用独立目录（独立 cookie 罐：站点登录在网页播放器里做一次即可）。
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
/// 要走 DComp overlay），带 fork 的窗口宿主哨兵；浏览器参数与可捕获环境不同 → 必须独立 user
/// data folder（同目录的环境参数必须逐字一致）→ 独立 cookie 罐，登录态从内置档复制。
Future<WebViewEnvironment>? _windowedEnv;

String webVideoWindowedUserDataFolder() {
  // 硬件 PlayReady（MF CDM）要求 profile 住在 %LOCALAPPDATA% 下：真机实测 profile 放在仓库目录
  // （itest 隔离根）时 Netflix 报 D7702-1003，同一份代码 profile 挪到 LOCALAPPDATA 即起播；
  // 生产默认路径本来就在 LOCALAPPDATA（[webVideoCapturableUserDataFolder]），itest 用此覆盖指到
  // LOCALAPPDATA 下的独立测试目录（不碰用户真实 profile）。
  final String? override =
      Platform.environment['FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER'];
  if (override != null && override.isNotEmpty) return override;
  return '${webVideoCapturableUserDataFolder()}-4k';
}

Future<WebViewEnvironment> webVideoWindowedEnvironment() {
  return _windowedEnv ??= WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(
      userDataFolder: webVideoWindowedUserDataFolder(),
      additionalBrowserArguments:
          '--autoplay-policy=no-user-gesture-required '
          '$kWebVideoWindowedHostingSentinel',
    ),
  );
}

/// 窗口宿主档环境的浏览器进程没了（WebView2 ProcessFailed，fork 转成 onRenderProcessGone）：
/// 丢掉单例，下次 [webVideoWindowedEnvironment] 重建。同目录同参数的新环境在旧浏览器进程还活着
/// 时会直接接到它上面（WebView2 的环境共享规则），所以只是渲染进程死了也照样可用。返回被换下
/// 的旧环境（调用方负责释放）。
Future<WebViewEnvironment>? discardWebVideoWindowedEnvironment() {
  final Future<WebViewEnvironment>? old = _windowedEnv;
  _windowedEnv = null;
  return old;
}

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

/// 登录 cookie 的来源环境，按顺序抄（后抄的同名 cookie 盖掉先抄的）：先内置档，再 app 内
/// 浏览器（[MangaWebViewEnvironment]，「浏览」里的标签页都在它里面）。浏览器排后面：站点并进
/// 浏览器之后（2026-10-26）用户是在浏览器里登录、再点「用 Fushi 播放」进播放页的，只抄内置档
/// 的话播放页拿不到浏览器里的登录态，要求重新登录（2026-10-27 用户报 Netflix）。
const List<Future<WebViewEnvironment?> Function()> kWebVideoLoginCookieSources =
    <Future<WebViewEnvironment?> Function()>[
      webVideoCapturableEnvironment,
      MangaWebViewEnvironment.obtain,
    ];

/// 窗口宿主档用独立环境（浏览器参数不同 → 独立 cookie 罐）：把内置档与 app 内浏览器已登录
/// 的站点 cookie 复制过来（[kWebVideoLoginCookieSources]），用户不用登录两次。尽力而为：
/// 单个来源失败只记日志、不挡其它来源（最坏是站点要求登录）。
Future<void> copyWebVideoLoginCookies({
  required Uri uri,
  required WebViewEnvironment to,
  List<Future<WebViewEnvironment?> Function()> sources =
      kWebVideoLoginCookieSources,
}) async {
  final WebUri url = WebUri('${uri.scheme}://${uri.host}/');
  final CookieManager dst = CookieManager.instance(webViewEnvironment: to);
  for (final Future<WebViewEnvironment?> Function() source in sources) {
    try {
      final WebViewEnvironment? from = await source();
      // 没有显式环境（非 Windows / 建不出来）或就是目标自己：没东西可抄。
      if (from == null || identical(from, to)) continue;
      final List<Cookie> cookies = await CookieManager.instance(
        webViewEnvironment: from,
      ).getCookies(url: url);
      for (final Cookie c in cookies) {
        await dst.setCookie(
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
      }
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'cookie copy: $e');
    }
  }
}

/// 浏览器扩展送来的站点会话（[BrowserCookieImportGate]，与漫画源登录同一条通道）写进视频
/// 的两个 WebView2 环境：窗口宿主档是站点页面真正用的那份；内置档也写，因为每次开页
/// [copyWebVideoLoginCookies] 会把内置档的同名 cookie 抄过去，只写一边会被旧值盖回。
/// 逐条写、单条失败不中断（WebView2 会拒个别属性组合）；返回写进窗口宿主档的条数。
Future<int> importWebVideoBrowserCookies(
  List<BrowserSiteCookie> cookies,
) async {
  int written = 0;
  for (final Future<WebViewEnvironment> Function() env
      in <Future<WebViewEnvironment> Function()>[
        webVideoCapturableEnvironment,
        webVideoWindowedEnvironment,
      ]) {
    final bool primary = env == webVideoWindowedEnvironment;
    final CookieManager manager;
    try {
      manager = CookieManager.instance(webViewEnvironment: await env());
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'browser cookie env: $e');
      continue;
    }
    final int count = await writeBrowserSiteCookies(manager, cookies);
    if (primary) written = count;
  }
  return written;
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
  });

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
  /// 进程）、重新抄登录 cookie，并记下重建后要回到的地址。失败抛出由 death guard 记录——重建
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
    await copyWebVideoLoginCookies(uri: Uri.parse(surfaceUrl), to: env);
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

  /// 建 WebView 之前的异步准备：注入脚本、窗口宿主档环境、从内置档复制登录 cookie。
  /// 资产缺失 / WebView2 Runtime 缺失会抛（调用方落失败态，不吞）。
  Future<void> prepare({required FushiShortcutRegistry shortcuts}) async {
    final Uri uri = Uri.parse(pageUrl);
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
    await copyWebVideoLoginCookies(uri: uri, to: env);
    _userScripts = scripts;
    _environment = env;
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
    _disposed = true;
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
        initialUserScripts: session._userScripts,
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          sharedCookiesEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          disableContextMenu: true,
          supportZoom: false,
        ),
        onWebViewCreated: session._onWebViewCreated,
        onLoadStart: (InAppWebViewController _, WebUri? url) =>
            session._onLoading(true, url?.toString()),
        onLoadStop: (InAppWebViewController _, WebUri? url) {
          session._onLoading(false, url?.toString());
          unawaited(session._refreshHistory(url?.toString()));
          session._onLoadStop();
        },
        onUpdateVisitedHistory:
            (InAppWebViewController _, WebUri? url, bool? __) =>
                unawaited(session._refreshHistory(url?.toString())),
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

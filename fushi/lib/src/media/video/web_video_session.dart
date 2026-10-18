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

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

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

/// document-start 注入脚本（按导航 host 选 bridge）：垫片（可选）→ 站点 bridge → adapters →
/// providers → glue →（可选）DOM 字幕层 → 键盘桥。资产读取失败直接抛（调用方落失败态）。
Future<UnmodifiableListView<UserScript>> loadWebVideoUserScripts({
  required String host,
  required bool softwareDrm,
  required bool domOverlay,
  required String keyBridgeScript,
}) async {
  final List<String> assets = <String>[
    // 垫片必须排第一：站点脚本一跑就会抓走原始 EME 函数引用。
    if (softwareDrm) kWebVideoEmeShimAsset,
    ...webVideoBridgeAssetsForHost(host),
    kWebVideoAdaptersAsset,
    kWebVideoProvidersAsset,
    kWebVideoGlueAsset,
    if (domOverlay) kWebVideoDomSubtitlesAsset,
  ];
  final List<String> sources = <String>[];
  for (final String asset in assets) {
    sources.add(await rootBundle.loadString(asset));
  }
  sources.add(keyBridgeScript);
  return UnmodifiableListView<UserScript>(<UserScript>[
    for (final String src in sources)
      UserScript(
        source: src,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
  ]);
}

/// 窗口宿主档用独立环境（浏览器参数不同 → 独立 cookie 罐）：把内置档已登录的站点 cookie
/// 复制过来，用户不用登录两次。尽力而为，失败只记日志（站点会要求登录）。
Future<void> copyWebVideoLoginCookies({
  required Uri uri,
  required WebViewEnvironment to,
}) async {
  try {
    final WebViewEnvironment from = await webVideoCapturableEnvironment();
    final WebUri url = WebUri('${uri.scheme}://${uri.host}/');
    final List<Cookie> cookies = await CookieManager.instance(
      webViewEnvironment: from,
    ).getCookies(url: url);
    final CookieManager dst = CookieManager.instance(webViewEnvironment: to);
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
  });

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

  bool get isReady => _environment != null && _userScripts != null;

  /// 建 WebView 之前的异步准备：注入脚本、窗口宿主档环境、从内置档复制登录 cookie。
  /// 资产缺失 / WebView2 Runtime 缺失会抛（调用方落失败态，不吞）。
  Future<void> prepare({required FushiShortcutRegistry shortcuts}) async {
    final Uri uri = Uri.parse(pageUrl);
    final UnmodifiableListView<UserScript> scripts =
        await loadWebVideoUserScripts(
          host: uri.host,
          // 窗口宿主档就是为硬件 DRM 开的，不装软件 DRM 垫片。
          softwareDrm: false,
          // 字幕归 Flutter 叠层（底层合成下 Flutter 画在 WebView 上面）。
          domOverlay: false,
          keyBridgeScript: webVideoKeyBridgeScript(shortcuts),
        );
    final WebViewEnvironment env = await webVideoWindowedEnvironment();
    await copyWebVideoLoginCookies(uri: uri, to: env);
    _userScripts = scripts;
    _environment = env;
  }

  /// 在站点页面里执行一条 `window.__fushiWebVideo.*` 表达式（[WebVideoPlatformPlayer.evaluate]
  /// 的实现）。glue 没装上 / WebView 还没建时什么也不做；失败只记日志。
  Future<void> evaluate(String expression) async {
    final InAppWebViewController? web = _web;
    if (web == null || _disposed) return;
    try {
      await web.evaluateJavascript(
        source:
            '(function(){try{return window.__fushiWebVideo&&'
            '($expression);}catch(e){return String(e);}})()',
      );
    } catch (e) {
      ErrorLogService.instance.log(
        'web_video',
        'evaluateJavascript failed: $e',
      );
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

  Future<void> setVideoOnly(bool on) =>
      evaluate('window.__fushiWebVideo.setVideoOnly($on)');

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

  void _applyInputEnabled() {
    final Object? viewId = _viewId;
    if (viewId == null || _disposed) return;
    final bool enabled = !_playerMode;
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
    controller.addJavaScriptHandler(
      handlerName: kWebVideoJsHandler,
      callback: _onJsMessage,
    );
    controller.addJavaScriptHandler(
      handlerName: kWebVideoKeyBridgeHandler,
      callback: (List<dynamic> args) {
        if (args.isNotEmpty) onKeyToken?.call(args.first.toString());
        return null;
      },
    );
  }

  void _onLoadStop() {
    // 字幕由 Fushi 叠层画，站点自己的字幕藏起来（visibility，DOM 采样 live 轨照读）。
    unawaited(setNativeSubtitlesHidden(true));
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
      case 'state':
        final WebVideoPlaybackState? state = parseWebVideoStatePayload(msg);
        if (state != null) {
          _lastState = state;
          onState?.call(state);
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
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'web_video_underlay',
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    final WebVideoSession session = widget.session;
    if (!session.isReady) return const SizedBox.shrink();
    return KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        webViewEnvironment: session._environment,
        initialUrlRequest: URLRequest(url: WebUri(session.pageUrl)),
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

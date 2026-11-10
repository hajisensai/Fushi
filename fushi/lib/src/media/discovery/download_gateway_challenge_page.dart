/// 下载网关人机验证（BUG-4323）：在 WebView 里让站点自己的 JS 解题，截下它
/// 「解完 → 回跳原资源 URL」那一跳，把那一刻的 URL 与 cookie 交回下载队列。
///
/// 实测协议（frontgate 网关，`snippet-pow-equihash` 脚本）：浏览器请求网关 URL
/// 得到一页解题脚本（Equihash n=144 k=7，题目绑出口 IP 与资源路径，10 分钟有效）；
/// 解完 POST `/__pow/verify` 换一次性 `consume` 凭据，写入 `Path=<资源路径>`、
/// `Max-Age=5` 的 cookie（写不进时改拼 `__ct` 查询参数），然后
/// `location.replace(<原资源 URL>)`。凭据**一次性**：要是放 WebView 真去请求那一跳，
/// 凭据就被 WebView 自己用掉、下载器拿到的只是废票。所以这里拦下那次导航（取消），
/// 把 URL + cookie 交给下载器，由它发出唯一一次带凭据的请求。
///
/// 「解完」的判据与站点无关：页面加载完成之后，主框架导航回**同一资源**
/// （scheme/host/port/path 相同），并且相对开页时**多了 cookie 或多了查询参数**——
/// 两样都没多出来的回跳是解题脚本自己的「题目过期，重载重来」，放行。
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_engine/media/discovery/download_gateway_challenge.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/download_gateway_challenge_gate.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 判定一次主框架导航是不是「解完题、带着放行凭据回跳原资源」。
///
/// 是 → 返回下载器应发出的请求（导航 URL + 该 URL 下的全部 cookie + 解题 UA）；
/// 不是 → null（放行这次导航）。纯函数，单测直接喂 cookie 快照。
DownloadGatewayClearance? downloadGatewayClearanceForNavigation({
  required Uri challengeUrl,
  required Uri navigation,
  required Map<String, String> baselineCookies,
  required Map<String, String> currentCookies,
  String? userAgent,
}) {
  if (!_sameResource(challengeUrl, navigation)) return null;
  final bool gainedCookie = currentCookies.entries.any(
    (MapEntry<String, String> cookie) =>
        cookie.value.isNotEmpty && baselineCookies[cookie.key] != cookie.value,
  );
  final Map<String, List<String>> before = challengeUrl.queryParametersAll;
  final bool gainedQuery = navigation.queryParametersAll.entries.any(
    (MapEntry<String, List<String>> param) =>
        !_sameValues(before[param.key], param.value),
  );
  if (!gainedCookie && !gainedQuery) return null;
  final String cookieHeader = <String>[
    for (final MapEntry<String, String> cookie in currentCookies.entries)
      if (cookie.value.isNotEmpty) '${cookie.key}=${cookie.value}',
  ].join('; ');
  final String ua = userAgent?.trim() ?? '';
  return DownloadGatewayClearance(
    url: navigation,
    headers: <String, String>{
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      if (ua.isNotEmpty) 'User-Agent': ua,
    },
  );
}

bool _sameResource(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port &&
    a.path == b.path;

bool _sameValues(List<String>? a, List<String> b) {
  if (a == null || a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 在系统浏览器里打开挑战 URL（解题页之外的退路：浏览器自己解题并直接下载）。
/// 打不开返回 false，不抛（`launchUrl` 在没有 handler 的环境会 throw）。
Future<bool> openDownloadGatewayChallengeInBrowser(Uri challengeUrl) async {
  try {
    return await launchUrl(challengeUrl, mode: LaunchMode.externalApplication);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log(
      'openDownloadGatewayChallengeInBrowser',
      error,
      stack,
    );
    return false;
  }
}

/// 下载网关验证页：解完自动关闭并返回 [DownloadGatewayClearance]；用户关闭 → null。
class DownloadGatewayChallengePage extends StatefulWidget {
  const DownloadGatewayChallengePage({
    super.key,
    required this.challengeUrl,
    this.cookieReader,
    this.webViewBuilder,
    this.environmentFactory,
    this.browserOpener,
  });

  final Uri challengeUrl;

  /// 测试注入：默认读 [CookieManager]（与 WebView 绑同一个环境）。
  final Future<List<Cookie>> Function(WebUri url)? cookieReader;

  /// 测试注入：替掉真 [InAppWebView]（widget 测试环境没有平台视图）。
  final Widget Function(BuildContext context)? webViewBuilder;

  /// 测试注入：默认 [MangaWebViewEnvironment.obtain]。WebView 与 [CookieManager]
  /// 必须绑同一个环境（BUG-2477）；该环境也带着 app 代理参数——题目绑出口 IP，
  /// 解题与下载必须走同一出口。
  final Future<WebViewEnvironment?> Function()? environmentFactory;

  /// 测试注入：默认 [openDownloadGatewayChallengeInBrowser]。
  final Future<bool> Function(Uri url)? browserOpener;

  @override
  State<DownloadGatewayChallengePage> createState() =>
      _DownloadGatewayChallengePageState();
}

class _DownloadGatewayChallengePageState
    extends State<DownloadGatewayChallengePage> {
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'download_gateway_challenge',
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  bool _environmentReady = false;
  WebViewEnvironment? _environment;

  /// 解题页首次加载完成时的 cookie 快照；null = 页面还没加载完，所有导航放行。
  Map<String, String>? _baselineCookies;
  String? _userAgent;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareEnvironment());
  }

  Future<void> _prepareEnvironment() async {
    WebViewEnvironment? environment;
    try {
      environment =
          await (widget.environmentFactory ?? MangaWebViewEnvironment.obtain)();
    } on Object {
      environment = null;
    }
    if (!mounted) return;
    setState(() {
      _environment = environment;
      _environmentReady = true;
    });
  }

  Future<Map<String, String>> _cookiesFor(Uri url) async {
    final WebUri target = WebUri.uri(url);
    final List<Cookie> cookies =
        await (widget.cookieReader?.call(target) ??
            CookieManager.instance(
              webViewEnvironment: _environment,
            ).getCookies(url: target));
    return <String, String>{
      for (final Cookie cookie in cookies)
        cookie.name: cookie.value?.toString() ?? '',
    };
  }

  Future<void> _onLoadStop(InAppWebViewController controller) async {
    if (_baselineCookies != null) return;
    try {
      final Object? ua = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      if (ua is String) _userAgent = ua;
    } on Object {
      // 拿不到 UA 就不带：凭据未必绑 UA，下载器用默认 UA 照常请求。
    }
    try {
      _baselineCookies = await _cookiesFor(widget.challengeUrl);
    } on Object {
      _baselineCookies = const <String, String>{};
    }
  }

  Future<NavigationActionPolicy> _onNavigation(NavigationAction action) async {
    final Map<String, String>? baseline = _baselineCookies;
    final WebUri? url = action.request.url;
    if (_done || baseline == null || url == null || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    final Map<String, String> current;
    try {
      current = await _cookiesFor(url);
    } on Object {
      return NavigationActionPolicy.ALLOW;
    }
    final DownloadGatewayClearance? clearance =
        downloadGatewayClearanceForNavigation(
          challengeUrl: widget.challengeUrl,
          navigation: url,
          baselineCookies: baseline,
          currentCookies: current,
          userAgent: _userAgent,
        );
    if (clearance == null) return NavigationActionPolicy.ALLOW;
    _complete(clearance);
    // 取消：一次性凭据留给下载器那唯一一次请求。
    return NavigationActionPolicy.CANCEL;
  }

  void _complete(DownloadGatewayClearance clearance) {
    if (_done || !mounted) return;
    _done = true;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).pop(clearance);
  }

  Future<void> _openInBrowser() async {
    final bool opened =
        await (widget.browserOpener ?? openDownloadGatewayChallengeInBrowser)(
          widget.challengeUrl,
        );
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        FushiSnackBar(content: Text(t.collection_web_page_open_failed)),
      );
      return;
    }
    // 交给浏览器下载了：本页不再等，任务按「需要人机验证」收尾。
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: FushiAppBar(
        title: Text(t.discovery_download_challenge_required),
        leading: FushiIconButtonControl(
          icon: const FushiIcon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          FushiIconButtonControl(
            key: const ValueKey<String>('download-gateway-challenge-browser'),
            icon: const FushiIcon(Icons.open_in_browser),
            tooltip: t.discovery_download_challenge_open_browser,
            onPressed: () => unawaited(_openInBrowser()),
          ),
        ],
      ),
      body: FushiEntranceScope(
        child: Column(
          children: <Widget>[
            FushiStaggeredEntrance(
              index: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(
                  '${widget.challengeUrl.host} · '
                  '${t.discovery_download_challenge_hint}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            Expanded(
              child:
                  widget.webViewBuilder?.call(context) ??
                  (!_environmentReady
                      ? const FushiLoadingView()
                      : KeyedSubtree(
                          key: _deathGuard.rebuildKey,
                          child: InAppWebView(
                            webViewEnvironment: _environment,
                            initialUrlRequest: URLRequest(
                              url: WebUri.uri(widget.challengeUrl),
                            ),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              sharedCookiesEnabled: true,
                              useShouldOverrideUrlLoading: true,
                            ),
                            onLoadStop: (InAppWebViewController c, _) =>
                                unawaited(_onLoadStop(c)),
                            shouldOverrideUrlLoading:
                                (
                                  InAppWebViewController _,
                                  NavigationAction action,
                                ) => _onNavigation(action),
                            onWebContentProcessDidTerminate:
                                (InAppWebViewController _) => unawaited(
                                  _deathGuard.handleWebContentTerminated(),
                                ),
                            onRenderProcessGone:
                                (
                                  InAppWebViewController _,
                                  RenderProcessGoneDetail detail,
                                ) => unawaited(
                                  _deathGuard.handleDeath(
                                    didCrash: detail.didCrash,
                                    rendererPriorityAtExit:
                                        detail.rendererPriorityAtExit,
                                  ),
                                ),
                          ),
                        )),
            ),
          ],
        ),
      ),
    );
  }
}

/// 装上「推一页 [DownloadGatewayChallengePage] 解题」的解题器。
///
/// 按挑战 URL 单飞：同一资源的并发请求共享一次解题。不按 host 合并——题目
/// 绑资源路径（`pathHash`），一次放行只对那一个文件有效。
/// 顺序是硬要求：先建 future → 再写 map → 最后挂清理（同
/// `installMihonCloudflareResolver`）。
void installDownloadGatewayChallengeSolver(
  GlobalKey<NavigatorState> navigatorKey, {
  @visibleForTesting Widget Function(Uri challengeUrl)? pageBuilder,
}) {
  final Map<String, Future<DownloadGatewayClearance?>> inflight =
      <String, Future<DownloadGatewayClearance?>>{};
  DownloadGatewayChallengeGate.solver = (Uri challengeUrl) {
    final String key = challengeUrl.toString();
    final Future<DownloadGatewayClearance?>? pending = inflight[key];
    if (pending != null) return pending;
    final Future<DownloadGatewayClearance?> solving = _pushChallengePage(
      navigatorKey,
      challengeUrl,
      pageBuilder,
    );
    inflight[key] = solving;
    return solving.whenComplete(() => inflight.remove(key));
  };
}

Future<DownloadGatewayClearance?> _pushChallengePage(
  GlobalKey<NavigatorState> navigatorKey,
  Uri challengeUrl,
  Widget Function(Uri challengeUrl)? pageBuilder,
) async {
  final NavigatorState? navigator = navigatorKey.currentState;
  if (navigator == null) return null;
  return navigator.push<DownloadGatewayClearance>(
    MaterialPageRoute<DownloadGatewayClearance>(
      // 路由层中和界面整体缩放，WebView 才按真实视口栅格化（BUG-2522）。
      builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
        child:
            pageBuilder?.call(challengeUrl) ??
            DownloadGatewayChallengePage(challengeUrl: challengeUrl),
      ),
      fullscreenDialog: true,
    ),
  );
}

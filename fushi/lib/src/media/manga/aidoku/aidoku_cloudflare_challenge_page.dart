import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

/// 把「在 WebView 里解 Cloudflare 挑战」装成 [AidokuCloudflareGate.resolver]。
/// 在 app 根 navigator 就绪后调用一次；runtime 遇到 `CLOUDFLARE_CHALLENGE` 时
/// 会推一页 [AidokuCloudflareChallengePage]，拿到 `cf_clearance` 后自动关闭。
///
/// 按 host 单飞：并发调用（全局搜索扇出 / 源匹配）同站的挑战共享同一次解题，
/// 不会叠出多个全屏页——后到的调用等第一次的结果，成功后各自带新 cookie 重试。
void installAidokuCloudflareResolver(GlobalKey<NavigatorState> navigatorKey) {
  final Map<String, Future<bool>> inflight = <String, Future<bool>>{};
  AidokuCloudflareGate.resolver = (Uri challengeUrl, String userAgent) {
    return inflight[challengeUrl.host] ??= () async {
      try {
        final NavigatorState? navigator = navigatorKey.currentState;
        if (navigator == null) return false;
        final bool? solved = await navigator.push<bool>(
          MaterialPageRoute<bool>(
            builder: (BuildContext context) => AidokuCloudflareChallengePage(
              challengeUrl: challengeUrl,
              userAgent: userAgent,
              jar: AidokuCookieJar.shared,
            ),
            fullscreenDialog: true,
          ),
        );
        return solved ?? false;
      } finally {
        inflight.remove(challengeUrl.host);
      }
    }();
  };
}

/// 用**被拦请求同一 User-Agent** 加载被拦的页面，让用户/浏览器完成 Cloudflare
/// 验证；`cf_clearance` 一落到 WebView 的 cookie 存储就整站导出到 [jar] 并返回 true。
///
/// 只轮询 cookie、不解析页面：Cloudflare 的挑战页形态（managed / turnstile /
/// interactive）会变，cookie 是唯一稳定的完成信号。「解完」的判据是出现一个
/// **值不同于 jar 里现存条目**的 `cf_clearance`——WebView 的共享 cookie 存储里
/// 可能还留着上一轮的陈旧 cookie（正是它失效才走到这一页），只查存在会秒判
/// 成功、带着旧 cookie 重试然后再次被拦。
class AidokuCloudflareChallengePage extends StatefulWidget {
  const AidokuCloudflareChallengePage({
    super.key,
    required this.challengeUrl,
    required this.jar,
    this.userAgent = kAidokuUserAgent,
    this.pollInterval = const Duration(seconds: 1),
    this.cookieReader,
    this.webViewBuilder,
  });

  final Uri challengeUrl;
  final AidokuCookieJar jar;

  /// 被拦请求实际用的 UA；`cf_clearance` 绑定解题时的 UA，必须逐字节一致。
  final String userAgent;

  final Duration pollInterval;

  /// 测试注入：默认读 [CookieManager]（iOS 上即 WKHTTPCookieStore）。
  final Future<List<Cookie>> Function(WebUri url)? cookieReader;

  /// 测试注入：替掉真 [InAppWebView]（widget 测试环境没有平台视图）。
  final Widget Function(BuildContext context)? webViewBuilder;

  @override
  State<AidokuCloudflareChallengePage> createState() =>
      _AidokuCloudflareChallengePageState();
}

class _AidokuCloudflareChallengePageState
    extends State<AidokuCloudflareChallengePage> {
  Timer? _poll;
  bool _checking = false;
  bool _done = false;

  /// jar 里现存（= 已被判失效）的 `cf_clearance` 值；WebView 里出现同值只说明
  /// 共享 cookie 存储还留着旧账，不算解完。null = 基线未就绪，先不判。
  Set<String>? _staleClearance;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(widget.pollInterval, (_) => unawaited(_check()));
    unawaited(_initBaseline());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _initBaseline() async {
    final Set<String> stale = <String>{};
    try {
      await widget.jar.ensureLoaded();
      final String? current = widget.jar.clearanceValueFor(widget.challengeUrl);
      if (current != null) stale.add(current);
    } on Object {
      // jar 读不动就当没有旧值：最坏情况是把陈旧 cookie 误判为解完，
      // 重试失败后调用方按原错误上报，不会卡死。
    }
    _staleClearance = stale;
  }

  Future<List<Cookie>> _readCookies(WebUri url) =>
      widget.cookieReader?.call(url) ??
      CookieManager.instance().getCookies(url: url);

  /// 挑战页是在站点根域发 cookie 的，用 origin 查而不是带路径的原始 URL。
  WebUri get _origin => WebUri.uri(
    Uri(
      scheme: widget.challengeUrl.scheme,
      host: widget.challengeUrl.host,
      port: widget.challengeUrl.hasPort ? widget.challengeUrl.port : null,
      path: '/',
    ),
  );

  Future<void> _check() async {
    final Set<String>? staleClearance = _staleClearance;
    if (_checking || _done || !mounted || staleClearance == null) return;
    _checking = true;
    try {
      final List<Cookie> cookies = await _readCookies(_origin);
      final bool solved = cookies.any(
        (Cookie cookie) =>
            cookie.name == kCloudflareClearanceCookie &&
            (cookie.value?.toString().isNotEmpty ?? false) &&
            !staleClearance.contains(cookie.value?.toString()),
      );
      if (!solved || !mounted) return;
      try {
        await widget.jar.replaceForHost(
          widget.challengeUrl.host,
          cookies
              .map((Cookie cookie) => _toJarCookie(cookie))
              .toList(growable: false),
        );
      } on Object {
        // 持久化失败先不置 _done：cookie 还在 WebView 里，下一轮轮询重试；
        // 用户始终能用关闭按钮退出。
        return;
      }
      _done = true;
      _poll?.cancel();
      if (!mounted) return;
      // 关闭过渡期（用户刚点了关闭）route 已不在顶层，此时 pop 会弹掉底下的
      // 页面——只在自己仍是当前路由时收尾。
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) return;
      Navigator.of(context).pop(true);
    } finally {
      _checking = false;
    }
  }

  AidokuCookie _toJarCookie(Cookie cookie) => AidokuCookie(
    name: cookie.name,
    value: cookie.value?.toString() ?? '',
    domain: cookie.domain ?? widget.challengeUrl.host,
    path: cookie.path ?? '/',
    secure: cookie.isSecure ?? false,
    expiresAt: cookie.expiresDate,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.manga_source_cloudflare_verify_title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              '${widget.challengeUrl.host} · '
              '${t.manga_source_cloudflare_verify_hint}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child:
                widget.webViewBuilder?.call(context) ??
                InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri.uri(widget.challengeUrl),
                  ),
                  initialSettings: InAppWebViewSettings(
                    // 与被拦请求逐字节一致，见 [AidokuCloudflareResolver]。
                    userAgent: widget.userAgent,
                    javaScriptEnabled: true,
                    sharedCookiesEnabled: true,
                  ),
                  onLoadStop: (_, __) => unawaited(_check()),
                ),
          ),
        ],
      ),
    );
  }
}

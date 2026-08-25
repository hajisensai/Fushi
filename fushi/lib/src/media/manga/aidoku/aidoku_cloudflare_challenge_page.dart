import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

/// 把「在 WebView 里解 Cloudflare 挑战」装成 [AidokuCloudflareGate.resolver]。
/// 在 app 根 navigator 就绪后调用一次；runtime 遇到 `CLOUDFLARE_CHALLENGE` 时
/// 会推一页 [AidokuCloudflareChallengePage]，拿到 `cf_clearance` 后自动关闭。
void installAidokuCloudflareResolver(GlobalKey<NavigatorState> navigatorKey) {
  AidokuCloudflareGate.resolver = (Uri challengeUrl) async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return false;
    final bool? solved = await navigator.push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => AidokuCloudflareChallengePage(
          challengeUrl: challengeUrl,
          jar: AidokuCookieJar.shared,
        ),
        fullscreenDialog: true,
      ),
    );
    return solved ?? false;
  };
}

/// 用与 wasm host **同一 User-Agent** 加载被拦的页面，让用户/浏览器完成 Cloudflare
/// 验证；`cf_clearance` 一落到 WebView 的 cookie 存储就整站导出到 [jar] 并返回 true。
///
/// 只轮询 cookie、不解析页面：Cloudflare 的挑战页形态（managed / turnstile /
/// interactive）会变，cookie 是唯一稳定的完成信号。
class AidokuCloudflareChallengePage extends StatefulWidget {
  const AidokuCloudflareChallengePage({
    super.key,
    required this.challengeUrl,
    required this.jar,
    this.pollInterval = const Duration(seconds: 1),
    this.cookieReader,
  });

  final Uri challengeUrl;
  final AidokuCookieJar jar;
  final Duration pollInterval;

  /// 测试注入：默认读 [CookieManager]（iOS 上即 WKHTTPCookieStore）。
  final Future<List<Cookie>> Function(WebUri url)? cookieReader;

  @override
  State<AidokuCloudflareChallengePage> createState() =>
      _AidokuCloudflareChallengePageState();
}

class _AidokuCloudflareChallengePageState
    extends State<AidokuCloudflareChallengePage> {
  Timer? _poll;
  bool _checking = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(widget.pollInterval, (_) => unawaited(_check()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
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
    if (_checking || _done || !mounted) return;
    _checking = true;
    try {
      final List<Cookie> cookies = await _readCookies(_origin);
      final bool solved = cookies.any(
        (Cookie cookie) =>
            cookie.name == kCloudflareClearanceCookie &&
            (cookie.value?.toString().isNotEmpty ?? false),
      );
      if (!solved || !mounted) return;
      _done = true;
      _poll?.cancel();
      await widget.jar.replaceForHost(
        widget.challengeUrl.host,
        cookies
            .map((Cookie cookie) => _toJarCookie(cookie))
            .toList(growable: false),
      );
      if (mounted) Navigator.of(context).pop(true);
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
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri.uri(widget.challengeUrl),
              ),
              initialSettings: InAppWebViewSettings(
                // 与 kAidokuUserAgent 逐字节一致，见该常量注释。
                userAgent: kAidokuUserAgent,
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 该源能不能在 app 里登录，以及登录页要打开哪个地址；不能则返回 null。
///
/// 两个条件缺一不可：
/// 1. [runtime] 能消费浏览器里的登录态：要么宿主持有 cookie、登录完导出给它
///    （桌面 sidecar，[HostCookieMihonRuntime]），要么扩展直接读平台浏览器那份
///    （Android，[BrowserCookieMihonRuntime]，BUG-2479）。判据是**能力**，不是
///    `Platform.isXxx`。
/// 2. 该源报得出能解析出 host 的 [baseUrl]。有些源的 baseUrl 是空串或相对地址，
///    那样既开不了登录页，也无从决定 cookie 的域。
///
/// 抽成纯函数是为了能被直接断言：这种「决定入口显不显示」的判据一旦悄悄恒假，
/// 表现就是按钮从此不出现，而任何页面测试都不会因此变红。
Uri? mihonLoginTarget({required Object? runtime, required String baseUrl}) {
  if (runtime is! HostCookieMihonRuntime &&
      runtime is! BrowserCookieMihonRuntime) {
    return null;
  }
  final Uri? parsed = Uri.tryParse(baseUrl.trim());
  if (parsed == null || parsed.host.isEmpty) return null;
  return parsed;
}

/// 推一页 [MihonWebLoginPage] 并等用户登录完；返回 true = 登录态已交给运行时。
///
/// 作品页（锁定章节的引导）与源管理页共用这一个入口，两处对「哪种运行时怎么收尾」
/// 的答案必须一致。[runtime] 不满足 [mihonLoginTarget] 时直接返回 false。
Future<bool> openMihonWebLogin(
  BuildContext context, {
  required Object? runtime,
  required String sourceName,
  required String baseUrl,
}) async {
  final Uri? target = mihonLoginTarget(runtime: runtime, baseUrl: baseUrl);
  if (target == null) return false;
  MihonCookieJar? jar;
  if (runtime is HostCookieMihonRuntime) {
    final MangaCookieJar hostJar = runtime.cookieJar;
    if (hostJar is! MihonCookieJar) return false;
    jar = hostJar;
  }
  final bool? saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (BuildContext _) =>
          MihonWebLoginPage(sourceName: sourceName, baseUrl: target, jar: jar),
    ),
  );
  return saved ?? false;
}

/// 在真实浏览器里登录漫画源，然后把会话交给运行时（BUG-2425）。
///
/// ## 为什么是「用户点完成」而不是轮询判定
///
/// Cloudflare 解题有唯一确定的完成信号（出现新的 `cf_clearance`），所以那边可以
/// 轮询。**登录没有这种信号**：成功后落在哪个页面、set 了哪些 cookie，每个站点
/// 都不一样，日站还常有「登录 → 选择账号 → 回跳」的多步流程。拿「出现了某个
/// cookie」当完成判据只会在一部分站点上碰巧成立，在其余站点上过早导出半截会话，
/// 表现为「显示已登录但还是锁着」——比不判定更糟。
///
/// 所以这里不猜：用户自己确认登录完成，点「完成」时导出当前整站 cookie。
///
/// ## 两种收尾
///
/// [jar] 非空（桌面 sidecar）：导出浏览器 cookie 到 jar，一条都没有就不关页。
/// [jar] 为空（Android）：扩展读的就是这张 WebView 写的系统 `CookieManager`，
/// 没有东西要导出，点「完成」直接关页。
///
/// ## 域原样保留
///
/// 导出的条目**保留浏览器给的真实域**（`member.bookwalker.jp` 就存成它自己），
/// 不重标到源站 host。线格式是结构化的，域/path/secure/hostOnly/过期全程无损，
/// 由 sidecar 那边的 okhttp jar 按每个实际请求 URL 做匹配——这既比重标准确，也
/// 不会把作用域平白放宽到源站父域及其全部子域。
///
/// ## WebView 与 CookieManager 必须绑同一个环境
///
/// Windows 上 cookie 归 WebView2 环境所有；WebView 与 CookieManager 各走各的
/// 默认环境时读不到对方的 cookie（BUG-2477）。环境由 [MangaWebViewEnvironment]
/// 统一提供，拿到之前不建 WebView。
class MihonWebLoginPage extends StatefulWidget {
  const MihonWebLoginPage({
    required this.sourceName,
    required this.baseUrl,
    required this.jar,
    this.cookieReader,
    this.webViewBuilder,
    this.environmentFactory,
    super.key,
  });

  final String sourceName;

  /// 源站 baseUrl；登录页从它打开，导出时也以它的 host 判「同一站点」。
  final Uri baseUrl;

  /// 宿主的 cookie jar；null = 运行时直接读浏览器那份，不导出。
  final MihonCookieJar? jar;

  /// 测试注入：默认读绑定环境的 [CookieManager]。
  final Future<List<Cookie>> Function(WebUri url)? cookieReader;

  /// 测试注入：widget 测试里没有平台视图。
  final Widget Function(BuildContext context)? webViewBuilder;

  /// 测试注入：默认 [MangaWebViewEnvironment.obtain]。
  final Future<WebViewEnvironment?> Function()? environmentFactory;

  @override
  State<MihonWebLoginPage> createState() => _MihonWebLoginPageState();
}

class _MihonWebLoginPageState extends State<MihonWebLoginPage> {
  // 只救命、不重建：登录页没有「当前进度」可恢复，renderer 死后让用户自己重开
  // 比自动重建更清楚（重建会把已填一半的登录表单悄悄清空）。
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'mihon-web-login',
  );

  /// 登录途中真正访问过的 origin。
  ///
  /// 只查 baseUrl 一个 origin 是不够的：日站的登录域常常和内容域不同
  /// （`member.bookwalker.jp` vs `bookwalker.jp`），而 `getCookies(url:)` 只返回
  /// 对该 URL 生效的条目。把走过的 origin 都查一遍，才不会漏掉真正的会话 cookie。
  final Set<Uri> _visited = <Uri>{};

  bool _saving = false;

  /// 环境就绪前不建 WebView（见类文档）。
  bool _environmentReady = false;
  WebViewEnvironment? _environment;

  InAppWebViewController? _controller;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _visited.add(_originOf(widget.baseUrl));
    _currentUrl = widget.baseUrl.toString();
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

  static Uri _originOf(Uri url) => Uri(
    scheme: url.scheme,
    host: url.host,
    port: url.hasPort ? url.port : null,
    path: '/',
  );

  Future<List<Cookie>> _readCookies(WebUri url) =>
      widget.cookieReader?.call(url) ??
      CookieManager.instance(
        webViewEnvironment: _environment,
      ).getCookies(url: url);

  void _noteVisited(WebUri? url) {
    final Uri? parsed = url;
    if (parsed == null || parsed.host.isEmpty) return;
    if (!mounted) return;
    _visited.add(_originOf(parsed));
  }

  /// 每次导航后同步地址栏与前进/后退可用态。
  Future<void> _syncNavigation(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    _noteVisited(url);
    bool back = false;
    bool forward = false;
    try {
      back = await controller.canGoBack();
      forward = await controller.canGoForward();
    } on Object {
      // 平台实现没给（或 WebView 已销毁）：按钮保持禁用即可。
    }
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
      if (url != null) _currentUrl = url.toString();
    });
  }

  /// 把浏览器里的整站 cookie 导出到 jar；返回导出条数。
  Future<int> _export(MihonCookieJar jar) async {
    final String host = widget.baseUrl.host;
    final Map<String, MangaCookie> deduped = <String, MangaCookie>{};
    for (final Uri origin in _visited) {
      final List<Cookie> cookies = await _readCookies(WebUri.uri(origin));
      for (final Cookie cookie in cookies) {
        final MangaCookie? mapped = _toJarCookie(cookie, origin.host, host);
        if (mapped == null) continue;
        // 按 (name, domain) 去重，**不是**只按 name：同名 cookie 在登录子域与
        // 内容域上取值不同是常态，只按 name 去重会让其中一份把另一份挤掉，而
        // 挤掉哪一份取决于 origin 的遍历顺序——那顺序又不是「访问先后」
        // （`Set.add` 命中已有元素不会把它挪到末尾），等于随机挑一个。
        deduped['${mapped.name}${mapped.canonicalDomain}'] = mapped;
      }
    }
    final List<MangaCookie> fresh = deduped.values.toList(growable: false);
    if (fresh.isEmpty) return 0;
    await jar.replaceForSite(host, fresh);
    return fresh.length;
  }

  /// 浏览器 cookie → jar cookie。
  ///
  /// 只收与源站**同一站点**的条目：cookie 的域覆盖 [siteHost]（父域），或反过来
  /// 是它的子域。第三方域（统计、广告、SSO 供应商）一概不进 jar——它们对源站请求
  /// 没有用，进来只会被原样交给扩展，白白扩大外泄面。
  ///
  /// [originHost] 是读到这条 cookie 的那个 origin：浏览器对 host-only cookie
  /// （`Set-Cookie` 未写 `Domain=`）不报 domain，此时它的域就是该 origin 的 host，
  /// 且**只对这一个 host 生效**。
  static MangaCookie? _toJarCookie(
    Cookie cookie,
    String originHost,
    String siteHost,
  ) {
    final String name = cookie.name.trim();
    if (name.isEmpty) return null;
    final String? reported = cookie.domain?.toString().trim();
    final bool hostOnly = reported == null || reported.isEmpty;
    final String domain = MangaCookie.canonicalizeDomain(
      hostOnly ? originHost : reported,
    );
    if (domain.isEmpty) return null;
    final bool sameSite =
        MangaCookie.hostMatchesDomain(siteHost, domain) ||
        MangaCookie.hostMatchesDomain(domain, siteHost);
    if (!sameSite) return null;
    final num? expires = cookie.expiresDate as num?;
    return MangaCookie(
      name: name,
      value: cookie.value?.toString() ?? '',
      domain: domain,
      path: cookie.path?.toString().trim().isNotEmpty == true
          ? cookie.path!.toString()
          : '/',
      secure: cookie.isSecure ?? false,
      hostOnly: hostOnly,
      // 会话 cookie（无 expires）落 null：jar 会一直留着它，直到下次登录整站替换。
      expiresAt: expires == null || expires <= 0 ? null : expires.toInt(),
    );
  }

  Future<void> _finish() async {
    if (_saving) return;
    final MihonCookieJar? jar = widget.jar;
    if (jar == null) {
      // 浏览器持有 cookie 的运行时：没有东西要导出，关页即生效。
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        Navigator.of(context).pop(true);
      }
      return;
    }
    setState(() => _saving = true);
    int saved = 0;
    Object? failure;
    try {
      saved = await _export(jar);
    } on Object catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    // 导出失败或一条都没拿到时**不关页**：直接 pop 会让用户以为登录成功了。
    if (failure != null || saved == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.mihon_source_login_empty)));
      return;
    }
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(true);
    }
  }

  /// Android 返回键：网页能后退就先后退，退无可退才关页。
  Future<void> _onBackInvoked() async {
    final InAppWebViewController? controller = _controller;
    if (controller != null && _canGoBack) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_onBackInvoked());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.sourceName),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('mihon_login_done'),
              onPressed: _saving ? null : () => unawaited(_finish()),
              child: Text(t.mihon_source_login_done),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '${widget.baseUrl.host} · ${t.mihon_source_login_hint}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            _buildNavigationBar(context),
            Expanded(child: _buildWebView(context)),
          ],
        ),
      ),
    );
  }

  /// 后退 / 前进 / 刷新 + 当前地址。登录流程常常跨好几页（登录 → 选账号 →
  /// 回跳），没有这些就只能关页重来。
  Widget _buildNavigationBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final InAppWebViewController? controller = _controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('mihon_login_back'),
            tooltip: t.back,
            onPressed: controller != null && _canGoBack
                ? () => unawaited(controller.goBack())
                : null,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            key: const ValueKey<String>('mihon_login_forward'),
            tooltip: t.mihon_source_login_forward,
            onPressed: controller != null && _canGoForward
                ? () => unawaited(controller.goForward())
                : null,
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            key: const ValueKey<String>('mihon_login_reload'),
            tooltip: t.refresh,
            onPressed: controller != null
                ? () => unawaited(controller.reload())
                : null,
            icon: const Icon(Icons.refresh),
          ),
          Expanded(
            child: Text(
              _currentUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView(BuildContext context) {
    final Widget Function(BuildContext context)? stub = widget.webViewBuilder;
    if (stub != null) return stub(context);
    if (!_environmentReady) {
      return const Center(child: CircularProgressIndicator());
    }
    return KeyedSubtree(
      // 重建 key 挂在 WebView **之上**：renderer 死后换 key 才能真正
      // 重建出新的 platform view，而不动 WebView 自己的锚点。
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        key: const ValueKey<String>('mihon_login_webview'),
        webViewEnvironment: _environment,
        initialUrlRequest: URLRequest(url: WebUri.uri(widget.baseUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          sharedCookiesEnabled: true,
        ),
        onWebViewCreated: (InAppWebViewController controller) {
          if (mounted) setState(() => _controller = controller);
        },
        onLoadStop: (InAppWebViewController controller, WebUri? url) =>
            unawaited(_syncNavigation(controller, url)),
        onUpdateVisitedHistory:
            (InAppWebViewController controller, WebUri? url, bool? _) =>
                unawaited(_syncNavigation(controller, url)),
        // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
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

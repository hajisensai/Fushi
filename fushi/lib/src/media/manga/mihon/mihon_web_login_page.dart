import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 在真实浏览器里登录漫画源，然后把会话交给宿主的 cookie jar（BUG-2425）。
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
/// ## 域的重定标（必须与 sidecar 对齐）
///
/// 导出时会把子域 cookie（如 `member.bookwalker.jp`）**重标到源站 baseUrl 的
/// host**（`bookwalker.jp`）。这不是图省事：sidecar 的 `DalvikHandler` 收到
/// `Cookie:` 头后，本来就会用 `source.getBaseUrl()` 的 host 重建每一条
/// cookie 的域。宿主若原样保留子域，`cookieHeaderFor(baseUrl)` 就匹配不到它们、
/// 根本不会发出去——登录会静默失败。两边看同一个域，是这条链路能通的前提。
///
/// 代价是 cookie 作用域被放宽到源站的父域及其全部子域。范围仅限该源站点、且与
/// sidecar 既有行为一致；要收窄必须两侧一起改。
class MihonWebLoginPage extends StatefulWidget {
  const MihonWebLoginPage({
    required this.sourceName,
    required this.baseUrl,
    required this.jar,
    this.cookieReader,
    this.webViewBuilder,
    super.key,
  });

  final String sourceName;

  /// 源站 baseUrl；导出的 cookie 全部重标到它的 host。
  final Uri baseUrl;

  final MihonCookieJar jar;

  /// 测试注入：默认读 [CookieManager]。
  final Future<List<Cookie>> Function(WebUri url)? cookieReader;

  /// 测试注入：widget 测试里没有平台视图。
  final Widget Function(BuildContext context)? webViewBuilder;

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

  @override
  void initState() {
    super.initState();
    _visited.add(_originOf(widget.baseUrl));
  }

  static Uri _originOf(Uri url) =>
      Uri(scheme: url.scheme, host: url.host, port: url.hasPort ? url.port : null, path: '/');

  Future<List<Cookie>> _readCookies(WebUri url) =>
      widget.cookieReader?.call(url) ??
      CookieManager.instance().getCookies(url: url);

  void _noteVisited(WebUri? url) {
    final Uri? parsed = url;
    if (parsed == null || parsed.host.isEmpty) return;
    if (!mounted) return;
    _visited.add(_originOf(parsed));
  }

  /// 把浏览器里的整站 cookie 导出到 jar；返回导出条数。
  Future<int> _export() async {
    final String host = widget.baseUrl.host;
    // 后访问到的 origin 排在后面：同名 cookie 以最近一次登录流程写的为准，
    // 与 sidecar 收头时 `distinctBy { it.name }` 的取值方向保持一致。
    final List<MangaCookie> collected = <MangaCookie>[];
    for (final Uri origin in _visited) {
      final List<Cookie> cookies = await _readCookies(WebUri.uri(origin));
      for (final Cookie cookie in cookies) {
        final MangaCookie? mapped = _toJarCookie(cookie, host);
        if (mapped != null) collected.add(mapped);
      }
    }
    final Map<String, MangaCookie> deduped = <String, MangaCookie>{
      for (final MangaCookie cookie in collected) cookie.name: cookie,
    };
    final List<MangaCookie> fresh = deduped.values.toList(growable: false);
    if (fresh.isEmpty) return 0;
    await widget.jar.replaceForHost(host, fresh);
    return fresh.length;
  }

  /// 浏览器 cookie → jar cookie，域重标到 [host]（见类文档）。
  ///
  /// 只收与源站**同一站点**的条目：cookie 的域覆盖 host（父域），或反过来是
  /// host 的子域。第三方域（统计、广告、SSO 供应商）一概不进 jar——它们对源站
  /// 请求没有用，进来只会被原样发给源站，白白扩大外泄面。
  static MangaCookie? _toJarCookie(Cookie cookie, String host) {
    final String name = cookie.name.trim();
    if (name.isEmpty) return null;
    final String domain = MangaCookie.canonicalizeDomain(
      (cookie.domain ?? host).toString(),
    );
    if (domain.isEmpty) return null;
    final bool sameSite =
        MangaCookie.hostMatchesDomain(host, domain) ||
        MangaCookie.hostMatchesDomain(domain, host);
    if (!sameSite) return null;
    final num? expires = cookie.expiresDate as num?;
    return MangaCookie(
      name: name,
      value: cookie.value?.toString() ?? '',
      domain: host,
      secure: cookie.isSecure ?? false,
      // 会话 cookie（无 expires）落 null：jar 会一直留着它，直到下次登录整站替换。
      expiresAt: expires == null || expires <= 0 ? null : expires.toInt(),
    );
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    int saved = 0;
    Object? failure;
    try {
      saved = await _export();
    } on Object catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    // 导出失败或一条都没拿到时**不关页**：直接 pop 会让用户以为登录成功了。
    if (failure != null || saved == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.mihon_source_login_empty)),
      );
      return;
    }
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              '${widget.baseUrl.host} · ${t.mihon_source_login_hint}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child:
                widget.webViewBuilder?.call(context) ??
                KeyedSubtree(
                  // 重建 key 挂在 WebView **之上**：renderer 死后换 key 才能真正
                  // 重建出新的 platform view，而不动 WebView 自己的锚点。
                  key: _deathGuard.rebuildKey,
                  child: InAppWebView(
                    key: const ValueKey<String>('mihon_login_webview'),
                    initialUrlRequest: URLRequest(
                      url: WebUri.uri(widget.baseUrl),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      sharedCookiesEnabled: true,
                    ),
                    onLoadStop: (InAppWebViewController _, WebUri? url) =>
                        _noteVisited(url),
                    // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
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
                ),
          ),
        ],
      ),
    );
  }
}

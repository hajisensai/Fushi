import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';

/// 浏览器扩展送来的一条站点 cookie（`chrome.cookies.Cookie` 的子集）。
@immutable
class BrowserSiteCookie {
  const BrowserSiteCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.secure,
    required this.hostOnly,
    this.expiresAt,
  });

  final String name;
  final String value;

  /// 已去掉前导 `.`（Chromium 给域 cookie 带 `.example.jp`）。
  final String domain;
  final String path;
  final bool secure;
  final bool hostOnly;

  /// 毫秒；会话 cookie 为 null。
  final int? expiresAt;

  /// 扩展线格式：`{name, value, domain, path, secure, httpOnly, hostOnly,
  /// expirationDate(秒)}`。字段缺失 / 形状不对 → null（丢弃该条，不整批失败）。
  static BrowserSiteCookie? fromJson(Object? json) {
    if (json is! Map) return null;
    final String name = json['name']?.toString().trim() ?? '';
    if (name.isEmpty) return null;
    String domain = json['domain']?.toString().trim() ?? '';
    final bool hostOnly = json['hostOnly'] == true || !domain.startsWith('.');
    if (domain.startsWith('.')) domain = domain.substring(1);
    if (domain.isEmpty) return null;
    final Object? expiration = json['expirationDate'];
    final int? expiresAt = expiration is num && expiration > 0
        ? (expiration * 1000).round()
        : null;
    final String path = json['path']?.toString().trim() ?? '';
    return BrowserSiteCookie(
      name: name,
      value: json['value']?.toString() ?? '',
      domain: domain.toLowerCase(),
      path: path.isEmpty ? '/' : path,
      secure: json['secure'] == true,
      hostOnly: hostOnly,
      expiresAt: expiresAt,
    );
  }
}

/// 一次「等浏览器扩展把某站会话送过来」的登记。
@immutable
class BrowserCookieImportRequest {
  const BrowserCookieImportRequest({required this.host, required this.nonce});

  /// 源站 host（已去 `www.`）；扩展按它查 `chrome.cookies.getAll({domain})`。
  final String host;

  /// 一次性随机串：扩展回传必须带同一个，防止别的本机进程往 jar 里塞东西。
  final String nonce;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'nonce': nonce,
  };
}

/// 一次送达：扩展回传的站点 cookie（已按线格式解析，未做站点过滤）。
@immutable
class BrowserCookieDelivery {
  const BrowserCookieDelivery({required this.host, required this.cookies});

  final String host;
  final List<BrowserSiteCookie> cookies;
}

/// 浏览器扩展 → app 的站点会话导入闸门（BUG-2480）。
///
/// ## 流程
///
/// 1. 登录页 [begin]：登记 host + nonce，把源站在系统浏览器里打开；
/// 2. 扩展在心跳 / 该站页面加载完成时看到 `/api/extension/status` 回包里的
///    `cookieImport`，`chrome.cookies.getAll({domain: host})` 后 POST
///    `/api/extension/site-cookies`（带 nonce）；
/// 3. [deliver] 校验 nonce，把这一批推给登记者的 [BrowserCookieImportRequestHandle.deliveries]；
///    登记**不因一次送达而结束**——用户可能还没在浏览器里登录，登完页面再加载
///    一次扩展就再送一次，登录页照单全收直到用户点「完成」/关页（[end]）。
///
/// 同一时刻只有一个登记（登录页是模态的）；新登记覆盖旧的。
///
/// 单例而不是经构造注入：yomitan API server 在 `AppModel` 深处装配，登录页在
/// UI 树里，两头都够不着对方；与 `MihonCloudflareGate` 同一写法。
abstract final class BrowserCookieImportGate {
  static BrowserCookieImportRequestHandle? _active;

  /// 当前待导入的登记；扩展探活时随状态回包带出去。没有则 null。
  static BrowserCookieImportRequest? get pending => _active?.request;

  /// 登记一次导入；返回句柄，登录页从 [BrowserCookieImportRequestHandle.deliveries]
  /// 收货，结束时必须 [BrowserCookieImportRequestHandle.end]。
  static BrowserCookieImportRequestHandle begin(String host) {
    _active?.end();
    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportRequestHandle._(
          BrowserCookieImportRequest(
            host: normalizeHost(host),
            nonce: _nonce(),
          ),
        );
    _active = handle;
    return handle;
  }

  /// 扩展回传入口；nonce 不匹配 / 没有登记 → false（端点回 409）。
  static bool deliver({
    required String nonce,
    required String host,
    required List<BrowserSiteCookie> cookies,
  }) {
    final BrowserCookieImportRequestHandle? active = _active;
    if (active == null || active.request.nonce != nonce) return false;
    active._push(BrowserCookieDelivery(host: host, cookies: cookies));
    return true;
  }

  /// `www.` 前缀对 cookie 归属没有意义（站点的会话 cookie 几乎都发在裸域或
  /// 登录子域），去掉后 `getAll({domain})` 才能把裸域和全部子域一并拿到。
  static String normalizeHost(String host) {
    final String lower = host.trim().toLowerCase();
    return lower.startsWith('www.') ? lower.substring(4) : lower;
  }

  static String _nonce() {
    final Random random = Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  static void _endedBy(BrowserCookieImportRequestHandle handle) {
    if (identical(_active, handle)) _active = null;
  }

  @visibleForTesting
  static void resetForTesting() {
    _active?.end();
    _active = null;
  }
}

/// 一次登记的生命周期：[deliveries] 收扩展送来的批次，[end] 撤销登记。
class BrowserCookieImportRequestHandle {
  BrowserCookieImportRequestHandle._(this.request);

  final BrowserCookieImportRequest request;
  // 同步派发：[BrowserCookieImportGate.deliver] 一返回 true 监听者就已经拿到这批，
  // 端点回 200 与「app 已收下」同义；异步工作（写 jar）由监听者自己做。
  final StreamController<BrowserCookieDelivery> _controller =
      StreamController<BrowserCookieDelivery>.broadcast(sync: true);
  bool _ended = false;

  Stream<BrowserCookieDelivery> get deliveries => _controller.stream;

  void _push(BrowserCookieDelivery delivery) {
    if (_ended) return;
    _controller.add(delivery);
  }

  void end() {
    if (_ended) return;
    _ended = true;
    BrowserCookieImportGate._endedBy(this);
    unawaited(_controller.close());
  }
}

/// 扩展送来的 cookie → jar cookie，**只收与源站同一站点的条目**：cookie 的域覆盖
/// [siteHost]（父域）或是它的子域。`getAll({domain})` 本身已按域筛过，这里再筛一遍
/// 是让「进 jar 的东西」在 app 这一侧有唯一判据，与登录页从 WebView 导出那条路
/// 用同一个规则。
List<MangaCookie> browserCookiesForSite(
  Iterable<BrowserSiteCookie> cookies,
  String siteHost,
) {
  final String site = BrowserCookieImportGate.normalizeHost(siteHost);
  final Map<String, MangaCookie> deduped = <String, MangaCookie>{};
  for (final BrowserSiteCookie cookie in cookies) {
    final String domain = MangaCookie.canonicalizeDomain(cookie.domain);
    if (domain.isEmpty) continue;
    final bool sameSite =
        MangaCookie.hostMatchesDomain(site, domain) ||
        MangaCookie.hostMatchesDomain(domain, site);
    if (!sameSite) continue;
    final MangaCookie mapped = MangaCookie(
      name: cookie.name,
      value: cookie.value,
      domain: domain,
      path: cookie.path,
      secure: cookie.secure,
      hostOnly: cookie.hostOnly,
      expiresAt: cookie.expiresAt,
    );
    deduped['${mapped.name}${mapped.canonicalDomain}'] = mapped;
  }
  return deduped.values.toList(growable: false);
}

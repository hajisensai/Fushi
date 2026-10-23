import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// app 内浏览器（`FushiWebBrowserPage`）的一个站点书签。
@immutable
class WebBrowserSite {
  const WebBrowserSite({required this.name, required this.url});

  final String name;
  final Uri url;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'url': url.toString(),
  };

  static WebBrowserSite? fromJson(Object? json) {
    if (json is! Map) return null;
    final Uri? url = parseWebBrowserAddress(json['url']?.toString() ?? '');
    if (url == null) return null;
    final String name = json['name']?.toString().trim() ?? '';
    return WebBrowserSite(name: name.isEmpty ? url.host : name, url: url);
  }

  @override
  bool operator ==(Object other) =>
      other is WebBrowserSite && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);
}

/// 预置的漫画站：只放正规 / 常见的站，不预置成人站。只在网页漫画能力可用时
/// 预置（iOS 合规：不预置任何漫画来源，见 [webBrowserPresetSites]）。用户删光后
/// 不会自动补回（偏好里存的是用户自己的表，空数组就是空）。
final List<WebBrowserSite> kWebBrowserMangaPresetSites =
    List<WebBrowserSite>.unmodifiable(<WebBrowserSite>[
      WebBrowserSite(name: 'MangaDex', url: Uri.parse('https://mangadex.org/')),
      WebBrowserSite(name: 'Komiic', url: Uri.parse('https://komiic.com/')),
      WebBrowserSite(
        name: '拷贝漫画',
        url: Uri.parse('https://www.mangacopy.com/'),
      ),
      WebBrowserSite(
        name: 'WEBTOON',
        url: Uri.parse('https://www.webtoons.com/'),
      ),
    ]);

/// 从没改过站点表时的预置：网页漫画能力可用（[mangaAvailable]）才预置漫画站，
/// 否则空表。
List<WebBrowserSite> webBrowserPresetSites({required bool mangaAvailable}) =>
    mangaAvailable ? kWebBrowserMangaPresetSites : const <WebBrowserSite>[];

/// 解析偏好里存的站点表；空串 = 从没改过 → [presets]；坏 JSON → [presets]。
List<WebBrowserSite> parseWebBrowserSites(
  String raw, {
  required List<WebBrowserSite> presets,
}) {
  if (raw.trim().isEmpty) return presets;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return presets;
  }
  if (decoded is! List) return presets;
  return List<WebBrowserSite>.unmodifiable(<WebBrowserSite>[
    for (final Object? item in decoded) ?WebBrowserSite.fromJson(item),
  ]);
}

/// 从站点表里移除 [site]（按 URL）。
List<WebBrowserSite> removeWebBrowserSite(
  List<WebBrowserSite> sites,
  WebBrowserSite site,
) => List<WebBrowserSite>.unmodifiable(<WebBrowserSite>[
  for (final WebBrowserSite s in sites)
    if (s.url.toString() != site.url.toString()) s,
]);

String encodeWebBrowserSites(List<WebBrowserSite> sites) => jsonEncode(
  <Object?>[for (final WebBrowserSite site in sites) site.toJson()],
);

/// 站点表里加一项（同 URL 已在则不重复加，返回原表）。
List<WebBrowserSite> addWebBrowserSite(
  List<WebBrowserSite> sites,
  WebBrowserSite site,
) {
  if (sites.any(
    (WebBrowserSite s) => s.url.toString() == site.url.toString(),
  )) {
    return sites;
  }
  return List<WebBrowserSite>.unmodifiable(<WebBrowserSite>[...sites, site]);
}

/// 地址栏输入 → 可打开的 http(s) 地址；不像网址返回 null（交给搜索引擎）。
///
/// - 写了 `http://` / `https://`：用户明说是网址，任何非空主机都直接打开——
///   `http://localhost:55000/texthooker`、`http://nas:8080` 这类本机 / 局域网
///   地址没有点号，旧判据「主机必须带点」把它们统统送去了搜索（5wWlKU_Rir）；
/// - 没写协议：主机带点（域名 / IPv4）、`[IPv6]`，或 `localhost` 带端口 / 路径
///   才算网址。回环与 IP 字面量补 `http`（本机服务几乎都不是 TLS，浏览器同
///   口径），其余补 `https`。裸 `localhost` / 单个词仍按搜索处理。
Uri? parseWebBrowserAddress(String input) {
  final String text = input.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  final bool explicitScheme = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
  ).hasMatch(text);
  if (explicitScheme) {
    final Uri? uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.host.isEmpty ? null : uri;
  }
  final Uri? probe = Uri.tryParse('http://$text');
  if (probe == null || probe.host.isEmpty) return null;
  final String host = probe.host;
  final bool ipLiteral =
      host.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
  final bool localhost =
      host == 'localhost' &&
      (probe.hasPort || text.length > 'localhost'.length);
  if (!localhost && !ipLiteral && !host.contains('.')) return null;
  return Uri.tryParse('${localhost || ipLiteral ? 'http' : 'https'}://$text');
}

/// 用 [next] 替换站点表里 URL 与 [previous] 相同的那一项（编辑站点）。
/// 新 URL 与表里另一项撞了时丢掉被编辑的这项、保留原有那项，不出现重复。
List<WebBrowserSite> replaceWebBrowserSite(
  List<WebBrowserSite> sites,
  WebBrowserSite previous,
  WebBrowserSite next,
) {
  final String oldUrl = previous.url.toString();
  final String newUrl = next.url.toString();
  final bool collides =
      newUrl != oldUrl &&
      sites.any((WebBrowserSite s) => s.url.toString() == newUrl);
  return List<WebBrowserSite>.unmodifiable(<WebBrowserSite>[
    for (final WebBrowserSite s in sites)
      if (s.url.toString() != oldUrl) s else if (!collides) next,
  ]);
}

/// 地址栏的搜索引擎（用户 2026-10-20：「搜索框不要用网址，要支持搜索引擎，并且
/// 可切换默认谷歌」）。值名即持久化值，改名要迁移。
enum WebBrowserSearchEngine {
  google('Google', 'https://www.google.com/search'),
  bing('Bing', 'https://www.bing.com/search'),
  duckDuckGo('DuckDuckGo', 'https://duckduckgo.com/');

  const WebBrowserSearchEngine(this.label, this.endpoint);

  /// 专有名词，不进 i18n。
  final String label;
  final String endpoint;

  /// 用本引擎搜 [query] 的地址（三家都吃 `q` 参数）。
  Uri searchUrl(String query) => Uri.parse(
    endpoint,
  ).replace(queryParameters: <String, String>{'q': query.trim()});

  static WebBrowserSearchEngine fromName(Object? name) =>
      WebBrowserSearchEngine.values.firstWhere(
        (WebBrowserSearchEngine e) => e.name == name,
        orElse: () => WebBrowserSearchEngine.google,
      );
}

/// 当前搜索引擎的偏好键（设备本地）。
const String kWebBrowserSearchEnginePref = 'web_browser_search_engine';

WebBrowserSearchEngine readWebBrowserSearchEngine(PrefStore prefs) =>
    WebBrowserSearchEngine.fromName(prefs.getPref(kWebBrowserSearchEnginePref));

Future<void> writeWebBrowserSearchEngine(
  PrefStore prefs,
  WebBrowserSearchEngine engine,
) => prefs.setPref(kWebBrowserSearchEnginePref, engine.name);

/// 地址栏输入 → 要打开的地址：像网址就直接打开（[parseWebBrowserAddress]），
/// 否则交给 [engine] 搜索；空输入返回 null。
Uri? resolveWebBrowserInput(String input, WebBrowserSearchEngine engine) {
  final String text = input.trim();
  if (text.isEmpty) return null;
  return parseWebBrowserAddress(text) ?? engine.searchUrl(text);
}

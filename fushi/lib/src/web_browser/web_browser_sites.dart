import 'dart:convert';

import 'package:flutter/foundation.dart';

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

/// 地址栏输入 → 可打开的 http(s) 地址。没写协议的补 https；不像网址返回 null。
Uri? parseWebBrowserAddress(String input) {
  String text = input.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
    text = 'https://$text';
  }
  final Uri? uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  if (uri.host.isEmpty || !uri.host.contains('.')) return null;
  return uri;
}

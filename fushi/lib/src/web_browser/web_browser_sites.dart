import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// app 内浏览器（`FushiWebBrowserPage`）的一个站点书签。
///
/// 视频站点与浏览器站点是同一份表（用户 2026-10-26「这个站点和视频站点有什么关系？
/// 有必要分开吗？」）。站点一律在浏览器里打开（用户只看到一个浏览器，
/// `docs/specs/2026-11-01-one-browser.md`）；[openInPlayer] 为 true 的站点，观看页由浏览器
/// 自动交给 Fushi 播放器层（Windows 的网页站点后端，Netflix 硬件 DRM / Fushi 字幕层 / 每集
/// 落库）。播放器层只在 Windows 上有，其它平台忽略这个标记。
@immutable
class WebBrowserSite {
  const WebBrowserSite({
    required this.name,
    required this.url,
    this.openInPlayer = false,
  });

  final String name;
  final Uri url;

  /// 「用 Fushi 播放本站视频」：观看页自动交给播放器层（只在有播放器层的平台生效，见
  /// `webBrowserSiteAutoPlays`）。名字与 JSON 键 `player` 是旧「用播放页打开」的持久化名，冻结。
  final bool openInPlayer;

  WebBrowserSite copyWith({bool? openInPlayer}) => WebBrowserSite(
    name: name,
    url: url,
    openInPlayer: openInPlayer ?? this.openInPlayer,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'url': url.toString(),
    if (openInPlayer) 'player': true,
  };

  static WebBrowserSite? fromJson(Object? json) {
    if (json is! Map) return null;
    final Uri? url = parseWebBrowserAddress(json['url']?.toString() ?? '');
    if (url == null) return null;
    final String name = json['name']?.toString().trim() ?? '';
    return WebBrowserSite(
      name: name.isEmpty ? url.host : name,
      url: url,
      openInPlayer: json['player'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WebBrowserSite &&
      other.name == name &&
      other.url == url &&
      other.openInPlayer == openInPlayer;

  @override
  int get hashCode => Object.hash(name, url, openInPlayer);
}

/// 新加站点时「用 Fushi 播放本站视频」的初值：不进播放器层基本没法看的站（Netflix 要硬件
/// DRM）默认开，其它站默认关。[playerAvailable] 由调用方按平台给。
bool webBrowserSiteDefaultsToPlayer(Uri url, {required bool playerAvailable}) {
  if (!playerAvailable) return false;
  final String host = url.host.toLowerCase();
  return host == 'netflix.com' || host.endsWith('.netflix.com');
}

/// 把旧「视频站点」子页里用户自己加的站点（[legacy]：`(名称, 地址)`）并进站点表，
/// 一律标成用播放页打开；同地址已在表里的只把它标成播放页。
List<WebBrowserSite> mergeLegacyVideoSites(
  List<WebBrowserSite> sites,
  Iterable<(String, String)> legacy,
) {
  final List<WebBrowserSite> out = <WebBrowserSite>[...sites];
  for (final (String name, String rawUrl) in legacy) {
    final Uri? url = parseWebBrowserAddress(rawUrl);
    if (url == null) continue;
    final int i = out.indexWhere(
      (WebBrowserSite s) => s.url.toString() == url.toString(),
    );
    if (i >= 0) {
      out[i] = out[i].copyWith(openInPlayer: true);
    } else {
      out.add(
        WebBrowserSite(
          name: name.trim().isEmpty ? url.host : name.trim(),
          url: url,
          openInPlayer: true,
        ),
      );
    }
  }
  return List<WebBrowserSite>.unmodifiable(out);
}

/// 解析偏好里存的站点表；空串（从没改过）/ 坏 JSON → 空表。
///
/// 不预置任何站点（用户 2026-10-26「浏览器的默认网页删掉」）：站点全是用户自己加的。
List<WebBrowserSite> parseWebBrowserSites(String raw) {
  if (raw.trim().isEmpty) return const <WebBrowserSite>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <WebBrowserSite>[];
  }
  if (decoded is! List) return const <WebBrowserSite>[];
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

/// 地址栏可用的一个搜索引擎：内置 [WebBrowserSearchEngine] 或用户自定义的
/// [WebBrowserCustomSearchEngine]。地址栏、联想、搜索引擎页只认这个接口。
abstract interface class WebBrowserSearchProvider {
  /// 写进 [kWebBrowserSearchEnginePref] 的值（内置 = 枚举名，自定义 = `custom:<id>`）。
  String get prefValue;

  /// 显示名（专有名词 / 用户起的名字，不进 i18n）。
  String get label;

  /// 用本引擎搜 [query] 的地址。
  Uri searchUrl(String query);

  /// 在线联想地址；没有联想接口返回 null。响应约定为 OpenSearch JSON
  /// `["query", ["s1", "s2", ...]]`。
  Uri? suggestUrl(String query);
}

/// 地址栏的搜索引擎（用户 2026-10-20：「搜索框不要用网址，要支持搜索引擎，并且
/// 可切换默认谷歌」）。值名即持久化值，改名要迁移。
enum WebBrowserSearchEngine implements WebBrowserSearchProvider {
  google(
    'Google',
    'https://www.google.com/search',
    'https://suggestqueries.google.com/complete/search?client=firefox&q=%s',
  ),
  bing(
    'Bing',
    'https://www.bing.com/search',
    'https://api.bing.com/osjson.aspx?query=%s',
  ),
  duckDuckGo(
    'DuckDuckGo',
    'https://duckduckgo.com/',
    'https://duckduckgo.com/ac/?type=list&q=%s',
  );

  const WebBrowserSearchEngine(this.label, this.endpoint, this.suggestTemplate);

  /// 专有名词，不进 i18n。
  @override
  final String label;
  final String endpoint;

  /// 联想接口模板（`%s` = 查询词），三家都回 OpenSearch JSON。
  final String suggestTemplate;

  @override
  String get prefValue => name;

  /// 用本引擎搜 [query] 的地址（三家都吃 `q` 参数）。
  @override
  Uri searchUrl(String query) => Uri.parse(
    endpoint,
  ).replace(queryParameters: <String, String>{'q': query.trim()});

  @override
  Uri? suggestUrl(String query) =>
      fillWebBrowserSearchTemplate(suggestTemplate, query);

  static WebBrowserSearchEngine fromName(Object? name) =>
      WebBrowserSearchEngine.values.firstWhere(
        (WebBrowserSearchEngine e) => e.name == name,
        orElse: () => WebBrowserSearchEngine.google,
      );
}

/// 模板占位符。
const String kWebBrowserSearchPlaceholder = '%s';

/// 把 [template] 里的 `%s` 换成编码后的 [query]；模板不是 http(s) 或不含 `%s`
/// 返回 null。
Uri? fillWebBrowserSearchTemplate(String template, String query) {
  if (!isValidWebBrowserSearchTemplate(template)) return null;
  return Uri.tryParse(
    template.trim().replaceAll(
      kWebBrowserSearchPlaceholder,
      Uri.encodeQueryComponent(query.trim()),
    ),
  );
}

/// 模板是否可用：http(s)、有主机、含 `%s`、不含空格。
bool isValidWebBrowserSearchTemplate(String template) {
  final String text = template.trim();
  if (!text.contains(kWebBrowserSearchPlaceholder) || text.contains(' ')) {
    return false;
  }
  final Uri? probe = Uri.tryParse(
    text.replaceAll(kWebBrowserSearchPlaceholder, 'x'),
  );
  return probe != null &&
      (probe.scheme == 'http' || probe.scheme == 'https') &&
      probe.host.isNotEmpty;
}

/// 用户自定义的搜索引擎（名称 + 含 `%s` 的搜索模板 + 可选联想模板）。
@immutable
class WebBrowserCustomSearchEngine implements WebBrowserSearchProvider {
  const WebBrowserCustomSearchEngine({
    required this.id,
    required this.name,
    required this.searchTemplate,
    this.suggestTemplate,
  });

  /// 稳定 id（创建时生成，编辑不变），选中项持久化引用它。
  final String id;
  final String name;
  final String searchTemplate;
  final String? suggestTemplate;

  static const String prefPrefix = 'custom:';

  @override
  String get prefValue => '$prefPrefix$id';

  @override
  String get label => name;

  @override
  Uri searchUrl(String query) =>
      fillWebBrowserSearchTemplate(searchTemplate, query) ??
      WebBrowserSearchEngine.google.searchUrl(query);

  @override
  Uri? suggestUrl(String query) {
    final String? template = suggestTemplate;
    if (template == null || template.trim().isEmpty) return null;
    return fillWebBrowserSearchTemplate(template, query);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'search': searchTemplate,
    if (suggestTemplate != null) 'suggest': suggestTemplate,
  };

  static WebBrowserCustomSearchEngine? fromJson(Object? json) {
    if (json is! Map) return null;
    final String id = json['id']?.toString().trim() ?? '';
    final String search = json['search']?.toString().trim() ?? '';
    if (id.isEmpty || !isValidWebBrowserSearchTemplate(search)) return null;
    final String suggest = json['suggest']?.toString().trim() ?? '';
    final String name = json['name']?.toString().trim() ?? '';
    return WebBrowserCustomSearchEngine(
      id: id,
      name: name.isEmpty ? (Uri.tryParse(search)?.host ?? id) : name,
      searchTemplate: search,
      suggestTemplate: isValidWebBrowserSearchTemplate(suggest)
          ? suggest
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WebBrowserCustomSearchEngine &&
      other.id == id &&
      other.name == name &&
      other.searchTemplate == searchTemplate &&
      other.suggestTemplate == suggestTemplate;

  @override
  int get hashCode => Object.hash(id, name, searchTemplate, suggestTemplate);
}

/// 当前搜索引擎的偏好键（设备本地）。值：内置枚举名（旧值原样兼容）或
/// `custom:<id>`。
const String kWebBrowserSearchEnginePref = 'web_browser_search_engine';

/// 自定义搜索引擎表的偏好键（设备本地，JSON 数组）。
const String kWebBrowserCustomSearchEnginesPref =
    'web_browser_custom_search_engines';

/// 只读内置引擎；选中的是自定义引擎时返回 Google。**旧接口**，新代码用
/// [readWebBrowserSearchProvider]。
WebBrowserSearchEngine readWebBrowserSearchEngine(PrefStore prefs) =>
    WebBrowserSearchEngine.fromName(prefs.getPref(kWebBrowserSearchEnginePref));

Future<void> writeWebBrowserSearchEngine(
  PrefStore prefs,
  WebBrowserSearchEngine engine,
) => writeWebBrowserSearchProvider(prefs, engine);

List<WebBrowserCustomSearchEngine> parseWebBrowserCustomSearchEngines(
  String raw,
) {
  if (raw.trim().isEmpty) return const <WebBrowserCustomSearchEngine>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <WebBrowserCustomSearchEngine>[];
  }
  if (decoded is! List) return const <WebBrowserCustomSearchEngine>[];
  final Set<String> seen = <String>{};
  final List<WebBrowserCustomSearchEngine> result =
      <WebBrowserCustomSearchEngine>[];
  for (final Object? item in decoded) {
    final WebBrowserCustomSearchEngine? engine =
        WebBrowserCustomSearchEngine.fromJson(item);
    if (engine != null && seen.add(engine.id)) result.add(engine);
  }
  return List<WebBrowserCustomSearchEngine>.unmodifiable(result);
}

String encodeWebBrowserCustomSearchEngines(
  List<WebBrowserCustomSearchEngine> engines,
) => jsonEncode(<Object?>[
  for (final WebBrowserCustomSearchEngine e in engines) e.toJson(),
]);

List<WebBrowserCustomSearchEngine> readWebBrowserCustomSearchEngines(
  PrefStore prefs,
) => parseWebBrowserCustomSearchEngines(
  prefs.getPref(kWebBrowserCustomSearchEnginesPref)?.toString() ?? '',
);

Future<void> writeWebBrowserCustomSearchEngines(
  PrefStore prefs,
  List<WebBrowserCustomSearchEngine> engines,
) => prefs.setPref(
  kWebBrowserCustomSearchEnginesPref,
  encodeWebBrowserCustomSearchEngines(engines),
);

/// 全部可选引擎：内置三家在前，自定义按添加顺序在后。
List<WebBrowserSearchProvider> webBrowserSearchProviders(PrefStore prefs) =>
    List<WebBrowserSearchProvider>.unmodifiable(<WebBrowserSearchProvider>[
      ...WebBrowserSearchEngine.values,
      ...readWebBrowserCustomSearchEngines(prefs),
    ]);

/// 按持久化值找引擎；找不到（含自定义已删）回落 Google。
WebBrowserSearchProvider webBrowserSearchProviderFromPref(
  Object? value,
  List<WebBrowserCustomSearchEngine> customs,
) {
  final String text = value?.toString() ?? '';
  if (text.startsWith(WebBrowserCustomSearchEngine.prefPrefix)) {
    final String id = text.substring(
      WebBrowserCustomSearchEngine.prefPrefix.length,
    );
    for (final WebBrowserCustomSearchEngine e in customs) {
      if (e.id == id) return e;
    }
    return WebBrowserSearchEngine.google;
  }
  return WebBrowserSearchEngine.fromName(text);
}

/// 当前选中的搜索引擎（内置或自定义）。
WebBrowserSearchProvider readWebBrowserSearchProvider(PrefStore prefs) =>
    webBrowserSearchProviderFromPref(
      prefs.getPref(kWebBrowserSearchEnginePref),
      readWebBrowserCustomSearchEngines(prefs),
    );

Future<void> writeWebBrowserSearchProvider(
  PrefStore prefs,
  WebBrowserSearchProvider provider,
) => prefs.setPref(kWebBrowserSearchEnginePref, provider.prefValue);

/// 新增或按 id 替换一条自定义引擎。
Future<void> upsertWebBrowserCustomSearchEngine(
  PrefStore prefs,
  WebBrowserCustomSearchEngine engine,
) {
  final List<WebBrowserCustomSearchEngine> current =
      readWebBrowserCustomSearchEngines(prefs);
  final bool exists = current.any(
    (WebBrowserCustomSearchEngine e) => e.id == engine.id,
  );
  return writeWebBrowserCustomSearchEngines(
    prefs,
    <WebBrowserCustomSearchEngine>[
      for (final WebBrowserCustomSearchEngine e in current)
        e.id == engine.id ? engine : e,
      if (!exists) engine,
    ],
  );
}

/// 删一条自定义引擎；删的是当前选中项时选中回落 Google。
Future<void> removeWebBrowserCustomSearchEngine(
  PrefStore prefs,
  String id,
) async {
  final bool wasSelected =
      readWebBrowserSearchProvider(prefs).prefValue ==
      '${WebBrowserCustomSearchEngine.prefPrefix}$id';
  await writeWebBrowserCustomSearchEngines(
    prefs,
    <WebBrowserCustomSearchEngine>[
      for (final WebBrowserCustomSearchEngine e
          in readWebBrowserCustomSearchEngines(prefs))
        if (e.id != id) e,
    ],
  );
  if (wasSelected) {
    await writeWebBrowserSearchProvider(prefs, WebBrowserSearchEngine.google);
  }
}

/// 生成一个新自定义引擎 id（时间戳 base36，冲突时递增）。
String newWebBrowserCustomSearchEngineId(
  List<WebBrowserCustomSearchEngine> existing, {
  DateTime? now,
}) {
  int seed = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final Set<String> taken = <String>{
    for (final WebBrowserCustomSearchEngine e in existing) e.id,
  };
  while (taken.contains(seed.toRadixString(36))) {
    seed++;
  }
  return seed.toRadixString(36);
}

/// 地址栏输入 → 要打开的地址：像网址就直接打开（[parseWebBrowserAddress]），
/// 否则交给 [engine] 搜索；空输入返回 null。
Uri? resolveWebBrowserInput(String input, WebBrowserSearchProvider engine) {
  final String text = input.trim();
  if (text.isEmpty) return null;
  return parseWebBrowserAddress(text) ?? engine.searchUrl(text);
}

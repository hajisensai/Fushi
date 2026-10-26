/// 用户自配的「RSS 搜索站」配置（种子搜索的唯一来源之一，另一个是 Torznab）。
///
/// 仓库不内置任何 BT 搜索站，也不给预设或模板：用户自己添加站点的 RSS 搜索地址
/// （形如 `https://example.com/rss?q={query}`）。
/// 一条配置 = 一个 URL 模板 + 参与哪些域；解析走通用 RSS / Atom 解析
/// （`rss_feed_parser.dart`），不认站点私有结构。
library;

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 模板里必须出现的查询词占位符（替换为 URL 编码后的查询词）。
const String kRssSearchQueryPlaceholder = '{query}';

/// 模板里可选的页码占位符（从 1 起）。没有它的站点只取第一页。
const String kRssSearchPagePlaceholder = '{page}';

/// RSS 搜索站参与的域：视频三域（对应 [VideoDiscoveryCategory]）+ 发现页四域
/// （对应 [DiscoveryMediaKind]）。持久化用 [name]（JSON 里的字符串值，冻结）。
enum RssSearchDomain {
  anime(videoCategory: VideoDiscoveryCategory.anime),
  movie(videoCategory: VideoDiscoveryCategory.movie),
  tv(videoCategory: VideoDiscoveryCategory.tv),
  novel(discoveryKind: DiscoveryMediaKind.novel),
  audiobook(discoveryKind: DiscoveryMediaKind.audiobook),
  manga(discoveryKind: DiscoveryMediaKind.manga),
  game(discoveryKind: DiscoveryMediaKind.game);

  const RssSearchDomain({this.videoCategory, this.discoveryKind});

  /// 视频域对应的发现分类；非视频域为 null。
  final VideoDiscoveryCategory? videoCategory;

  /// 发现页域对应的媒体种类；视频域为 null。
  final DiscoveryMediaKind? discoveryKind;

  bool get isVideo => videoCategory != null;

  static RssSearchDomain fromVideoCategory(VideoDiscoveryCategory category) =>
      switch (category) {
        VideoDiscoveryCategory.anime => RssSearchDomain.anime,
        VideoDiscoveryCategory.movie => RssSearchDomain.movie,
        VideoDiscoveryCategory.tv => RssSearchDomain.tv,
      };

  static RssSearchDomain fromDiscoveryKind(DiscoveryMediaKind kind) =>
      switch (kind) {
        DiscoveryMediaKind.novel => RssSearchDomain.novel,
        DiscoveryMediaKind.audiobook => RssSearchDomain.audiobook,
        DiscoveryMediaKind.manga => RssSearchDomain.manga,
        DiscoveryMediaKind.game => RssSearchDomain.game,
      };

  /// 持久化名 → 枚举；不认识的值（更新版本写入的新域）返回 null，由调用方丢弃。
  static RssSearchDomain? tryParse(String raw) {
    for (final RssSearchDomain value in RssSearchDomain.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

class RssSearchSiteConfig {
  /// 构造即校验：[id] 非空且不含 `:` / `,`（订阅 provider id 是 `rss:<id>`），
  /// [urlTemplate] 必须含 [kRssSearchQueryPlaceholder]、展开后是带 host 的
  /// http/https 地址、无 user info / fragment，并过
  /// [isSafeExternalProviderEndpoint]（明文 HTTP 只认回环或 [allowInsecureHttp]）。
  /// 不合法抛 [ArgumentError]。
  RssSearchSiteConfig({
    required this.id,
    required this.name,
    required String urlTemplate,
    this.enabled = true,
    this.priority = 100,
    Iterable<RssSearchDomain> domains = const <RssSearchDomain>[],
    this.allowInsecureHttp = false,
  }) : urlTemplate = urlTemplate.trim(),
       domains = Set<RssSearchDomain>.unmodifiable(domains) {
    final String trimmedId = id.trim();
    if (trimmedId.isEmpty || trimmedId != id) {
      throw ArgumentError.value(id, 'id', 'must be non-empty and trimmed');
    }
    if (id.contains(':') || id.contains(',')) {
      throw ArgumentError.value(id, 'id', 'must not contain ":" or ","');
    }
    final String? problem = validateRssSearchUrlTemplate(
      this.urlTemplate,
      allowInsecureHttp: allowInsecureHttp,
    );
    if (problem != null) throw ArgumentError(problem);
  }

  /// 坏行（缺字段 / 模板非法）抛 [ArgumentError] / [TypeError]；批量解码见
  /// [decodeRssSearchSiteConfigs]（坏行跳过）。
  factory RssSearchSiteConfig.fromJson(Map<String, Object?> json) {
    final Object? rawDomains = json['domains'];
    return RssSearchSiteConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      urlTemplate: json['urlTemplate'] as String? ?? '',
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      priority: json['priority'] is int ? json['priority']! as int : 100,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
      domains: <RssSearchDomain>[
        if (rawDomains is List)
          for (final Object? value in rawDomains)
            if (value is String) ?RssSearchDomain.tryParse(value),
      ],
    );
  }

  final String id;
  final String name;

  /// 含 `{query}`（可选 `{page}`）的搜索地址模板。
  final String urlTemplate;
  final bool enabled;

  /// 越小越先搜、跨源去重时越优先。
  final int priority;
  final Set<RssSearchDomain> domains;
  final bool allowInsecureHttp;

  /// 本站参与的视频域；空 = 不参与视频资源搜索。
  Set<VideoDiscoveryCategory> get videoCategories => <VideoDiscoveryCategory>{
    for (final RssSearchDomain domain in domains)
      if (domain.videoCategory != null) domain.videoCategory!,
  };

  /// 本站参与的发现页域。
  Set<DiscoveryMediaKind> get discoveryKinds => <DiscoveryMediaKind>{
    for (final RssSearchDomain domain in domains)
      if (domain.discoveryKind != null) domain.discoveryKind!,
  };

  /// 模板里有 `{page}` = 能翻页。
  bool get supportsPaging => urlTemplate.contains(kRssSearchPagePlaceholder);

  /// 是否参与视频资源搜索里某个域（[category] 为 null = 纯关键词搜索：任何勾了
  /// 视频域的站都参与）。
  bool appliesToVideo(VideoDiscoveryCategory? category) {
    if (!enabled) return false;
    final Set<VideoDiscoveryCategory> categories = videoCategories;
    if (categories.isEmpty) return false;
    return category == null || categories.contains(category);
  }

  /// 是否参与发现页某个域。
  bool appliesToDiscovery(DiscoveryMediaKind kind) =>
      enabled && domains.contains(RssSearchDomain.fromDiscoveryKind(kind));

  /// 展开模板：`{query}` 换成 URL 编码的查询词，`{page}` 换成页码。
  Uri buildSearchUri(String query, {int page = 1}) {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    return Uri.parse(_expandRssSearchTemplate(urlTemplate, query, page));
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'urlTemplate': urlTemplate,
    'enabled': enabled,
    'priority': priority,
    'domains': <String>[
      for (final RssSearchDomain domain in RssSearchDomain.values)
        if (domains.contains(domain)) domain.name,
    ],
    'allowInsecureHttp': allowInsecureHttp,
  };

  RssSearchSiteConfig copyWith({
    String? name,
    String? urlTemplate,
    bool? enabled,
    int? priority,
    Iterable<RssSearchDomain>? domains,
    bool? allowInsecureHttp,
  }) => RssSearchSiteConfig(
    id: id,
    name: name ?? this.name,
    urlTemplate: urlTemplate ?? this.urlTemplate,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
    domains: domains ?? this.domains,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  // 模板本身可能带私有站的 passkey，日志里只露 host。
  @override
  String toString() {
    final Uri? sample = Uri.tryParse(
      _expandRssSearchTemplate(urlTemplate, 'q', 1),
    );
    return 'RssSearchSiteConfig(id=$id, name=$name, host=${sample?.host}, '
        'enabled=$enabled, priority=$priority, '
        'domains=${domains.map((RssSearchDomain d) => d.name).join(',')})';
  }
}

/// 校验 URL 模板，合法返回 null，否则返回英文原因（设置页 / WebUI 直接展示或
/// 映射成本地化文案）。判据与 [RssSearchSiteConfig] 构造器同一处。
String? validateRssSearchUrlTemplate(
  String template, {
  bool allowInsecureHttp = false,
}) {
  final String value = template.trim();
  if (value.isEmpty) return 'URL template is required';
  if (!value.contains(kRssSearchQueryPlaceholder)) {
    return 'URL template must contain $kRssSearchQueryPlaceholder';
  }
  final Uri? uri = Uri.tryParse(_expandRssSearchTemplate(value, 'test', 1));
  if (uri == null) return 'URL template is not a valid URL';
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return 'URL template must use HTTP or HTTPS';
  }
  if (uri.host.isEmpty) return 'URL template must have a host';
  if (uri.userInfo.isNotEmpty || uri.hasFragment) {
    return 'URL template must not contain user info or a fragment';
  }
  if (!isSafeExternalProviderEndpoint(
    uri,
    allowInsecureHttp: allowInsecureHttp,
  )) {
    return 'URL template must use HTTPS unless insecure HTTP is explicitly '
        'allowed or the host is loopback';
  }
  return null;
}

String _expandRssSearchTemplate(String template, String query, int page) =>
    template
        .replaceAll(kRssSearchQueryPlaceholder, Uri.encodeQueryComponent(query))
        .replaceAll(kRssSearchPagePlaceholder, '$page');

/// 解码偏好里的 JSON 数组；坏行跳过（偏好可被用户改、也会从旧版本同步来，一条
/// 坏配置不该让其它站点一起消失）。
List<RssSearchSiteConfig> decodeRssSearchSiteConfigs(Object? value) {
  if (value is! List) return const <RssSearchSiteConfig>[];
  final List<RssSearchSiteConfig> configs = <RssSearchSiteConfig>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in value) {
    if (entry is! Map) continue;
    try {
      final RssSearchSiteConfig config = RssSearchSiteConfig.fromJson(
        entry.map(
          (Object? key, Object? value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
      if (seen.add(config.id)) configs.add(config);
    } on Object {
      // 跳过坏行，见函数说明。
    }
  }
  return List<RssSearchSiteConfig>.unmodifiable(configs);
}

List<Map<String, Object?>> encodeRssSearchSiteConfigs(
  Iterable<RssSearchSiteConfig> configs,
) => configs
    .map((RssSearchSiteConfig config) => config.toJson())
    .toList(growable: false);

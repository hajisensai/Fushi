import 'package:flutter/widgets.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/rss_search_site_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_body_items.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';

/// 视频外部提供方（`VideoExternalProviderSettingsSection` 的 jimaku /
/// openSubtitles / subdl / torznab / downloadRouting 各 scope，正文自绘 widget）
/// 与「RSS 搜索站」设置区（`RssSearchSiteSettingsSection`）在控制通道上的条目。
///
/// 写入全部走页面同一个 [AppVideoExternalSettingsStore]（同一组 AppModel /
/// prefs 方法，含下载流水线运行时重建），字段校验走页面同一份
/// `torznabConfigFromFields` / `openSubtitlesConfigFromFields` /
/// `videoDownloadPathMappingFromFields`——校验不过不写，报原因。
///
/// AJATT 开关与默认字幕语言已是 schema 行（`services.subtitle_preferences` /
/// `services.subtitle_default_language`），这里不重复。
///
/// id 统一 `<页面原前缀>.cli.<名>`：页面的 `services.*` / `downloads.*` 是设置搜索
/// 的 reveal 目标，不能重复。
List<CtlBodyPage> buildCtlVideoProvidersBodyPages() => <CtlBodyPage>[
  _jimakuPage(),
  _openSubtitlesPage(),
  _subdlPage(),
  _rssSitesPage(),
  _torznabPage(),
  _downloadRoutingPage(),
];

AppVideoExternalSettingsStore _store(SettingsContext c) =>
    AppVideoExternalSettingsStore(c.appModel);

bool _servicesVisible(SettingsContext c) => isSettingsDestinationVisible(
  SettingsDestinationId.services,
  c.appModel.moduleVisibility,
);

/// 资源索引器两页在 iOS 上整节不渲染（App Store 合规，与 schema 同一判据）。
bool _resourcesVisible(SettingsContext c) =>
    _servicesVisible(c) &&
    StoreRestrictedCapability.externalDiscovery.isAvailable;

String _servicesCrumb(String leaf) =>
    '${t.settings_destination_services} › $leaf';

// ── 字幕来源 ──────────────────────────────────────────────────────────────────

CtlBodyPage _jimakuPage() => CtlBodyPage(
  breadcrumb: _servicesCrumb('Jimaku'),
  visible: _servicesVisible,
  items: <SettingsItem>[
    SettingsSwitchItem(
      id: 'services.jimaku.cli.enabled',
      title: 'Jimaku · ${t.video_external_enabled}',
      subtitle: t.video_jimaku_enabled_hint,
      value: (SettingsContext c) => c.appModel.jimakuEnabled,
      onChanged: (SettingsContext c, bool v) => _store(c).saveJimakuEnabled(v),
      defaultValue: true,
    ),
    SettingsTextItem(
      id: 'services.jimaku.cli.api_key',
      title: t.video_jimaku_api_key,
      subtitle: t.video_jimaku_api_key_hint,
      secret: true,
      value: (SettingsContext c) => c.appModel.jimakuApiKey,
      onChanged: (SettingsContext c, String v) => _store(c).saveJimakuApiKey(v),
    ),
  ],
);

CtlBodyPage _subdlPage() => CtlBodyPage(
  breadcrumb: _servicesCrumb('SubDL'),
  visible: _servicesVisible,
  items: <SettingsItem>[
    SettingsSwitchItem(
      id: 'services.subdl.cli.enabled',
      title: 'SubDL · ${t.video_external_enabled}',
      subtitle: t.video_subdl_enabled_hint,
      value: (SettingsContext c) => c.appModel.videoSubtitleSubdlEnabled,
      onChanged: (SettingsContext c, bool v) => _store(c).saveSubdlEnabled(v),
      defaultValue: true,
    ),
    SettingsTextItem(
      id: 'services.subdl.cli.api_key',
      title: 'SubDL · ${t.video_external_api_key}',
      subtitle: t.video_subdl_api_key_hint,
      secret: true,
      value: (SettingsContext c) => c.appModel.videoSubtitleSubdlApiKey,
      onChanged: (SettingsContext c, String v) => _store(c).saveSubdlApiKey(v),
    ),
  ],
);

/// OpenSubtitles 表单的一份可改快照（与页面草稿同形）。
typedef _OsFields = ({
  String endpoint,
  String apiKey,
  String username,
  String password,
  String userAgent,
  bool enabled,
  bool allowInsecureHttp,
});

_OsFields _osFields(SettingsContext c) {
  final OpenSubtitlesConfig config =
      c.appModel.prefsRepo.videoSubtitleOpenSubtitlesConfig;
  return (
    endpoint: config.baseUrl.toString(),
    apiKey: config.apiKey,
    username: config.username ?? '',
    password: config.password ?? '',
    userAgent: config.userAgent,
    enabled: config.enabled,
    allowInsecureHttp: config.allowInsecureHttp,
  );
}

/// 改 OpenSubtitles 的一个字段：整份过页面同一份校验，不合法不写。
Future<void> _writeOpenSubtitles(
  SettingsContext c,
  _OsFields Function(_OsFields f) mutate,
) async {
  final _OsFields f = mutate(_osFields(c));
  final OpenSubtitlesConfig? config = openSubtitlesConfigFromFields(
    endpoint: f.endpoint,
    apiKey: f.apiKey,
    username: f.username,
    password: f.password,
    userAgent: f.userAgent,
    enabled: f.enabled,
    allowInsecureHttp: f.allowInsecureHttp,
  );
  if (config == null) {
    throw ArgumentError(
      f.userAgent.trim().isEmpty
          ? 'User-Agent 不能为空'
          : '${t.video_external_endpoint_invalid}（须为 https 或 loopback；'
                'http 需先把 insecure_http 设为 true）',
    );
  }
  await _store(c).saveOpenSubtitlesConfig(config);
}

CtlBodyPage _openSubtitlesPage() => CtlBodyPage(
  breadcrumb: _servicesCrumb(t.video_opensubtitles_settings_title),
  visible: _servicesVisible,
  items: <SettingsItem>[
    SettingsCustomItem(
      id: 'services.opensubtitles.cli.enabled',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: 'OpenSubtitles · ${t.video_external_enabled}',
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => '${_osFields(c).enabled}',
        write: (SettingsContext c, String raw) {
          final bool v = parseCtlSettingBool(raw);
          return _writeOpenSubtitles(
            c,
            (_OsFields f) => (
              endpoint: f.endpoint,
              apiKey: f.apiKey,
              username: f.username,
              password: f.password,
              userAgent: f.userAgent,
              enabled: v,
              allowInsecureHttp: f.allowInsecureHttp,
            ),
          );
        },
        help: 'true / false',
        options: (SettingsContext _) => const <String>['true', 'false'],
      ),
    ),
    SettingsCustomItem(
      id: 'services.opensubtitles.cli.endpoint',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_opensubtitles_endpoint,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => _osFields(c).endpoint,
        write: (SettingsContext c, String raw) => _writeOpenSubtitles(
          c,
          (_OsFields f) => (
            endpoint: raw.trim(),
            apiKey: f.apiKey,
            username: f.username,
            password: f.password,
            userAgent: f.userAgent,
            enabled: f.enabled,
            allowInsecureHttp: f.allowInsecureHttp,
          ),
        ),
        help: 'API 端点 URL（https；loopback 或开了 insecure_http 才可 http）',
      ),
    ),
    SettingsTextItem(
      id: 'services.opensubtitles.cli.api_key',
      title: 'OpenSubtitles · ${t.video_external_api_key}',
      secret: true,
      value: (SettingsContext c) => _osFields(c).apiKey,
      onChanged: (SettingsContext c, String v) => _writeOpenSubtitles(
        c,
        (_OsFields f) => (
          endpoint: f.endpoint,
          apiKey: v,
          username: f.username,
          password: f.password,
          userAgent: f.userAgent,
          enabled: f.enabled,
          allowInsecureHttp: f.allowInsecureHttp,
        ),
      ),
    ),
    SettingsCustomItem(
      id: 'services.opensubtitles.cli.username',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_external_username_optional,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => _osFields(c).username,
        write: (SettingsContext c, String raw) => _writeOpenSubtitles(
          c,
          (_OsFields f) => (
            endpoint: f.endpoint,
            apiKey: f.apiKey,
            username: raw,
            password: f.password,
            userAgent: f.userAgent,
            enabled: f.enabled,
            allowInsecureHttp: f.allowInsecureHttp,
          ),
        ),
        help: '登录用户名；空串 = 不登录',
      ),
    ),
    SettingsTextItem(
      id: 'services.opensubtitles.cli.password',
      title: t.video_external_password_optional,
      secret: true,
      value: (SettingsContext c) => _osFields(c).password,
      onChanged: (SettingsContext c, String v) => _writeOpenSubtitles(
        c,
        (_OsFields f) => (
          endpoint: f.endpoint,
          apiKey: f.apiKey,
          username: f.username,
          password: v,
          userAgent: f.userAgent,
          enabled: f.enabled,
          allowInsecureHttp: f.allowInsecureHttp,
        ),
      ),
    ),
    SettingsCustomItem(
      id: 'services.opensubtitles.cli.user_agent',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_opensubtitles_user_agent,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => _osFields(c).userAgent,
        write: (SettingsContext c, String raw) => _writeOpenSubtitles(
          c,
          (_OsFields f) => (
            endpoint: f.endpoint,
            apiKey: f.apiKey,
            username: f.username,
            password: f.password,
            userAgent: raw,
            enabled: f.enabled,
            allowInsecureHttp: f.allowInsecureHttp,
          ),
        ),
        help: 'User-Agent（不能为空）',
      ),
    ),
    SettingsCustomItem(
      id: 'services.opensubtitles.cli.insecure_http',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: 'OpenSubtitles · ${t.video_external_insecure_http}',
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => '${_osFields(c).allowInsecureHttp}',
        write: (SettingsContext c, String raw) {
          final bool v = parseCtlSettingBool(raw);
          return _writeOpenSubtitles(
            c,
            (_OsFields f) => (
              endpoint: f.endpoint,
              apiKey: f.apiKey,
              username: f.username,
              password: f.password,
              userAgent: f.userAgent,
              enabled: f.enabled,
              allowInsecureHttp: v,
            ),
          );
        },
        help: 'true / false（${t.video_external_insecure_http_hint}）',
        options: (SettingsContext _) => const <String>['true', 'false'],
      ),
    ),
  ],
);

// ── 资源索引器 ────────────────────────────────────────────────────────────────

/// 模板里可能带私有站 passkey：列表只给 host，模板本身按凭据遮掉。
Map<String, Object?> _rssRecord(RssSearchSiteConfig site) => <String, Object?>{
  'id': site.id,
  'name': site.name,
  'host': site.buildSearchUri('q').host,
  'urlTemplate': redactCtlSecret(site.urlTemplate),
  'enabled': site.enabled,
  'priority': site.priority,
  'domains': <String>[
    for (final RssSearchDomain domain in RssSearchDomain.values)
      if (site.domains.contains(domain)) domain.name,
  ].join(','),
  'allowInsecureHttp': site.allowInsecureHttp,
};

List<RssSearchSiteConfig> _rssSites(SettingsContext c) =>
    c.appModel.prefsRepo.resourceRssSites;

Set<RssSearchDomain> _parseRssDomains(String raw) {
  final Set<RssSearchDomain> domains = <RssSearchDomain>{};
  for (final String name in raw.split(',')) {
    if (name.trim().isEmpty) continue;
    final RssSearchDomain? domain = RssSearchDomain.tryParse(name.trim());
    if (domain == null) {
      throw ArgumentError(
        '未知的媒体域「$name」；可选：'
        '${RssSearchDomain.values.map((RssSearchDomain d) => d.name).join('、')}',
      );
    }
    domains.add(domain);
  }
  if (domains.isEmpty) throw ArgumentError('domains 至少选一个');
  return domains;
}

/// 字段 → 站点配置（与设置页同一份校验）；不合法抛 [ArgumentError] 说明哪项错。
RssSearchSiteConfig _buildRssSite({
  required String id,
  required String name,
  required String urlTemplate,
  required bool enabled,
  required String priority,
  required Set<RssSearchDomain> domains,
  required bool allowInsecureHttp,
}) {
  if (name.trim().isEmpty) throw ArgumentError('name 不能为空');
  final int? parsedPriority = int.tryParse(priority.trim());
  if (parsedPriority == null) {
    throw ArgumentError('priority 必须是整数，收到「$priority」');
  }
  final String? problem = rssSearchUrlTemplateError(
    urlTemplate,
    allowInsecureHttp: allowInsecureHttp,
  );
  if (problem != null) throw ArgumentError(problem);
  return RssSearchSiteConfig(
    id: id,
    name: name.trim(),
    urlTemplate: urlTemplate,
    enabled: enabled,
    priority: parsedPriority,
    domains: domains,
    allowInsecureHttp: allowInsecureHttp,
  );
}

RssSearchSiteConfig _requireRssSite(SettingsContext c, String id) {
  for (final RssSearchSiteConfig site in _rssSites(c)) {
    if (site.id == id) return site;
  }
  throw ArgumentError('没有 id 为「$id」的 RSS 搜索站');
}

Future<void> _saveRssSites(
  SettingsContext c,
  List<RssSearchSiteConfig> sites,
) => AppRssSearchSiteSettingsStore(c.appModel).saveSites(sites);

const List<SettingsCliParam> _rssFields = <SettingsCliParam>[
  SettingsCliParam('name', help: '站点名称', required: false),
  SettingsCliParam(
    'url_template',
    help: '搜索地址模板，必须含 {query}（可选 {page}），如 $kRssSearchUrlTemplateExample',
    required: false,
    secret: true,
  ),
  SettingsCliParam(
    'domains',
    help: '逗号分隔的媒体域：anime,movie,tv,novel,audiobook,manga,game',
    required: false,
  ),
  SettingsCliParam('enabled', help: 'true/false，默认 true', required: false),
  SettingsCliParam('priority', help: '整数，默认 100（越小越先搜）', required: false),
  SettingsCliParam(
    'insecure_http',
    help: 'true/false，允许明文 http 地址，默认 false',
    required: false,
  ),
];

CtlBodyPage _rssSitesPage() => CtlBodyPage(
  breadcrumb: _servicesCrumb(t.video_rss_settings_title),
  visible: _resourcesVisible,
  items: <SettingsItem>[
    SettingsCustomItem(
      id: 'services.rss_sites.cli.sites',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_rss_settings_title,
      cliList: SettingsCliList(
        fields: _rssFields,
        list: (SettingsContext c) async => <Map<String, Object?>>[
          for (final RssSearchSiteConfig site in _rssSites(c)) _rssRecord(site),
        ],
        add: (SettingsContext c, Map<String, String> fields) async {
          if ((fields['url_template'] ?? '').trim().isEmpty) {
            throw ArgumentError('缺少字段 url_template');
          }
          final RssSearchSiteConfig site = _buildRssSite(
            id: newVideoExternalRecordId('rss'),
            name: fields['name'] ?? '',
            urlTemplate: fields['url_template']!,
            enabled: _boolField(fields, 'enabled', true),
            priority: fields['priority'] ?? '100',
            domains: _parseRssDomains(fields['domains'] ?? ''),
            allowInsecureHttp: _boolField(fields, 'insecure_http', false),
          );
          await _saveRssSites(c, <RssSearchSiteConfig>[..._rssSites(c), site]);
          return _rssRecord(site);
        },
        update:
            (SettingsContext c, String id, Map<String, String> fields) async {
              final RssSearchSiteConfig old = _requireRssSite(c, id);
              final String? domains = fields['domains'];
              final RssSearchSiteConfig next = _buildRssSite(
                id: old.id,
                name: fields['name'] ?? old.name,
                urlTemplate: fields['url_template'] ?? old.urlTemplate,
                enabled: _boolField(fields, 'enabled', old.enabled),
                priority: fields['priority'] ?? '${old.priority}',
                domains: domains == null
                    ? old.domains
                    : _parseRssDomains(domains),
                allowInsecureHttp: _boolField(
                  fields,
                  'insecure_http',
                  old.allowInsecureHttp,
                ),
              );
              await _saveRssSites(c, <RssSearchSiteConfig>[
                for (final RssSearchSiteConfig site in _rssSites(c))
                  site.id == id ? next : site,
              ]);
              return _rssRecord(next);
            },
        remove: (SettingsContext c, String id) async {
          _requireRssSite(c, id);
          await _saveRssSites(c, <RssSearchSiteConfig>[
            for (final RssSearchSiteConfig site in _rssSites(c))
              if (site.id != id) site,
          ]);
        },
      ),
    ),
  ],
);

Map<String, Object?> _torznabRecord(TorznabIndexerConfig config) =>
    <String, Object?>{
      'id': config.id,
      'name': config.name,
      'endpoint': config.endpoint.toString(),
      'enabled': config.enabled,
      'priority': config.priority,
      'categories': config.categories,
      'allowInsecureHttp': config.allowInsecureHttp,
      'apiKey': redactCtlSecret(config.apiKey),
    };

List<TorznabIndexerConfig> _torznabConfigs(SettingsContext c) =>
    c.appModel.prefsRepo.videoResourceTorznabConfigs;

/// 字段 → 索引器配置（与页面同一份校验）；不合法抛 [ArgumentError] 说明哪项错。
TorznabIndexerConfig _buildTorznab({
  required String id,
  required String name,
  required String endpoint,
  required String apiKey,
  required bool enabled,
  required String priority,
  required String categories,
  required bool allowInsecureHttp,
}) {
  if (name.trim().isEmpty) throw ArgumentError('name 不能为空');
  if (int.tryParse(priority.trim()) == null) {
    throw ArgumentError('priority 必须是整数，收到「$priority」');
  }
  final TorznabIndexerConfig? config = torznabConfigFromFields(
    id: id,
    name: name,
    endpoint: endpoint,
    apiKey: apiKey,
    enabled: enabled,
    priority: priority,
    categories: categories,
    allowInsecureHttp: allowInsecureHttp,
  );
  if (config != null) return config;
  final bool categoriesOk =
      categories.trim().isEmpty ||
      categories
          .split(',')
          .every((String raw) => (int.tryParse(raw.trim()) ?? -1) >= 0);
  throw ArgumentError(
    categoriesOk
        ? '${t.video_external_endpoint_invalid}（须为 https 或 loopback、不带 query；'
              'http 需 insecure_http=true）'
        : t.video_external_categories_invalid,
  );
}

TorznabIndexerConfig _requireTorznab(SettingsContext c, String id) {
  for (final TorznabIndexerConfig config in _torznabConfigs(c)) {
    if (config.id == id) return config;
  }
  throw ArgumentError('没有 id 为「$id」的 Torznab 索引器');
}

bool _boolField(Map<String, String> fields, String name, bool fallback) {
  final String? raw = fields[name];
  return raw == null ? fallback : parseCtlSettingBool(raw);
}

const List<SettingsCliParam> _torznabFields = <SettingsCliParam>[
  SettingsCliParam('name', help: '索引器名称', required: false),
  SettingsCliParam(
    'endpoint',
    help:
        'Torznab API 端点（如 https://host/api/v2.0/indexers/all/results/torznab）',
    required: false,
  ),
  SettingsCliParam(
    'api_key',
    help: 'Torznab API key',
    required: false,
    secret: true,
  ),
  SettingsCliParam('enabled', help: 'true/false，默认 true', required: false),
  SettingsCliParam('priority', help: '整数，默认 100', required: false),
  SettingsCliParam(
    'categories',
    help: '逗号分隔的分类号（如 5000,5070）；空 = 不限',
    required: false,
  ),
  SettingsCliParam(
    'insecure_http',
    help: 'true/false，允许明文 http 端点，默认 false',
    required: false,
  ),
];

CtlBodyPage _torznabPage() => CtlBodyPage(
  breadcrumb: _servicesCrumb(t.video_torznab_settings_title),
  visible: _resourcesVisible,
  items: <SettingsItem>[
    SettingsCustomItem(
      id: 'services.torznab.cli.indexers',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_torznab_settings_title,
      cliList: SettingsCliList(
        fields: _torznabFields,
        list: (SettingsContext c) async => <Map<String, Object?>>[
          for (final TorznabIndexerConfig config in _torznabConfigs(c))
            _torznabRecord(config),
        ],
        add: (SettingsContext c, Map<String, String> fields) async {
          if ((fields['endpoint'] ?? '').trim().isEmpty) {
            throw ArgumentError('缺少字段 endpoint');
          }
          final TorznabIndexerConfig config = _buildTorznab(
            id: newVideoExternalRecordId('torznab'),
            name: fields['name'] ?? '',
            endpoint: fields['endpoint']!,
            apiKey: fields['api_key'] ?? '',
            enabled: _boolField(fields, 'enabled', true),
            priority: fields['priority'] ?? '100',
            categories: fields['categories'] ?? '',
            allowInsecureHttp: _boolField(fields, 'insecure_http', false),
          );
          await _store(c).saveTorznabConfigs(<TorznabIndexerConfig>[
            ..._torznabConfigs(c),
            config,
          ]);
          return _torznabRecord(config);
        },
        update:
            (SettingsContext c, String id, Map<String, String> fields) async {
              final TorznabIndexerConfig old = _requireTorznab(c, id);
              final TorznabIndexerConfig next = _buildTorznab(
                id: old.id,
                name: fields['name'] ?? old.name,
                endpoint: fields['endpoint'] ?? old.endpoint.toString(),
                apiKey: fields['api_key'] ?? old.apiKey,
                enabled: _boolField(fields, 'enabled', old.enabled),
                priority: fields['priority'] ?? '${old.priority}',
                categories: fields['categories'] ?? old.categories.join(','),
                allowInsecureHttp: _boolField(
                  fields,
                  'insecure_http',
                  old.allowInsecureHttp,
                ),
              );
              await _store(c).saveTorznabConfigs(<TorznabIndexerConfig>[
                for (final TorznabIndexerConfig config in _torznabConfigs(c))
                  config.id == id ? next : config,
              ]);
              return _torznabRecord(next);
            },
        remove: (SettingsContext c, String id) async {
          _requireTorznab(c, id);
          await _store(c).saveTorznabConfigs(<TorznabIndexerConfig>[
            for (final TorznabIndexerConfig config in _torznabConfigs(c))
              if (config.id != id) config,
          ]);
        },
      ),
    ),
  ],
);

// ── 下载落盘管道 ──────────────────────────────────────────────────────────────

Map<String, Object?> _mappingRecord(VideoDownloadBackendPathMappingConfig m) =>
    <String, Object?>{
      'id': videoDownloadPathMappingId(m),
      'backendProfileId': m.backendProfileId,
      'remoteRoot': m.remoteRoot,
      'localRoot': m.localRoot,
    };

List<VideoDownloadBackendPathMappingConfig> _mappings(SettingsContext c) =>
    c.appModel.prefsRepo.videoDownloadBackendPathMappings;

VideoDownloadBackendPathMappingConfig _buildMapping({
  required String profile,
  required String remote,
  required String local,
}) {
  final VideoDownloadBackendPathMappingConfig? mapping =
      videoDownloadPathMappingFromFields(
        backendProfileId: profile,
        remoteRoot: remote,
        localRoot: local,
      );
  if (mapping == null) {
    throw ArgumentError(
      '${t.video_download_path_mapping_invalid}（profile / remote_root 不能为空，'
      'local_root 必须是绝对路径）',
    );
  }
  return mapping;
}

void _requireUniqueMapping(
  List<VideoDownloadBackendPathMappingConfig> others,
  VideoDownloadBackendPathMappingConfig mapping,
) {
  final String id = videoDownloadPathMappingId(mapping);
  if (others.any(
    (VideoDownloadBackendPathMappingConfig m) =>
        videoDownloadPathMappingId(m) == id,
  )) {
    throw ArgumentError('已有同一后端 profile + 远端根的映射「$id」');
  }
}

VideoDownloadBackendPathMappingConfig _requireMapping(
  SettingsContext c,
  String id,
) {
  for (final VideoDownloadBackendPathMappingConfig m in _mappings(c)) {
    if (videoDownloadPathMappingId(m) == id) return m;
  }
  throw ArgumentError('没有 id 为「$id」的路径映射');
}

/// 目标视频来源的写法：`none` / 空串 = 不指定；否则是本机可用视频来源的 id。
Future<void> _writeTargetSource(SettingsContext c, String raw) async {
  final String value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == 'none') {
    await _store(c).saveTargetSourceId(null);
    return;
  }
  final int? id = int.tryParse(value);
  final VideoExternalSettingsSnapshot snapshot = await _store(c).load();
  final bool known = snapshot.managedVideoSources.any(
    (ManagedVideoSourceOption s) => s.id == id,
  );
  if (id == null || !known) {
    final String options = snapshot.managedVideoSources
        .map((ManagedVideoSourceOption s) => '${s.id}（${s.label}）')
        .join('、');
    throw ArgumentError(
      '「$value」不是可用的本机视频来源；可选：none'
      '${options.isEmpty ? '' : '、$options'}',
    );
  }
  await _store(c).saveTargetSourceId(id);
}

Future<Object?> _targetSourceCandidates(
  SettingsContext c,
  Map<String, String> args,
) async {
  final VideoExternalSettingsSnapshot snapshot = await _store(c).load();
  return <String, Object?>{
    'current': snapshot.targetSourceId?.toString() ?? 'none',
    'candidates': <Map<String, Object?>>[
      <String, Object?>{
        'value': 'none',
        'label': t.video_download_target_source_none,
      },
      for (final ManagedVideoSourceOption s in snapshot.managedVideoSources)
        <String, Object?>{
          'value': '${s.id}',
          'label': s.label,
          'rootPath': s.rootPath,
        },
    ],
  };
}

CtlBodyPage _downloadRoutingPage() => CtlBodyPage(
  breadcrumb: '${t.nav_downloads} › ${t.settings_downloads_routing_title}',
  visible: (SettingsContext c) => isSettingsDestinationVisible(
    SettingsDestinationId.downloads,
    c.appModel.moduleVisibility,
  ),
  items: <SettingsItem>[
    SettingsCustomItem(
      id: 'downloads.routing.cli.path_mappings',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_download_path_mappings_title,
      cliList: SettingsCliList(
        fields: const <SettingsCliParam>[
          SettingsCliParam(
            'profile',
            help: '下载后端 profile id；add 时省略 = 用当前 qB 配置推导出的 id',
            required: false,
          ),
          SettingsCliParam('remote_root', help: '后端看到的远端根路径', required: false),
          SettingsCliParam(
            'local_root',
            help: '本机对应的绝对路径',
            required: false,
            path: true,
          ),
        ],
        list: (SettingsContext c) async => <Map<String, Object?>>[
          for (final VideoDownloadBackendPathMappingConfig m in _mappings(c))
            _mappingRecord(m),
        ],
        add: (SettingsContext c, Map<String, String> fields) async {
          String profile = fields['profile'] ?? '';
          if (profile.trim().isEmpty) {
            profile = (await _store(c).load()).suggestedBackendProfileId;
          }
          final VideoDownloadBackendPathMappingConfig mapping = _buildMapping(
            profile: profile,
            remote: fields['remote_root'] ?? '',
            local: fields['local_root'] ?? '',
          );
          final List<VideoDownloadBackendPathMappingConfig> current = _mappings(
            c,
          );
          _requireUniqueMapping(current, mapping);
          await _store(c).savePathMappings(
            <VideoDownloadBackendPathMappingConfig>[...current, mapping],
          );
          return _mappingRecord(mapping);
        },
        update:
            (SettingsContext c, String id, Map<String, String> fields) async {
              final VideoDownloadBackendPathMappingConfig old = _requireMapping(
                c,
                id,
              );
              final VideoDownloadBackendPathMappingConfig next = _buildMapping(
                profile: fields['profile'] ?? old.backendProfileId,
                remote: fields['remote_root'] ?? old.remoteRoot,
                local: fields['local_root'] ?? old.localRoot,
              );
              final List<VideoDownloadBackendPathMappingConfig> others =
                  <VideoDownloadBackendPathMappingConfig>[
                    for (final VideoDownloadBackendPathMappingConfig m
                        in _mappings(c))
                      if (videoDownloadPathMappingId(m) != id) m,
                  ];
              _requireUniqueMapping(others, next);
              await _store(
                c,
              ).savePathMappings(<VideoDownloadBackendPathMappingConfig>[
                for (final VideoDownloadBackendPathMappingConfig m in _mappings(
                  c,
                ))
                  videoDownloadPathMappingId(m) == id ? next : m,
              ]);
              return _mappingRecord(next);
            },
        remove: (SettingsContext c, String id) async {
          _requireMapping(c, id);
          await _store(
            c,
          ).savePathMappings(<VideoDownloadBackendPathMappingConfig>[
            for (final VideoDownloadBackendPathMappingConfig m in _mappings(c))
              if (videoDownloadPathMappingId(m) != id) m,
          ]);
        },
      ),
    ),
    SettingsCustomItem(
      id: 'downloads.routing.cli.target_source',
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.video_download_target_source_title,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) =>
            c.appModel.prefsRepo.videoDownloadTargetSourceId?.toString() ??
            'none',
        write: _writeTargetSource,
        help:
            'none = 不指定；或本机视频来源 id（候选见 `config run downloads.routing.cli.target_source_candidates`）',
      ),
    ),
    SettingsActionItem(
      id: 'downloads.routing.cli.target_source_candidates',
      title: '${t.video_download_target_source_title} · candidates',
      onTap: (SettingsContext c) async {
        await _targetSourceCandidates(c, const <String, String>{});
      },
      cli: const SettingsCliAction(run: _targetSourceCandidates),
    ),
  ],
);

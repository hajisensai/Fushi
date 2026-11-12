import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/media/tracking/plugin/bangumi_token_migration.dart'
    show signInBundledBangumiWithToken;
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

/// 设置 →「媒体追踪」页（`MediaTrackingSettingsBody`，经 `SettingsDestination.body`
/// 逃生口渲染）在控制通道上的条目。
///
/// `connect` signs in Bangumi (a personal access token, not browser OAuth);
/// `search` and `mappings` work on any connected site (`site`, default
/// `bangumi`).
///
/// 这些条目操作 Bangumi，连接方式是**个人访问令牌**（不是浏览器 OAuth：
/// 令牌在 [BangumiApiClient.accessTokenUrl] 由用户自己生成后粘贴），所以 CLI 用
/// `connect` 动作经 `--secret-stdin` / `--secret-from-env` 收令牌即可，无需回调。
/// Both ways the `bangumi` site is served work the same here: the built-in
/// provider (token in preferences) or the bundled Bangumi plugin (the token
/// goes to the plugin's sign-in; search and lookup through the site's
/// [TrackingSubjectSearch]). The service says which (`usesBuiltInBangumi`).
///
/// - `media_tracking.cli.status`：连接状态 / 待同步 / 上次同步 / 失败原因 / 待手动关联；
/// - `media_tracking.cli.connect`：校验令牌 → 落盘 → 记账号名 → 立即同步（同页面「连接」）；
/// - `media_tracking.cli.sync_now`：立即同步；
/// - `media_tracking.cli.search`：在追踪站点搜条目（建映射前找 subject id）；
/// - `media_tracking.cli.local_targets`：可建映射的本地条目；
/// - `media_tracking.cli.mappings`（`config items … ls|add|rm`）：映射列表、手动添加
///   （保存后立即同步，同页面对话框）、删除。
const String kCtlTrackingIdPrefix = 'media_tracking.cli.';

String _id(String name) => '$kCtlTrackingIdPrefix$name';

MediaTrackingService _service(SettingsContext c) =>
    c.appModel.mediaTrackingService;

/// The registered site [siteId] (default `bangumi`); throws for an unknown id.
TrackingProvider _site(SettingsContext c, String? siteId) {
  final String id = (siteId ?? '').trim().isEmpty
      ? kTrackingProviderBangumi
      : siteId!.trim();
  final TrackingProvider? provider = _service(c).providers.byId(id);
  if (provider == null) {
    final String known = _service(
      c,
    ).providers.all.map((TrackingProvider p) => p.id).join(' | ');
    throw ArgumentError('Unknown site "$id" (one of: $known)');
  }
  return provider;
}

/// Throws unless [provider] is signed in. Bangumi asks the service (built-in
/// or bundled plugin), other sites ask the provider.
void _requireConfigured(SettingsContext c, TrackingProvider provider) {
  final bool configured = provider.id == kTrackingProviderBangumi
      ? _service(c).isConfigured
      : provider.isConfigured;
  if (configured) return;
  throw StateError(
    provider.id == kTrackingProviderBangumi
        ? 'Not signed in to Bangumi (run config run ${_id('connect')} '
              '--secret-stdin first)'
        : '${provider.displayName} is not signed in (sign in from Settings '
              '> Media tracking first)',
  );
}

const SettingsCliParam _siteParam = SettingsCliParam(
  'site',
  help: 'Tracking site id: bangumi or a tracking plugin site; default bangumi',
  required: false,
);

List<CtlBodyPage> buildCtlTrackingBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.settings_destination_tracking,
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.mediaTracking,
      c.appModel.moduleVisibility,
    ),
    items: <SettingsItem>[
      _action(
        id: 'status',
        title: t.media_tracking_status_title,
        subtitle: t.media_tracking_sync_section,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            final MediaTrackingService service = _service(c);
            return mediaTrackingStatusRecord(
              await service.loadStatus(),
              home: await service.loadHomeSnapshot(),
              rowFacts: await loadTrackingRowFacts(c.appModel.database),
              sites: await service.loadProviderStatuses(),
              siteName: (String id) =>
                  service.providers.byId(id)?.displayName ?? id,
            );
          },
        ),
      ),
      _action(
        id: 'connect',
        title: t.media_tracking_connect,
        subtitle: t.media_tracking_access_token_hint,
        cli: SettingsCliAction(
          run: _connect,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'token',
              help:
                  'Bangumi personal access token (create one at ${BangumiApiClient.accessTokenUrl})',
              secret: true,
            ),
          ],
        ),
      ),
      _action(
        id: 'sync_now',
        title: t.media_tracking_sync_now,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            if (!(await _service(c).loadProviderStatuses()).any(
              (MediaTrackingProviderStatus s) => s.enabled && s.configured,
            )) {
              _requireConfigured(c, _site(c, null));
            }
            return _syncRecord(await _service(c).syncNow(force: true));
          },
        ),
      ),
      _action(
        id: 'search',
        title: t.media_tracking_search_site,
        cli: SettingsCliAction(
          run: _search,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'keyword',
              help: 'Search keyword (a title), a subject id or a site link',
            ),
            SettingsCliParam(
              'kind',
              help: 'anime | novel | manga | game; default anime',
              required: false,
            ),
            _siteParam,
          ],
        ),
      ),
      _action(
        id: 'local_targets',
        title: t.media_tracking_local_item,
        cli: SettingsCliAction(
          run: _localTargets,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'query',
              help:
                  'Filter by title (contains, case-insensitive); omit for all',
              required: false,
            ),
          ],
        ),
      ),
      SettingsCustomItem(
        id: _id('mappings'),
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.media_tracking_mappings,
        cliList: SettingsCliList(
          list: (SettingsContext c) async {
            final MediaTrackingService service = _service(c);
            final MediaTrackingStatus status = await service.loadStatus();
            final Map<int, MediaTrackingFailure> failures =
                status.failureByMappingId;
            return <Map<String, Object?>>[
              for (final MediaTrackingMappingRow m
                  in (await service.loadHomeSnapshot()).mappings)
                <String, Object?>{
                  ..._mappingRecord(m),
                  if (failures[m.id] case final MediaTrackingFailure f)
                    'lastError': f.error,
                },
            ];
          },
          add: _addMapping,
          remove: (SettingsContext c, String id) async {
            final int? mappingId = int.tryParse(id);
            final MediaTrackingMappingRow? mapping = mappingId == null
                ? null
                : (await _service(c).loadHomeSnapshot()).mappings
                      .where((MediaTrackingMappingRow m) => m.id == mappingId)
                      .firstOrNull;
            if (mapping == null) {
              throw ArgumentError('No link "$id" (see the id column of ls)');
            }
            await _service(c).removeLink(mapping);
          },
          fields: const <SettingsCliParam>[
            SettingsCliParam(
              'media_type',
              help:
                  'Local item type: video | video_collection | book | game (see local_targets)',
            ),
            SettingsCliParam(
              'media_key',
              help: 'Local item key (the key column of local_targets)',
            ),
            SettingsCliParam(
              'subject_id',
              help: 'Subject id on the site (see search)',
            ),
            SettingsCliParam(
              'subject_name',
              help:
                  'Subject name; omit to look it up on the site by subject_id',
              required: false,
            ),
            SettingsCliParam(
              'kind',
              help:
                  'anime | novel | manga | game; omit for the local type default',
              required: false,
            ),
            SettingsCliParam(
              'progress_mode',
              help:
                  'episode | chapter | volume | status; omit for the local type default',
              required: false,
            ),
            SettingsCliParam(
              'progress_offset',
              help:
                  'Local 0-based number plus this offset = remote progress; always 0 in status mode',
              required: false,
            ),
            _siteParam,
          ],
        ),
      ),
    ],
  ),
];

// ── 执行体 ──────────────────────────────────────────────────────────────────

Future<Object?> _connect(SettingsContext c, Map<String, String> args) async {
  final String token = (args['token'] ?? '').trim();
  if (token.isEmpty) throw ArgumentError('A Bangumi access token is required');
  if (!_service(c).usesBuiltInBangumi) {
    // The bundled Bangumi plugin serves the site: its sign-in checks and
    // keeps the token (the same as its row in Settings).
    final String account = await signInBundledBangumiWithToken(
      c.appModel.trackingPluginProviders,
      token,
    );
    final MediaTrackingSyncResult sync = await _service(c).syncNow(force: true);
    return <String, Object?>{'account': account, 'sync': _syncRecord(sync)};
  }
  // 校验 + 落令牌 + 记账号名是服务层的一次原子「连接」，与页面同一入口。
  final BangumiUser user = await _service(c).connect(token);
  final MediaTrackingSyncResult sync = await _service(c).syncNow(force: true);
  return <String, Object?>{
    'account': user.nickname.trim().isEmpty ? user.username : user.nickname,
    'username': user.username,
    'sync': _syncRecord(sync),
  };
}

Future<Object?> _search(SettingsContext c, Map<String, String> args) async {
  final TrackingProvider site = _site(c, args['site']);
  _requireConfigured(c, site);
  final String keyword = (args['keyword'] ?? '').trim();
  if (keyword.isEmpty) throw ArgumentError('keyword must not be empty');
  final TrackingKind kind = args['kind'] == null
      ? TrackingKind.anime
      : _parseKind(args['kind']!);
  final List<TrackingSearchHit> results = await _service(
    c,
  ).searchSiteSubjects(providerId: site.id, kind: kind, query: keyword);
  return <Map<String, Object?>>[
    for (final TrackingSearchHit s in results)
      <String, Object?>{
        'id': s.subjectId,
        'name': s.name,
        if (s.altName.isNotEmpty) 'secondaryName': s.altName,
        'episodes': s.episodeCount ?? 0,
        'volumes': s.finalVolume ?? 0,
      },
  ];
}

Future<Object?> _localTargets(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String query = (args['query'] ?? '').trim().toLowerCase();
  final List<MediaTrackingLocalTarget> targets =
      await loadMediaTrackingLocalTargets(c.appModel.database);
  return <Map<String, Object?>>[
    for (final MediaTrackingLocalTarget target in targets)
      if (query.isEmpty || target.title.toLowerCase().contains(query))
        <String, Object?>{
          'media_type': target.type.value,
          'key': target.key,
          'title': target.title,
          'kinds': <String>[
            for (final TrackingKind k in allowedTrackingKindsFor(target.type))
              k.value,
          ],
          'progress_modes': <String>[
            for (final TrackingProgressMode m in allowedTrackingModesFor(
              target.type,
            ))
              m.value,
          ],
        },
  ];
}

Future<Object?> _addMapping(
  SettingsContext c,
  Map<String, String> fields,
) async {
  final TrackingProvider site = _site(c, fields['site']);
  _requireConfigured(c, site);
  final TrackingMediaType type = _parseMediaType(
    _required(fields, 'media_type'),
  );
  final String key = _required(fields, 'media_key');
  final int? subjectId = int.tryParse(_required(fields, 'subject_id'));
  if (subjectId == null || subjectId <= 0) {
    throw ArgumentError('subject_id must be a positive integer');
  }
  final List<MediaTrackingLocalTarget> targets =
      await loadMediaTrackingLocalTargets(c.appModel.database);
  final MediaTrackingLocalTarget? target = targets
      .where((MediaTrackingLocalTarget t) => t.type == type && t.key == key)
      .firstOrNull;
  if (target == null) {
    throw ArgumentError('No local item ${type.value}:$key (see local_targets)');
  }
  final TrackingKind kind = fields['kind'] == null
      ? defaultTrackingKindFor(type)
      : _parseKind(fields['kind']!);
  if (!allowedTrackingKindsFor(type).contains(kind)) {
    throw ArgumentError('${type.value} cannot use kind=${kind.value}');
  }
  if (!_service(c).manualLinkSitesFor(kind).contains(site)) {
    throw ArgumentError(
      '${site.id} cannot take a hand link for kind=${kind.value} (signed in, '
      'kind switched on and searchable are required)',
    );
  }
  final TrackingProgressMode mode = fields['progress_mode'] == null
      ? defaultTrackingModeFor(type)
      : (TrackingProgressMode.tryParse(fields['progress_mode']!) ??
            (throw ArgumentError(
              'progress_mode must be episode | chapter | volume | status',
            )));
  if (!allowedTrackingModesFor(type).contains(mode)) {
    throw ArgumentError('${type.value} cannot use progress_mode=${mode.value}');
  }
  int? offset;
  final String? rawOffset = fields['progress_offset'];
  if (rawOffset != null) {
    offset = int.tryParse(rawOffset);
    if (offset == null) {
      throw ArgumentError('progress_offset must be an integer');
    }
  }
  final String subjectName = (fields['subject_name'] ?? '').trim().isNotEmpty
      ? fields['subject_name']!.trim()
      : await _subjectName(c, site, subjectId, kind);
  final MediaTrackingSyncResult sync = await _service(c)
      .saveManualMappingAndSync(
        mediaType: type,
        mediaKey: key,
        mediaTitle: target.title,
        kind: kind,
        subjectId: subjectId,
        subjectName: subjectName,
        progressMode: mode,
        progressOffset: normalizeTrackingProgressOffset(mode, offset),
        provider: site.id,
      );
  final MediaTrackingHomeSnapshot home = await _service(c).loadHomeSnapshot();
  final MediaTrackingMappingRow? saved = home.mappings
      .where(
        (MediaTrackingMappingRow m) =>
            m.mediaType == type.value &&
            m.mediaKey == key &&
            m.provider == site.id,
      )
      .firstOrNull;
  return <String, Object?>{
    if (saved != null) ..._mappingRecord(saved),
    'sync': _syncRecord(sync),
  };
}

/// The name of subject [subjectId] of [kind] on [site], looked up on the site.
/// Throws when the subject does not exist or is of another kind.
Future<String> _subjectName(
  SettingsContext c,
  TrackingProvider site,
  int subjectId,
  TrackingKind kind,
) async {
  final List<TrackingSearchHit> found = await _service(
    c,
  ).searchSiteSubjects(providerId: site.id, kind: kind, query: '$subjectId');
  if (found.isEmpty) {
    throw ArgumentError(
      '${site.displayName} has no ${kind.value} subject $subjectId',
    );
  }
  return found.first.name;
}

// ── 记录 / 解析 ─────────────────────────────────────────────────────────────

Map<String, Object?> _failureRecord(MediaTrackingFailure f) =>
    <String, Object?>{
      'mappingId': f.mappingId,
      'title': f.mediaTitle,
      'subjectId': f.subjectId,
      'attempts': f.attemptCount,
      'error': f.error,
    };

/// 状态快照的 JSON 形态（不含令牌）：每个站点各自一条（[sites]，内置
/// Bangumi 与插件站点同口径，`MediaTrackingService.loadProviderStatuses`），
/// 顶层字段是全部已登录站点的汇总（任一已登录 / 待发送合计 / 最近一次同步 /
/// 任一登录失效），链接数与待手动关联覆盖所有站点。
Map<String, Object?> mediaTrackingStatusRecord(
  MediaTrackingStatus status, {
  MediaTrackingHomeSnapshot? home,
  TrackingRowFacts rowFacts = TrackingRowFacts.empty,
  required List<MediaTrackingProviderStatus> sites,
  required String Function(String providerId) siteName,
}) {
  final DateTime now = DateTime.now();
  final List<MediaTrackingProviderStatus> active =
      <MediaTrackingProviderStatus>[
        for (final MediaTrackingProviderStatus site in sites)
          if (site.enabled && site.configured) site,
      ];
  final int lastSyncAt = active.fold<int>(
    0,
    (int at, MediaTrackingProviderStatus site) =>
        site.lastSyncAt > at ? site.lastSyncAt : at,
  );
  return <String, Object?>{
    'configured': active.isNotEmpty,
    'unauthorized': active.any(
      (MediaTrackingProviderStatus site) => site.unauthorized,
    ),
    'pending': active.fold<int>(
      0,
      (int n, MediaTrackingProviderStatus site) => n + site.pending,
    ),
    'lastSyncAt': lastSyncAt,
    'lastSync': trackingLastSyncAtLabel(lastSyncAt, now),
    'mappings': (home?.mappings ?? status.mappings).length,
    'sites': <Map<String, Object?>>[
      for (final MediaTrackingProviderStatus site in sites)
        <String, Object?>{
          'id': site.providerId,
          'name': siteName(site.providerId),
          'enabled': site.enabled,
          'configured': site.configured,
          'account': site.accountName,
          'unauthorized': site.unauthorized,
          'pending': site.pending,
          'lastSyncAt': site.lastSyncAt,
          'lastSync': trackingSiteLastSyncLabel(site, now),
          'lastSucceeded': site.lastSucceeded,
          'lastFailed': site.lastFailed,
          'failures': <Map<String, Object?>>[
            for (final MediaTrackingFailure f in site.failures)
              _failureRecord(f),
          ],
        },
    ],
    'failures': <Map<String, Object?>>[
      for (final MediaTrackingProviderStatus site in active)
        for (final MediaTrackingFailure f in site.failures)
          <String, Object?>{'site': site.providerId, ..._failureRecord(f)},
    ],
    'unlinked': <Map<String, Object?>>[
      for (final MediaTrackingUnlinkedItem u
          in home?.unlinked ?? status.unlinked)
        <String, Object?>{
          'media_type': u.mediaType.value,
          'key': u.mediaKey,
          'title': u.mediaTitle,
          // What the Tracking page labels the row (Anime / Live action /
          // Video / ...); `siteKind` is what a site would track it as.
          'kind': _rowKindName(
            trackingRowKindOf(
              u.kind,
              nature: rowFacts.of(u.mediaType.value, u.mediaKey).nature,
            ),
            u.kind,
          ),
          'siteKind': u.kind.value,
        },
    ],
    'accessTokenUrl': BangumiApiClient.accessTokenUrl,
    'signupUrl': BangumiApiClient.signupUrl,
  };
}

/// [rowKind] as snake_case (`live_action`); [fallback]'s value when null.
String _rowKindName(TrackingRowKind? rowKind, TrackingKind fallback) =>
    switch (rowKind) {
      TrackingRowKind.liveAction => 'live_action',
      final TrackingRowKind k => k.name,
      null => fallback.value,
    };

Map<String, Object?> _mappingRecord(MediaTrackingMappingRow m) =>
    <String, Object?>{
      'id': '${m.id}',
      'title': m.mediaTitle,
      'site': m.provider,
      'media_type': m.mediaType,
      'media_key': m.mediaKey,
      'kind': m.kind,
      'subject_id': m.subjectId,
      'subject_name': m.subjectName,
      'progress_mode': m.progressMode,
      'progress_offset': m.progressOffset,
      'summary': trackingMappingSubtitle(m),
    };

Map<String, Object?> _syncRecord(MediaTrackingSyncResult r) =>
    <String, Object?>{
      'success': r.isSuccess,
      'succeeded': r.succeeded,
      'failed': r.failed,
      'pending': r.pending,
      'unauthorized': r.unauthorized,
    };

String _required(Map<String, String> fields, String name) {
  final String value = (fields[name] ?? '').trim();
  if (value.isEmpty) throw ArgumentError('Missing field $name');
  return value;
}

TrackingKind _parseKind(String raw) {
  for (final TrackingKind kind in TrackingKind.values) {
    if (kind.value == raw.trim()) return kind;
  }
  throw ArgumentError('kind must be anime | novel | manga | game, got "$raw"');
}

TrackingMediaType _parseMediaType(String raw) {
  for (final TrackingMediaType type in TrackingMediaType.values) {
    // bookChapter 是卷映射的伴随行，不是用户可建的独立映射。
    if (type == TrackingMediaType.bookChapter) continue;
    // Media server episodes link from server ids, not by hand here.
    if (type == TrackingMediaType.remoteVideo ||
        type == TrackingMediaType.remoteSeries) {
      continue;
    }
    // Only a do-not-track key, never a link.
    if (type == TrackingMediaType.bookCollection) continue;
    if (type.value == raw) return type;
  }
  throw ArgumentError(
    'media_type must be video | video_collection | book | game, got "$raw"',
  );
}

SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  String? subtitle,
}) {
  final SettingsCliRun run = cli.run!;
  return SettingsActionItem(
    id: _id(id),
    title: title,
    subtitle: subtitle,
    cli: cli,
    // 控制通道只走 cli.run；onTap 是同一份实现的兜底（无参数时）。
    onTap: (SettingsContext c) async {
      await run(c, const <String, String>{});
    },
  );
}

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

/// 设置 →「媒体追踪」页（`MediaTrackingSettingsBody`，经 `SettingsDestination.body`
/// 逃生口渲染）在控制通道上的条目。
///
/// 页面只有 Bangumi 一个提供方，连接方式是**个人访问令牌**（不是浏览器 OAuth：
/// 令牌在 [BangumiApiClient.accessTokenUrl] 由用户自己生成后粘贴），所以 CLI 用
/// `connect` 动作经 `--secret-stdin` / `--secret-from-env` 收令牌即可，无需回调。
///
/// - `media_tracking.cli.status`：连接状态 / 待同步 / 上次同步 / 失败原因 / 待手动关联；
/// - `media_tracking.cli.connect`：校验令牌 → 落盘 → 记账号名 → 立即同步（同页面「连接」）；
/// - `media_tracking.cli.sync_now`：立即同步；
/// - `media_tracking.cli.search`：在 Bangumi 搜条目（建映射前找 subject id）；
/// - `media_tracking.cli.local_targets`：可建映射的本地条目；
/// - `media_tracking.cli.mappings`（`config items … ls|add|rm`）：映射列表、手动添加
///   （保存后立即同步，同页面对话框）、删除。
const String kCtlTrackingIdPrefix = 'media_tracking.cli.';

String _id(String name) => '$kCtlTrackingIdPrefix$name';

MediaTrackingService _service(SettingsContext c) =>
    c.appModel.mediaTrackingService;

void _requireConfigured(SettingsContext c) {
  if (!_service(c).isConfigured) {
    throw StateError(
      '${t.media_tracking_token_required}（先 config run ${_id('connect')} '
      '--secret-stdin）',
    );
  }
}

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
        title: t.media_tracking_account,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async =>
              mediaTrackingStatusRecord(await _service(c).loadStatus()),
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
              help: 'Bangumi 个人访问令牌（在 ${BangumiApiClient.accessTokenUrl} 生成）',
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
            _requireConfigured(c);
            return _syncRecord(await _service(c).syncNow(force: true));
          },
        ),
      ),
      _action(
        id: 'search',
        title: t.media_tracking_search,
        cli: SettingsCliAction(
          run: _search,
          params: const <SettingsCliParam>[
            SettingsCliParam('keyword', help: '搜索关键词（作品名）'),
            SettingsCliParam(
              'kind',
              help: 'anime | novel | manga | game；默认 anime',
              required: false,
            ),
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
              help: '按标题过滤（包含即命中，不分大小写）；省略 = 全部',
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
            final MediaTrackingStatus status = await _service(c).loadStatus();
            final Map<int, MediaTrackingFailure> failures =
                status.failureByMappingId;
            return <Map<String, Object?>>[
              for (final MediaTrackingMappingRow m in status.mappings)
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
            final MediaTrackingStatus status = await _service(c).loadStatus();
            if (mappingId == null ||
                !status.mappings.any(
                  (MediaTrackingMappingRow m) => m.id == mappingId,
                )) {
              throw ArgumentError('没有映射「$id」（见 ls 的 id 列）');
            }
            await MediaTrackingRepository(
              c.appModel.database,
            ).deleteMapping(mappingId);
            _service(c).notifyStatusChanged();
          },
          fields: const <SettingsCliParam>[
            SettingsCliParam(
              'media_type',
              help:
                  '本地条目类型：video | video_collection | book | game（见 local_targets）',
            ),
            SettingsCliParam(
              'media_key',
              help: '本地条目 key（见 local_targets 的 key 列）',
            ),
            SettingsCliParam('subject_id', help: 'Bangumi 条目 id（见 search）'),
            SettingsCliParam(
              'subject_name',
              help: '条目名；省略 = 按 subject_id 向 Bangumi 查',
              required: false,
            ),
            SettingsCliParam(
              'kind',
              help: 'anime | novel | manga | game；省略 = 按本地类型默认',
              required: false,
            ),
            SettingsCliParam(
              'progress_mode',
              help: 'episode | chapter | volume | status；省略 = 按本地类型默认',
              required: false,
            ),
            SettingsCliParam(
              'progress_offset',
              help: '本地 0 起序号加此偏移 = 远端进度；status 模式恒 0',
              required: false,
            ),
          ],
        ),
      ),
    ],
  ),
];

// ── 执行体 ──────────────────────────────────────────────────────────────────

Future<Object?> _connect(SettingsContext c, Map<String, String> args) async {
  final String token = (args['token'] ?? '').trim();
  if (token.isEmpty) throw ArgumentError(t.media_tracking_token_required);
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
  _requireConfigured(c);
  final String keyword = (args['keyword'] ?? '').trim();
  if (keyword.isEmpty) throw ArgumentError('keyword 不能为空');
  final TrackingKind kind = args['kind'] == null
      ? TrackingKind.anime
      : _parseKind(args['kind']!);
  final List<BangumiSubject> results = await _service(
    c,
  ).searchSubjects(keyword: keyword, kind: kind);
  return <Map<String, Object?>>[
    for (final BangumiSubject s in results)
      <String, Object?>{
        'id': s.id,
        'name': s.displayName,
        if (s.secondaryName.isNotEmpty) 'secondaryName': s.secondaryName,
        'episodes': s.episodeCount,
        'volumes': s.volumeCount,
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
  _requireConfigured(c);
  final TrackingMediaType type = _parseMediaType(
    _required(fields, 'media_type'),
  );
  final String key = _required(fields, 'media_key');
  final int? subjectId = int.tryParse(_required(fields, 'subject_id'));
  if (subjectId == null || subjectId <= 0) {
    throw ArgumentError('subject_id 必须是正整数');
  }
  final List<MediaTrackingLocalTarget> targets =
      await loadMediaTrackingLocalTargets(c.appModel.database);
  final MediaTrackingLocalTarget? target = targets
      .where((MediaTrackingLocalTarget t) => t.type == type && t.key == key)
      .firstOrNull;
  if (target == null) {
    throw ArgumentError('没有本地条目 ${type.value}:$key（见 local_targets）');
  }
  final TrackingKind kind = fields['kind'] == null
      ? defaultTrackingKindFor(type)
      : _parseKind(fields['kind']!);
  if (!allowedTrackingKindsFor(type).contains(kind)) {
    throw ArgumentError('${type.value} 不能用 kind=${kind.value}');
  }
  final TrackingProgressMode mode = fields['progress_mode'] == null
      ? defaultTrackingModeFor(type)
      : (TrackingProgressMode.tryParse(fields['progress_mode']!) ??
            (throw ArgumentError(
              'progress_mode 只能是 episode | chapter | volume | status',
            )));
  if (!allowedTrackingModesFor(type).contains(mode)) {
    throw ArgumentError('${type.value} 不能用 progress_mode=${mode.value}');
  }
  int? offset;
  final String? rawOffset = fields['progress_offset'];
  if (rawOffset != null) {
    offset = int.tryParse(rawOffset);
    if (offset == null) throw ArgumentError('progress_offset 必须是整数');
  }
  final String subjectName = (fields['subject_name'] ?? '').trim().isNotEmpty
      ? fields['subject_name']!.trim()
      : (await _service(c).getSubject(subjectId)).displayName;
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
      );
  final MediaTrackingStatus status = await _service(c).loadStatus();
  final MediaTrackingMappingRow? saved = status.mappings
      .where(
        (MediaTrackingMappingRow m) =>
            m.mediaType == type.value && m.mediaKey == key,
      )
      .firstOrNull;
  return <String, Object?>{
    if (saved != null) ..._mappingRecord(saved),
    'sync': _syncRecord(sync),
  };
}

// ── 记录 / 解析 ─────────────────────────────────────────────────────────────

/// 状态快照的 JSON 形态（不含令牌）。
Map<String, Object?> mediaTrackingStatusRecord(MediaTrackingStatus status) =>
    <String, Object?>{
      'configured': status.configured,
      'account': status.accountName,
      'unauthorized': status.unauthorized,
      'pending': status.pending,
      'lastSyncAt': status.lastSyncAt,
      'lastSync': trackingLastSyncLabel(status, DateTime.now()),
      'lastSucceeded': status.lastSucceeded,
      'lastFailed': status.lastFailed,
      'mappings': status.mappings.length,
      'failures': <Map<String, Object?>>[
        for (final MediaTrackingFailure f in status.failures)
          <String, Object?>{
            'mappingId': f.mappingId,
            'title': f.mediaTitle,
            'subjectId': f.subjectId,
            'attempts': f.attemptCount,
            'error': f.error,
          },
      ],
      'unlinked': <Map<String, Object?>>[
        for (final MediaTrackingUnlinkedItem u in status.unlinked)
          <String, Object?>{
            'media_type': u.mediaType.value,
            'key': u.mediaKey,
            'title': u.mediaTitle,
            'kind': u.kind.value,
          },
      ],
      'accessTokenUrl': BangumiApiClient.accessTokenUrl,
      'signupUrl': BangumiApiClient.signupUrl,
    };

Map<String, Object?> _mappingRecord(MediaTrackingMappingRow m) =>
    <String, Object?>{
      'id': '${m.id}',
      'title': m.mediaTitle,
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
  if (value.isEmpty) throw ArgumentError('缺少字段 $name');
  return value;
}

TrackingKind _parseKind(String raw) {
  for (final TrackingKind kind in TrackingKind.values) {
    if (kind.value == raw.trim()) return kind;
  }
  throw ArgumentError('kind 只能是 anime | novel | manga | game，收到「$raw」');
}

TrackingMediaType _parseMediaType(String raw) {
  for (final TrackingMediaType type in TrackingMediaType.values) {
    // bookChapter 是卷映射的伴随行，不是用户可建的独立映射。
    if (type == TrackingMediaType.bookChapter) continue;
    if (type.value == raw) return type;
  }
  throw ArgumentError(
    'media_type 只能是 video | video_collection | book | game，收到「$raw」',
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

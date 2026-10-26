import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 在线源（扩展仓库 / 扩展 / 在线漫画·小说·视频源 / 发现源）以及同一路由文件里的
/// 播放遥控、顶层导航的操作描述（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §4、§5.2、D9）。路由在 `ctl_online_routes.dart`；在线源的两个下载队列（漫画章节 /
/// 视频源剧集）与 CLI 小说下载任务归 `op_descriptions_downloads.dart`。
///
/// - 装扩展、更新扩展、添加仓库一律 `confirm: true`（D9）。
/// - 一条路由服务三个生态（`kind`），风险级按最坏的那个生态定：LNReader 卸载插件会
///   连插件存储（登录态）一起删，所以卸载扩展是 irreversible。
/// - iOS 合规：可用性只认 [StoreRestrictedCapability]。
List<OpDescription> describeOnlineOps(OpDescribeKit kit) {
  final _OnlineUndo u = _OnlineUndo(kit);
  final OpAvailability Function() anyOnline =
      _anyStore(const <StoreRestrictedCapability>[
        StoreRestrictedCapability.onlineMangaSource,
        StoreRestrictedCapability.onlineVideoSource,
        StoreRestrictedCapability.onlineNovelSource,
      ]);
  final OpAvailability Function() discovery = kit.whenStoreAllows(
    StoreRestrictedCapability.externalDiscovery,
  );
  return <OpDescription>[
    // ── 扩展仓库 ──────────────────────────────────────────────────────────
    OpDescription(
      id: 'online.repo.list',
      method: 'GET',
      pattern: '/api/admin/extensions/repos',
      summary:
          'List the extension repositories configured for one ecosystem '
          '(manga = Mihon, anime = Aniyomi, novel = LNReader) with sync errors.',
      params: const <OpParam>[_kind],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.repo.add',
      method: 'POST',
      pattern: '/api/admin/extensions/repos',
      summary:
          'Add an extension repository URL and fetch its catalog. Always asks '
          'the user first. Plain-http Mihon/Aniyomi repositories are only added '
          'after the user explicitly trusts the insecure URL on the confirmation '
          'card. Undo removes the repository again.',
      risk: OpRisk.write,
      confirm: true,
      params: const <OpParam>[
        _kind,
        OpParam.string(
          'url',
          description: 'Repository index URL (https preferred).',
          required: true,
        ),
        OpParam.userGate(
          'allowInsecure',
          description: 'User trusted a plain-http repository URL.',
        ),
      ],
      availability: anyOnline,
      undo: u.repoAddUndo(),
    ),
    OpDescription(
      id: 'online.repo.remove',
      method: 'DELETE',
      pattern: '/api/admin/extensions/repos',
      summary:
          'Remove an extension repository (installed extensions stay installed). '
          'Undo adds the same URL back and re-syncs it.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _kind,
        OpParam.string(
          'url',
          description: 'Repository URL exactly as listed by online.repo.list.',
          required: true,
        ),
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: anyOnline,
      undo: u.repoRemoveUndo(),
    ),
    OpDescription(
      id: 'online.repo.sync',
      method: 'POST',
      pattern: '/api/admin/extensions/repos/sync',
      summary:
          'Re-fetch every repository catalog of one ecosystem (refreshes the '
          'list of installable extensions and update badges; installs nothing).',
      params: const <OpParam>[_kind],
      availability: anyOnline,
    ),
    // ── 扩展 ──────────────────────────────────────────────────────────────
    OpDescription(
      id: 'online.extension.list',
      method: 'GET',
      pattern: '/api/admin/extensions',
      summary:
          'List installed extensions (version, enabled, hasUpdate); with '
          'available=true also the installable catalog from the repositories.',
      params: const <OpParam>[
        _kind,
        OpParam.boolean(
          'available',
          description: 'Include the repository catalog (not-yet-installed).',
        ),
        OpParam.string(
          'query',
          description: 'Filter by name or id substring (case-insensitive).',
        ),
        OpParam.string(
          'lang',
          description: 'Filter by language code, e.g. "ja".',
        ),
      ],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.extension.install',
      method: 'POST',
      pattern: '/api/admin/extensions/install',
      summary:
          'Install an extension from a configured repository (third-party code). '
          'Always asks the user first; the card shows name, repository and signer. '
          'A Mihon/Aniyomi extension whose signer is not yet trusted is only '
          'installed when the user explicitly trusts that signer on the card. '
          'Undo uninstalls it (only if it was not installed before).',
      risk: OpRisk.write,
      confirm: true,
      params: const <OpParam>[
        _kind,
        OpParam.string(
          'id',
          description:
              'Extension package name / plugin id from '
              'online.extension.list (available=true).',
          required: true,
        ),
        OpParam.userGate(
          'trustSigner',
          description:
              'User trusted the extension signer (SHA-256 shown on the card).',
        ),
      ],
      availability: anyOnline,
      undo: u.extensionInstallUndo(),
    ),
    OpDescription(
      id: 'online.extension.update',
      method: 'POST',
      pattern: '/api/admin/extensions/update',
      summary:
          'Update installed extensions that have a newer catalog version (all of '
          'one ecosystem, or just id). Never trusts a changed signer: those land in '
          '"failed". Always asks first; cannot be undone because the previous '
          'version is not kept.',
      risk: OpRisk.irreversible,
      confirm: true,
      params: const <OpParam>[
        _kind,
        OpParam.string(
          'id',
          description: 'Only update this extension id; omit for all updatable.',
        ),
      ],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.extension.remove',
      method: 'DELETE',
      pattern: '/api/admin/extensions/:id',
      summary:
          'Uninstall an extension. Mihon/Aniyomi keep source preferences unless '
          'clearData=true; LNReader (novel) always deletes the plugin storage '
          '(login state). Cannot be undone, so the user confirms.',
      risk: OpRisk.irreversible,
      availability: anyOnline,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Installed extension id from online.extension.list.',
          required: true,
          inPath: true,
        ),
        _kind,
        OpParam.boolean(
          'clearData',
          description:
              'Mihon/Aniyomi only: also clear the sources\' saved preferences.',
        ),
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
    ),
    OpDescription(
      id: 'online.extension.set-enabled',
      method: 'POST',
      pattern: '/api/admin/extensions/:id/enabled',
      summary:
          'Enable or disable an installed extension (disabling hides all of its '
          'sources). Undo restores the previous state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Installed extension id from online.extension.list.',
          required: true,
          inPath: true,
        ),
        _kind,
        OpParam.boolean('enabled', description: 'true = on.', required: true),
      ],
      availability: anyOnline,
      undo: u.extensionEnabledUndo(),
    ),
    // ── 在线源 ────────────────────────────────────────────────────────────
    OpDescription(
      id: 'online.source.list',
      method: 'GET',
      pattern: '/api/admin/sources',
      summary:
          'List the online sources provided by installed extensions '
          '(id, name, language, enabled, pinned).',
      params: const <OpParam>[_kind],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.search',
      method: 'GET',
      pattern: '/api/admin/sources/:sourceId/search',
      summary:
          'Search works in one enabled online source. Returns url/title/cover; '
          'pass url to online.source.get / add / download.',
      params: const <OpParam>[
        _sourceId,
        _kind,
        OpParam.string('q', description: 'Search keywords.', required: true),
        OpParam.integer('page', description: 'Page number, from 1.'),
      ],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.get',
      method: 'GET',
      pattern: '/api/admin/sources/:sourceId/work',
      summary:
          'Fetch a work\'s details and chapter / episode list (1-based index, '
          'locked, in-library / downloaded flags; bookKey if already on the shelf).',
      params: const <OpParam>[
        _sourceId,
        _kind,
        OpParam.string(
          'url',
          description: 'Work url from online.source.search / browse.',
          required: true,
        ),
      ],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.add',
      method: 'POST',
      pattern: '/api/admin/sources/:sourceId/library',
      summary:
          'Add an online work to the bookshelf (manga, novel) or the video library '
          '(anime: one online row per episode). Undo removes a shelf entry it '
          'created as long as it was not opened since (anime cannot be undone).',
      risk: OpRisk.write,
      params: const <OpParam>[
        _sourceId,
        _kind,
        OpParam.string(
          'url',
          description: 'Work url from online.source.search / browse.',
          required: true,
        ),
      ],
      availability: anyOnline,
      undo: u.sourceAddUndo(),
    ),
    OpDescription(
      id: 'online.source.download',
      method: 'POST',
      pattern: '/api/admin/sources/:sourceId/downloads',
      summary:
          'Download chapters / episodes of an online work. manga: adds to shelf and '
          'queues unlocked chapters (online.manga-download.list); anime: queues '
          'episodes in the download center (returns taskIds); novel: starts a '
          'whole-book download task (returns task id, see online.task.get). Undo '
          'cancels / removes what was queued and the shelf entry it created.',
      risk: OpRisk.write,
      longRunning: true,
      params: const <OpParam>[
        _sourceId,
        _kind,
        OpParam.string(
          'url',
          description: 'Work url from online.source.search / browse.',
          required: true,
        ),
        OpParam.string(
          'chapters',
          description:
              '1-based ranges like "1-10,15,20-"; omit for all chapters / episodes.',
        ),
      ],
      availability: anyOnline,
      undo: u.sourceDownloadUndo(),
    ),
    OpDescription(
      id: 'online.source.set',
      method: 'POST',
      pattern: '/api/admin/sources/:sourceId/settings',
      summary:
          'Enable / disable or pin / unpin one online source (give at least one). '
          'Undo restores the previous enabled and pinned state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _sourceIdAny,
        _kind,
        OpParam.boolean('enabled', description: 'Source on / off.'),
        OpParam.boolean('pinned', description: 'Pin to the top of the list.'),
      ],
      availability: anyOnline,
      undo: u.sourceSettingsUndo(),
    ),
    OpDescription(
      id: 'online.source.prefs',
      method: 'GET',
      pattern: '/api/admin/sources/:sourceId/preferences',
      summary:
          'List a Mihon/Aniyomi source\'s preferences (key, kind, current value, '
          'options). Not available for novel plugins.',
      params: const <OpParam>[_sourceIdAny, _kind],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.set-pref',
      method: 'POST',
      pattern: '/api/admin/sources/:sourceId/preferences',
      summary:
          'Change one Mihon/Aniyomi source preference, like the source settings '
          'dialog. Undo writes the previous value back.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _sourceIdAny,
        _kind,
        OpParam.string(
          'key',
          description: 'Preference key from online.source.prefs.',
          required: true,
        ),
        OpParam.string(
          'value',
          description:
              'New value: true/false, text, option label / value or "#N" '
              '(1-based), comma-separated list for multi-select.',
          required: true,
        ),
      ],
      availability: anyOnline,
      undo: u.sourcePreferenceUndo(),
    ),
    OpDescription(
      id: 'online.source.clear-data',
      method: 'DELETE',
      pattern: '/api/admin/sources/:sourceId/data',
      summary:
          'Clear a source\'s stored data: Mihon/Aniyomi runtime data and saved '
          'preferences, LNReader plugin storage (login state / tokens). Cannot be '
          'undone, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _sourceIdAny,
        _kind,
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.filters',
      method: 'GET',
      pattern: '/api/admin/sources/:sourceId/filters',
      summary:
          'List the filters a source supports (Mihon/Aniyomi: apply to search; '
          'LNReader: apply to popular / latest).',
      params: const <OpParam>[_sourceId, _kind],
      availability: anyOnline,
    ),
    OpDescription(
      id: 'online.source.browse',
      method: 'POST',
      pattern: '/api/admin/sources/:sourceId/browse',
      summary:
          'Browse one page of a source: popular / latest listing, or keyword search, '
          'optionally with filters from online.source.filters.',
      params: const <OpParam>[
        _sourceId,
        _kind,
        OpParam.string(
          'listing',
          description: 'popular or latest (mutually exclusive with query).',
          enumValues: <String>['popular', 'latest'],
        ),
        OpParam.string(
          'query',
          description: 'Keyword search instead of listing.',
        ),
        OpParam.integer('page', description: 'Page number, from 1.'),
        OpParam.object(
          'filters',
          description:
              '{filter name or path: value} from online.source.filters.',
        ),
      ],
      availability: anyOnline,
    ),
    // ── 发现 ──────────────────────────────────────────────────────────────
    OpDescription(
      id: 'online.discovery.sources',
      method: 'GET',
      pattern: '/api/admin/discovery/sources',
      summary:
          'List discovery sources (resource indexers for books, audiobooks, manga, '
          'games) and whether each is enabled.',
      params: const <OpParam>[_domainOptional],
      availability: discovery,
    ),
    OpDescription(
      id: 'online.discovery.search',
      method: 'GET',
      pattern: '/api/admin/discovery/search',
      summary:
          'Search discovery sources for downloadable resources. Result ids '
          '(r1, r2…) are valid for online.discovery.acquire during this app run.',
      params: const <OpParam>[
        _domainOptional,
        OpParam.string('q', description: 'Search keywords.', required: true),
        OpParam.string(
          'source',
          description:
              'Only this discovery source id (online.discovery.sources).',
        ),
      ],
      availability: discovery,
    ),
    OpDescription(
      id: 'online.discovery.acquire',
      method: 'POST',
      pattern: '/api/admin/discovery/acquire',
      summary:
          'Download one discovery result through the download center (torrent / '
          'direct link) and import it automatically. May show an in-app dialog. '
          'Cannot be undone (torrents announce to peers; the route returns no task '
          'id), so the user confirms.',
      risk: OpRisk.irreversible,
      needsUi: true,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Result id from online.discovery.search.',
          required: true,
        ),
      ],
      availability: kit.all(<OpAvailability Function()>[
        discovery,
        kit.whenStoreAllows(StoreRestrictedCapability.downloads),
      ]),
    ),
    // ── 播放遥控 ──────────────────────────────────────────────────────────
    const OpDescription(
      id: 'playback.status',
      method: 'GET',
      pattern: '/api/admin/playback',
      summary:
          'Current playback state of the video player page or the audiobook '
          '(title, playing, position, duration, speed, current cue).',
      params: <OpParam>[_target],
    ),
    OpDescription(
      id: 'playback.control',
      method: 'POST',
      pattern: '/api/admin/playback/control',
      summary:
          'Pause / resume / toggle playback or jump to the next / previous cue. '
          'Undo returns to the previous position and play state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'action',
          description: 'What to do.',
          required: true,
          enumValues: <String>['pause', 'resume', 'toggle', 'next', 'prev'],
        ),
        _target,
      ],
      undo: u.playbackPositionUndo(),
    ),
    OpDescription(
      id: 'playback.seek',
      method: 'POST',
      pattern: '/api/admin/playback/seek',
      summary:
          'Seek to an absolute position in seconds, or relative (+/-) with '
          'relative=true. Undo returns to the previous position.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.number(
          'seconds',
          description: 'Target position (or offset when relative) in seconds.',
          required: true,
        ),
        OpParam.boolean(
          'relative',
          description: 'Treat seconds as an offset from the current position.',
        ),
        _target,
      ],
      undo: u.playbackPositionUndo(),
    ),
    OpDescription(
      id: 'playback.rate',
      method: 'POST',
      pattern: '/api/admin/playback/rate',
      summary:
          'Set the playback speed (0.25–4; video speed is remembered per video). '
          'Undo restores the previous speed.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.number(
          'rate',
          description: 'Speed multiplier 0.25–4.',
          required: true,
        ),
        _target,
      ],
      undo: u.playbackRateUndo(),
    ),
    // ── 顶层导航 ──────────────────────────────────────────────────────────
    const OpDescription(
      id: 'nav.list',
      method: 'GET',
      pattern: '/api/admin/navigation',
      summary:
          'List the top-level pages (home, books, manga, video, music, browse, '
          'dictionaries, srs, games, web, settings), which are available and '
          'which is current.',
    ),
    const OpDescription(
      id: 'nav.go',
      method: 'POST',
      pattern: '/api/admin/navigation',
      summary:
          'Switch the app to a top-level page (pop=true first closes the reader / '
          'player on top). Navigation only; changes no data.',
      params: <OpParam>[
        OpParam.string(
          'page',
          description: 'Page name from nav.list.',
          required: true,
        ),
        OpParam.boolean(
          'pop',
          description: 'Close pages stacked on top (reader, player) first.',
        ),
      ],
    ),
  ];
}

// ── 共用参数 ──────────────────────────────────────────────────────────────

const OpParam _kind = OpParam.string(
  'kind',
  description:
      'Ecosystem: manga (Mihon), anime (Aniyomi video), novel (LNReader).',
  required: true,
  enumValues: <String>['manga', 'anime', 'novel'],
);

const OpParam _sourceId = OpParam.string(
  'sourceId',
  description:
      'Source id from online.source.list (novel: plugin id; manga/anime: source '
      'id, or "<extension package>:<source id>" when ambiguous). Must be enabled.',
  required: true,
  inPath: true,
);

const OpParam _sourceIdAny = OpParam.string(
  'sourceId',
  description:
      'Source id from online.source.list (novel: plugin id; manga/anime: source '
      'id, or "<extension package>:<source id>" when ambiguous).',
  required: true,
  inPath: true,
);

const OpParam _domainOptional = OpParam.string(
  'domain',
  description: 'Content domain; default book.',
  enumValues: <String>['book', 'audiobook', 'manga', 'game'],
);

const OpParam _target = OpParam.string(
  'target',
  description:
      'Which player: video page or audiobook; default auto (video page if open).',
  enumValues: <String>['auto', 'video', 'audiobook'],
);

// ── 私有助手（可能值得提进 OpDescribeKit） ───────────────────────────────

/// 几个合规能力**任一**可用即可用（一条路由按 `kind` 服务多个受限生态时用）。
OpAvailability Function() _anyStore(
  List<StoreRestrictedCapability> capabilities,
) => () {
  for (final StoreRestrictedCapability c in capabilities) {
    if (c.isAvailable) return const OpAvailability.available();
  }
  return OpAvailability.unavailable(
    'store_restricted',
    capabilities.map((StoreRestrictedCapability c) => c.name).join('|'),
  );
};

/// 撤销读写时要带的「作用域」：路径参数 + 原调用 body 里的若干字段（如 `kind`）。
/// kit 的 snapshotUndo 只带路径参数，而本域每条路由都靠 body 的 `kind` 选生态。
typedef _Scope = ({Map<String, String> params, Map<String, Object?> body});

List<Map<String, Object?>> _rows(Object? response, String key) {
  final Object? rows = response is Map ? response[key] : null;
  if (rows is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? row in rows)
      if (row is Map) row.cast<String, Object?>(),
  ];
}

Map<String, Object?> _map(Object? raw) =>
    raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};

String? _show(Object? value) {
  if (value == null) return null;
  final String text = value is String ? value : jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

OpUndoOutcome _failure(CtlFailure failure) => failure.status == 404
    ? OpUndoOutcome.superseded(failure.message)
    : OpUndoOutcome.failed(failure.message ?? failure.code);

class _OnlineUndo {
  _OnlineUndo(this.kit);

  final OpDescribeKit kit;

  /// 带 body 作用域的快照撤销（见 [_Scope]）。撤销前当前值已不是执行结果 →
  /// superseded，不覆盖用户的手动修改。
  OpUndo scopedSnapshot({
    required List<String> scope,
    required Future<Object?> Function(_Scope s) read,
    required Future<void> Function(_Scope s, Object? old) write,
    required Object? Function(CtlCall call, Object? result) newValue,
  }) => OpUndo(
    capture: (CtlCall call) async {
      final _Scope s = (
        params: Map<String, String>.of(call.params),
        body: <String, Object?>{
          for (final String key in scope)
            if (call.body.containsKey(key)) key: call.body[key],
        },
      );
      return <String, Object?>{
        'params': s.params,
        'body': s.body,
        'old': await read(s),
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Object? after = newValue(call, result);
      return OpUndoRecord(
        payload: <String, Object?>{...before, 'new': after},
        before: _show(before['old']),
        after: _show(after),
      );
    },
    revert: (Map<String, Object?> payload) async {
      final _Scope s = (
        params: <String, String>{
          for (final MapEntry<String, Object?> e in _map(
            payload['params'],
          ).entries)
            e.key: '${e.value}',
        },
        body: _map(payload['body']),
      );
      try {
        if (!OpDescribeKit.sameJson(await read(s), payload['new'])) {
          return const OpUndoOutcome.superseded();
        }
        await write(s, payload['old']);
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return _failure(failure);
      }
    },
  );

  Future<List<String>> _repoUrls(Object? kind) async => <String>[
    for (final Map<String, Object?> row in _rows(
      await kit.callRoute(
        'GET',
        '/api/admin/extensions/repos',
        body: <String, Object?>{'kind': kind},
      ),
      'repos',
    ))
      '${row['url']}',
  ];

  /// 添加仓库的撤销：删掉这次新出现的那个仓库。仓库地址可能被规范化（LNReader
  /// 补 `/`、Mihon 用索引里的 indexUrl），所以按「执行前后差集」找，原样命中优先。
  OpUndo repoAddUndo() => OpUndo(
    capture: (CtlCall call) async => <String, Object?>{
      'kind': call.body['kind'],
      'url': call.body['url'],
      'before': await _repoUrls(call.body['kind']),
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) =>
        OpUndoRecord(payload: before, after: '${before['url']}'),
    revert: (Map<String, Object?> payload) async {
      try {
        final String url = '${payload['url']}';
        final Set<String> before = <String>{
          for (final Object? u
              in payload['before'] as List? ?? const <Object?>[])
            '$u',
        };
        if (before.contains(url)) {
          return const OpUndoOutcome.done('repository existed before; kept');
        }
        final List<String> added = <String>[
          for (final String u in await _repoUrls(payload['kind']))
            if (!before.contains(u)) u,
        ];
        final String? target = added.contains(url)
            ? url
            : (added.length == 1 ? added.single : null);
        if (target == null) {
          return added.isEmpty
              ? const OpUndoOutcome.superseded('repository already removed')
              : OpUndoOutcome.failed(
                  'cannot tell which new repository to remove: ${added.join(', ')}',
                );
        }
        await kit.callRoute(
          'DELETE',
          '/api/admin/extensions/repos',
          body: <String, Object?>{
            'kind': payload['kind'],
            'url': target,
            'confirm': true,
          },
        );
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return _failure(failure);
      }
    },
  );

  /// 删除仓库的撤销：把同一地址加回去（明文 http 地址当初就被用户信任过，按原
  /// scheme 放行）。仓库此时已在 → superseded。
  OpUndo repoRemoveUndo() => kit.inverseRouteUndo(
    payloadOf: (CtlCall call, Object? result) => <String, Object?>{
      'kind': call.body['kind'],
      'url': call.body['url'],
    },
    describe: (Map<String, Object?> payload) => 'removed ${payload['url']}',
    inverse: (Map<String, Object?> payload) async {
      final String url = '${payload['url']}';
      if ((await _repoUrls(payload['kind'])).contains(url)) {
        throw CtlFailure.notFound('repository $url is back already');
      }
      return kit.callRoute(
        'POST',
        '/api/admin/extensions/repos',
        body: <String, Object?>{
          'kind': payload['kind'],
          'url': url,
          if (Uri.tryParse(url)?.scheme == 'http') 'allowInsecure': true,
        },
      );
    },
  );

  Future<Map<String, Object?>?> _installed(Object? kind, String id) async {
    for (final Map<String, Object?> row in _rows(
      await kit.callRoute(
        'GET',
        '/api/admin/extensions',
        body: <String, Object?>{'kind': kind},
      ),
      'installed',
    )) {
      if ('${row['id']}' == id) return row;
    }
    return null;
  }

  /// 安装的撤销：卸载（保留数据的那条）。执行前已装着（覆盖安装 / 升级）就不卸——
  /// 旧版本取不回来，卸掉反而比执行前更糟。
  OpUndo extensionInstallUndo() => OpUndo(
    capture: (CtlCall call) async {
      final String id = '${call.body['id']}';
      final Map<String, Object?>? row = await _installed(call.body['kind'], id);
      return <String, Object?>{
        'kind': call.body['kind'],
        'id': id,
        'wasInstalled': row != null,
        if (row != null) 'version': row['version'],
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) =>
        OpUndoRecord(
          payload: before,
          before: before['wasInstalled'] == true
              ? '${before['id']} ${before['version']}'
              : null,
          after: '${before['id']} ${_map(result)['version'] ?? ''}'.trim(),
        ),
    revert: (Map<String, Object?> payload) async {
      if (payload['wasInstalled'] == true) {
        return OpUndoOutcome.failed(
          '${payload['id']} was installed before (version '
          '${payload['version']}); the previous version cannot be restored',
        );
      }
      try {
        final String id = '${payload['id']}';
        if (await _installed(payload['kind'], id) == null) {
          return const OpUndoOutcome.superseded('already uninstalled');
        }
        await kit.callRoute(
          'DELETE',
          '/api/admin/extensions/:id',
          params: <String, String>{'id': id},
          body: <String, Object?>{'kind': payload['kind'], 'confirm': true},
        );
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return _failure(failure);
      }
    },
  );

  OpUndo extensionEnabledUndo() => scopedSnapshot(
    scope: const <String>['kind'],
    read: (_Scope s) async {
      final Map<String, Object?>? row = await _installed(
        s.body['kind'],
        s.params['id']!,
      );
      if (row == null) {
        throw CtlFailure.notFound('${s.params['id']} is not installed');
      }
      return row['enabled'];
    },
    write: (_Scope s, Object? old) async {
      await kit.callRoute(
        'POST',
        '/api/admin/extensions/:id/enabled',
        params: s.params,
        body: <String, Object?>{'kind': s.body['kind'], 'enabled': old == true},
      );
    },
    newValue: (CtlCall call, Object? result) =>
        _map(result)['enabled'] ?? call.body['enabled'],
  );

  /// 源列表里的一行（`sourceId` 或 `扩展包名:sourceId`）。
  Future<Map<String, Object?>> _sourceRow(Object? kind, String raw) async {
    for (final Map<String, Object?> row in _rows(
      await kit.callRoute(
        'GET',
        '/api/admin/sources',
        body: <String, Object?>{'kind': kind},
      ),
      'sources',
    )) {
      if ('${row['id']}' == raw || '${row['extension']}:${row['id']}' == raw) {
        return row;
      }
    }
    throw CtlFailure.notFound('source $raw no longer exists');
  }

  OpUndo sourceSettingsUndo() => scopedSnapshot(
    scope: const <String>['kind'],
    read: (_Scope s) async {
      final Map<String, Object?> row = await _sourceRow(
        s.body['kind'],
        s.params['sourceId']!,
      );
      return <String, Object?>{
        'enabled': row['enabled'] == true,
        'pinned': row['pinned'] == true,
      };
    },
    write: (_Scope s, Object? old) async {
      final Map<String, Object?> value = _map(old);
      await kit.callRoute(
        'POST',
        '/api/admin/sources/:sourceId/settings',
        params: s.params,
        body: <String, Object?>{
          'kind': s.body['kind'],
          'enabled': value['enabled'] == true,
          'pinned': value['pinned'] == true,
        },
      );
    },
    newValue: (CtlCall call, Object? result) => <String, Object?>{
      'enabled': _map(result)['enabled'] == true,
      'pinned': _map(result)['pinned'] == true,
    },
  );

  static Map<String, Object?>? _preference(Object? response, String key) {
    for (final Map<String, Object?> p in _rows(response, 'preferences')) {
      if ('${p['key']}' == key) {
        return <String, Object?>{'kind': p['kind'], 'value': p['value']};
      }
    }
    return null;
  }

  /// 偏好值 → 设置路由认的文本（list 存的是下标，写回用 `#N`；多选用逗号连）。
  static String _preferenceText(Map<String, Object?> pref) {
    final Object? value = pref['value'];
    switch ('${pref['kind']}') {
      case 'list':
        final int? index = value is int ? value : int.tryParse('$value');
        if (index == null || index < 0) {
          throw const CtlFailure.rejected('previous value was unset');
        }
        return '#${index + 1}';
      case 'multiSelect':
        return value is List
            ? value.map((Object? v) => '$v').join(',')
            : '${value ?? ''}';
      default:
        return '${value ?? ''}';
    }
  }

  OpUndo sourcePreferenceUndo() => scopedSnapshot(
    scope: const <String>['kind', 'key'],
    read: (_Scope s) async {
      final String key = '${s.body['key']}';
      final Map<String, Object?>? pref = _preference(
        await kit.callRoute(
          'GET',
          '/api/admin/sources/:sourceId/preferences',
          params: s.params,
          body: <String, Object?>{'kind': s.body['kind']},
        ),
        key,
      );
      if (pref == null) throw CtlFailure.notFound('preference $key is gone');
      return pref;
    },
    write: (_Scope s, Object? old) async {
      await kit.callRoute(
        'POST',
        '/api/admin/sources/:sourceId/preferences',
        params: s.params,
        body: <String, Object?>{
          'kind': s.body['kind'],
          'key': s.body['key'],
          'value': _preferenceText(_map(old)),
        },
      );
    },
    newValue: (CtlCall call, Object? result) =>
        _preference(result, '${call.body['key']}'),
  );

  /// 库列表里某个种类的全部条目键；库页被关掉（hiddenKinds）时返回 null = 不知道。
  Future<List<String>?> _libraryKeys(String libraryKind) async {
    try {
      final Object? listed = await kit.callRoute(
        'GET',
        '/api/admin/library/items',
        body: <String, Object?>{'kind': libraryKind},
      );
      if (_map(listed)['hiddenKinds'] is List &&
          (_map(listed)['hiddenKinds'] as List).isNotEmpty) {
        return null;
      }
      return <String>[
        for (final Map<String, Object?> row in _rows(listed, 'items'))
          '${row['key']}',
      ];
    } on CtlFailure {
      return null;
    }
  }

  static String? _libraryKindOf(Object? kind) => switch ('$kind') {
    'manga' => 'manga',
    'novel' => 'book',
    _ => null,
  };

  /// 删掉这次新进书架的条目：执行前就在 / 不知道执行前在不在 → 不动；之后被打开读过
  /// （有进度或读完）→ superseded。
  Future<OpUndoOutcome> _removeCreatedShelfBook(
    String? bookKey,
    List<String>? before,
  ) async {
    if (bookKey == null || bookKey.isEmpty) {
      return const OpUndoOutcome.failed('no bookKey recorded');
    }
    final String key = 'book:$bookKey';
    if (before == null || before.contains(key)) {
      return const OpUndoOutcome.done('was on the shelf before; kept');
    }
    final Object? item = await kit.callRoute(
      'GET',
      '/api/admin/library/items/:key',
      params: <String, String>{'key': key},
    );
    final Object? percent = _map(item)['percent'];
    if (_map(item)['completed'] == true || (percent is num && percent > 0)) {
      return const OpUndoOutcome.superseded('opened since; kept');
    }
    await kit.callRoute(
      'DELETE',
      '/api/admin/library/items/:key',
      params: <String, String>{'key': key},
      body: const <String, Object?>{'confirm': true},
    );
    return const OpUndoOutcome.done();
  }

  OpUndo sourceAddUndo() => OpUndo(
    capture: (CtlCall call) async {
      final String? libraryKind = _libraryKindOf(call.body['kind']);
      return <String, Object?>{
        'kind': call.body['kind'],
        if (libraryKind != null) 'before': await _libraryKeys(libraryKind),
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) =>
        OpUndoRecord(
          payload: <String, Object?>{
            ...before,
            'bookKey': _map(result)['bookKey'],
            'title': _map(result)['title'],
          },
          after: '${_map(result)['title'] ?? ''}',
        ),
    revert: (Map<String, Object?> payload) async {
      if (_libraryKindOf(payload['kind']) == null) {
        return const OpUndoOutcome.failed(
          'anime episodes added to the video library are not tracked by id; '
          'remove them from the video library',
        );
      }
      try {
        return await _removeCreatedShelfBook(
          payload['bookKey'] as String?,
          (payload['before'] as List?)?.map((Object? k) => '$k').toList(),
        );
      } on CtlFailure catch (failure) {
        return _failure(failure);
      }
    },
  );

  Future<List<String>> _mangaJobIds() async => <String>[
    for (final Map<String, Object?> row in _rows(
      await kit.callRoute('GET', '/api/admin/online/manga-downloads'),
      'jobs',
    ))
      '${row['id']}',
  ];

  /// 下载的撤销，按生态：
  /// - novel：任务还在跑 → 取消；已完成 → 删掉它建的那本书（没被读过）；
  /// - manga：取消 + 删除这次新入队的章节任务（按书 + 执行前任务 id 差集），再删
  ///   这次新进书架的条目；
  /// - anime：未完成的剧集任务暂停后连 `.part` 放弃；已下完的保留并在消息里说明。
  OpUndo sourceDownloadUndo() => OpUndo(
    capture: (CtlCall call) async {
      final String kind = '${call.body['kind']}';
      if (kind != 'manga') return <String, Object?>{'kind': kind};
      return <String, Object?>{
        'kind': kind,
        'jobsBefore': await _mangaJobIds(),
        'before': await _libraryKeys('manga'),
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Map<String, Object?> r = _map(result);
      return OpUndoRecord(
        payload: <String, Object?>{
          ...before,
          'bookKey': r['bookKey'],
          'taskId': r['id'],
          'taskIds': r['taskIds'],
        },
        after: '${r['title'] ?? ''}',
      );
    },
    revert: (Map<String, Object?> payload) async {
      try {
        switch ('${payload['kind']}') {
          case 'novel':
            return await _revertNovelDownload('${payload['taskId']}');
          case 'manga':
            return await _revertMangaDownload(payload);
          default:
            return await _revertEpisodeDownloads(<String>[
              for (final Object? id
                  in payload['taskIds'] as List? ?? const <Object?>[])
                '$id',
            ]);
        }
      } on CtlFailure catch (failure) {
        return _failure(failure);
      }
    },
  );

  Future<OpUndoOutcome> _revertNovelDownload(String taskId) async {
    final Map<String, Object?> task = _map(
      await kit.callRoute(
        'GET',
        '/api/admin/online/tasks/:id',
        params: <String, String>{'id': taskId},
      ),
    );
    switch ('${task['status']}') {
      case 'running':
        await kit.callRoute(
          'POST',
          '/api/admin/online/tasks/:id/cancel',
          params: <String, String>{'id': taskId},
        );
        return const OpUndoOutcome.done('cancel requested');
      case 'done':
        return _removeCreatedShelfBook(
          task['resultKey'] as String?,
          const <String>[],
        );
      default:
        return const OpUndoOutcome.done();
    }
  }

  Future<OpUndoOutcome> _revertMangaDownload(
    Map<String, Object?> payload,
  ) async {
    final String? bookKey = payload['bookKey'] as String?;
    final Set<String> before = <String>{
      for (final Object? id
          in payload['jobsBefore'] as List? ?? const <Object?>[])
        '$id',
    };
    for (final Map<String, Object?> job in _rows(
      await kit.callRoute(
        'GET',
        '/api/admin/online/manga-downloads',
        body: <String, Object?>{'book': bookKey},
      ),
      'jobs',
    )) {
      final String id = '${job['id']}';
      if (before.contains(id)) continue;
      final Map<String, String> params = <String, String>{'id': id};
      if (job['status'] == 'queued' || job['status'] == 'running') {
        await kit.callRoute(
          'POST',
          '/api/admin/online/manga-downloads/:id/cancel',
          params: params,
        );
      }
      await kit.callRoute(
        'DELETE',
        '/api/admin/online/manga-downloads/:id',
        params: params,
        body: const <String, Object?>{'confirm': true},
      );
    }
    return _removeCreatedShelfBook(
      bookKey,
      (payload['before'] as List?)?.map((Object? k) => '$k').toList(),
    );
  }

  Future<OpUndoOutcome> _revertEpisodeDownloads(List<String> ids) async {
    final List<String> kept = <String>[];
    for (final String id in ids) {
      final Map<String, String> params = <String, String>{'id': id};
      Map<String, Object?> task;
      try {
        task = _map(
          await kit.callRoute(
            'GET',
            '/api/admin/online/episode-downloads/:id',
            params: params,
          ),
        );
      } on CtlFailure catch (failure) {
        if (failure.status == 404) continue;
        rethrow;
      }
      if (task['status'] == 'completed') {
        kept.add('${task['title'] ?? id}');
        continue;
      }
      if (task['canPause'] == true) {
        await kit.callRoute(
          'POST',
          '/api/admin/online/episode-downloads/:id/pause',
          params: params,
        );
      }
      await kit.callRoute(
        'DELETE',
        '/api/admin/online/episode-downloads/:id',
        params: params,
        body: const <String, Object?>{'confirm': true, 'deleteFiles': true},
      );
    }
    return kept.isEmpty
        ? const OpUndoOutcome.done()
        : OpUndoOutcome.done('already downloaded, kept: ${kept.join(', ')}');
  }

  // ── 播放 ────────────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _playback(Object? target) async => _map(
    await kit.callRoute(
      'GET',
      '/api/admin/playback',
      body: <String, Object?>{if (target != null) 'target': target},
    ),
  );

  /// 播放器身份：视频看 bookUid，有声书看 bookKey。
  static String _identity(Map<String, Object?> status) =>
      '${status['kind']}:${status['bookUid'] ?? status['bookKey'] ?? ''}';

  /// 控制 / 跳转的撤销：回到执行前的位置与播放状态。换了视频 / 书 → superseded。
  OpUndo playbackPositionUndo() => OpUndo(
    capture: (CtlCall call) async => <String, Object?>{
      'status': await _playback(call.body['target']),
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Map<String, Object?> status = _map(before['status']);
      return OpUndoRecord(
        payload: before,
        before: '${status['positionMs']} ms',
        after: '${_map(result)['positionMs']} ms',
      );
    },
    revert: (Map<String, Object?> payload) async {
      final Map<String, Object?> old = _map(payload['status']);
      if (old['active'] != true || old['positionMs'] is! num) {
        return const OpUndoOutcome.failed('nothing was playing');
      }
      try {
        final String target = '${old['kind']}';
        final Map<String, Object?> now = await _playback(target);
        if (now['active'] != true || _identity(now) != _identity(old)) {
          return const OpUndoOutcome.superseded('a different item is playing');
        }
        await kit.callRoute(
          'POST',
          '/api/admin/playback/seek',
          body: <String, Object?>{
            'target': target,
            'seconds': (old['positionMs']! as num) / 1000,
          },
        );
        if (now['playing'] != old['playing']) {
          await kit.callRoute(
            'POST',
            '/api/admin/playback/control',
            body: <String, Object?>{
              'target': target,
              'action': old['playing'] == true ? 'resume' : 'pause',
            },
          );
        }
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return failure.status == 409
            ? OpUndoOutcome.superseded(failure.message)
            : _failure(failure);
      }
    },
  );

  OpUndo playbackRateUndo() => OpUndo(
    capture: (CtlCall call) async => <String, Object?>{
      'status': await _playback(call.body['target']),
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) =>
        OpUndoRecord(
          payload: <String, Object?>{...before, 'new': _map(result)['speed']},
          before: '${_map(before['status'])['speed']}x',
          after: '${_map(result)['speed']}x',
        ),
    revert: (Map<String, Object?> payload) async {
      final Map<String, Object?> old = _map(payload['status']);
      if (old['active'] != true || old['speed'] is! num) {
        return const OpUndoOutcome.failed('nothing was playing');
      }
      try {
        final String target = '${old['kind']}';
        final Map<String, Object?> now = await _playback(target);
        if (now['active'] != true ||
            _identity(now) != _identity(old) ||
            !OpDescribeKit.sameJson(now['speed'], payload['new'])) {
          return const OpUndoOutcome.superseded();
        }
        await kit.callRoute(
          'POST',
          '/api/admin/playback/rate',
          body: <String, Object?>{'target': target, 'rate': old['speed']},
        );
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return failure.status == 409
            ? OpUndoOutcome.superseded(failure.message)
            : _failure(failure);
      }
    },
  );
}

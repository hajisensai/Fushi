import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/media/people/person_identity.dart';

import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_link_inference_host.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/people/person_directory.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/ops/op_context.dart';

/// 作品图谱（跨媒体关联建议的接受 / 拒绝）与人物的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2；作品图谱见 `docs/specs/2026-10-24-cross-media-links.md`）。每条路由调用
/// UI 按钮背后的同一个方法，不另写业务逻辑：
/// - 列出 = 详情页「同一作品」区块的 [loadMediaLinkViews]；
/// - 接受 / 不相关 = 建议卡片两键背后的 `confirmMediaLink` / `removeMediaLink`；
/// - 查找相关作品 = 同一按钮的 [mediaLinkInferCallback]（「作品图谱」AI 已指派时会发
///   AI 请求，否则只跑确定性规则；MAL / Wikidata 查询照常联网）；
/// - 人物 = 人物页的 [loadPersonGraph] / [loadPersonPage] / [decidePersonIdentity] /
///   [unmergePersonPair]。
///
/// 端点写成 `<种类>:<本地键>`（种类是 `MediaLinkKind.dbValue`：`book` /
/// `video_collection` / `video_episode` / `game` / `music_album` / `music_track` /
/// `audiobook`），人物写成人物节点（`ref:<域>:<键>`，见 `people ls`）。
List<CtlRoute> buildMediaLinksCtlRoutes(OpContext context) {
  AppModel app() => context.appModel;
  FushiDatabase db() => app().database;

  void requireWritable() {
    if (app().isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  /// 端点所在模块关掉时拒绝（详情页本就进不去）。
  void requireEndpointModule(MediaLinkEndpoint e) {
    final List<ModuleId> modules = switch (e.kind) {
      MediaLinkKind.book => <ModuleId>[ModuleId.books, ModuleId.manga],
      MediaLinkKind.audiobook => <ModuleId>[ModuleId.listening, ModuleId.books],
      MediaLinkKind.videoCollection ||
      MediaLinkKind.videoEpisode => <ModuleId>[ModuleId.video],
      MediaLinkKind.game => <ModuleId>[ModuleId.games],
      MediaLinkKind.musicAlbum ||
      MediaLinkKind.musicTrack => <ModuleId>[ModuleId.music],
    };
    if (!modules.any(app().moduleVisibility.isEnabled)) {
      throw CtlFailure.rejected('${e.kind.dbValue} 所在模块已在设置里关闭');
    }
  }

  Future<MediaLinkEndpoint> localEndpoint(CtlCall call) async {
    final MediaLinkEndpoint self = parseMediaLinkEndpoint(
      call.params['endpoint'] ?? '',
    );
    requireEndpointModule(self);
    final MediaLinkEntry entry = await resolveMediaLinkEntry(db(), self);
    if (!entry.inLibrary) {
      throw CtlFailure.notFound('本机库里没有 ${mediaLinkEndpointWire(self)}');
    }
    return self;
  }

  /// 在 [self] 的连接里找另一端是 body `other`（可再按 `relation` 收窄）的那一条。
  Future<MediaLinkView> pickLink(MediaLinkEndpoint self, CtlCall call) async {
    final MediaLinkEndpoint other = parseMediaLinkEndpoint(
      call.requireString('other'),
    );
    final String? relation = call.optString('relation');
    final List<MediaLinkView> hits = <MediaLinkView>[
      for (final MediaLinkView v in await loadMediaLinkViews(db(), self))
        if (v.other.endpoint.kind == other.kind &&
            v.other.endpoint.key == other.key &&
            (relation == null || v.row.relation == relation))
          v,
    ];
    if (hits.isEmpty) {
      throw CtlFailure.notFound(
        '${mediaLinkEndpointWire(self)} 与 ${mediaLinkEndpointWire(other)} 之间没有关联',
      );
    }
    if (hits.length > 1) {
      throw CtlFailure.badRequest(
        '两者之间有多条关联，用 relation 指定：'
        '${hits.map((MediaLinkView v) => v.row.relation).join(' / ')}',
      );
    }
    return hits.single;
  }

  return <CtlRoute>[
    CtlRoute.get('$kMediaLinksCtlRoot/:endpoint', (CtlCall call) async {
      final MediaLinkEndpoint self = await localEndpoint(call);
      final String state = call.optString('state') ?? 'all';
      if (!const <String>{'all', 'confirmed', 'suggested'}.contains(state)) {
        throw CtlFailure.badRequest(
          'state 只能是 all / confirmed / suggested：$state',
        );
      }
      final MediaLinkEntry entry = await resolveMediaLinkEntry(db(), self);
      return <String, Object?>{
        'endpoint': mediaLinkEndpointWire(self),
        'title': entry.title,
        'links': <Map<String, Object?>>[
          for (final MediaLinkView v in await loadMediaLinkViews(db(), self))
            if (state == 'all' || v.state.name == state) mediaLinkViewJson(v),
        ],
      };
    }),
    CtlRoute.post('$kMediaLinksCtlRoot/:endpoint/accept', (CtlCall call) async {
      requireWritable();
      final MediaLinkEndpoint self = await localEndpoint(call);
      final MediaLinkView view = await pickLink(self, call);
      if (view.state != MediaLinkState.suggested) {
        throw const CtlFailure.conflict('这条关联已经是确认的，不是建议');
      }
      if (!await db().confirmMediaLink(view.id)) {
        throw const CtlFailure.conflict('这条建议已被否决或删除');
      }
      return <String, Object?>{
        'link': mediaLinkViewJson((await pickLink(self, call))),
      };
    }),
    CtlRoute.post('$kMediaLinksCtlRoot/:endpoint/reject', (CtlCall call) async {
      requireWritable();
      final MediaLinkEndpoint self = await localEndpoint(call);
      final MediaLinkView view = await pickLink(self, call);
      if (view.state != MediaLinkState.suggested) {
        throw const CtlFailure.conflict('已确认的关联不能当建议否决（在详情页长按卡片「移除关联」）');
      }
      await db().removeMediaLink(view.id);
      return <String, Object?>{
        'link': <String, Object?>{
          ...mediaLinkViewJson(view),
          'state': MediaLinkState.removed.name,
        },
      };
    }),
    CtlRoute.post('$kMediaLinksCtlRoot/:endpoint/infer', (CtlCall call) async {
      requireWritable();
      final MediaLinkEndpoint self = await localEndpoint(call);
      final Future<int> Function()? infer =
          (mediaLinkInferOverride?.call(context, self)) ??
          mediaLinkInferCallback(ref: context.ref, self: self);
      if (infer == null) {
        throw const CtlFailure.rejected('音乐条目没有推断来源，不能查找相关作品');
      }
      final bool ai =
          isAiModuleEnabled(app().moduleVisibility) &&
          resolveMediaLinkAiProvider(app().prefsRepo) != null;
      final Set<String> before = <String>{
        for (final MediaLinkRow r in await db().mediaLinksForEndpoint(
          self.kind,
          self.key,
          includeRemoved: true,
        ))
          _rowKey(r),
      };
      final int added = await infer();
      final List<Map<String, Object?>> fresh = <Map<String, Object?>>[
        for (final MediaLinkView v in await loadMediaLinkViews(db(), self))
          if (!before.contains(_rowKey(v.row))) mediaLinkViewJson(v),
      ];
      return <String, Object?>{
        'endpoint': mediaLinkEndpointWire(self),
        'added': added,
        'ai': ai,
        'suggestions': fresh,
      };
    }),
    CtlRoute.get(kPeopleCtlRoot, (CtlCall call) async {
      final String? search = call.optString('search');
      final int limit = call.optInt('limit') ?? 50;
      if (limit <= 0) throw const CtlFailure.badRequest('limit 必须是正整数');
      final PersonGraph graph = await loadPersonGraph(db());
      final List<PersonCluster> matched =
          <PersonCluster>[
            for (final PersonCluster c in graph.clusters)
              if (search == null ||
                  matchesMediaSearch(
                    query: search,
                    titles: <String>[c.displayName, ...c.otherNames],
                  ))
                c,
          ]..sort(
            (PersonCluster a, PersonCluster b) =>
                a.displayName.compareTo(b.displayName),
          );
      return <String, Object?>{
        'total': matched.length,
        'people': <Map<String, Object?>>[
          for (final PersonCluster c in matched.take(limit))
            personClusterJson(c),
        ],
      };
    }),
    CtlRoute.get('$kPeopleCtlRoot/:node', (CtlCall call) async {
      final String node = call.params['node'] ?? '';
      final PersonPageData? page = await loadPersonPage(db(), node);
      if (page == null) throw CtlFailure.notFound('没有人物 $node（见 people ls）');
      return personPageJson(page);
    }),
    CtlRoute.post('$kPeopleCtlRoot/:node/same', (CtlCall call) async {
      requireWritable();
      final String node = call.params['node'] ?? '';
      final String otherNode = call.requireString('other');
      final bool? same = call.optBool('same');
      if (same == null) {
        throw const CtlFailure.badRequest('same 缺失（true / false）');
      }
      final PersonGraph graph = await loadPersonGraph(db());
      final PersonCluster? self = graph.clusterOf(node);
      if (self == null) throw CtlFailure.notFound('没有人物 $node（见 people ls）');
      final PersonCluster? other = graph.clusterOf(otherNode);
      if (other == null) {
        throw CtlFailure.notFound('没有人物 $otherNode（见 people ls）');
      }
      final DateTime at = DateTime.now();
      final (String, String) pair;
      final PersonIdentityBridgeRow? previous;
      if (self.root != other.root) {
        previous = await db().manualPersonBridge(
          self.records.first.node,
          other.records.first.node,
        );
        pair = await decidePersonIdentity(
          db(),
          self,
          other,
          same: same,
          now: () => at,
        );
      } else {
        if (same) throw const CtlFailure.conflict('两者已经是同一人');
        // 同一人里的「不是同一人」= 人物页的「取消合并」：只能拆用户手动合并的那一对。
        final PersonPageData page = (await loadPersonPage(
          db(),
          node,
          graph: graph,
        ))!;
        final List<(String, String)> pairs = <(String, String)>[
          for (final (String, String) p in page.manualPairs)
            if (p.$1 == otherNode || p.$2 == otherNode) p,
        ];
        if (pairs.isEmpty) {
          throw const CtlFailure.conflict('这两条记录是靠共享外部 id 合并的，不能手动拆开');
        }
        pair = pairs.first;
        previous = await db().manualPersonBridge(pair.$1, pair.$2);
        await unmergePersonPair(db(), pair, now: () => at);
      }
      return <String, Object?>{
        'node': node,
        'other': otherNode,
        'same': same,
        'pair': <String>[pair.$1, pair.$2],
        'at': at.millisecondsSinceEpoch,
        'previous': previous == null
            ? null
            : <String, Object?>{
                'createdAt': previous.createdAt,
                'deletedAt': previous.deletedAt,
              },
      };
    }),
  ];
}

/// 测试接缝：替换「查找相关作品」的推断（默认 = 详情页按钮的
/// [mediaLinkInferCallback]，要联网查 MAL / Wikidata）。
@visibleForTesting
Future<int> Function()? Function(OpContext context, MediaLinkEndpoint self)?
mediaLinkInferOverride;

/// 作品图谱路由根（`/:endpoint`）。
const String kMediaLinksCtlRoot = '/api/admin/links';

/// 人物路由根。
const String kPeopleCtlRoot = '/api/admin/people';

/// `<种类>:<本地键>` → 端点；格式不对抛 400。
MediaLinkEndpoint parseMediaLinkEndpoint(String raw) {
  final int colon = raw.indexOf(':');
  final MediaLinkKind? kind = colon <= 0
      ? null
      : MediaLinkKind.tryParse(raw.substring(0, colon));
  final String key = colon < 0 ? '' : raw.substring(colon + 1);
  if (kind == null || key.isEmpty) {
    throw CtlFailure.badRequest(
      '端点要写成 <种类>:<键>，种类是 '
      '${MediaLinkKind.values.map((MediaLinkKind k) => k.dbValue).join(' / ')}：$raw',
    );
  }
  return (kind: kind, key: key);
}

String mediaLinkEndpointWire(MediaLinkEndpoint e) =>
    '${e.kind.dbValue}:${e.key}';

String _rowKey(MediaLinkRow r) =>
    '${r.fromKind}\u0000${r.fromKey}\u0000${r.relation}\u0000${r.toKind}\u0000${r.toKey}';

/// 一条连接的线上形状（站在 self 一端看）。`id` 是五元组身份（撤销与同步用）。
Map<String, Object?> mediaLinkViewJson(MediaLinkView v) => <String, Object?>{
  'id': mediaLinkIdJson(v.id),
  'relation': v.row.relation,
  'state': v.state.name,
  // 另一端是连接的 from 还是 to（adaptation 的 from = 原作，theme_song 的 from = 音乐）。
  'otherIs': v.otherIsFrom ? 'from' : 'to',
  'other': <String, Object?>{
    'endpoint': mediaLinkEndpointWire(v.other.endpoint),
    'title': v.other.title,
    'inLibrary': v.other.inLibrary,
  },
  if (v.row.role != null) 'role': v.row.role,
  if (v.row.episodeRange != null) 'episodes': v.row.episodeRange,
  'source': v.row.source,
  if (v.row.confidence != null) 'confidence': v.row.confidence,
  if (v.row.reason != null) 'reason': v.row.reason,
};

Map<String, Object?> mediaLinkIdJson(MediaLinkId id) => <String, Object?>{
  'fromKind': id.fromKind,
  'fromKey': id.fromKey,
  'relation': id.relation,
  'toKind': id.toKind,
  'toKey': id.toKey,
};

/// [mediaLinkIdJson] 的反向（撤销载荷 JSON 往返后读回）；缺字段返回 null。
MediaLinkId? mediaLinkIdFromJson(Object? raw) {
  if (raw is! Map) return null;
  final List<Object?> parts = <Object?>[
    raw['fromKind'],
    raw['fromKey'],
    raw['relation'],
    raw['toKind'],
    raw['toKey'],
  ];
  if (parts.any((Object? p) => p is! String)) return null;
  return (
    fromKind: parts[0]! as String,
    fromKey: parts[1]! as String,
    relation: parts[2]! as String,
    toKind: parts[3]! as String,
    toKey: parts[4]! as String,
  );
}

Map<String, Object?> personClusterJson(PersonCluster c) => <String, Object?>{
  'node': c.records.first.node,
  'name': c.displayName,
  if (c.otherNames.isNotEmpty) 'otherNames': c.otherNames,
  'domains': <String>{
    for (final PersonRecord r in c.records) r.domain.wire,
  }.toList(),
  'ids': c.idNodes.toList()..sort(),
};

Map<String, Object?> _workJson(PersonWorkLink w) => <String, Object?>{
  'endpoint': mediaLinkEndpointWire(w.entry.endpoint),
  'title': w.entry.title,
  'inLibrary': w.entry.inLibrary,
};

Map<String, Object?> personPageJson(PersonPageData page) => <String, Object?>{
  ...personClusterJson(page.cluster),
  'records': <Map<String, Object?>>[
    for (final PersonRecord r in page.cluster.records)
      <String, Object?>{
        'node': r.node,
        'domain': r.domain.wire,
        'name': r.name,
        if (r.originalName != null) 'originalName': r.originalName,
      },
  ],
  'voiceRoles': <Map<String, Object?>>[
    for (final PersonVideoRole r in page.videoRoles)
      <String, Object?>{
        'work': _workJson(r.work),
        if (r.characterName != null) 'character': r.characterName,
      },
  ],
  'staff': <Map<String, Object?>>[
    for (final PersonVideoRole r in page.videoStaff)
      <String, Object?>{
        'work': _workJson(r.work),
        if (r.roleLabel != null) 'role': r.roleLabel,
      },
  ],
  'gameRoles': <Map<String, Object?>>[
    for (final PersonGameRole r in page.gameRoles)
      <String, Object?>{
        'work': _workJson(r.work),
        'character': r.characterName,
        if (r.characterOriginal != null)
          'characterOriginal': r.characterOriginal,
        if (r.note != null) 'note': r.note,
      },
  ],
  'songs': <Map<String, Object?>>[
    for (final PersonSong s in page.songs)
      <String, Object?>{
        'work': _workJson(s.work),
        'roles': s.roles,
        if (s.characterNames.isNotEmpty) 'characters': s.characterNames,
      },
  ],
  'suggestions': <Map<String, Object?>>[
    for (final PersonSuggestion s in page.suggestions)
      <String, Object?>{
        'node': s.other.records.first.node,
        'name': s.other.displayName,
        'matchedName': s.matchedName,
      },
  ],
  'manualPairs': <List<String>>[
    for (final (String a, String b) in page.manualPairs) <String>[a, b],
  ],
};

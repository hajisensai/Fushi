import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show SrsCardCacheRow, SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/srs/srs_providers.dart';

/// 复习（SRS）：牌组 / 笔记查询、统计、sync v2 冲突、重复笔记合并的控制通道路由（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §2.2 / §8 P2）。CLI 侧命令见
/// `packages/fushi_cli/lib/src/commands/srs_commands.dart`（组 `srs`）。
///
/// 每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑：
/// - 牌组列表 = [SrsDbStore.deckSummaries]（牌组列表页）；
/// - 笔记搜索 = [SrsBrowseSession.query]（浏览页，Anki 搜索语法；
///   按字段搜 = [srsFieldContainsQuery]，与浏览页的字段下拉同一函数）；
/// - 统计 = [loadSrsStats]（统计页）；
/// - 冲突中心 = [SrsDbStore.sync2Conflicts] / [SrsDbStore.sync2Resolve]、
///   [SrsDbStore.syncConflicts] / [SrsDbStore.resolveConflict]、
///   [SrsDbStore.notesPendingDecision]、`duplicateNoteGroups` / `mergeNotes` /
///   `dismissDuplicates`（`srs_conflicts_page.dart` 直接调的同一组方法）。
///
/// 云同步（书 / 进度）中途的冲突不在这里：见 `ctl_data_routes.dart` 的
/// `/api/admin/sync/run`（`conflicts` 策略参数）。
const String kSrsCtlRoot = '/api/admin/srs';

/// 路由与撤销共用的依赖：store、模块门、写后通知界面刷新。测试注入假实现。
class SrsCtlDeps {
  const SrsCtlDeps({
    required this.store,
    required this.moduleEnabled,
    required this.changed,
  });

  /// 与页面同一个 store（`srsStoreProvider`）。null = 复习库没就绪。
  final Future<SrsDbStore?> Function() store;

  /// 复习模块开着（[ModuleId.srs]）。
  final bool Function() moduleEnabled;

  /// 写完后让打开着的复习页面重读（页面按钮写完也调同一个 `bumpSrsRevision`）。
  final void Function() changed;

  factory SrsCtlDeps.of(OpContext context) => SrsCtlDeps(
    store: () => readSrsStore(context.ref),
    moduleEnabled: () => context.appModel.moduleEnabled(ModuleId.srs),
    changed: () => bumpSrsRevision(context.ref),
  );
}

final Expando<SrsCtlDeps> _depsByContext = Expando<SrsCtlDeps>('srsCtlDeps');

/// [context] 上的复习依赖（路由与 `op_descriptions_srs.dart` 的撤销共用同一份）。
SrsCtlDeps srsCtlDeps(OpContext context) =>
    _depsByContext[context] ??= SrsCtlDeps.of(context);

/// 测试：给 [context] 换上假依赖（之后 [buildSrsCtlRoutes] 与撤销都用它）。
@visibleForTesting
void debugOverrideSrsCtlDeps(OpContext context, SrsCtlDeps deps) =>
    _depsByContext[context] = deps;

List<CtlRoute> buildSrsCtlRoutes(OpContext context) =>
    buildSrsCtlRoutesFor(srsCtlDeps(context));

/// 门控后的 store：模块关 → 422；复习库没就绪 → 422。
Future<SrsDbStore> requireSrsCtlStore(SrsCtlDeps deps) async {
  if (!deps.moduleEnabled()) {
    throw const CtlFailure.rejected('复习模块已关闭（设置 › 模块里打开）');
  }
  final SrsDbStore? store = await deps.store();
  if (store == null) {
    throw const CtlFailure.rejected('复习库还没就绪（稍后再试，或先打开一次复习页）');
  }
  return store;
}

/// 路由表本体：依赖按 [deps] 注入，测试不必起 [OpContext]。
List<CtlRoute> buildSrsCtlRoutesFor(SrsCtlDeps deps) => <CtlRoute>[
  CtlRoute.get('$kSrsCtlRoot/decks', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    return <String, Object?>{
      'decks': <Map<String, Object?>>[
        for (final SrsDeckSummary d in await store.deckSummaries())
          <String, Object?>{
            'id': d.deck.id,
            'name': d.fullName,
            'depth': d.depth,
            if (d.parentId != null) 'parentId': d.parentId,
            'new': d.newCount,
            'learn': d.learnCount,
            'review': d.reviewCount,
            'total': d.totalCards,
          },
      ],
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/notes', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsBrowseMode mode = switch (call.optString('mode') ?? 'notes') {
      'notes' => SrsBrowseMode.notes,
      'cards' => SrsBrowseMode.cards,
      final String other => throw CtlFailure.badRequest(
        'mode 只能是 notes / cards：$other',
      ),
    };
    final int limit = (call.optInt('limit') ?? 50).clamp(1, 1000);
    final int offset = (call.optInt('offset') ?? 0).clamp(0, 1 << 30);
    final String query = _browseQuery(call);
    // 与浏览页同一个常驻原生会话（按 profile）：只取这一页的行。
    final SrsBrowseResult result;
    try {
      result = await SrsBrowseSession(store).query(query: query, mode: mode);
    } on SrsSearchUnsupported catch (e) {
      throw CtlFailure.badRequest('搜索不合法：${e.reason}');
    }
    return <String, Object?>{
      'query': query,
      'mode': mode.name,
      'total': result.length,
      'items': <Map<String, Object?>>[
        for (final SrsBrowseRow r in await result.rows(offset, offset + limit))
          _browseItemJson(r, mode),
      ],
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/notes/:id', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final String id = call.params['id']!;
    final SrsNoteView? note = await store.note(id);
    if (note == null) throw CtlFailure.notFound('没有这条笔记：$id');
    final SrsNoteTypeView? type = await store.noteType(note.noteTypeId);
    final SrsDeckTree tree = await store.deckTree();
    return <String, Object?>{
      'id': note.id,
      'noteType': type?.name ?? note.noteTypeId,
      'fields': <String, String>{
        if (type != null)
          for (final SrsFieldDef f in type.fields) f.name: note.field(f.id)
        else
          ...note.fields,
      },
      'tags': note.tags,
      'createdAt': note.createdAt,
      if (note.deletedAt != null) 'deletedAt': note.deletedAt,
      if (note.hasPendingDecision) 'pendingDecision': true,
      'cards': <Map<String, Object?>>[
        for (final SrsCardCacheRow c in await store.cardsOfNote(id))
          if (!c.hidden) _cardJson(c, tree),
      ],
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/stats', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsStatsBundle bundle = await loadSrsStats(store);
    final String? deckArg = call.optString('deck');
    String? deckId;
    if (deckArg != null) {
      deckId = _resolveDeck(bundle.index.tree, deckArg);
    }
    // 与统计页的牌组筛选同一个子集（[SrsStatsData.subset]）。
    final SrsStatsData data = deckId == null
        ? bundle.data
        : bundle.data.subset(bundle.index.cardIdsInDeck(deckId));
    final SrsTodayStats today = data.todayStats();
    final SrsFutureDue due = data.futureDue(7);
    final SrsCardCounts counts = data.cardCounts();
    final SrsRetention month = data.retentionBetween(
      data.firstDayOf(SrsStatsRange.month),
      data.today,
    );
    final SrsStreak streak = data.streak();
    return <String, Object?>{
      if (deckId != null) 'deck': bundle.index.tree.fullName(deckId),
      'today': <String, Object?>{
        'reviews': today.count,
        'timeMs': today.durationMs,
        'correctRate': today.correctRate,
        'again': today.ratings[0],
        'hard': today.ratings[1],
        'good': today.ratings[2],
        'easy': today.ratings[3],
      },
      'due': <String, Object?>{
        'today': due.dueToday,
        'tomorrow': due.dueTomorrow,
        'overdue': due.overdue,
        'next7Days': due.total,
        if (due.byRecall > 0) 'byRecall': due.byRecall,
      },
      'cards': <String, Object?>{
        'new': counts.newCards,
        'learning': counts.learning,
        'relearning': counts.relearning,
        'young': counts.young,
        'mature': counts.mature,
        'suspended': counts.suspended,
        'buried': counts.buried,
        'total': counts.total,
      },
      'retention30d': <String, Object?>{
        'rate': month.rate,
        'young': month.youngRate,
        'mature': month.matureRate,
        'reviews': month.total,
      },
      'desiredRetention': data.desiredRetention(),
      'streak': <String, Object?>{
        'current': streak.current,
        'longest': streak.longest,
      },
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/conflicts', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsDeckTree tree = await store.deckTree();
    return <String, Object?>{
      'held': <Map<String, Object?>>[
        for (final Map<String, Object?> c in await store.sync2Conflicts())
          <String, Object?>{
            'id': c['id'],
            'kind': c['kind'],
            'entityKind': c['entityKind'],
            'entity': c['entity'],
            'label': await srsCtlEntityLabel(
              store,
              tree,
              SrsEntityKind.tryParse(c['entityKind'] as String?),
              c['entity'] as String? ?? '',
            ),
            'by': c['by'],
            'others': c['others'],
            'at': c['at'],
          },
      ],
      'fields': <Map<String, Object?>>[
        for (final (SrsEntityKind kind, String id, SrsRegister reg)
            in await store.syncConflicts())
          <String, Object?>{
            'kind': kind.wire,
            'entity': id,
            'key': reg.key,
            'label': await srsCtlEntityLabel(store, tree, kind, id),
            'current': _editJson(reg.winner!),
            'replaced': _editJson(reg.visibleLosers.first),
          },
      ],
      'pendingNotes': <Map<String, Object?>>[
        for (final SrsNoteCacheRow n in await store.notesPendingDecision())
          <String, Object?>{
            'id': n.id,
            'label': n.sortField,
            'reason': n.deletedAt != null ? 'delete' : 'fields',
          },
      ],
      'duplicates': <Map<String, Object?>>[
        for (final SrsDuplicateGroup g in await store.duplicateNoteGroups())
          <String, Object?>{
            'noteType': g.noteTypeId,
            'notes': <Map<String, Object?>>[
              for (final String id in g.noteIds)
                <String, Object?>{
                  'id': id,
                  'label': g.sortFields[id] ?? '',
                  'reviews': g.reviews[id] ?? 0,
                },
            ],
          },
      ],
    };
  }),
  // 冲突中心「删除被扣住」的「删除」：以删除为准（墓碑，内容仍在日志里；撤销 = 追加一条
  // deleted = null 的恢复，见 op_descriptions_srs.dart）。
  CtlRoute.post('$kSrsCtlRoot/conflicts/held/:id/delete', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final Map<String, Object?> held = await _requireHeld(store, call);
    final SrsEntityKind kind = _heldKind(held);
    final String entity = held['entity'] as String? ?? '';
    await store.sync2Resolve(held['id']! as String, delete: true);
    deps.changed();
    return <String, Object?>{
      'conflict': held['id'],
      'entityKind': kind.wire,
      'entity': entity,
      'deleted': true,
      'deletedAt': (await store.entityEdits(
        kind,
        entity,
      )).value(SrsFieldKeys.deleted),
    };
  }),
  // 「保留」：另一台设备的删除作废、条目照常保留。冲突项就此消失，回不到「待定」，要用户表态。
  CtlRoute.post('$kSrsCtlRoot/conflicts/held/:id/keep', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final Map<String, Object?> held = await _requireHeld(store, call);
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest(
        '「保留」会让另一台设备的删除作废、冲突项不再出现，需要确认（confirm: true / --yes）',
      );
    }
    await store.sync2Resolve(held['id']! as String, delete: false);
    deps.changed();
    return <String, Object?>{
      'conflict': held['id'],
      'entityKind': held['entityKind'],
      'entity': held['entity'],
      'deleted': false,
    };
  }),
  // 标志 / 设置类冲突：「确认」= 写当前值，「改回」= 写被覆盖的值（页面的两个按钮）。
  CtlRoute.post('$kSrsCtlRoot/conflicts/fields/resolve', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsEntityKind kind = srsCtlEntityKind(call.requireString('kind'));
    final String entity = call.requireString('entity');
    final String key = call.requireString('key');
    final String keep = call.requireString('keep');
    if (keep != 'current' && keep != 'replaced') {
      throw CtlFailure.badRequest('keep 只能是 current / replaced：$keep');
    }
    SrsRegister? reg;
    for (final (SrsEntityKind k, String id, SrsRegister r)
        in await store.syncConflicts(entity: (kind: kind, id: entity))) {
      if (k == kind && id == entity && r.key == key) reg = r;
    }
    if (reg == null) {
      throw CtlFailure.notFound(
        '没有这项冲突：${kind.wire}/$entity/$key（srs conflicts 查看）',
      );
    }
    final Object? previous = reg.winner!.value;
    final Object? value = keep == 'current'
        ? previous
        : reg.visibleLosers.first.value;
    await store.resolveConflict(kind, entity, key, value);
    deps.changed();
    return <String, Object?>{
      'kind': kind.wire,
      'entity': entity,
      'key': key,
      'keep': keep,
      'value': value,
      'previous': previous,
    };
  }),
  // 重复笔记「合并」：把 absorb 并进 keep（复习历史并入保留卡、空字段补齐、标签取并集、被吸收者墓碑化）。
  CtlRoute.post('$kSrsCtlRoot/duplicates/merge', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final String keep = call.requireString('keep');
    final List<String> absorb = <String>[
      for (final String id in call.stringList('absorb'))
        if (id != keep) id,
    ];
    if (absorb.isEmpty) {
      throw const CtlFailure.badRequest('absorb 至少给一条与 keep 不同的笔记');
    }
    final SrsMergeReport report;
    try {
      report = await store.mergeNotes(keepId: keep, absorbIds: absorb);
    } on StateError catch (e) {
      final String message = e.message;
      throw message.contains('not found')
          ? CtlFailure.notFound(message)
          : CtlFailure.badRequest(message);
    }
    deps.changed();
    final SrsNoteView? kept = await store.note(keep);
    return <String, Object?>{
      'keep': keep,
      'absorbed': absorb,
      'linkedCards': report.linkedCards,
      'unmatchedCards': report.unmatchedCards,
      if (kept != null) 'fields': kept.fields,
      if (kept != null) 'tags': kept.tags,
    };
  }),
  // 重复笔记「不是重复」：两两写 notDup 记录，之后不再建议这组。
  CtlRoute.post('$kSrsCtlRoot/duplicates/dismiss', (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final List<String> notes = call.stringList('notes').toSet().toList();
    if (notes.length < 2) {
      throw const CtlFailure.badRequest('notes 至少给两条笔记');
    }
    final Map<String, SrsNoteView?> views = await store.notes(notes);
    for (final String id in notes) {
      if (views[id] == null) throw CtlFailure.notFound('没有这条笔记：$id');
    }
    await store.dismissDuplicates(notes);
    deps.changed();
    return <String, Object?>{'dismissed': notes};
  }),
];

// ─────────────────────────────────────────────────────────────────────────
// 助手
// ─────────────────────────────────────────────────────────────────────────

/// 实体类型 wire 值（`deck` / `notetype` / `note` / `card` / `profile`）。
SrsEntityKind srsCtlEntityKind(String raw) =>
    SrsEntityKind.tryParse(raw) ??
    (throw CtlFailure.badRequest(
      'kind 只能是 ${SrsEntityKind.values.map((SrsEntityKind k) => k.wire).join(' / ')}：$raw',
    ));

/// 浏览查询：`q`（Anki 搜索语法）或 `field` + `q`（按字段包含，与浏览页字段下拉同一函数），
/// 再与 `deck`（牌组全名，含子牌组）取交。
String _browseQuery(CtlCall call) {
  final String text = call.optString('q') ?? '';
  final String? field = call.optString('field');
  final String? deck = call.optString('deck');
  return <String>[
    if (deck != null) srsDeckQuery(deck),
    if (field != null) srsFieldContainsQuery(field, text) else text,
  ].where((String s) => s.isNotEmpty).join(' ');
}

Map<String, Object?> _browseItemJson(SrsBrowseRow c, SrsBrowseMode mode) =>
    <String, Object?>{
      'noteId': c.noteId,
      if (mode == SrsBrowseMode.cards) 'cardId': c.cardId,
      'sortField': c.sortText,
      'noteType': c.noteTypeName,
      'deck': c.deckName,
      'tags': c.tags,
      if (mode == SrsBrowseMode.cards) ...<String, Object?>{
        'template': c.templateName,
        'queue': c.queue?.name,
        'dueInDays': c.dueInDays,
        'reps': c.reps,
        'lapses': c.lapses,
      } else
        'cards': c.cardCount,
    };

Map<String, Object?> _cardJson(SrsCardCacheRow c, SrsDeckTree tree) =>
    <String, Object?>{
      'id': c.id,
      'deck': tree[c.deckId] == null ? c.deckId : tree.fullName(c.deckId),
      'queue': c.queue,
      if (c.dueDay != null) 'dueDay': c.dueDay,
      if (c.dueAt != null) 'dueAt': c.dueAt,
      'intervalDays': c.scheduledDays,
      'reps': c.reps,
      'lapses': c.lapses,
      if (c.suspended) 'suspended': true,
      if (c.flag != 0) 'flag': c.flag,
    };

Map<String, Object?> _editJson(SrsFieldEdit e) => <String, Object?>{
  'value': e.value,
  'device': e.dot.writerId,
  'at': e.hlc.physical,
};

/// 牌组参数：id 或全名。
String _resolveDeck(SrsDeckTree tree, String raw) {
  if (tree[raw] != null) return raw;
  for (final SrsDeckView d in tree.decks) {
    if (tree.fullName(d.id) == raw) return d.id;
  }
  throw CtlFailure.notFound('没有这个牌组：$raw（srs decks 查看）');
}

Future<Map<String, Object?>> _requireHeld(
  SrsDbStore store,
  CtlCall call,
) async {
  final String id = call.params['id']!;
  for (final Map<String, Object?> c in await store.sync2Conflicts()) {
    if (c['id'] == id) return c;
  }
  throw CtlFailure.notFound('没有这项被扣住的删除：$id（srs conflicts 查看）');
}

SrsEntityKind _heldKind(Map<String, Object?> held) =>
    SrsEntityKind.tryParse(held['entityKind'] as String?) ??
    (throw CtlFailure.conflict('冲突项的实体类型不认识：${held['entityKind']}'));

/// 冲突里实体的人读名（与冲突中心页同口径）：牌组全名 / 笔记（卡片按所属笔记）的第一个字段 /
/// 笔记类型名。
Future<String> srsCtlEntityLabel(
  SrsDbStore store,
  SrsDeckTree tree,
  SrsEntityKind? kind,
  String id,
) async {
  String firstField(SrsNoteView? n, SrsNoteTypeView? nt) {
    final SrsFieldDef? first = nt?.fields.firstOrNull;
    if (n == null || first == null) return '';
    return n.field(first.id).replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  switch (kind) {
    case SrsEntityKind.deck:
      return tree[id] == null ? id : tree.fullName(id);
    case SrsEntityKind.card:
      final SrsCardDetail? d = await store.cardDetail(id);
      final String text = firstField(d?.note, d?.noteType);
      return text.isEmpty ? id : text;
    case SrsEntityKind.note:
      final SrsNoteView? n = await store.note(id);
      final String text = firstField(
        n,
        n == null ? null : await store.noteType(n.noteTypeId),
      );
      return text.isEmpty ? id : text;
    case SrsEntityKind.noteType:
      return (await store.noteType(id))?.name ?? id;
    case SrsEntityKind.profile:
      return 'profile';
    case null:
      return id;
  }
}

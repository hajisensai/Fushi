/// 复习（SRS）的控制通道路由：牌组 / 笔记查询、统计、sync v2 冲突、重复笔记合并、批量改笔记（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §2.2 / §8 P2）。app 与无头服务端共用的一份实现：
///
/// - app：`fushi/lib/src/ops/ctl_srs_routes.dart` 只做装配（当前 profile 的 store、模块门、写后让页面重读），
///   CLI 侧命令见 `packages/fushi_cli/lib/src/commands/srs_commands.dart`（组 `srs`）；
/// - 无头服务端：`packages/fushi_server/lib/src/admin/admin_srs_ctl.dart` 把同一张路由表挂在 admin API 下，
///   每份被提供的 profile 一个 store，调用方用 `profile` 参数点名（[kSrsCtlProfileParam]）。
///
/// 每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑：
/// - 牌组列表 = [SrsDbStore.deckSummaries]（牌组列表页）；
/// - 笔记搜索 = [SrsBrowseSession.query]（浏览页，Anki 搜索语法；
///   按字段搜 = [srsFieldContainsQuery]，与浏览页的字段下拉同一函数）；
/// - 统计 = [loadSrsStats]（统计页）；
/// - 冲突中心 = [SrsDbStore.sync2Conflicts] / [SrsDbStore.sync2Resolve]、
///   [SrsDbStore.syncConflicts] / [SrsDbStore.resolveConflict]、
///   [SrsDbStore.notesPendingDecision]、`duplicateNoteGroups` / `mergeNotes` /
///   `dismissDuplicates`（app 的 `srs_conflicts_page.dart` 直接调的同一组方法）；
/// - 批量改笔记（设置卡型 / 设置字段 / 查找替换）= `srs_note_batch_edit.dart` 的 `srsPlan*` +
///   [srsApplyNoteFieldPlan]（浏览页批量菜单）。
///
/// 操作描述与撤销（给 AI 助手的工具集）在 `srs_ctl_ops.dart`。
library;

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show SrsCardCacheRow, SrsEntityRow, SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';

const String kSrsCtlRoot = '/api/admin/srs';

/// 点名 profile 的参数名（query 或 body）。只有多 profile 的宿主认它；单库宿主忽略。
const String kSrsCtlProfileParam = 'profile';

/// 一次调用（或一次撤销）作用的那份复习库。
class SrsCtlTarget {
  const SrsCtlTarget(this.store, {this.profile});

  final SrsDbStore store;

  /// 多 profile 宿主（无头服务端）里这份库的 profile uid：进撤销载荷，撤销时回到同一份；写后通知也按它。
  /// 单库宿主（app：只有当前 profile）为 null，撤销载荷里不带。
  final String? profile;
}

/// 路由与撤销共用的宿主依赖：取库（含宿主自己的门：模块开关、库是否就绪、点名的 profile 有没有提供）、
/// 写后通知。
class SrsCtlHost {
  const SrsCtlHost({required this.open, required this.changed});

  /// 取这次调用作用的库。[profile] = 调用方给的 [kSrsCtlProfileParam]（没给 = null）；撤销时是执行那次
  /// 记进载荷的 [SrsCtlTarget.profile]。不可用时抛 [CtlFailure]。
  final Future<SrsCtlTarget> Function(String? profile) open;

  /// 写完后通知宿主（app：让打开着的复习页面重读；服务端：把这份 profile 发出去）。
  final void Function(SrsCtlTarget target) changed;
}

/// 这次调用实际打开的那份库（按 [CtlCall] 实例挂，随调用对象回收）：撤销快照从这里取
/// [SrsCtlTarget.profile]，与路由 handler 用的是同一份。
final Expando<SrsCtlTarget> _targetByCall = Expando<SrsCtlTarget>(
  'srsCtlTarget',
);

/// 按 [call] 的 [kSrsCtlProfileParam] 取库，并记下这次调用作用的是哪一份。
Future<SrsCtlTarget> srsCtlOpen(SrsCtlHost host, CtlCall call) async =>
    _targetByCall[call] = await host.open(call.optString(kSrsCtlProfileParam));

/// [call] 这次调用作用的 profile（多 profile 宿主）；单库宿主、或这次调用没取过库时 null。
String? srsCtlProfileOf(CtlCall call) => _targetByCall[call]?.profile;

/// 多 profile 宿主（[SrsCtlTarget.profile] 非空）：调用方按 id 点名的笔记必须属于这次作用的那一份。
///
/// 复习库按 id 的读写（[SrsDbStore.note] / `mergeNotes` / `dismissDuplicates` / 批量改字段）不按
/// profile 过滤：一份 srs.db 里别的 profile 的 id 也取得到、也写得进。点名 A 却给了 B 的 id 时不拦就是
/// 写错库（实测：合并会把 B 的笔记删掉，设字段会往 B 的笔记上写 A 的字段 id）。属于别的 profile 的 id
/// 按「不存在」回 404；库里根本没有的 id 交回各路由原有的处理。
///
/// 单库宿主（app）不查，行为与下沉前相同——那边同样的缺口单独记在 BUG-4480。
Future<void> _requireInTarget(SrsCtlTarget target, List<String> ids) async {
  if (target.profile == null || ids.isEmpty) return;
  final SrsDbStore store = target.store;
  for (int i = 0; i < ids.length; i += _kOwnerLookupChunk) {
    final List<String> chunk = ids.sublist(
      i,
      i + _kOwnerLookupChunk > ids.length ? ids.length : i + _kOwnerLookupChunk,
    );
    final SrsEntityRow? foreign =
        await (store.db.select(store.db.srsEntities)
              ..where(
                (t) =>
                    t.id.isIn(chunk) &
                    t.profileUid.equals(store.profileUid).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (foreign != null) throw CtlFailure.notFound('没有这条笔记：${foreign.id}');
  }
}

/// [_requireInTarget] 一次查询的 id 数（SQLite 绑定变量上限之内）。
const int _kOwnerLookupChunk = 500;

/// 路由表本体：宿主依赖按 [host] 注入。
List<CtlRoute> srsCtlRoutes(SrsCtlHost host) => <CtlRoute>[
  CtlRoute.get('$kSrsCtlRoot/decks', (CtlCall call) async {
    final SrsDbStore store = (await srsCtlOpen(host, call)).store;
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
            // RWKV 牌组的 review = 今天结束前回忆率会降到目标以下的卡。
            if (d.rwkvScheduled) 'reviewByRwkv': true,
            'total': d.totalCards,
          },
      ],
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/notes', (CtlCall call) async {
    final SrsDbStore store = (await srsCtlOpen(host, call)).store;
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
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
    final String id = call.params['id']!;
    await _requireInTarget(target, <String>[id]);
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
    final SrsDbStore store = (await srsCtlOpen(host, call)).store;
    final SrsStatsLoad bundle = await loadSrsStats(store);
    final String? deckArg = call.optString('deck');
    String? deckId;
    if (deckArg != null) {
      deckId = _resolveDeck(bundle.tree, deckArg);
    }
    // 与统计页的牌组筛选同一个子集（牌组子树里的卡）。
    final SrsStatsReport data = await bundle.report(
      decks: deckId == null ? null : bundle.subtree(deckId),
      futureDays: 7,
    );
    final SrsTodayStats today = data.todayStats;
    final SrsFutureDue due = data.future;
    final SrsCardCounts counts = data.cardCounts;
    final SrsRetention month = data.rangeRetention;
    final SrsStreak streak = data.streak;
    return <String, Object?>{
      if (deckId != null) 'deck': bundle.tree.fullName(deckId),
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
      'desiredRetention': data.desiredRetention,
      'streak': <String, Object?>{
        'current': streak.current,
        'longest': streak.longest,
      },
    };
  }),
  CtlRoute.get('$kSrsCtlRoot/conflicts', (CtlCall call) async {
    final SrsDbStore store = (await srsCtlOpen(host, call)).store;
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
  // 冲突中心「删除被扣住」的「删除」：以删除为准（墓碑，内容仍在日志里；撤销 = 按撤销凭据追加一条
  // deleted = null 的恢复，见 srs_ctl_ops.dart）。
  CtlRoute.post('$kSrsCtlRoot/conflicts/held/:id/delete', (CtlCall call) async {
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
    final Map<String, Object?> held = await _requireHeld(store, call);
    final SrsEntityKind kind = _heldKind(held);
    final String entity = held['entity'] as String? ?? '';
    srsCtlUndo[call] = (await store.undoable(
      () => store.sync2Resolve(held['id']! as String, delete: true),
    )).$2;
    host.changed(target);
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
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
    final Map<String, Object?> held = await _requireHeld(store, call);
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest(
        '「保留」会让另一台设备的删除作废、冲突项不再出现，需要确认（confirm: true / --yes）',
      );
    }
    await store.sync2Resolve(held['id']! as String, delete: false);
    host.changed(target);
    return <String, Object?>{
      'conflict': held['id'],
      'entityKind': held['entityKind'],
      'entity': held['entity'],
      'deleted': false,
    };
  }),
  // 标志 / 设置类冲突：「确认」= 写当前值，「改回」= 写被覆盖的值（页面的两个按钮）。
  CtlRoute.post('$kSrsCtlRoot/conflicts/fields/resolve', (CtlCall call) async {
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
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
    srsCtlUndo[call] = (await store.undoable(
      () => store.resolveConflict(kind, entity, key, value),
    )).$2;
    host.changed(target);
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
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
    final String keep = call.requireString('keep');
    final List<String> absorb = <String>[
      for (final String id in call.stringList('absorb'))
        if (id != keep) id,
    ];
    if (absorb.isEmpty) {
      throw const CtlFailure.badRequest('absorb 至少给一条与 keep 不同的笔记');
    }
    await _requireInTarget(target, <String>[keep, ...absorb]);
    final SrsMergeReport report;
    try {
      final (SrsMergeReport r, SrsEditUndo undo) = await store.undoable(
        () => store.mergeNotes(keepId: keep, absorbIds: absorb),
      );
      report = r;
      srsCtlUndo[call] = undo;
    } on StateError catch (e) {
      final String message = e.message;
      throw message.contains('not found')
          ? CtlFailure.notFound(message)
          : CtlFailure.badRequest(message);
    }
    host.changed(target);
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
    final SrsCtlTarget target = await srsCtlOpen(host, call);
    final SrsDbStore store = target.store;
    final List<String> notes = call.stringList('notes').toSet().toList();
    if (notes.length < 2) {
      throw const CtlFailure.badRequest('notes 至少给两条笔记');
    }
    await _requireInTarget(target, notes);
    final Map<String, SrsNoteView?> views = await store.notes(notes);
    for (final String id in notes) {
      if (views[id] == null) throw CtlFailure.notFound('没有这条笔记：$id');
    }
    srsCtlUndo[call] = (await store.undoable(
      () => store.dismissDuplicates(notes),
    )).$2;
    host.changed(target);
    return <String, Object?>{'dismissed': notes};
  }),
  // 批量改笔记（浏览页批量菜单的「设置卡型 / 设置字段 / 查找替换」同一组引擎函数）。
  for (final SrsCtlNoteBatch op in SrsCtlNoteBatch.values)
    CtlRoute.post('$kSrsCtlRoot/notes/batch/${op.wire}', (CtlCall call) async {
      final SrsCtlTarget target = await srsCtlOpen(host, call);
      final SrsDbStore store = target.store;
      await _requireInTarget(target, call.stringList('notes'));
      final (SrsNoteFieldPlan plan, Map<String, Object?> echo) =
          await srsCtlPlanNoteBatch(store, call, op);
      final bool dryRun = call.optBool('dryRun') ?? false;
      if (dryRun || plan.isEmpty) {
        return srsCtlNotePlanJson(plan, echo, dryRun: dryRun);
      }
      final SrsNoteFieldApplied applied = await srsApplyNoteFieldPlan(
        store,
        plan,
      );
      srsCtlUndo[call] = applied.undo;
      if (applied.changes.isNotEmpty) host.changed(target);
      return srsCtlNotePlanJson(plan, echo, dryRun: false, applied: applied);
    }),
];

/// 这次调用写入的撤销凭据（按 [CtlCall] 实例挂，随调用对象回收；语义见
/// `package:fushi_engine/srs/srs_edit_undo.dart`）。撤销载荷（`srs_ctl_ops.dart`）从这里取：
/// 载荷 = 实际写下的改动与它们的 dot，不在执行前另算一遍；凭据也不进回给调用方 / 模型的结果。
final Expando<SrsEditUndo> srsCtlUndo = Expando<SrsEditUndo>('srsCtlUndo');

/// 三种批量改笔记（路由段名 = [wire]）。
enum SrsCtlNoteBatch {
  cardType('card-type'),
  setField('set-field'),
  findReplace('find-replace');

  const SrsCtlNoteBatch(this.wire);
  final String wire;
}

/// 一次批量改笔记最多处理的笔记数（防止一句宽泛的查询把整个库都改了）。
const int kSrsCtlBatchNoteLimit = 5000;

/// body / query 里的原样字符串（不 trim：查找替换与字段值里的空白有意义）。
String? _rawString(CtlCall call, String name) {
  final Object? raw = call.body[name] ?? call.query[name];
  return raw == null ? null : '$raw';
}

/// 批量目标：`notes`（笔记 id 数组）或查询（`q` / `field` / `deck`，与 `srs.notes.search`
/// 同一套）。两者都没给 → 400（不允许「不给条件 = 全库」）。
Future<List<String>> _batchTargets(SrsDbStore store, CtlCall call) async {
  final List<String> ids = call.stringList('notes');
  if (ids.isNotEmpty) {
    if (ids.length > kSrsCtlBatchNoteLimit) {
      throw CtlFailure.badRequest(
        '一次最多改 $kSrsCtlBatchNoteLimit 条笔记（给了 ${ids.length} 条）',
      );
    }
    return ids;
  }
  final String query = _browseQuery(call);
  if (query.isEmpty) {
    throw const CtlFailure.badRequest('给 notes（笔记 id）或 q / field / deck 查询条件');
  }
  final SrsBrowseResult result;
  try {
    result = await SrsBrowseSession(
      store,
    ).query(query: query, mode: SrsBrowseMode.notes);
  } on SrsSearchUnsupported catch (e) {
    throw CtlFailure.badRequest('搜索不合法：${e.reason}');
  }
  if (result.length > kSrsCtlBatchNoteLimit) {
    throw CtlFailure.badRequest(
      '查询命中 ${result.length} 条笔记，超过一次 $kSrsCtlBatchNoteLimit 条的上限；缩小查询再试',
    );
  }
  return <String>[
    for (final SrsBrowseRow r in await result.rows(0, result.length)) r.noteId,
  ];
}

/// 按 [call] 的参数算出 [op] 的修改计划（只读；路由里算一次，预演就到此为止）。
Future<(SrsNoteFieldPlan, Map<String, Object?>)> srsCtlPlanNoteBatch(
  SrsDbStore store,
  CtlCall call,
  SrsCtlNoteBatch op,
) async {
  switch (op) {
    case SrsCtlNoteBatch.cardType:
      final String raw = call.requireString('type');
      final SrsCardType type =
          SrsCardType.tryParse(raw) ??
          (throw CtlFailure.badRequest(
            'type 只能是 ${SrsCardType.values.map((SrsCardType t) => t.wire).join(' / ')}：$raw',
          ));
      final List<String> notes = await _batchTargets(store, call);
      return (
        await srsPlanCardType(store, notes, type),
        <String, Object?>{'type': type.wire},
      );
    case SrsCtlNoteBatch.setField:
      final String field = call.requireString('targetField');
      final String value = _rawString(call, 'value') ?? '';
      final List<String> notes = await _batchTargets(store, call);
      return (
        await srsPlanSetField(store, notes, field, value),
        <String, Object?>{'targetField': field, 'value': value},
      );
    case SrsCtlNoteBatch.findReplace:
      final String find = _rawString(call, 'find') ?? '';
      if (find.isEmpty) throw const CtlFailure.badRequest('find 缺失');
      final String replace = _rawString(call, 'replace') ?? '';
      final String? field = call.optString('targetField');
      final bool regex = call.optBool('regex') ?? false;
      final List<String> notes = await _batchTargets(store, call);
      try {
        return (
          await srsPlanFindReplace(
            store,
            notes,
            fieldName: field,
            find: find,
            replace: replace,
            regex: regex,
            caseSensitive: call.optBool('caseSensitive') ?? true,
          ),
          <String, Object?>{
            'find': find,
            'replace': replace,
            'targetField': ?field,
            'regex': regex,
          },
        );
      } on FormatException catch (e) {
        throw CtlFailure.badRequest('正则不合法：${e.message}');
      }
  }
}

/// 回给调用方的摘要：改动只给前 [kSrsCtlBatchSampleSize] 条样例（字段值截短），不把整批
/// HTML 塞给模型；完整的改动清单只进撤销快照。[applied] 非空 = 已落库：条数按实际写下的算，
/// `conflicts` = 计划之后又被改过、因而没写的笔记数。
Map<String, Object?> srsCtlNotePlanJson(
  SrsNoteFieldPlan plan,
  Map<String, Object?> echo, {
  required bool dryRun,
  SrsNoteFieldApplied? applied,
}) => <String, Object?>{
  ...echo,
  'dryRun': dryRun,
  'notes': applied?.noteCount ?? plan.noteCount,
  'fieldChanges': applied?.changes.length ?? plan.changes.length,
  if (applied != null && applied.conflicts > 0) 'conflicts': applied.conflicts,
  'unchanged': plan.unchanged,
  'skipped': plan.skipped.length,
  if (plan.skipped.isNotEmpty)
    'skippedSample': plan.skipped.take(kSrsCtlBatchSampleSize).toList(),
  if (plan.missing.isNotEmpty) 'missing': plan.missing,
  'sample': <Map<String, Object?>>[
    for (final SrsNoteFieldChange c in (applied?.changes ?? plan.changes).take(
      kSrsCtlBatchSampleSize,
    ))
      <String, Object?>{
        'note': c.noteId,
        'field': c.fieldName,
        'before': _clip(c.before),
        'after': _clip(c.after),
      },
  ],
};

/// 摘要里的改动样例条数。
const int kSrsCtlBatchSampleSize = 20;

String _clip(String s) => s.length <= 160 ? s : '${s.substring(0, 160)}…';

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

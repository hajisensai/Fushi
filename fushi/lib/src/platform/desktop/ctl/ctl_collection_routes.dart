import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_settings.dart';

import 'package:fushi/src/media/collections/collection_ai_order.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show
        collectionDetailSortPrefKey,
        kCollectionDetailManualSortValue,
        loadCollectionMemberMeta,
        sortedCollectionRows;
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

/// collection 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/collection_commands.dart`）。
///
/// 每条路由调合集详情页按钮背后的同一个方法：手动定序 = 拖拽落盘的
/// `reorderCollectionItems`；按名称 / 导入时间 = 一键整理的 [sortedCollectionRows]；
/// AI = 详情页「AI 排序」的 [runCollectionAiOrder]（用户意图）。三者落盘后都把详情
/// 页排序偏好切成 manual，与页面行为一致。
List<CtlRoute> buildCollectionCtlRoutes(DesktopCtlContext context) {
  FushiDatabase db() => context.appModel.database;
  return buildCollectionCtlRoutesFor(
    database: db,
    aiSettings: () => context.appModel.prefsRepo,
  );
}

/// 路由表本体：数据库与 AI 指派来源按回调注入，测试不必起 [DesktopCtlContext]。
List<CtlRoute> buildCollectionCtlRoutesFor({
  required FushiDatabase Function() database,
  required AiSettingsSource Function() aiSettings,
  CollectionAiClientFactory? aiClientFactory,
}) {
  return <CtlRoute>[
    CtlRoute.get(kCollectionCtlRoot, (CtlCall call) async {
      final FushiDatabase db = database();
      final Map<int, int> counts = <int, int>{};
      for (final MediaCollectionItemRow r in await db.getAllCollectionItems()) {
        counts[r.collectionId] = (counts[r.collectionId] ?? 0) + 1;
      }
      return <String, Object?>{
        'collections': <Map<String, Object?>>[
          for (final MediaCollectionRow c in await db.getAllMediaCollections())
            <String, Object?>{
              'id': c.id,
              'name': c.name,
              'type': c.collectionType,
              'members': counts[c.id] ?? 0,
              'manualOrder': c.orderUpdatedAt > 0,
            },
        ],
      };
    }),
    CtlRoute.get('$kCollectionCtlRoot/:id/items', (CtlCall call) async {
      final FushiDatabase db = database();
      final MediaCollectionRow collection = await _collection(db, call);
      return _itemsJson(db, collection);
    }),
    CtlRoute.put('$kCollectionCtlRoot/:id/order', (CtlCall call) async {
      final FushiDatabase db = database();
      final MediaCollectionRow collection = await _collection(db, call);
      final List<String> tokens = call.stringList('keys');
      if (tokens.isEmpty) throw const CtlFailure.badRequest('keys 缺失');
      final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
        collection.id,
      );
      final List<CollectionMemberKey> ordered = resolveCollectionCtlKeys(
        rows,
        tokens,
      );
      // 子集是 DAO 的合法用法：没点名的成员留在原槽位（BUG-1194 的不变量）。
      await db.reorderCollectionItems(collection.id, ordered);
      await _markManual(db, collection.id);
      return _itemsJson(db, collection);
    }),
    CtlRoute.post('$kCollectionCtlRoot/:id/sort', (CtlCall call) async {
      final FushiDatabase db = database();
      final MediaCollectionRow collection = await _collection(db, call);
      final String by = call.requireString('by');
      final bool dryRun = call.optBool('dryRun') ?? false;
      switch (by) {
        case 'title' || 'imported':
          return _sortByRule(
            db,
            collection,
            byTitle: by == 'title',
            dryRun: dryRun,
          );
        case 'ai':
          final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
            db: db,
            collectionId: collection.id,
            settings: aiSettings(),
            userIntent: true,
            dryRun: dryRun,
            clientFactory: aiClientFactory,
          );
          if (outcome.status == CollectionAiOrderStatus.noProvider) {
            throw const CtlFailure.rejected(
              '「合集排序」没有指派 AI 提供商（设置 › 模型 › LLM），未发请求',
            );
          }
          return collectionAiOutcomeJson(
            collection.id,
            outcome,
            dryRun: dryRun,
          );
      }
      throw CtlFailure.badRequest('by 只能是 title / imported / ai：$by');
    }),
  ];
}

/// 路由根。
const String kCollectionCtlRoot = '/api/admin/collections';

Future<MediaCollectionRow> _collection(FushiDatabase db, CtlCall call) async {
  final int? id = int.tryParse(call.params['id'] ?? '');
  if (id == null || id <= 0) {
    throw CtlFailure.badRequest('合集 id 必须是正整数：${call.params['id']}');
  }
  final MediaCollectionRow? row = await db.getMediaCollectionById(id);
  if (row == null) throw CtlFailure.notFound('合集 $id 不存在');
  return row;
}

/// CLI 展示 / 接收的成员键：`<mediaType>:<entryKey>`。
String collectionCtlKey(MediaCollectionItemRow row) =>
    '${row.mediaType}:${row.entryKey}';

/// 把 CLI 给的键解析成本合集里的成员：认 `<mediaType>:<entryKey>`、
/// `<mediaType>|<entryKey>`，以及在本合集内唯一的裸 entryKey。认不出、有歧义或
/// 重复给出一律 400——不能静默丢掉用户点名的成员。
List<CollectionMemberKey> resolveCollectionCtlKeys(
  List<MediaCollectionItemRow> rows,
  List<String> tokens,
) {
  final List<CollectionMemberKey> out = <CollectionMemberKey>[];
  final Set<String> seen = <String>{};
  for (final String token in tokens) {
    final List<MediaCollectionItemRow> hits = <MediaCollectionItemRow>[
      for (final MediaCollectionItemRow r in rows)
        if (collectionCtlKey(r) == token ||
            '${r.mediaType}|${r.entryKey}' == token)
          r,
    ];
    if (hits.isEmpty) {
      hits.addAll(<MediaCollectionItemRow>[
        for (final MediaCollectionItemRow r in rows)
          if (r.entryKey == token) r,
      ]);
    }
    if (hits.isEmpty) {
      throw CtlFailure.badRequest('合集里没有成员 $token');
    }
    if (hits.length > 1) {
      throw CtlFailure.badRequest('成员键 $token 有歧义，请写成 <mediaType>:<entryKey>');
    }
    final MediaCollectionItemRow hit = hits.single;
    if (!seen.add(collectionCtlKey(hit))) {
      throw CtlFailure.badRequest('成员 ${collectionCtlKey(hit)} 重复给出');
    }
    out.add((mediaType: hit.mediaType, entryKey: hit.entryKey));
  }
  return out;
}

Future<Map<String, Object?>> _itemsJson(
  FushiDatabase db,
  MediaCollectionRow collection,
) async {
  final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
    collection.id,
  );
  final Map<String, ({String title, int importedAt})> meta =
      await loadCollectionMemberMeta(db);
  return <String, Object?>{
    'id': collection.id,
    'name': collection.name,
    'items': <Map<String, Object?>>[
      for (final MediaCollectionItemRow r in rows)
        <String, Object?>{
          'key': collectionCtlKey(r),
          'mediaType': r.mediaType,
          'entryKey': r.entryKey,
          'title': meta['${r.mediaType}|${r.entryKey}']?.title ?? r.entryKey,
          'sortIndex': r.sortIndex,
        },
    ],
  };
}

Future<Map<String, Object?>> _sortByRule(
  FushiDatabase db,
  MediaCollectionRow collection, {
  required bool byTitle,
  required bool dryRun,
}) async {
  final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
    collection.id,
  );
  final List<MediaCollectionItemRow> next = await sortedCollectionRows(
    db: db,
    rows: rows,
    byTitle: byTitle,
  );
  bool changed = false;
  for (int i = 0; i < rows.length; i++) {
    if (collectionCtlKey(rows[i]) != collectionCtlKey(next[i])) changed = true;
  }
  if (!dryRun && rows.length > 1) {
    await db.reorderCollectionItems(collection.id, <CollectionMemberKey>[
      for (final MediaCollectionItemRow r in next)
        (mediaType: r.mediaType, entryKey: r.entryKey),
    ]);
    await _markManual(db, collection.id);
  }
  final Map<String, ({String title, int importedAt})> meta =
      await loadCollectionMemberMeta(db);
  return <String, Object?>{
    'id': collection.id,
    'status': 'sorted',
    'changed': changed,
    'persisted': !dryRun && rows.length > 1,
    'dryRun': dryRun,
    'order': <Map<String, Object?>>[
      for (final MediaCollectionItemRow r in next)
        <String, Object?>{
          'key': collectionCtlKey(r),
          'title': meta['${r.mediaType}|${r.entryKey}']?.title ?? r.entryKey,
          'ambiguous': false,
        },
    ],
  };
}

/// AI 排序结论 → 线上 JSON（状态名即 [CollectionAiOrderStatus] 的枚举名）。
Map<String, Object?> collectionAiOutcomeJson(
  int collectionId,
  CollectionAiOrderOutcome outcome, {
  required bool dryRun,
}) => <String, Object?>{
  'id': collectionId,
  'status': outcome.status.name,
  'changed': outcome.changed,
  'persisted': outcome.persisted,
  'dryRun': dryRun,
  if (outcome.failure != null) 'failure': outcome.failure,
  'order': <Map<String, Object?>>[
    for (final CollectionAiOrderEntry e in outcome.order)
      <String, Object?>{
        'key': '${e.mediaType}:${e.entryKey}',
        'title': e.title,
        'ambiguous': e.ambiguous,
      },
  ],
};

Future<void> _markManual(FushiDatabase db, int collectionId) => db.setPref(
  collectionDetailSortPrefKey(collectionId),
  kCollectionDetailManualSortValue,
);

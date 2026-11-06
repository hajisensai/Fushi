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
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_library_shelf.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 合集「定序」路由：手动定序与一键排序（含 AI）。与合集的列出 / 详情 / 建删改 /
/// 成员增删同在 `/api/admin/library/collections` 下，由
/// `buildLibraryManageCtlRoutes` 一并注册；CLI 侧是同一个 `collection` 命令组的
/// `order` / `sort`（`packages/fushi_cli/lib/src/commands/collection_commands.dart`）。
///
/// 每条路由调合集详情页按钮背后的同一个方法：手动定序 = 拖拽落盘的
/// `reorderCollectionItems`；按名称 / 导入时间 = 一键整理的 [sortedCollectionRows]；
/// AI = 详情页「AI 排序」的 [runCollectionAiOrder]（用户意图）。三者落盘后都把详情
/// 页排序偏好切成 manual，与页面行为一致。
///
/// 成员键与 `collection get` / `add` / `remove` 同一形状（[LibraryCtlKey]：
/// `book:` / `srt:` / `video:` / `game:`），由 [LibraryCtlShelf.keyForCollectionMember]
/// 从成员行换算，不另立一套键。
List<CtlRoute> buildCollectionCtlRoutes(OpContext context) {
  return buildCollectionCtlRoutesFor(
    database: () => context.appModel.database,
    shelf: () => LibraryCtlShelf(
      db: context.appModel.database,
      galgameRepo: context.appModel.galgameRepo,
    ),
    aiSettings: () => context.appModel.prefsRepo,
    isReadonly: () => context.appModel.isMigrationReadonly,
  );
}

/// 路由表本体：数据库、书架执行层与 AI 指派来源按回调注入，测试不必起
/// [OpContext]。
List<CtlRoute> buildCollectionCtlRoutesFor({
  required FushiDatabase Function() database,
  required LibraryCtlShelf Function() shelf,
  required AiSettingsSource Function() aiSettings,
  CollectionAiClientFactory? aiClientFactory,
  bool Function()? isReadonly,
}) {
  // 与书架管理其它写路由同一闸门：数据已迁到新版时旧版只读。dry-run 不写库，放行。
  void requireWritable({bool dryRun = false}) {
    if (!dryRun && (isReadonly?.call() ?? false)) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  return <CtlRoute>[
    CtlRoute.put('$kCollectionCtlRoot/:id/order', (CtlCall call) async {
      final FushiDatabase db = database();
      final LibraryCtlShelf s = shelf();
      final MediaCollectionRow collection = await _collection(db, call);
      final List<String> tokens = call.stringList('keys');
      if (tokens.isEmpty) throw const CtlFailure.badRequest('keys 缺失');
      requireWritable();
      final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
        collection.id,
      );
      final List<CollectionMemberKey> ordered = resolveCollectionCtlKeys(
        await _keyedRows(s, rows),
        tokens,
      );
      // 子集是 DAO 的合法用法：没点名的成员留在原槽位（BUG-1194 的不变量）。
      await db.reorderCollectionItems(collection.id, ordered);
      await _markManual(db, collection.id);
      return s.collectionDetail(collection.id);
    }),
    CtlRoute.post('$kCollectionCtlRoot/:id/sort', (CtlCall call) async {
      final FushiDatabase db = database();
      final LibraryCtlShelf s = shelf();
      final MediaCollectionRow collection = await _collection(db, call);
      final String by = call.requireString('by');
      final bool dryRun = call.optBool('dryRun') ?? false;
      requireWritable(dryRun: dryRun);
      switch (by) {
        case 'title' || 'imported':
          return _sortByRule(
            db,
            s,
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
            keys: <String, String>{
              for (final CollectionAiOrderEntry e in outcome.order)
                _rawKey(e.mediaType, e.entryKey): await _wireKey(
                  s,
                  e.mediaType,
                  e.entryKey,
                ),
            },
          );
      }
      throw CtlFailure.badRequest('by 只能是 title / imported / ai：$by');
    }),
  ];
}

/// 路由根：与 `kLibraryCtlManageRoot` 下合集的列出 / 详情 / 建删改同一前缀
/// （测试钉住两者一致）。
const String kCollectionCtlRoot = '/api/admin/library/collections';

Future<MediaCollectionRow> _collection(FushiDatabase db, CtlCall call) async {
  final int? id = int.tryParse(call.params['id'] ?? '');
  if (id == null || id <= 0) {
    throw CtlFailure.badRequest('合集 id 必须是正整数：${call.params['id']}');
  }
  final MediaCollectionRow? row = await db.getMediaCollectionById(id);
  if (row == null) throw CtlFailure.notFound('没有 id=$id 的合集');
  return row;
}

String _rawKey(String mediaType, String entryKey) => '$mediaType|$entryKey';

/// 成员行在 CLI 上的键（[LibraryCtlKey.wire]）；未知种类的透传行没有条目键，
/// 退回 `<mediaType>|<entryKey>` 原值。
Future<String> _wireKey(
  LibraryCtlShelf shelf,
  String mediaType,
  String entryKey,
) async =>
    (await shelf.keyForCollectionMemberRef(mediaType, entryKey))?.wire ??
    _rawKey(mediaType, entryKey);

Future<List<({MediaCollectionItemRow row, String key})>> _keyedRows(
  LibraryCtlShelf shelf,
  List<MediaCollectionItemRow> rows,
) async => <({MediaCollectionItemRow row, String key})>[
  for (final MediaCollectionItemRow r in rows)
    (row: r, key: await _wireKey(shelf, r.mediaType, r.entryKey)),
];

/// 把 CLI 给的键解析成本合集里的成员：认条目键（`collection get` 列出的
/// `book:` / `srt:` / `video:` / `game:` 形状），以及在本合集内唯一的裸 id。认不出、
/// 有歧义或重复给出一律 400——不能静默丢掉用户点名的成员。
List<CollectionMemberKey> resolveCollectionCtlKeys(
  List<({MediaCollectionItemRow row, String key})> rows,
  List<String> tokens,
) {
  final List<CollectionMemberKey> out = <CollectionMemberKey>[];
  final Set<String> seen = <String>{};
  for (final String token in tokens) {
    final List<({MediaCollectionItemRow row, String key})> hits =
        <({MediaCollectionItemRow row, String key})>[
          for (final ({MediaCollectionItemRow row, String key}) r in rows)
            if (r.key == token) r,
        ];
    if (hits.isEmpty) {
      hits.addAll(<({MediaCollectionItemRow row, String key})>[
        for (final ({MediaCollectionItemRow row, String key}) r in rows)
          if (r.row.entryKey == token ||
              LibraryCtlKey.tryParse(r.key)?.id == token)
            r,
      ]);
    }
    if (hits.isEmpty) {
      throw CtlFailure.badRequest('合集里没有成员 $token（键见 collection get）');
    }
    if (hits.length > 1) {
      throw CtlFailure.badRequest('成员键 $token 有歧义，请写完整的条目键（见 collection get）');
    }
    final ({MediaCollectionItemRow row, String key}) hit = hits.single;
    if (!seen.add(hit.key)) {
      throw CtlFailure.badRequest('成员 ${hit.key} 重复给出');
    }
    out.add((mediaType: hit.row.mediaType, entryKey: hit.row.entryKey));
  }
  return out;
}

Future<Map<String, Object?>> _sortByRule(
  FushiDatabase db,
  LibraryCtlShelf shelf,
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
    if (_rawKey(rows[i].mediaType, rows[i].entryKey) !=
        _rawKey(next[i].mediaType, next[i].entryKey)) {
      changed = true;
    }
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
          'key': await _wireKey(shelf, r.mediaType, r.entryKey),
          'title': meta[_rawKey(r.mediaType, r.entryKey)]?.title ?? r.entryKey,
          'ambiguous': false,
        },
    ],
  };
}

/// AI 排序结论 → 线上 JSON（状态名即 [CollectionAiOrderStatus] 的枚举名）。
/// [keys] 把成员原值（`<mediaType>|<entryKey>`）换成 CLI 条目键；缺项退回原值。
Map<String, Object?> collectionAiOutcomeJson(
  int collectionId,
  CollectionAiOrderOutcome outcome, {
  required bool dryRun,
  Map<String, String> keys = const <String, String>{},
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
        'key':
            keys[_rawKey(e.mediaType, e.entryKey)] ??
            _rawKey(e.mediaType, e.entryKey),
        'title': e.title,
        'ambiguous': e.ambiguous,
      },
  ],
};

Future<void> _markManual(FushiDatabase db, int collectionId) => db.setPref(
  collectionDetailSortPrefKey(collectionId),
  kCollectionDetailManualSortValue,
);

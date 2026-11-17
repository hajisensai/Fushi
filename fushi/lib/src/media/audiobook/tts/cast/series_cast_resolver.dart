/// 书 → 系列的应用侧解析（`SeriesCastProfile.seriesKey` 由应用给，引擎只当不透明串）。
///
/// 口径：书显式关联过系列（[SeriesCastStore.linkOf]）就用它；否则取包含这本书的
/// 第一个合集（`collectionType = 'collection'`，按 id 最小，与库网格「折进 id 最小的
/// 合集卡」同口径），键为 `collection:<id>`；都没有 = 不属于任何系列。
///
/// 合集成员的 `entryKey` 自 schema v83 起是 `epub_books.uid`，旧行可能仍是 `bookKey`，
/// 两种都认。
library;

import 'dart:io';

import 'package:drift/drift.dart'
    show QueryRow, ResultSetImplementation, Variable;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';

/// 系列档案与「书 → 系列」关联的存储：`<db>/tts_cast/`（与选角表同目录）。
SeriesCastStore seriesCastStoreFor(AppModel appModel) => SeriesCastStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// 合集派生的系列键前缀。
const String kCollectionSeriesPrefix = 'collection:';

/// [bookKey] 所属系列；null = 不属于任何系列。
Future<String?> resolveSeriesKey(AppModel appModel, String bookKey) async {
  final String? linked = await seriesCastStoreFor(appModel).linkOf(bookKey);
  if (linked != null) return linked;
  final FushiDatabase db = appModel.database;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  final List<String> keys = <String>[bookKey, ?row?.uid];
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT MIN(c.id) AS cid FROM media_collections c '
        'JOIN media_collection_items i ON i.collection_id = c.id '
        "WHERE c.collection_type = 'collection' AND i.media_type = 'epub' "
        'AND i.entry_key IN (${List<String>.filled(keys.length, '?').join(', ')})',
        variables: <Variable<Object>>[
          for (final String k in keys) Variable<String>(k),
        ],
        readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
          db.mediaCollections,
          db.mediaCollectionItems,
        },
      )
      .get();
  final int? id = rows.isEmpty ? null : rows.first.readNullable<int>('cid');
  return id == null ? null : '$kCollectionSeriesPrefix$id';
}

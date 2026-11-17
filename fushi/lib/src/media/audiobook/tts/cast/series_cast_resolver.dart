/// 书 → 系列身份的解析（按系列记忆角色与声音，见引擎层 `series_cast.dart`）。
///
/// 系列键：用户显式关联过（[SeriesCastStore.linkOf]）就用它；否则取书所在的第一个
/// 合集（`collectionType == 'collection'`，成员 `mediaType == 'epub'`，`entryKey` 是
/// 书的 bookKey；合集成员键也可能是 uid，两种都认）作 `collection:<id>`；都没有 = 不属于
/// 任何系列。档案与小说选角表同目录（`<databaseDirectory>/tts_cast`）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';

/// 系列档案存储（与 `ttsCastStoreFor` 同目录）。
SeriesCastStore seriesCastStoreFor(AppModel appModel) => SeriesCastStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// [bookKey] 所属的系列键；null = 不属于任何系列。
Future<String?> resolveSeriesKey(AppModel appModel, String bookKey) async {
  final String? linked = await seriesCastStoreFor(appModel).linkOf(bookKey);
  if (linked != null) return linked;
  final FushiDatabase db = appModel.database;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  final Set<String> keys = <String>{
    bookKey,
    if (row != null && row.uid.isNotEmpty) row.uid,
  };
  final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      if (c.collectionType == 'collection') c.id: c,
  };
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != 'epub' || !keys.contains(item.entryKey)) continue;
    if (collections.containsKey(item.collectionId)) {
      return 'collection:${item.collectionId}';
    }
  }
  return null;
}

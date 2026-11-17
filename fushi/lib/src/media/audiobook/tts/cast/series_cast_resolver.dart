/// 一本书属于哪个「系列」（按系列记忆角色与声音、按系列关联音源都按它）。
///
/// 约定（小说 / 漫画有声共用）：
/// 1. 用户显式指定过的系列（[SeriesCastStore.linkOf]）优先；
/// 2. 否则取第一个包含这本书的合集（`MediaCollections.collectionType == 'collection'`，
///    成员 `mediaType == 'epub'`，成员键是 bookKey 或 uid——见
///    `getMediaCollectionsForEntryDomain` 的说明），系列键 `collection:<id>`；
/// 3. 都没有 = 不属于任何系列（null）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';

/// 系列档案目录：与 `TtsCastStore` 同一个 `<db>/tts_cast/`。
SeriesCastStore seriesCastStoreFor(AppModel appModel) => SeriesCastStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// [bookKey] 的系列键（见文件头约定）；不属于任何系列返回 null。
Future<String?> resolveSeriesKey(AppModel appModel, String bookKey) async {
  final String? explicit = await seriesCastStoreFor(appModel).linkOf(bookKey);
  if (explicit != null) return explicit;
  final FushiDatabase db = appModel.database;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  final Set<String> keys = <String>{
    bookKey,
    if (row != null && row.uid.isNotEmpty) row.uid,
  };
  final List<MediaCollectionRow> collections = await db
      .getAllMediaCollections();
  final Set<int> plainCollections = <int>{
    for (final MediaCollectionRow c in collections)
      if (c.collectionType == 'collection') c.id,
  };
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != 'epub') continue;
    if (!plainCollections.contains(item.collectionId)) continue;
    if (keys.contains(item.entryKey)) return 'collection:${item.collectionId}';
  }
  return null;
}

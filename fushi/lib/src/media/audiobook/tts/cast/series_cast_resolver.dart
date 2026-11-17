/// 应用层的「系列」身份：书属于哪个系列、系列档案存在哪。
///
/// 约定（漫画演出稿与小说选角表共用）：
/// - 书显式关联过（[SeriesCastStore.linkOf]）→ 用它（关联到 [kSeriesKeyStandalone]
///   = 用户把它从合集推断里单独拿出来，不属于任何系列）；
/// - 否则取包含这本书的第一个合集（`collectionType == 'collection'`，按合集排序），
///   身份 `collection:<id>`；合集成员键新行是书的 uid、旧行可能仍是 bookKey，两种都认；
/// - 都没有 → 不属于任何系列。
///
/// 档案与选角表同目录（`<db>/tts_cast/`），后缀不同互不覆盖。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';

/// 合集推断出的系列身份前缀。
const String kSeriesKeyCollectionPrefix = 'collection:';

/// 显式「不归入任何系列」的关联值。
const String kSeriesKeyStandalone = 'standalone:';

/// 系列档案存储：`<db>/tts_cast/`。
SeriesCastStore seriesCastStoreFor(AppModel appModel) => SeriesCastStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// [bookKey] 所属的系列身份；null = 不属于任何系列。
Future<String?> resolveSeriesKey(AppModel appModel, String bookKey) async {
  final String? linked = await seriesCastStoreFor(appModel).linkOf(bookKey);
  if (linked == kSeriesKeyStandalone) return null;
  if (linked != null) return linked;
  final int? collection = await _firstCollectionOf(appModel.database, bookKey);
  return collection == null ? null : '$kSeriesKeyCollectionPrefix$collection';
}

/// [seriesKey] 是合集推断的身份时返回合集 id。
int? seriesCollectionId(String seriesKey) =>
    seriesKey.startsWith(kSeriesKeyCollectionPrefix)
    ? int.tryParse(seriesKey.substring(kSeriesKeyCollectionPrefix.length))
    : null;

Future<int?> _firstCollectionOf(FushiDatabase db, String bookKey) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  final Set<String> keys = <String>{
    bookKey,
    if (row != null && row.uid.isNotEmpty) row.uid,
  };
  final Set<int> containing = <int>{
    for (final MediaCollectionItemRow item in await db.getAllCollectionItems())
      if (item.mediaType == 'epub' && keys.contains(item.entryKey))
        item.collectionId,
  };
  if (containing.isEmpty) return null;
  for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
    if (c.collectionType == 'collection' && containing.contains(c.id)) {
      return c.id;
    }
  }
  return null;
}

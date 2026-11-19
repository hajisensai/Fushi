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
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';

/// 合集推断出的系列身份前缀。
const String kSeriesKeyCollectionPrefix = 'collection:';

/// 显式「不归入任何系列」的关联值。
const String kSeriesKeyStandalone = 'standalone:';

/// 系列档案存储：`<db>/tts_cast/`。
SeriesCastStore seriesCastStoreFor(AudioProductionHost appModel) =>
    SeriesCastStore(
      Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
    );

/// [bookKey] 所属的系列身份；null = 不属于任何系列。
Future<String?> resolveSeriesKey(
  AudioProductionHost appModel,
  String bookKey,
) => resolveSeriesKeyIn(
  appModel.database,
  seriesCastStoreFor(appModel),
  bookKey,
);

/// [resolveSeriesKey] 的本体（只依赖数据库与档案存储，测试直接调）。
Future<String?> resolveSeriesKeyIn(
  FushiDatabase db,
  SeriesCastStore store,
  String bookKey,
) async {
  final String? linked = await store.linkOf(bookKey);
  if (linked == kSeriesKeyStandalone) return null;
  if (linked != null) return linked;
  final int? collection = await _firstCollectionOf(db, bookKey);
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

/// 系列成员书（bookKey），按系列顺序：合集推断的系列先按合集内顺序（成员键 uid /
/// bookKey 都认），再接档案里显式关联的成员；显式关联到别的系列 / 显式不归入的书
/// 剔掉，不在书库的剔掉。小说「按系列跑」、漫画按系列标注与生成共用这一份顺序。
Future<List<String>> seriesMemberBooks(
  AudioProductionHost appModel,
  String seriesKey,
) => seriesMemberBooksIn(
  appModel.database,
  seriesCastStoreFor(appModel),
  seriesKey,
);

/// [seriesMemberBooks] 的本体（只依赖数据库与档案存储，测试直接调）。
Future<List<String>> seriesMemberBooksIn(
  FushiDatabase db,
  SeriesCastStore store,
  String seriesKey,
) async {
  final List<String> ordered = <String>[];
  final int? collection = seriesCollectionId(seriesKey);
  if (collection != null) {
    for (final MediaCollectionItemRow item in await db.getCollectionItems(
      collection,
    )) {
      if (item.mediaType != 'epub') continue;
      final EpubBookRow? row =
          await db.getEpubBookByUid(item.entryKey) ??
          await db.getEpubBook(item.entryKey);
      if (row != null) ordered.add(row.bookKey);
    }
  }
  final SeriesCastProfile profile = await store.load(seriesKey);
  final List<String> out = <String>[];
  for (final String bookKey in <String>{...ordered, ...profile.members}) {
    final String? link = await store.linkOf(bookKey);
    if (link != null && link != seriesKey) continue;
    if (await db.getEpubBook(bookKey) == null) continue;
    out.add(bookKey);
  }
  return out;
}

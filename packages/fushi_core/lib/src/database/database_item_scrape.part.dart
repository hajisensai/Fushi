// 单本书 / 漫画 / 字幕书 / 游戏的刮削资料与附加图（schema v155）。
// 表语义见 tables.dart 的 [ItemScrapeMeta] / [ItemImages]。
part of 'database.dart';

/// [ItemScrapeMeta] / [ItemImages] 收的宿主种类：视频有自己的刮削宿主
/// （[VideoScrapeMeta] / [MediaImages]），不进这两张表。
const Set<MediaKind> kItemScrapeMediaKinds = <MediaKind>{
  MediaKind.epub,
  MediaKind.srt,
  MediaKind.game,
};

void _checkItemScrapeKind(MediaKind kind) {
  if (!kItemScrapeMediaKinds.contains(kind)) {
    throw ArgumentError.value(
      kind,
      'mediaType',
      'item scrape data only covers epub / srt / game',
    );
  }
}

mixin _FushiDbItemScrape on _$FushiDatabase {
  /// 条目刮削资料 / 附加图变了（任何写入者：刮削写回、控制通道脚本、删书清行）。
  /// 库页的批量预取映射据此重载；同 [watchCollectionTablesChanged] 用手动
  /// [StreamController] + [tableUpdates]，不用 drift keyed `.watch()`（BUG-834）。
  Stream<void> watchItemScrapeChanged() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub =
            tableUpdates(
              TableUpdateQuery.onAllTables(
                <ResultSetImplementation<dynamic, dynamic>>[
                  itemScrapeMeta,
                  itemImages,
                ],
              ),
            ).listen((_) {
              if (!controller.isClosed) controller.add(null);
            });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  // ── item_scrape_meta ───────────────────────────────────────────────

  /// 写入 / 整行覆盖一个条目的刮削资料（重刮即替换；`mediaType` 只收
  /// [kItemScrapeMediaKinds]）。
  Future<void> upsertItemScrapeMeta(ItemScrapeMetaCompanion meta) {
    final MediaKind? kind = MediaKind.tryParse(meta.mediaType.value);
    if (kind == null) {
      throw ArgumentError.value(meta.mediaType.value, 'mediaType');
    }
    _checkItemScrapeKind(kind);
    return into(itemScrapeMeta).insertOnConflictUpdate(meta);
  }

  Future<ItemScrapeMetaRow?> getItemScrapeMeta(
    MediaKind mediaType,
    String entryKey,
  ) =>
      (select(itemScrapeMeta)..where(
            ($ItemScrapeMetaTable t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey),
          ))
          .getSingleOrNull();

  /// 全表（库页批量预取，调用方按 (mediaType, entryKey) 内存分桶）。
  Future<List<ItemScrapeMetaRow>> getAllItemScrapeMeta() =>
      select(itemScrapeMeta).get();

  /// 删一个条目的刮削资料（不动附加图）。返回删除行数。
  Future<int> deleteItemScrapeMeta(MediaKind mediaType, String entryKey) =>
      (delete(itemScrapeMeta)..where(
            ($ItemScrapeMetaTable t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey),
          ))
          .go();

  // ── item_images ────────────────────────────────────────────────────

  /// 某条目的附加图（kind 组内按 position 升序）。
  Future<List<ItemImageRow>> getItemImages(
    MediaKind mediaType,
    String entryKey,
  ) =>
      (select(itemImages)
            ..where(
              ($ItemImagesTable t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey),
            )
            ..orderBy([
              ($ItemImagesTable t) => OrderingTerm(expression: t.kind),
              ($ItemImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 某一种附加图的全部行（库页只要 backdrop / logo 时不拉整表）。
  Future<List<ItemImageRow>> getItemImagesOfKind(MediaImageKind kind) =>
      (select(itemImages)
            ..where(($ItemImagesTable t) => t.kind.equals(kind.dbValue))
            ..orderBy([
              ($ItemImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 全表附加图（文件回收的保留集）。
  Future<List<ItemImageRow>> getAllItemImages() => select(itemImages).get();

  /// 整体替换某条目某一种附加图（[paths] 按顺序成为 position 0..n；空 = 清空）。
  /// 返回被替换掉、且不在新组里的旧文件路径（调用方据此回收文件）。
  Future<List<String>> replaceItemImagesOfKind({
    required MediaKind mediaType,
    required String entryKey,
    required MediaImageKind kind,
    required List<({String path, String? sourceUrl})> images,
  }) {
    _checkItemScrapeKind(mediaType);
    if (kind != MediaImageKind.backdrop && images.length > 1) {
      throw ArgumentError.value(
        images.length,
        'images',
        'only backdrop allows more than one image',
      );
    }
    return transaction(() async {
      final List<ItemImageRow> old =
          await (select(itemImages)..where(
                ($ItemImagesTable t) =>
                    t.mediaType.equals(mediaType.dbValue) &
                    t.entryKey.equals(entryKey) &
                    t.kind.equals(kind.dbValue),
              ))
              .get();
      await (delete(itemImages)..where(
            ($ItemImagesTable t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey) &
                t.kind.equals(kind.dbValue),
          ))
          .go();
      for (int i = 0; i < images.length; i++) {
        await into(itemImages).insert(
          ItemImagesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: entryKey,
            kind: kind.dbValue,
            position: Value<int>(i),
            path: images[i].path,
            sourceUrl: Value<String?>(images[i].sourceUrl),
          ),
        );
      }
      final Set<String> kept = <String>{
        for (final ({String path, String? sourceUrl}) img in images) img.path,
      };
      return <String>[
        for (final ItemImageRow row in old)
          if (!kept.contains(row.path)) row.path,
      ];
    });
  }

  /// 宿主删除时清它的刮削资料与附加图行（逻辑外键无 cascade；删书 / 删字幕书 /
  /// 删游戏路径在自己的事务里调用）。返回被删图行的文件路径，供调用方回收。
  Future<List<String>> deleteItemScrapeDataFor(
    MediaKind mediaType,
    Iterable<String> entryKeys,
  ) => transaction(() => _purgeItemScrapeRows(this, mediaType, entryKeys));
}

/// [_FushiDbItemScrape.deleteItemScrapeDataFor] 的实体：顶层函数，好让删书 /
/// 删字幕书 / 删游戏所在的其它 mixin 在**自己的事务里**直接调（mixin 之间没有
/// `on` 依赖）。返回被删图行的文件路径。
Future<List<String>> _purgeItemScrapeRows(
  _$FushiDatabase db,
  MediaKind mediaType,
  Iterable<String> entryKeys,
) async {
  final List<String> keys = entryKeys.toSet().toList(growable: false);
  if (keys.isEmpty) return const <String>[];
  final List<String> paths = <String>[];
  // 与合集成员批删同量级的块，避开 999 绑定变量上限。
  for (int start = 0; start < keys.length; start += 500) {
    final List<String> chunk = keys.sublist(
      start,
      start + 500 > keys.length ? keys.length : start + 500,
    );
    final List<ItemImageRow> rows =
        await (db.select(db.itemImages)..where(
              ($ItemImagesTable t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.isIn(chunk),
            ))
            .get();
    paths.addAll(rows.map((ItemImageRow r) => r.path));
    await (db.delete(db.itemImages)..where(
          ($ItemImagesTable t) =>
              t.mediaType.equals(mediaType.dbValue) & t.entryKey.isIn(chunk),
        ))
        .go();
    await (db.delete(db.itemScrapeMeta)..where(
          ($ItemScrapeMetaTable t) =>
              t.mediaType.equals(mediaType.dbValue) & t.entryKey.isIn(chunk),
        ))
        .go();
  }
  return paths;
}

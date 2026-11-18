import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException;
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/image_download.dart'
    show ImageDownloadException;

import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart'
    show itemScrapeDetailsFromJson, itemScrapeDetailsToJson;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 单本书 / 漫画 / 字幕书 / 游戏的刮削资料与横版背景（v161 `item_scrape_meta` /
/// `item_images`）的控制通道路由：`fushi_cli library scrape-meta get|set|clear`。
///
/// 写入经 [ItemScrapeStore]（与书籍刮削写回、游戏元数据刮削同一个入口），图片走
/// 同一个原子落盘 writer。主要用途是脚本造测试数据 / 手动补资料；书架、游戏库的
/// 系列色块订阅表变化，写完即刷新。条目键与 `library ls` 同形（`book:` / `srt:` /
/// `game:`；视频有自己的刮削宿主，回 422）。
List<CtlRoute> buildLibraryScrapeCtlRoutes(OpContext context) {
  AppModel app() => context.appModel;

  return <CtlRoute>[
    CtlRoute.get('$kLibraryScrapeCtlItems/:key/scrape-meta', (
      CtlCall call,
    ) async {
      final ItemScrapeKey key = await resolveLibraryItemScrapeKey(
        app(),
        call.params['key'] ?? '',
      );
      return itemScrapeStateJson(app().database, call.params['key']!, key);
    }),
    CtlRoute.put('$kLibraryScrapeCtlItems/:key/scrape-meta', (
      CtlCall call,
    ) async {
      _requireWritable(app());
      final String raw = call.params['key'] ?? '';
      final ItemScrapeKey key = await resolveLibraryItemScrapeKey(app(), raw);
      final ItemScrapeStore store = libraryItemScrapeStoreFactory(
        app().database,
      );
      final ItemScrapeDetails patch = _detailsOf(call);
      if (call.optBool('replace') == true) {
        await store.writeMeta(key, patch);
      } else {
        await store.mergeMeta(key, patch);
      }
      await _setImage(
        store,
        key,
        MediaImageKind.backdrop,
        path: call.optString('backdropPath'),
        url: call.optString('backdropUrl'),
      );
      await _setImage(
        store,
        key,
        MediaImageKind.logo,
        path: call.optString('logoPath'),
        url: call.optString('logoUrl'),
      );
      _refresh(context);
      return itemScrapeStateJson(app().database, raw, key);
    }),
    CtlRoute.delete('$kLibraryScrapeCtlItems/:key/scrape-meta', (
      CtlCall call,
    ) async {
      _requireWritable(app());
      final String raw = call.params['key'] ?? '';
      final ItemScrapeKey key = await resolveLibraryItemScrapeKey(app(), raw);
      final ItemScrapeStore store = libraryItemScrapeStoreFactory(
        app().database,
      );
      await app().database.deleteItemScrapeDataFor(key.mediaType, <String>[
        key.entryKey,
      ]);
      final int removed = await store.reclaimUnreferencedFiles();
      _refresh(context);
      return <String, Object?>{'key': raw, 'cleared': true, 'files': removed};
    }),
  ];
}

/// 测试接缝：路由用它造写入口（测试注入临时图片目录 / 下载桩）。
@visibleForTesting
ItemScrapeStore Function(FushiDatabase db) libraryItemScrapeStoreFactory =
    ItemScrapeStore.new;

/// 路由前缀（与 `library` 其它条目路由同一根，路由表测试要求 library 路由都在它下面）。
const String kLibraryScrapeCtlItems = '/api/admin/library/items';

void _requireWritable(AppModel app) {
  if (app.isMigrationReadonly) {
    throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
  }
}

void _refresh(OpContext context) {
  context.ref
    ..invalidate(fushiBooksProvider(JapaneseLanguage.instance))
    ..invalidate(srtBooksProvider);
}

/// `book:<bookKey>` / `srt:<uid>` / `game:<id>` → 条目刮削身份（同合集成员口径：
/// 书 = EpubBooks.uid）。条目不存在 404，视频 422。
Future<ItemScrapeKey> resolveLibraryItemScrapeKey(
  AppModel app,
  String raw,
) async {
  final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
  if (key == null) {
    throw CtlFailure.badRequest('条目键「$raw」格式不对（见 library ls）');
  }
  final FushiDatabase db = app.database;
  switch (key.store) {
    case LibraryCtlStore.book:
      final String? uid = await db.resolveEpubBookUid(key.id);
      if (uid == null || uid.isEmpty) {
        throw CtlFailure.notFound('书架里没有 ${key.wire}');
      }
      return ItemScrapeKey(MediaKind.epub, uid);
    case LibraryCtlStore.srt:
      if (await SrtBookRepository(db).findByUid(key.id) == null) {
        throw CtlFailure.notFound('书架里没有 ${key.wire}');
      }
      return ItemScrapeKey(MediaKind.srt, key.id);
    case LibraryCtlStore.game:
      if (await db.getGalgame(key.id) == null) {
        throw CtlFailure.notFound('游戏库里没有 ${key.wire}');
      }
      return ItemScrapeKey(MediaKind.game, key.id);
    case LibraryCtlStore.video:
      throw const CtlFailure.rejected(
        '视频的刮削资料走视频刮削（video scrape …），这里只管书 / 漫画 / 有声书 / 游戏',
      );
  }
}

/// 条目当前的刮削资料 + 附加图（线上形状，CLI / AI / 撤销快照共用）。
Future<Map<String, Object?>> itemScrapeStateJson(
  FushiDatabase db,
  String raw,
  ItemScrapeKey key,
) async {
  final ItemScrapeMetaRow? meta = await db.getItemScrapeMeta(
    key.mediaType,
    key.entryKey,
  );
  return <String, Object?>{
    'key': raw,
    'mediaType': key.mediaType.dbValue,
    'entryKey': key.entryKey,
    'meta': meta == null
        ? null
        : itemScrapeDetailsToJson(ItemScrapeDetails.fromRow(meta)),
    'images': <Map<String, Object?>>[
      for (final ItemImageRow row in await db.getItemImages(
        key.mediaType,
        key.entryKey,
      ))
        <String, Object?>{
          'kind': row.kind,
          'position': row.position,
          'path': row.path,
          if (row.sourceUrl != null) 'sourceUrl': row.sourceUrl,
        },
    ],
  };
}

/// 撤销 `set`：资料写回执行前那份（之前没有 → 删行），执行前没有的图种类清掉
/// （执行前已有的图被同路径覆盖，无从恢复，保持现状）。
Future<void> restoreItemScrapeState(
  AppModel app,
  String raw,
  Map<String, Object?> before,
) async {
  final ItemScrapeKey key = await resolveLibraryItemScrapeKey(app, raw);
  final ItemScrapeStore store = libraryItemScrapeStoreFactory(app.database);
  final Object? meta = before['meta'];
  if (meta is Map) {
    await store.writeMeta(
      key,
      itemScrapeDetailsFromJson(Map<String, Object?>.from(meta)),
    );
  } else {
    await app.database.deleteItemScrapeMeta(key.mediaType, key.entryKey);
  }
  final Set<String> hadKinds = <String>{
    for (final Object? image in (before['images'] as List<Object?>? ?? []))
      if (image is Map) '${image['kind']}',
  };
  for (final MediaImageKind kind in <MediaImageKind>[
    MediaImageKind.backdrop,
    MediaImageKind.logo,
  ]) {
    if (!hadKinds.contains(kind.dbValue)) await store.clearImage(key, kind);
  }
}

ItemScrapeDetails _detailsOf(CtlCall call) {
  final double? rating = _optDouble(call, 'rating');
  if (rating != null && (rating < 0 || rating > 10)) {
    throw CtlFailure.badRequest('rating 要在 0~10 之间：$rating');
  }
  final String? date = call.optString('date');
  final int? year = call.optInt('year');
  if (date != null && !RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(date)) {
    throw CtlFailure.badRequest('date 要写成 YYYY / YYYY-MM / YYYY-MM-DD：$date');
  }
  return ItemScrapeDetails(
    source: call.optString('source') ?? ItemScrapeStore.manualSource,
    subjectId: call.optString('subjectId'),
    title: call.optString('title'),
    originalTitle: call.optString('originalTitle'),
    summary: call.optString('summary'),
    airDate: date ?? year?.toString(),
    rating: rating,
    ratingCount: call.optInt('ratingCount'),
    tags: call.stringList('genres'),
    detailUrl: call.optString('detailUrl'),
  );
}

double? _optDouble(CtlCall call, String name) {
  final Object? raw = call.body[name] ?? call.query[name];
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  final double? parsed = double.tryParse('$raw'.trim());
  if (parsed == null) throw CtlFailure.badRequest('$name 必须是数字');
  return parsed;
}

Future<void> _setImage(
  ItemScrapeStore store,
  ItemScrapeKey key,
  MediaImageKind kind, {
  required String? path,
  required String? url,
}) async {
  if (path != null && url != null) {
    throw CtlFailure.badRequest('${kind.dbValue} 的本地路径与 URL 二选一');
  }
  try {
    if (path != null) {
      final File file = File(path);
      if (!file.isAbsolute) throw CtlFailure.badRequest('路径必须是绝对路径：$path');
      if (!file.existsSync()) throw CtlFailure.notFound('图片不存在：$path');
      await store.setImageFromFile(key, kind, file);
    } else if (url != null) {
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw CtlFailure.badRequest('url 只支持 http / https：$url');
      }
      await store.setImageFromUrl(key, kind, url);
    }
  } on CoverImageInvalidException {
    throw CtlFailure.rejected('${kind.dbValue} 图片无法解码，没有写入');
  } on ImageDownloadException catch (e) {
    throw CtlFailure.conflict('${kind.dbValue} 图片下载失败：$e');
  }
}

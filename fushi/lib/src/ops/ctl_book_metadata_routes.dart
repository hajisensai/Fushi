import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/metadata/books/book_catalog.dart'
    show findIsbnIn;
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart'
    show BookArtSource;
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 书的元数据与封面刮削（写回从对话框抽出的门面）的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑：
/// 候选 = 「在线匹配封面」弹窗的 [BookMetadataScrapeFacade.searchDetailed] / `fetchById`；
/// 写回 = 书架卡「在线刮削封面」的 [BookMetadataScrapeFacade.applyToBook]（这里
/// 带 `keepBackup`，撤销靠快照 + 封面备份）。
///
/// 条目键与 `library` 命令同一形状（[LibraryCtlKey] 的 `book:` / `srt:`）。与弹窗
/// 一样受「在线服务」模块门：模块关掉时刮削按钮不渲染，这里回 422。
List<CtlRoute> buildBookMetadataCtlRoutes(OpContext context) {
  AppModel app() => context.appModel;
  void invalidateBooks() {
    context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    context.ref.invalidate(srtBooksProvider);
  }

  void requireServices() {
    if (!app().moduleVisibility.isEnabled(ModuleId.services)) {
      throw const CtlFailure.rejected('「在线服务」模块已在设置里关闭，不能联网刮削');
    }
  }

  /// 楽天要设备本地凭据；没填时与弹窗一样不可用（422，带去哪填的提示）。
  RakutenBooksCredentials requireSourceUsable(BookScrapeSource source) {
    final RakutenBooksCredentials creds = app().bookScrapeRakutenCredentials;
    if (source.needsCredentials && !creds.isComplete) {
      throw const CtlFailure.rejected(
        '楽天ブックス需要先在「设置 › 在线服务 › 资料来源 › 楽天ブックス」填写 '
        'applicationId 与 accessKey',
      );
    }
    return creds;
  }

  return <CtlRoute>[
    CtlRoute.get(kBookMetadataCtlSearch, (CtlCall call) async {
      requireServices();
      final BookScrapeSource source = _source(call.optString('source'));
      final String query = call.requireString('query');
      if (source.isbnOnly && findIsbnIn(query) == null) {
        throw CtlFailure.badRequest('${source.label} 只能按 ISBN 查：$query');
      }
      // NSFW 候选默认不回（与弹窗对没标 NSFW 的书同一口径），`nsfw=true` 才带上。
      final bool includeNsfw = call.optBool('nsfw') ?? false;
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory(
        rakuten: requireSourceUsable(source),
      );
      try {
        final BookScrapeSearchResult found = await _scrape(
          () => facade.searchDetailed(
            source: source,
            query: query,
            includeNsfw: includeNsfw,
          ),
        );
        return <String, Object?>{
          'source': source.name,
          'query': query,
          // 原词零结果时实际命中的改写词（去卷号 / 拆混写名，BUG-5372）。
          if (found.query != query.trim()) 'matchedQuery': found.query,
          'candidates': <Map<String, Object?>>[
            for (final BookScrapeCandidate c in found.candidates)
              bookScrapeCandidateJson(c),
          ],
          if (found.hiddenNsfw > 0) 'hiddenNsfw': found.hiddenNsfw,
        };
      } finally {
        facade.close();
      }
    }),
    CtlRoute.get('$kBookMetadataCtlSearch/:source/:id', (CtlCall call) async {
      requireServices();
      final BookScrapeSource source = _source(call.params['source']);
      final String id = call.params['id'] ?? '';
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory(
        rakuten: requireSourceUsable(source),
      );
      try {
        final BookScrapeCandidate? found = await _scrape(
          () => facade.fetchById(source: source, id: id),
        );
        if (found == null) {
          throw CtlFailure.notFound('${source.label} 没有 $id（或该条目没有封面）');
        }
        return bookScrapeCandidateJson(found);
      } finally {
        facade.close();
      }
    }),
    CtlRoute.get('$kBookMetadataCtlSearch/:source/:id/volumes', (
      CtlCall call,
    ) async {
      requireServices();
      final BookScrapeSource source = _source(call.params['source']);
      if (source != BookScrapeSource.mangabaka) {
        throw const CtlFailure.badRequest('只有 mangabaka 提供每卷封面');
      }
      final String id = call.params['id'] ?? '';
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory();
      try {
        // language：书的版本语言（zh / ko…）；该语言没有卷封面时回落日文版。
        final BookVolumeCoverSet set = await _scrape(
          () => facade.volumeCoverSet(
            id,
            language: call.optString('language') ?? '',
          ),
        );
        final List<BookVolumeCover> volumes = set.covers;
        return <String, Object?>{
          'source': source.name,
          'id': id,
          // 实际用的版本语言（与请求的不同 = 回落了日文版）。
          'language': set.language,
          'volumes': <Map<String, Object?>>[
            for (final BookVolumeCover v in volumes)
              <String, Object?>{
                'volume': v.volume,
                'label': v.label,
                'url': v.url,
                'width': ?v.width,
                'height': ?v.height,
              },
          ],
          'attribution': 'Data from MangaBaka (CC BY-NC-SA 4.0)',
        };
      } finally {
        facade.close();
      }
    }),
    CtlRoute.post('$kBookMetadataCtlItems/:key/scrape', (CtlCall call) async {
      requireServices();
      if (app().isMigrationReadonly) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final MediaItem item = await resolveBookMetadataItem(
        app(),
        call.params['key'] ?? '',
      );
      final BookScrapeSource source = _source(call.optString('source'));
      final String id = call.requireString('id');
      final Set<BookMetadataField> fields = _fields(call.stringList('fields'));
      final num? volume = _volume(call);
      if (volume != null && source != BookScrapeSource.mangabaka) {
        throw const CtlFailure.badRequest('volume 只对 mangabaka 有效');
      }
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory(
        rakuten: requireSourceUsable(source),
      );
      File? cover;
      try {
        // onlyEmpty：只填当前空着的字段（库管家自动写回用）。显示名覆盖 / 作者 /
        // override 封面 / 条目资料都没有「谁设的」标记，有值就一律不碰。
        if (call.optBool('onlyEmpty') ?? false) {
          final BookMetadataState now = await facade.currentState(
            appModel: app(),
            item: item,
          );
          fields.removeWhere(
            (BookMetadataField f) => switch (f) {
              BookMetadataField.title =>
                (now.overrideTitle ?? '').trim().isNotEmpty,
              BookMetadataField.author => (now.author ?? '').trim().isNotEmpty,
              BookMetadataField.cover => now.coverSha != null,
              BookMetadataField.details => now.details != null,
            },
          );
          if (fields.isEmpty) {
            throw const CtlFailure.rejected('要写的字段都已有值（onlyEmpty），没有可写回的内容');
          }
        }
        final BookScrapeCandidate? candidate = await _scrape(
          () => facade.fetchById(source: source, id: id),
        );
        if (candidate == null) {
          throw CtlFailure.notFound('${source.label} 没有 $id（或该条目没有封面）');
        }
        if (fields.contains(BookMetadataField.cover)) {
          if (volume == null) {
            cover = await _scrape(() => facade.downloadCover(candidate));
          } else {
            // 按这本书的版本语言挑卷封面（中文版用中文版封面，没有再回落日文版）。
            final String language =
                await BookMetadataScrapeFacade.languageForItem(
                  app().database,
                  item,
                );
            final List<BookVolumeCover> volumes = await _scrape(
              () =>
                  facade.volumeCovers(candidate.subjectId, language: language),
            );
            final BookVolumeCover? picked = volumes
                .where((BookVolumeCover v) => (v.volume - volume).abs() < 0.01)
                .firstOrNull;
            if (picked == null) {
              throw CtlFailure.notFound(
                'MangaBaka 上 ${candidate.title} 没有第 $volume 卷的日文封面',
              );
            }
            cover = await _scrape(() => facade.downloadVolumeCover(picked));
          }
        }
        final BookMetadataApplyResult result = await facade.applyToBook(
          appModel: app(),
          item: item,
          cover: cover,
          title: fields.contains(BookMetadataField.title)
              ? candidate.title
              : null,
          author: fields.contains(BookMetadataField.author)
              ? candidate.author
              : null,
          details: fields.contains(BookMetadataField.details)
              ? candidate
              : null,
          keepBackup: true,
        );
        if (result.applied.isEmpty) {
          throw const CtlFailure.rejected(
            '没有可写回的内容（封面图片无法解码 / 候选没有作者 / 该书不支持改作者）',
          );
        }
        context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
        context.ref.invalidate(srtBooksProvider);
        return <String, Object?>{
          'key': call.params['key'],
          'candidate': bookScrapeCandidateJson(candidate),
          'requested': <String>[
            for (final BookMetadataField f in fields) f.name,
          ],
          'applied': <String>[
            for (final BookMetadataField f in result.applied) f.name,
          ],
          'before': result.before.toJson(),
          'after': result.after.toJson(),
        };
      } finally {
        facade.close();
        if (cover != null && cover.existsSync()) {
          try {
            await cover.delete();
          } on FileSystemException {
            // 临时文件，删不掉由系统清理。
          }
        }
      }
    }),
    // ── 每卷封面 + 横幅（刮削层，与 override 分开存） ──
    CtlRoute.post('$kBookArtCtlCollections/:id/scrape-art', (
      CtlCall call,
    ) async {
      requireServices();
      final bool dryRun = call.optBool('dryRun') ?? false;
      if (!dryRun && app().isMigrationReadonly) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final int collectionId = _collectionId(call);
      final BookArtScrapeService service = bookArtServiceFactory(app());
      try {
        final List<String> keys = await service.collectionBookKeys(
          collectionId,
        );
        if (keys.isEmpty) {
          throw CtlFailure.notFound('合集 $collectionId 里没有本地书');
        }
        final Map<String, BookArtSeriesPin> pins = _pins(call);
        final BookArtRunResult result = await service.run(
          keys,
          dryRun: dryRun,
          pins: pins,
          onlyPinnedGroups: pins.isNotEmpty,
        );
        if (pins.isNotEmpty && result.series.isEmpty) {
          throw CtlFailure.notFound(
            '合集 $collectionId 里没有系列键 ${pins.keys.single}',
          );
        }
        if (!dryRun) invalidateBooks();
        return <String, Object?>{
          'collectionId': collectionId,
          ...result.toJson(),
          if (!dryRun) ...await _undoState(app(), result.snapshots),
        };
      } finally {
        service.close();
      }
    }),
    CtlRoute.delete('$kBookArtCtlCollections/:id/scrape-art', (
      CtlCall call,
    ) async {
      if (app().isMigrationReadonly) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final int collectionId = _collectionId(call);
      final List<String> keys = await collectionMemberBookKeys(
        app().database,
        collectionId,
      );
      return _removeArt(app(), keys, invalidateBooks, reject: false);
    }),
    CtlRoute.delete('$kBookMetadataCtlItems/:key/scraped-art', (
      CtlCall call,
    ) async {
      if (app().isMigrationReadonly) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final LibraryCtlKey? key = LibraryCtlKey.tryParse(
        call.params['key'] ?? '',
      );
      if (key == null || key.store != LibraryCtlStore.book) {
        throw CtlFailure.badRequest('只有本地书（book:<bookKey>）有已获取的封面');
      }
      return _removeArt(app(), <String>[key.id], invalidateBooks, reject: true);
    }),
  ];
}

/// `volume`（可带小数，如 28.5）；没给 → null。
num? _volume(CtlCall call) {
  final String? raw = call.optString('volume');
  if (raw == null) return null;
  final num? parsed = num.tryParse(raw);
  if (parsed == null) throw CtlFailure.badRequest('volume 必须是数字：$raw');
  return parsed;
}

/// 清除 [bookKeys] 的刮削层；返回清掉的书与撤销所需的快照。[reject]（单本移除）时
/// 记为否决：之后重刮不会把同一张图写回来；合集清除是整体重置，不记否决。
Future<Map<String, Object?>> _removeArt(
  AppModel app,
  List<String> bookKeys,
  void Function() invalidate, {
  required bool reject,
}) async {
  final BookArtStore store = BookArtStore.of(app.thumbnailsDirectory);
  final List<BookArtSnapshot> snapshots = <BookArtSnapshot>[];
  for (final String key in bookKeys) {
    if (!store.hasCover(key) && store.recordFor(key) == null) continue;
    snapshots.add(await store.snapshot(key));
    if (reject) {
      await store.rejectCover(key);
    } else {
      await store.remove(key);
    }
  }
  invalidate();
  return <String, Object?>{
    'removed': <String>[for (final BookArtSnapshot s in snapshots) s.bookKey],
    ...await _undoState(app, snapshots),
  };
}

/// 撤销载荷：执行前快照 + 执行后各书刮削层指纹（撤销前比对，之后被改过就 superseded）。
Future<Map<String, Object?>> _undoState(
  AppModel app,
  List<BookArtSnapshot> snapshots,
) async {
  final BookArtStore store = BookArtStore.of(app.thumbnailsDirectory);
  return <String, Object?>{
    'undo': <String, Object?>{
      'snapshots': <Map<String, Object?>>[
        for (final BookArtSnapshot s in snapshots) s.toJson(),
      ],
      'after': <String, Object?>{
        for (final BookArtSnapshot s in snapshots)
          s.bookKey: await store.fingerprint(s.bookKey),
      },
    },
  };
}

/// 测试接缝：造每卷封面刮削服务（测试注入离线 http client）。
@visibleForTesting
BookArtScrapeService Function(AppModel app) bookArtServiceFactory =
    (AppModel app) => BookArtScrapeService(
      database: app.database,
      store: BookArtStore.of(app.thumbnailsDirectory),
    );

/// 合集每卷封面路由根（`/:id/scrape-art`）。
const String kBookArtCtlCollections = '/api/admin/book/collections';

int _collectionId(CtlCall call) {
  final int? id = int.tryParse(call.params['id'] ?? '');
  if (id == null) throw CtlFailure.badRequest('合集 id 不对：${call.params['id']}');
  return id;
}

/// `seriesKey` + `source` + `seriesId` 三个一起给 = 钉死那一组的系列（待确认时由调用方选定）。
Map<String, BookArtSeriesPin> _pins(CtlCall call) {
  final String? seriesKey = call.optString('seriesKey');
  final String? source = call.optString('source');
  final String? id = call.optString('seriesId');
  if (seriesKey == null && source == null && id == null) {
    return const <String, BookArtSeriesPin>{};
  }
  final BookArtSource? parsed = BookArtSource.tryParse(source);
  if (seriesKey == null || parsed == null || id == null) {
    throw const CtlFailure.badRequest(
      '钉死系列要同时给 seriesKey、source（mangabaka / bangumi）与 seriesId',
    );
  }
  if (int.tryParse(id) == null) {
    throw CtlFailure.badRequest('seriesId 必须是数字：$id');
  }
  return <String, BookArtSeriesPin>{
    seriesKey: BookArtSeriesPin(source: parsed, id: id),
  };
}

/// 造门面的工厂（[rakuten] = 本机楽天凭据，路由从设置里读出后传入）。
typedef BookMetadataFacadeFactory =
    BookMetadataScrapeFacade Function({RakutenBooksCredentials? rakuten});

/// 测试接缝：路由用它造门面（测试注入离线 scraper / 下载桩）。
@visibleForTesting
BookMetadataFacadeFactory bookMetadataFacadeFactory =
    BookMetadataScrapeFacade.new;

/// 候选搜索路由（`?source=&query=`）。
const String kBookMetadataCtlSearch = '/api/admin/book/scrape';

/// 写回路由的条目根（`/:key/scrape`）。
const String kBookMetadataCtlItems = '/api/admin/book/items';

/// 候选的线上形状（CLI 与 AI 共用）。
Map<String, Object?> bookScrapeCandidateJson(BookScrapeCandidate c) =>
    <String, Object?>{
      'source': c.source.name,
      'id': c.subjectId,
      'title': c.title,
      if (c.originalTitle != null) 'originalTitle': c.originalTitle,
      if (c.author != null) 'author': c.author,
      // 形态：novel / manga / manhwa / manhua / oneShot（AniList 给，其余源不带）。
      if (c.format != null) 'format': c.format!.name,
      if (c.year != null) 'year': c.year,
      if (c.publisher != null) 'publisher': c.publisher,
      if (c.series != null) 'series': c.series,
      if (c.volume != null) 'volume': c.volume,
      if (c.isbn != null) 'isbn': c.isbn,
      if (c.summary != null)
        'summary': c.summary!.length > 300
            ? '${c.summary!.substring(0, 300)}…'
            : c.summary,
      'coverUrl': c.coverUrl,
      if (c.bannerUrl != null) 'bannerUrl': c.bannerUrl,
      'detailUrl': c.detailUrl,
      if (c.isAdult) 'adult': true,
    };

/// `book:<bookKey>` / `srt:<uid>` → 书架上的 [MediaItem]（与 `library` 路由同一
/// 换算：字幕书配了 EPUB 就落到那本 EPUB 上，否则是字幕书自己的身份）。
Future<MediaItem> resolveBookMetadataItem(AppModel app, String raw) async {
  final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
  if (key == null) {
    throw CtlFailure.badRequest('条目键「$raw」格式不对（见 library ls）');
  }
  switch (key.store) {
    case LibraryCtlStore.book:
      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey(key.id);
      if (item == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
      return item;
    case LibraryCtlStore.srt:
      final SrtBook? srt = await SrtBookRepository(
        app.database,
      ).findByUid(key.id);
      if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
      if (srt.bookKey.isNotEmpty) {
        final MediaItem? item = await ReaderFushiSource.instance
            .mediaItemForBookKey(srt.bookKey);
        if (item != null) return item;
      }
      return MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierForSrtUid(srt.uid),
        title: srt.title,
        author: srt.author,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
    case LibraryCtlStore.video:
    case LibraryCtlStore.game:
      throw const CtlFailure.rejected('只有书 / 漫画 / 有声书（book: / srt:）能刮书籍元数据');
  }
}

BookScrapeSource _source(String? raw) {
  if (raw == null || raw.trim().isEmpty) return BookScrapeSource.bangumi;
  return BookScrapeSource.tryParse(raw) ??
      (throw CtlFailure.badRequest(
        'source 只能是 '
        '${BookScrapeSource.values.map((BookScrapeSource s) => s.name).join(' / ')}'
        '：$raw',
      ));
}

Set<BookMetadataField> _fields(List<String> raw) {
  if (raw.isEmpty) {
    return <BookMetadataField>{
      BookMetadataField.cover,
      BookMetadataField.details,
    };
  }
  return <BookMetadataField>{
    for (final String r in raw)
      BookMetadataField.tryParse(r.toLowerCase()) ??
          (throw CtlFailure.badRequest(
            'fields 只能是 cover / title / author / details：$r',
          )),
  };
}

/// 刮削源的失败折成 409（源站 / 网络问题，稍后重试），不当成 500。
Future<T> _scrape<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on BookScrapeException catch (e) {
    throw CtlFailure.conflict('刮削源请求失败：${e.message}');
  } on ImageDownloadException catch (e) {
    throw CtlFailure.conflict('封面下载失败：$e');
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/metadata/image_download.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 书的元数据与封面刮削（写回从对话框抽出的门面）的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑：
/// 候选 = 「在线匹配封面」弹窗的 [BookMetadataScrapeFacade.search] / `fetchById`；
/// 写回 = 书架卡「在线刮削封面」的 [BookMetadataScrapeFacade.applyToBook]（这里
/// 带 `keepBackup`，撤销靠快照 + 封面备份）。
///
/// 条目键与 `library` 命令同一形状（[LibraryCtlKey] 的 `book:` / `srt:`）。与弹窗
/// 一样受「在线服务」模块门：模块关掉时刮削按钮不渲染，这里回 422。
List<CtlRoute> buildBookMetadataCtlRoutes(OpContext context) {
  AppModel app() => context.appModel;

  void requireServices() {
    if (!app().moduleVisibility.isEnabled(ModuleId.services)) {
      throw const CtlFailure.rejected('「在线服务」模块已在设置里关闭，不能联网刮削');
    }
  }

  return <CtlRoute>[
    CtlRoute.get(kBookMetadataCtlSearch, (CtlCall call) async {
      requireServices();
      final BookScrapeSource source = _source(call.optString('source'));
      final String query = call.requireString('query');
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory();
      try {
        final List<BookScrapeCandidate> found = await _scrape(
          () => facade.search(source: source, query: query),
        );
        return <String, Object?>{
          'source': source.name,
          'query': query,
          'candidates': <Map<String, Object?>>[
            for (final BookScrapeCandidate c in found)
              bookScrapeCandidateJson(c),
          ],
        };
      } finally {
        facade.close();
      }
    }),
    CtlRoute.get('$kBookMetadataCtlSearch/:source/:id', (CtlCall call) async {
      requireServices();
      final BookScrapeSource source = _source(call.params['source']);
      final String id = call.params['id'] ?? '';
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory();
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
      final BookMetadataScrapeFacade facade = bookMetadataFacadeFactory();
      File? cover;
      try {
        final BookScrapeCandidate? candidate = await _scrape(
          () => facade.fetchById(source: source, id: id),
        );
        if (candidate == null) {
          throw CtlFailure.notFound('${source.label} 没有 $id（或该条目没有封面）');
        }
        if (fields.contains(BookMetadataField.cover)) {
          cover = await _scrape(() => facade.downloadCover(candidate));
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
  ];
}

/// 测试接缝：路由用它造门面（测试注入离线 scraper / 下载桩）。
@visibleForTesting
BookMetadataScrapeFacade Function() bookMetadataFacadeFactory =
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
      if (c.year != null) 'year': c.year,
      if (c.summary != null)
        'summary': c.summary!.length > 300
            ? '${c.summary!.substring(0, 300)}…'
            : c.summary,
      'coverUrl': c.coverUrl,
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
  for (final BookScrapeSource s in BookScrapeSource.values) {
    if (s.name == raw.trim().toLowerCase()) return s;
  }
  throw CtlFailure.badRequest('source 只能是 bangumi / dlsite：$raw');
}

Set<BookMetadataField> _fields(List<String> raw) {
  if (raw.isEmpty) return <BookMetadataField>{BookMetadataField.cover};
  return <BookMetadataField>{
    for (final String r in raw)
      BookMetadataField.tryParse(r.toLowerCase()) ??
          (throw CtlFailure.badRequest('fields 只能是 cover / title / author：$r')),
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

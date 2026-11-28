import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/display_title_store_series.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_pdf_source.dart';
import 'package:fushi/src/media/types/reader_media_type.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/pages/implementations/history_reader_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';

/// A source for the [ReaderMediaType], which handles primarily text-based
/// media.
abstract class ReaderMediaSource extends MediaSource {
  /// Initialise a media source.
  ReaderMediaSource({
    required super.uniqueKey,
    required super.sourceName,
    required super.description,
    required super.icon,
    required super.implementsSearch,
    required super.implementsHistory,
    super.overridesAutoImage = false,
    super.overridesAutoAudio = false,
  }) : super(mediaType: ReaderMediaType.instance);

  /// BUG-1317：EPUB / 漫画 / PDF 是**同一本书**的三种 `EpubBooks.format`，共享
  /// `hoshi://book/<bookKey>` 身份，而 `mediaSourceIdentifier` 由**当前** format
  /// 现算（转化后会变）。override 书名 / 封面必须跟着**书**走，不跟着阅读器走，
  /// 所以三源统一存进 EPUB 源的偏好命名空间。
  @override
  MediaSource get overrideStore => ReaderFushiSource.instance;

  /// BUG-1317 读取期回退：存量 override 按写入时的 format 散落在三个源各自的
  /// `src:<sourceId>:` 命名空间里，三个都要试。
  @override
  List<MediaSource> get legacyOverrideStores => <MediaSource>[
    ReaderFushiSource.instance,
    MangaFushiSource.instance,
    ReaderPdfSource.instance,
  ];

  /// 作者编辑（BUG-220 / BUG-5082）：EPUB / 漫画 / PDF 是同一张 `EpubBooks` 表的
  /// 三种 `format`，作者是同一列，字幕书写 `srt_books.author`。能力挂在书族基类上
  /// 而不是逐个子类覆盖——此前漫画补过一次、PDF 一直漏着（`ReaderPdfSource` 沿用
  /// [MediaSource] 默认 false，编辑框里没有作者栏）。
  @override
  bool get supportsAuthorEdit => true;

  /// 按书身份写作者：`hoshi://book/<bookKey>` 写 `epub_books.author`（与 format
  /// 无关，主键不变无需改键）；`hoshi://srtbook/<uid>` 写 `srt_books.author`
  /// （BUG-1018 A3）。空白作者 = 清空。
  @override
  Future<void> setAuthorFromMediaItem({
    required MediaItem item,
    required String? author,
  }) async {
    final FushiDatabase? db = sharedDatabase;
    if (db == null) return;
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey != null) {
      await db.updateEpubBookAuthor(bookKey, author);
      return;
    }
    final String? srtUid = ReaderFushiSource.parseSrtBookUid(
      item.mediaIdentifier,
    );
    if (srtUid == null) return;
    final SrtBookRepository repo = SrtBookRepository(db);
    final SrtBook? book = await repo.findByUid(srtUid);
    if (book == null) return;
    // 与 updateEpubBookAuthor 同一「空白即清空」语义。
    final String trimmed = (author ?? '').trim();
    book.author = trimmed.isEmpty ? null : trimmed;
    await repo.save(book);
  }

  /// 书族显示名出口：用户改过的显示名（override）原样显示；没改过时显示原名，
  /// 但去掉文件名标题末尾的 `[8 位十六进制]` 哈希后缀与书店系列注记
  /// `<系列名> (文库名)`（[cleanBookDisplayTitle]，只改显示，`item.title` 本身仍是身份原名）。
  @override
  String getDisplayTitleFromMediaItem(MediaItem item) =>
      getOverrideTitleFromMediaItem(item) ?? cleanBookDisplayTitle(item.title);

  /// 「已获取的每卷封面」：三种书共用 `hoshi://book/<bookKey>` 身份，刮削层按
  /// bookKey 存（[BookArtStore]），只查内存索引。字幕书（`fushi://srtbook/`）没有。
  @override
  File? scrapedThumbnailFile({
    required AppModel appModel,
    required MediaItem item,
  }) {
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey == null) return null;
    return BookArtStore.of(appModel.thumbnailsDirectory).coverFileFor(bookKey);
  }

  /// 删书时连同刮削层（卷封面 + 来源元数据，横幅按引用回收）一起清掉。
  @override
  Future<void> clearOverrideValues({
    required AppModel appModel,
    required MediaItem item,
  }) async {
    await super.clearOverrideValues(appModel: appModel, item: item);
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey != null) {
      await BookArtStore.of(
        appModel.thumbnailsDirectory,
        database: appModel.database,
      ).remove(bookKey);
    }
  }

  // TODO-786：阅读类媒体源默认卡槽比例归到书封比例 [kShelfBookCardAspectRatio]
  // （≈160/260），让书架封面 fitHeight 自然铺满、消除两侧白带。（书架视频分区
  // 死路径已删，视频卡槽比例随之移除，视频卡归「视频」tab 自管。）
  @override
  double get aspectRatio => kShelfBookCardAspectRatio;

  /// The body widget to show in the tab when this source's media type and this
  /// source is selected.
  @override
  BasePage buildHistoryPage({MediaItem? item, Widget? navigation}) {
    // 通用回退页无页头，导航条无处安放——忽略它只是没有视图切换，不影响正确性。
    return const HistoryReaderPage();
  }
}

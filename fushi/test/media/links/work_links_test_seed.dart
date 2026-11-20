import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

/// 作品层界面测试共用的造数：一套三卷小说（规则合集，算系列）、一部动画合集、
/// 一本漫画、一首 OP、一个只有建议连接的游戏。
class WorkLinksSeed {
  WorkLinksSeed._(this.db, this.novelSeriesId, this.animeId);

  final FushiDatabase db;
  final int novelSeriesId;
  final int animeId;

  MediaLinkEndpoint get anime => (
    kind: MediaLinkKind.videoCollection,
    key: collectionTagEntryKey(animeId),
  );

  static const MediaLinkEndpoint vol1 = (kind: MediaLinkKind.book, key: 'vol1');
  static const MediaLinkEndpoint vol2 = (kind: MediaLinkKind.book, key: 'vol2');
  static const MediaLinkEndpoint manga = (kind: MediaLinkKind.book, key: 'm1');
  static const MediaLinkEndpoint op = (
    kind: MediaLinkKind.musicTrack,
    key: 't1',
  );
  static const MediaLinkEndpoint game = (kind: MediaLinkKind.game, key: 'g');

  /// [withManga] / [withOp] / [withSuggestedGame] 控制挂哪些连接。
  static Future<WorkLinksSeed> create(
    FushiDatabase db, {
    bool withManga = true,
    bool withOp = true,
    bool withSuggestedGame = true,
  }) async {
    for (int i = 1; i <= 3; i++) {
      await insertBook(db, 'vol$i', '某小说 $i', uid: 'u$i');
    }
    await insertBook(db, 'm1', '某漫画', uid: 'um1', format: 'manga');
    final int series = await db.createMediaCollection(
      '某小说系列',
      collectionType: 'playlist',
      origin: CollectionOrigin.rule,
    );
    for (int i = 1; i <= 3; i++) {
      await db.addToCollection(series, MediaKind.epub, 'u$i');
    }
    final int anime = await db.createMediaCollection('某动画');
    final WorkLinksSeed seed = WorkLinksSeed._(db, series, anime);
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: vol1,
      to: seed.anime,
    );
    if (withManga) {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: manga,
        to: seed.anime,
      );
    }
    if (withOp) {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: op,
        to: seed.anime,
        role: 'op',
      );
    }
    if (withSuggestedGame) {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: seed.anime,
        to: game,
        source: MediaLinkSource.ai,
        confidence: 0.5,
      );
    }
    return seed;
  }

  static Future<void> insertBook(
    FushiDatabase db,
    String key,
    String title, {
    required String uid,
    String format = 'epub',
  }) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: key,
      title: title,
      epubPath: '/tmp/$key.epub',
      extractDir: '/tmp/$key',
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: 0,
      uid: Value<String>(uid),
      format: Value<String>(format),
    ),
  );
}

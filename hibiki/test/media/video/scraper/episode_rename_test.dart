import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/episode_rename.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// TODO-2491：集显示名提案与批量改名守卫。
///
/// 关键契约：dryRun 只出对照表**零写库**；执行态写穿 `video_books.title`；
/// 集名缺失（集级刮削回退写了作品名）时提案退化为纯 `E01` 式；未刮成员零提案
/// （自动刮削路径永不改名——改名只能从这里、经用户确认走）。
void main() {
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> boundCollection(FushiDatabase db, {String name = '作品名'}) async {
    final int id = await db.createMediaCollection(name);
    await db.upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(id),
      source: 'bangumi',
      subjectId: '100',
      title: name,
      scrapedAt: DateTime(2026),
    ));
    return id;
  }

  Future<void> addScrapedEpisode(
    FushiDatabase db,
    int collectionId,
    String uid, {
    required String title,
    int? episodeNumber,
    String? episodeTitle,
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: uid,
      title: title,
      videoPath: '/videos/$uid.mkv',
    ));
    await db.addToCollectionRaw(collectionId, 'video', uid);
    if (episodeNumber != null) {
      await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
        bookUid: uid,
        source: 'bangumi',
        subjectId: '100',
        title: episodeTitle ?? '作品名',
        episodeNumber: Value<int?>(episodeNumber),
        scrapedAt: DateTime(2026),
      ));
    }
  }

  group('proposeEpisodeDisplayName', () {
    test('formats E<padded> <title>, pure E<padded> without title', () {
      expect(
        proposeEpisodeDisplayName(episodeNumber: 1, episodeTitle: '出会い'),
        'E01 出会い',
      );
      expect(proposeEpisodeDisplayName(episodeNumber: 7), 'E07');
      expect(proposeEpisodeDisplayName(episodeNumber: 7, episodeTitle: '  '),
          'E07',
          reason: '空白集名等同无集名');
      expect(
        proposeEpisodeDisplayName(
            episodeNumber: 7, episodeTitle: 'x', padWidth: 3),
        'E007 x',
      );
      expect(proposeEpisodeDisplayName(episodeNumber: 123), 'E123',
          reason: '集号宽于 padWidth 时不截断');
    });
  });

  group('renameCollectionEpisodes', () {
    test('dryRun returns old->new table without writing', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db);
      await addScrapedEpisode(db, id, 'u1',
          title: 'Show - 01', episodeNumber: 1, episodeTitle: '出会い');
      await addScrapedEpisode(db, id, 'u2',
          title: 'Show - 02', episodeNumber: 2, episodeTitle: '別れ');
      await addScrapedEpisode(db, id, 'raw', title: '未刮的成员');

      final List<EpisodeRenameProposal> proposals =
          await renameCollectionEpisodes(
        db: db,
        collectionId: id,
        dryRun: true,
      );
      expect(proposals, hasLength(2), reason: '未刮成员不产生提案');
      expect(proposals.first.oldTitle, 'Show - 01');
      expect(proposals.first.newTitle, 'E01 出会い');
      expect(proposals.last.newTitle, 'E02 別れ');

      expect((await db.getVideoBookByBookUid('u1'))!.title, 'Show - 01',
          reason: 'dryRun 绝不写库');
      expect((await db.getVideoBookByBookUid('raw'))!.title, '未刮的成员');
    });

    test('execute writes titles through video_books and skips already-equal',
        () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db);
      await addScrapedEpisode(db, id, 'u1',
          title: 'Show - 01', episodeNumber: 1, episodeTitle: '出会い');
      await addScrapedEpisode(db, id, 'u2',
          title: 'E02 別れ', episodeNumber: 2, episodeTitle: '別れ');

      final List<EpisodeRenameProposal> proposals =
          await renameCollectionEpisodes(
        db: db,
        collectionId: id,
        dryRun: false,
      );
      expect(proposals, hasLength(1), reason: '新旧同名不产出提案');
      expect((await db.getVideoBookByBookUid('u1'))!.title, 'E01 出会い');
      expect((await db.getVideoBookByBookUid('u2'))!.title, 'E02 別れ');
    });

    test('episode title equal to work title degrades to bare E<n>', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db, name: '孤独摇滚！');
      // 集级刮削在集名缺失时回退写了作品名——提案不能拼成「E01 孤独摇滚！」。
      await addScrapedEpisode(db, id, 'u1',
          title: 'Show - 01', episodeNumber: 1, episodeTitle: '孤独摇滚！');

      final List<EpisodeRenameProposal> proposals =
          await renameCollectionEpisodes(
        db: db,
        collectionId: id,
        dryRun: true,
      );
      expect(proposals.single.newTitle, 'E01');
    });

    test('pad width follows max episode number (three digits)', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db);
      await addScrapedEpisode(db, id, 'u1',
          title: 'a', episodeNumber: 1, episodeTitle: '一');
      await addScrapedEpisode(db, id, 'u100',
          title: 'b', episodeNumber: 100, episodeTitle: '百');

      final List<EpisodeRenameProposal> proposals =
          await renameCollectionEpisodes(
        db: db,
        collectionId: id,
        dryRun: true,
      );
      expect(proposals.map((EpisodeRenameProposal p) => p.newTitle).toList(),
          <String>['E001 一', 'E100 百'],
          reason: '零填充宽度取合集内最大集号宽度');
    });
  });
}

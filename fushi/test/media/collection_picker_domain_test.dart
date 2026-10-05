import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2974：书移出合集后想加回去，「加入合集」列表里出现了视频
/// 的合集。合集表不带种类列，弹窗直接取全部合集。修复后候选由数据层按库页域
/// （书架 / 漫画库 / 视频库 / 游戏库）过滤，弹窗只认这一个来源。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<String> seedEpub(
    FushiDatabase db,
    String bookKey, {
    String format = 'epub',
  }) async {
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp',
      chapterCount: 1,
      chaptersJson: '["a"]',
      importedAt: 0,
      format: Value<String>(format),
    ));
    return (await db.resolveEpubBookUid(bookKey))!;
  }

  Future<
      ({
        FushiDatabase db,
        String bookUid,
        String mangaUid,
        int bookCol,
        int srtCol,
        int videoCol,
        int mangaCol,
        int gameCol,
      })> seed() async {
    final FushiDatabase db = await openDb();
    final String bookUid = await seedEpub(db, 'novel');
    final String otherBookUid = await seedEpub(db, 'novel2');
    final String mangaUid = await seedEpub(db, 'comic', format: 'manga');
    final String mangaUid2 = await seedEpub(db, 'comic2', format: 'manga');
    final int bookCol = await db.createMediaCollection('书合集');
    await db.addToCollection(bookCol, MediaKind.epub, otherBookUid);
    final int srtCol = await db.createMediaCollection('有声书合集');
    await db.addToCollection(srtCol, MediaKind.srt, 'srt-uid');
    final int videoCol = await db.createMediaCollection('视频合集');
    await db.addToCollection(videoCol, MediaKind.video, 'video-uid');
    final int mangaCol = await db.createMediaCollection('漫画合集');
    await db.addToCollection(mangaCol, MediaKind.epub, mangaUid2);
    final int gameCol = await db.createMediaCollection('游戏合集');
    await db.addToCollection(gameCol, MediaKind.game, 'game-key');
    return (
      db: db,
      bookUid: bookUid,
      mangaUid: mangaUid,
      bookCol: bookCol,
      srtCol: srtCol,
      videoCol: videoCol,
      mangaCol: mangaCol,
      gameCol: gameCol,
    );
  }

  Set<int> ids(List<MediaCollectionRow> rows) =>
      <int>{for (final MediaCollectionRow r in rows) r.id};

  test('数据层按库页域过滤：书只见书合集，视频只见视频合集，漫画只见漫画合集', () async {
    final s = await seed();
    expect(
      ids(await s.db
          .getMediaCollectionsForEntryDomain(MediaKind.epub, s.bookUid)),
      <int>{s.bookCol, s.srtCol},
      reason: '书（epub 非漫画）与字幕书同属书架域，不得出现视频 / 漫画 / 游戏合集',
    );
    expect(
      ids(await s.db
          .getMediaCollectionsForEntryDomain(MediaKind.srt, 'another-srt')),
      <int>{s.bookCol, s.srtCol},
    );
    expect(
      ids(await s.db.getMediaCollectionsForEntryDomain(MediaKind.video, 'v2')),
      <int>{s.videoCol},
    );
    expect(
      ids(await s.db
          .getMediaCollectionsForEntryDomain(MediaKind.epub, s.mangaUid)),
      <int>{s.mangaCol},
      reason: 'epub 行按 format 区分书 / 漫画',
    );
    expect(
      ids(await s.db.getMediaCollectionsForEntryDomain(MediaKind.game, 'g2')),
      <int>{s.gameCol},
    );
  });

  test('新建合集随首个成员落在正确的域', () async {
    final s = await seed();
    final int fresh = await s.db.createMediaCollection('新书合集');
    await s.db.addToCollection(fresh, MediaKind.epub, s.bookUid);
    expect(
      ids(await s.db.getMediaCollectionsForEntryDomain(MediaKind.epub, 'x')),
      contains(fresh),
    );
    expect(
      ids(await s.db.getMediaCollectionsForEntryDomain(MediaKind.video, 'v2')),
      isNot(contains(fresh)),
    );
  });

  test('旧成员行仍是 bookKey（非 uid）时同样识别漫画域', () async {
    final s = await seed();
    final int legacy = await s.db.createMediaCollection('旧漫画合集');
    await s.db.addToCollection(legacy, MediaKind.epub, 'comic');
    expect(
      ids(await s.db
          .getMediaCollectionsForEntryDomain(MediaKind.epub, s.mangaUid)),
      <int>{s.mangaCol, legacy},
    );
  });

  test('mapping：collectionShelfDomainOf 穷尽且 epub 按 isManga 分流', () {
    expect(
        collectionShelfDomainOf(MediaKind.epub), CollectionShelfDomain.books);
    expect(collectionShelfDomainOf(MediaKind.epub, isManga: true),
        CollectionShelfDomain.manga);
    expect(collectionShelfDomainOf(MediaKind.srt), CollectionShelfDomain.books);
    expect(
        collectionShelfDomainOf(MediaKind.video), CollectionShelfDomain.video);
    expect(
        collectionShelfDomainOf(MediaKind.game), CollectionShelfDomain.games);
  });

  Future<void> openDialog(
    WidgetTester tester,
    FushiDatabase db,
    String entryKey,
  ) async {
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showAddToCollectionDialog(
                context: context,
                database: db,
                mediaType: MediaKind.epub,
                entryKey: entryKey,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('书的「加入合集」弹窗不出现视频合集', (WidgetTester tester) async {
    late ({
      FushiDatabase db,
      String bookUid,
      String mangaUid,
      int bookCol,
      int srtCol,
      int videoCol,
      int mangaCol,
      int gameCol,
    }) s;
    await tester.runAsync(() async => s = await seed());
    await openDialog(tester, s.db, s.bookUid);
    expect(find.text('书合集'), findsOneWidget);
    expect(find.text('视频合集'), findsNothing, reason: 'BUG-2974：书不得看到视频合集');
    expect(find.text('漫画合集'), findsNothing);
    expect(find.text('游戏合集'), findsNothing);
  });

  test('弹窗候选只走数据层的域过滤来源（源码守卫）', () {
    final String src =
        File('lib/src/media/collections/add_to_collection_dialog.dart')
            .readAsStringSync();
    expect(src.contains('getMediaCollectionsForEntryDomain('), isTrue);
    expect(src.contains('getAllMediaCollections('), isFalse,
        reason: '「加入合集」不得再取全部合集（BUG-2974）');
  });

  test('新建合集落在本域：同名合集属别的库页时拒绝复用（源码守卫）', () {
    final String src =
        File('lib/src/media/collections/add_to_collection_dialog.dart')
            .readAsStringSync();
    expect(src.contains('collection_name_taken_other_library'), isTrue,
        reason: 'createMediaCollection 按自然键复用；别的域占着同名时必须拦下，'
            '否则书会被塞进视频合集');
  });
}

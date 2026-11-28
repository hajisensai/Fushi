import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_art_scrape.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/models/preferences_repository.dart';

import '../../ops/book_metadata_test_fixture.dart';

/// 合集「清除已获取的封面」：界面路径没有撤销，必须先确认；取消时一本都不删。
/// 焦点驱动（Esc 取消），不点坐标。
void main() {
  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;
  late ItemScrapeStore itemScrape;
  late BookArtStore store;

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_art_clear_');
    model = BookMetaTestModel(db, prefs, thumbs);
    itemScrape = ItemScrapeStore(
      db,
      imagesDirectory: Directory('${thumbs.path}/items'),
    );
    store = BookArtStore.of(thumbs, database: db, itemScrape: itemScrape);
    await store.write(
      record: const BookArtRecord(
        bookKey: 'k1',
        source: 'mangabaka',
        seriesId: '1',
        seriesTitle: 'Series',
        scrapedAt: 1,
      ),
    );
  });

  tearDown(() async {
    BookArtStore.resetForTesting();
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  testWidgets('清除前弹确认框；Esc 取消时刮削层原样保留', (WidgetTester tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    bool changed = false;
    final Future<void> done = CollectionArtScrape(
      database: db,
      thumbnailsDirectory: thumbs,
      servicesEnabled: () => true,
      migrationReadonly: () => model.isMigrationReadonly,
    ).clear(host, collectionId: 1, onChanged: () => changed = true);
    await tester.pumpAndSettle();
    expect(find.text(t.collection_art_scrape_clear_confirm), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await done;

    expect(find.text(t.collection_art_scrape_clear_confirm), findsNothing);
    expect(changed, isFalse);
    expect(store.recordFor('k1'), isNotNull);
    expect(File('${store.coverPathFor('k1')}.json').existsSync(), isTrue);
  });

  // BUG-5396：合集 epub 成员行 entryKey 是书 uid（v83）；清除曾按 uid 去找按
  // bookKey 记的刮削层，一本都删不掉。
  testWidgets('成员按 uid 存：Enter 确认后清掉该书的刮削层', (WidgetTester tester) async {
    await seedBook(db, 'k1');
    final String uid = (await db.resolveEpubBookUid('k1'))!;
    final int collectionId = await db.createMediaCollection('Series');
    await db.addToCollection(collectionId, MediaKind.epub, uid);

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    bool changed = false;
    final Future<void> done = CollectionArtScrape(
      database: db,
      thumbnailsDirectory: thumbs,
      servicesEnabled: () => true,
      migrationReadonly: () => model.isMigrationReadonly,
    ).clear(host, collectionId: collectionId, onChanged: () => changed = true);
    await tester.pumpAndSettle();
    expect(find.text(t.collection_art_scrape_clear_confirm), findsOneWidget);

    bool finished = false;
    unawaited(done.then((_) => finished = true));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // 确认后：drift 查询走假时钟、刮削层删文件走真实 IO，交替推进到清除做完。
    for (int i = 0; i < 100 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(finished, isTrue);

    expect(changed, isTrue);
    expect(store.recordFor('k1'), isNull);
  });

  // BUG-5609：横幅贴在书的背景图上（item_images，与书籍刮削同一份）。「清除已获取
  // 的封面和横幅」只撤获取贴上的那张：书籍刮削写的背景图哪怕记录里也记着横幅，
  // 也原样保留。
  testWidgets('清除只撤获取贴上的横幅，别处来的背景图不动', (WidgetTester tester) async {
    const String bannerUrl = 'https://images.mangabaka.dev/banner/1';
    final int collectionId = await db.createMediaCollection('Series');
    final Map<String, ItemScrapeKey> keys = <String, ItemScrapeKey>{};
    for (final String bookKey in <String>['k1', 'k2']) {
      await seedBook(db, bookKey);
      final String uid = (await db.resolveEpubBookUid(bookKey))!;
      await db.addToCollection(collectionId, MediaKind.epub, uid);
      keys[bookKey] = ItemScrapeKey(MediaKind.epub, uid);
    }
    late String foreign;
    await tester.runAsync(() async {
      final File banner = File('${thumbs.path}/banner.png')
        ..writeAsBytesSync(
          img.encodePng(img.Image(width: 16, height: 9)..clear()),
        );
      expect(await store.applyBanner('k1', banner, url: bannerUrl), isTrue);
      for (final String bookKey in <String>['k1', 'k2']) {
        await store.write(
          record: BookArtRecord(
            bookKey: bookKey,
            source: 'mangabaka',
            seriesId: '1',
            seriesTitle: 'Series',
            bannerKey: 'mangabaka_1',
            bannerUrl: bannerUrl,
            scrapedAt: 1,
          ),
        );
      }
      final File other = File('${thumbs.path}/anilist.png')
        ..writeAsBytesSync(
          img.encodePng(
            img.Image(width: 20, height: 9)..clear(img.ColorRgb8(9, 9, 9)),
          ),
        );
      foreign = await itemScrape.setImageFromFile(
        keys['k2']!,
        MediaImageKind.backdrop,
        other,
        sourceUrl: 'https://s4.anilist.co/banner/2.jpg',
      );
    });

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    final Future<void> done = CollectionArtScrape(
      database: db,
      thumbnailsDirectory: thumbs,
      servicesEnabled: () => true,
      migrationReadonly: () => model.isMigrationReadonly,
    ).clear(host, collectionId: collectionId, onChanged: () {});
    await tester.pumpAndSettle();
    bool finished = false;
    unawaited(done.then((_) => finished = true));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (int i = 0; i < 100 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(finished, isTrue);

    await tester.runAsync(() async {
      expect(
        await itemScrape.firstImage(keys['k1']!, MediaImageKind.backdrop),
        isNull,
      );
      final ItemImageRow? kept = await itemScrape.firstImage(
        keys['k2']!,
        MediaImageKind.backdrop,
      );
      expect(kept?.path, foreign);
      expect(File(foreign).existsSync(), isTrue);
    });
    expect(store.recordFor('k1'), isNull);
    expect(store.recordFor('k2'), isNull);
  });
}

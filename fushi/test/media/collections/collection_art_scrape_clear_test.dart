import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
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
  late BookArtStore store;

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_art_clear_');
    model = BookMetaTestModel(db, prefs, thumbs);
    store = BookArtStore.of(thumbs);
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

  // BUG-5373：合集 epub 成员行 entryKey 是书 uid（v83）；清除曾按 uid 去找按
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
}

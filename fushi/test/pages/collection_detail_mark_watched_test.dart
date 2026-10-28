import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 系列详情页：集多选 + 批量标记已看 / 未看（视频此前没有手动标记入口）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  int changed = 0;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    changed = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (int i = 1; i <= 3; i++) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value('video/e$i'),
          title: Value('Show 0$i'),
          videoPath: Value('/v/Show 0$i.mkv'),
          lastPositionMs: Value<int>(i == 1 ? 5 * 60 * 1000 : 0),
        ),
      );
    }
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    for (int i = 1; i <= 3; i++) {
      await db.addToCollection(collectionId, MediaKind.video, 'video/e$i');
    }
  });

  tearDown(() => db.close());

  Future<List<CollectionEpisodeSlot>> loadSlots() async {
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      collectionId,
    );
    return <CollectionEpisodeSlot>[
      for (final MediaCollectionItemRow item in items)
        if (await db.getVideoBookByBookUid(item.entryKey)
            case final VideoBookRow row)
          CollectionEpisodeSlot.local(row),
    ];
  }

  Widget buildApp() => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          origin: 'user',
          organizeAliases: '',
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadEpisodes: loadSlots,
        onOpenEpisode: (VideoBookRow _) {},
        onChanged: () => changed++,
      ),
    ),
  );

  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder row(String uid) =>
      find.byKey(ValueKey<String>('collection-episode-row-$uid'));

  Future<DateTime?> completedAt(WidgetTester tester, String uid) async {
    final VideoBookRow? r = await tester.runAsync<VideoBookRow?>(
      () => db.getVideoBookByBookUid(uid),
    );
    return r!.completedAt;
  }

  testWidgets('多选两集 → 标记已看：只改选中的集、清掉断点、退出多选', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('collection-selection-count')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('collection-select-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.tap(row('video/e1'));
    await tester.pumpAndSettle();
    await tester.tap(row('video/e2'));
    await tester.pumpAndSettle();
    expect(find.text(t.collection_selected_count(n: 2)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-selection-watched')),
    );
    await tester.pumpAndSettle();

    expect(await completedAt(tester, 'video/e1'), isNotNull);
    expect(await completedAt(tester, 'video/e2'), isNotNull);
    expect(await completedAt(tester, 'video/e3'), isNull);
    final VideoBookRow e1 = (await tester.runAsync<VideoBookRow?>(
      () => db.getVideoBookByBookUid('video/e1'),
    ))!;
    expect(e1.lastPositionMs, 0, reason: '标记已看一并收回续播位置');
    expect(changed, greaterThan(0), reason: '通知库页刷新');
    expect(
      find.byKey(const ValueKey<String>('collection-selection-count')),
      findsNothing,
      reason: '做完退出多选',
    );
  });

  testWidgets('全选本季 → 标记未看：全部取消已看', (WidgetTester tester) async {
    useSurface(tester);
    for (int i = 1; i <= 3; i++) {
      await db.markVideoCompleted('video/e$i', DateTime(2026));
    }
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-select-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_select_all_in_season));
    await tester.pumpAndSettle();
    expect(find.text(t.collection_selected_count(n: 3)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-selection-unwatched')),
    );
    await tester.pumpAndSettle();

    for (int i = 1; i <= 3; i++) {
      expect(await completedAt(tester, 'video/e$i'), isNull);
    }
  });

  testWidgets('没选任何集：标记按钮不可点', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('collection-select-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-selection-watched')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.text(t.collection_selected_count(n: 0)), findsOneWidget);
    expect(await completedAt(tester, 'video/e1'), isNull);
  });
}

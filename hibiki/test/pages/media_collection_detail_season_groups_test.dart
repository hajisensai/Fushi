import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 合集内分季（用户拍板「多季直接在合集里面分开」，根本性修法=分组按文件名
/// **现场派生**、不落库）：
/// - 多季合集**进入即分节**（存量合集零迁移、无需任何动作）；
/// - 单季合集保持平铺列表（零变化）；
/// - 「按季排序」动作把乱序列表整理成季→集连续并真写穿 DB；
/// - 节内拖拽重排把各节按显示顺序拼回全序落盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  Future<void> seed(List<(String, String)> rows) async {
    for (final (String uid, String title) in rows) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    for (final (String uid, _) in rows) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
  }

  /// 加入顺序故意乱序：S02E01, S01E01, Fan Disc, S01E02。
  Future<void> seedMultiSeason() => seed(const <(String, String)>[
        ('video/s2e1', 'Show S02E01'),
        ('video/s1e1', 'Show S01E01'),
        ('video/pv', 'Show Fan Disc'),
        ('video/s1e2', 'Show S01E02'),
      ]);

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in all) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow it in items)
        if (byUid[it.entryKey] case final VideoBookRow row) row,
    ];
  }

  Future<List<String>> persistedOrder() async => <String>[
        for (final MediaCollectionItemRow it
            in await db.getCollectionItems(collectionId))
          it.entryKey,
      ];

  Widget buildApp() => TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              id: collectionId,
              name: 'Show',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
              orderUpdatedAt: 0,
            ),
            loadMembers: loadMembers,
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
          ),
        ),
      );

  void useWideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('多季合集进入即分节（分组派生自文件名，存量零迁移、无需任何动作）', (WidgetTester tester) async {
    useWideSurface(tester);
    await seedMultiSeason();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    expect(find.text('PV·特典'), findsOneWidget);
  });

  testWidgets('单季合集：平铺列表，无分节标题（零变化）', (WidgetTester tester) async {
    useWideSurface(tester);
    await seed(const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
    ]);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('第 1 季'), findsNothing);
    expect(find.text('PV·特典'), findsNothing);
    expect(find.text('Show 01'), findsOneWidget);
  });

  testWidgets('「按季排序」：季→集重排、PV/特典殿后，真写穿 sortIndex',
      (WidgetTester tester) async {
    useWideSurface(tester);
    await seedMultiSeason();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.segment));
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/s1e1', 'video/s1e2', 'video/s2e1', 'video/pv'],
      reason: '季升序→集升序，PV/特典殿后，且真写穿 sortIndex（不是只动内存）',
    );
  });

  testWidgets('分节视图节内拖拽：各节按显示顺序拼回全序落盘', (WidgetTester tester) async {
    useWideSurface(tester);
    await seedMultiSeason();
    // 先整理成分季连续（s1e1, s1e2, s2e1, pv），使分节与全序一致。
    await db.reorderCollectionItems(collectionId, <CollectionMemberKey>[
      for (final String uid in <String>[
        'video/s1e1',
        'video/s1e2',
        'video/s2e1',
        'video/pv',
      ])
        (mediaType: MediaKind.video.dbValue, entryKey: uid),
    ]);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 长按第 1 季首行（S01E01）往下拖过一行 → 节内变为 s1e2, s1e1。
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Show S01E01')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (int step = 0; step < 5; step++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/s1e2', 'video/s1e1', 'video/s2e1', 'video/pv'],
      reason: '节内重排只动本节，其余节保持，拼回全序落盘',
    );
  });
}

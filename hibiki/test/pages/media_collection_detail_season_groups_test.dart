import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v64 合集内分季（用户拍板「多季直接在合集里面分开」）：
/// - 未分组合集保持平铺列表（零变化）；
/// - 「按季分组」动作按文件名重排（季→集，PV/特典殿后）并写分组键，真写穿 DB；
/// - 已分组（≥2 组）合集按季分节渲染分节标题；
/// - 节内拖拽重排把各节按显示顺序拼回全序落盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  /// 加入顺序故意乱序：S02E01, S01E01, Fan Disc, S01E02。
  const List<(String, String)> seeds = <(String, String)>[
    ('video/s2e1', 'Show S02E01'),
    ('video/s1e1', 'Show S01E01'),
    ('video/pv', 'Show Fan Disc'),
    ('video/s1e2', 'Show S01E02'),
  ];

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in seeds) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  Future<void> addAll({bool withGroupKeys = false}) async {
    for (final (String uid, String title) in seeds) {
      await db.addToCollection(
        collectionId,
        MediaKind.video,
        uid,
        groupKey: withGroupKeys
            ? (title.contains('S02')
                ? 's2'
                : title.contains('S01')
                    ? 's1'
                    : 'extras')
            : null,
      );
    }
  }

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

  Future<Map<String, String?>> persistedGroupKeys() async => <String, String?>{
        for (final MediaCollectionItemRow it
            in await db.getCollectionItems(collectionId))
          it.entryKey: it.groupKey,
      };

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

  testWidgets('未分组合集：平铺列表，无分节标题（零变化）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await addAll();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('第 1 季'), findsNothing);
    expect(find.text('PV·特典'), findsNothing);
    expect(find.text('Show S02E01'), findsOneWidget);
  });

  testWidgets('「按季分组」：季→集重排 + 分组键真写穿 DB，列表按季分节', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await addAll();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.segment));
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/s1e1', 'video/s1e2', 'video/s2e1', 'video/pv'],
      reason: '季升序→集升序，PV/特典殿后，且真写穿 sortIndex',
    );
    expect(await persistedGroupKeys(), <String, String?>{
      'video/s1e1': 's1',
      'video/s1e2': 's1',
      'video/s2e1': 's2',
      'video/pv': 'extras',
    });
    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    expect(find.text('PV·特典'), findsOneWidget);
  });

  testWidgets('已分组合集进入即分节渲染（不需要重跑动作）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await addAll(withGroupKeys: true);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    expect(find.text('PV·特典'), findsOneWidget);
  });

  testWidgets('分节视图节内拖拽：各节按显示顺序拼回全序落盘', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await addAll(withGroupKeys: true);
    // 先把顺序整理成分季连续（s1e1, s1e2, s2e1, pv），使分节与全序一致。
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

import 'package:drift/drift.dart' show GeneratedColumn, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi_core/fushi_core.dart';

/// 合集内分季（用户拍板「多季直接在合集里面分开」；分组是**文件名的纯函数、
/// 不落库**）落到当前详情页形态：顶部大图 + 横向剧集轨 + 默认折叠的管理列表。
///
/// 钉死四件事：
/// ①多季合集**首屏**就能看见季 tab —— 不需要先展开那条默认折叠的管理列表
///   （详情页改版成大图 + 折叠列表后，分季若只做在折叠区里，用户打开页面根本看不见）；
/// ②切 tab 换成该季的剧集（轨道与管理列表同一份可见成员）；
/// ③单季合集**不出现 tab**（不给普通合集平白加一层 UI）；
/// ④分季纯派生：只看/只切 tab 绝不写 DB，表结构里也没有任何分组列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// 集列表里的标题（顶部大图也会渲染「续播集」标题，不限定范围会误判）。
  /// hayase 式集卡的标题带「N. 」前缀，故用 textContaining。
  Finder railText(String title) => find.descendant(
        of: find.byType(FushiReorderableGrid),
        matching: find.textContaining(title),
      );

  Future<void> seed(
    List<(String, String)> rows, {
    Set<String> completed = const <String>{},
    Set<String> started = const <String>{},
  }) async {
    for (final (String uid, String title) in rows) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
        completedAt: completed.contains(uid)
            ? Value(DateTime(2026))
            : const Value<DateTime?>(null),
        lastPositionMs: Value(started.contains(uid) ? 60000 : 0),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    for (final (String uid, _) in rows) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
  }

  /// 加入顺序故意乱序（S02 在前、PV 夹中间）：tab 仍必须按季升序 + 特典殿后。
  Future<void> seedMultiSeason() => seed(const <(String, String)>[
        ('video/s2e1', 'Show S02E01'),
        ('video/s1e1', 'Show S01E01'),
        ('video/pv', 'Show Fan Disc'),
        ('video/s1e2', 'Show S01E02'),
      ]);

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
          '${it.entryKey}@${it.sortIndex}',
      ];

  Widget buildApp({VoidCallback? onChanged}) => TranslationProvider(
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
            onChanged: onChanged ?? () {},
          ),
        ),
      );

  /// 足够高的画布：顶部大图 clamp 到 600，剧集区（含季 tab）随后仍在首屏内，
  /// 从而能真的断言「不滚动、不展开就看得见」。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('多季合集：首屏就能看见季 tab 与默认展开的集列表，tab 按季升序、特典殿后',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await seedMultiSeason();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // hayase 式改版（TODO-2491）：集列表默认全量可见，不再有折叠的管理列表。
    expect(
      find.byType(FushiReorderableGrid),
      findsOneWidget,
      reason: '集列表（宽卡网格）必须默认可见，无需任何展开动作',
    );
    final Finder tabs = find.byKey(const ValueKey<String>(
      'collection-season-tabs',
    ));
    expect(tabs, findsOneWidget);
    // 真的画在首屏可见区域内（不是只挂在树上）。
    expect(tester.getTopLeft(tabs).dy, lessThan(1400));

    final List<String> labels = tester
        .widgetList<Tab>(find.descendant(of: tabs, matching: find.byType(Tab)))
        .map((Tab tab) => tab.text ?? '')
        .toList();
    expect(labels, <String>['第 1 季', '第 2 季', 'PV·特典'],
        reason: '加入顺序乱序，tab 仍按季升序排列、PV/特典殿后');
  });

  testWidgets('「标题 2 - 集号」命名也出季 tab，两季不再交错（BUG-1543）',
      (WidgetTester tester) async {
    useTallSurface(tester);
    // 用户实测命名：第 2 季的季号只体现为标题尾随的「2」。
    await seed(const <(String, String)>[
      ('video/s1e1', 'Hibike! Euphonium - 01 (BD 1280x720 x264 AACx3)'),
      ('video/s2e1', 'Hibike! Euphonium 2 - 01 (BD 1280x720 x264 AAC)'),
      ('video/s1e2', 'Hibike! Euphonium - 02 (BD 1280x720 x264 AACx3)'),
      ('video/s2e2', 'Hibike! Euphonium 2 - 02 (BD 1280x720 x264 AAC)'),
    ]);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder tabs =
        find.byKey(const ValueKey<String>('collection-season-tabs'));
    expect(tabs, findsOneWidget, reason: '两季必须出 tab，此前全被判成第 1 季');
    final List<String> labels = tester
        .widgetList<Tab>(find.descendant(of: tabs, matching: find.byType(Tab)))
        .map((Tab tab) => tab.text ?? '')
        .toList();
    expect(labels, <String>['第 1 季', '第 2 季']);

    // 第 1 季 tab 里只有第 1 季的集（此前 S1/S2 按集号交错混排）。
    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();
    expect(railText('Hibike! Euphonium - 01'), findsOneWidget);
    expect(railText('Hibike! Euphonium - 02'), findsOneWidget);
    expect(railText('Hibike! Euphonium 2 - 01'), findsNothing);
  });

  testWidgets('多季合集：切 tab 换成该季剧集', (WidgetTester tester) async {
    useTallSurface(tester);
    await seedMultiSeason();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 无任何播放痕迹 → 续播落在全序第 0 个（S02E01），tab 随之停在第 2 季。
    expect(railText('Show S02E01'), findsOneWidget);
    expect(railText('Show S01E01'), findsNothing);

    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();

    expect(railText('Show S01E01'), findsOneWidget);
    expect(railText('Show S01E02'), findsOneWidget);
    expect(railText('Show S02E01'), findsNothing);
    expect(railText('Show Fan Disc'), findsNothing);

    await tester.tap(find.text('PV·特典'));
    await tester.pumpAndSettle();

    expect(railText('Show Fan Disc'), findsOneWidget);
    expect(railText('Show S01E01'), findsNothing);
  });

  testWidgets('多季合集：进页面停在续播那一季（大图与列表讲同一件事）', (WidgetTester tester) async {
    useTallSurface(tester);
    // 落盘序已是季→集连续；第 1 季看完、第 2 季第一集看了一半 → 续播在 S02E01。
    await seed(
      const <(String, String)>[
        ('video/s1e1', 'Show S01E01'),
        ('video/s1e2', 'Show S01E02'),
        ('video/s2e1', 'Show S02E01'),
        ('video/pv', 'Show Fan Disc'),
      ],
      completed: const <String>{'video/s1e1', 'video/s1e2'},
      started: const <String>{'video/s2e1'},
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(railText('Show S02E01'), findsOneWidget);
    expect(railText('Show S01E01'), findsNothing,
        reason: '初始 tab 必须是续播集所在的季，而不是恒定第 1 季');
  });

  testWidgets('单季合集：不出现季 tab（不平白加一层 UI）', (WidgetTester tester) async {
    useTallSurface(tester);
    await seed(const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
    ]);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('collection-season-tabs')),
      findsNothing,
    );
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('第 1 季'), findsNothing);
    expect(railText('Show 01'), findsOneWidget);
    expect(railText('Show 02'), findsOneWidget);
  });

  testWidgets('分季是文件名纯函数派生：只看/只切 tab 不写任何 DB 行', (WidgetTester tester) async {
    useTallSurface(tester);
    await seedMultiSeason();
    final List<String> before = await persistedOrder();
    // 页面每次落盘都会喊 onChanged 让库页刷新 —— 用它当「有没有写过 DB」的
    // 探针，比只比 sortIndex 强：把同一份顺序重写一遍，值不变但确实写了。
    int persistCalls = 0;
    await tester.pumpWidget(buildApp(onChanged: () => persistCalls++));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PV·特典'));
    await tester.pumpAndSettle();

    expect(persistCalls, 0, reason: '只看/只切 tab 不得触发任何落盘');
    expect(await persistedOrder(), before,
        reason: '分季只是展示派生：进页面 + 切 tab 都不得改动 sortIndex（更不落分组列）');
  });

  testWidgets('「按季排序」动作：季→集重排、PV/特典殿后，真写穿 sortIndex',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await seedMultiSeason();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_sort_by_season).last);
    await tester.pumpAndSettle();

    expect(
      <String>[
        for (final MediaCollectionItemRow it
            in await db.getCollectionItems(collectionId))
          it.entryKey,
      ],
      <String>['video/s1e1', 'video/s1e2', 'video/s2e1', 'video/pv'],
      reason: 'tab 展示序是派生的，本动作把落盘全序也整理成季→集连续',
    );
  });

  test('合集成员表没有任何分组/季列（分组不落库，存量合集零迁移）', () {
    final FushiDatabase database =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final List<String> columns = database.mediaCollectionItems.$columns
        .map((GeneratedColumn<Object> c) => c.name.toLowerCase())
        .toList();
    expect(columns, isNot(anyElement(contains('group'))));
    expect(columns, isNot(anyElement(contains('season'))));
  });
}

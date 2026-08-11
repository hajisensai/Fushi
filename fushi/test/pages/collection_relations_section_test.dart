import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/collection_relations_section.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2484 UI：合集详情页「相关作品」横滚区。
///
/// 钉四件事：
/// ① 无关系边 → 整块不渲染（未刮削合集与本功能引入前逐像素一致）；
/// ② 有关系边 → 卡片带关系类型徽标 + 标题；
/// ③ 已绑定边点击 → 走 onOpenCollection(targetCollectionId)；
/// ④ 未绑定边点击 → 弹菜单，「绑定到已有合集」选中后真写穿
///    collection_relations.target_collection_id。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  late int otherCollectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId =
        await db.createMediaCollection('本篇', collectionType: 'playlist');
    otherCollectionId =
        await db.createMediaCollection('续篇合集', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  Future<void> seedRelations({int? boundTarget}) =>
      db.replaceCollectionRelations(
          collectionId, <CollectionRelationsCompanion>[
        CollectionRelationsCompanion.insert(
          collectionId: collectionId,
          relationType: 'sequel',
          sortIndex: const Value<int>(0),
          targetCollectionId: Value<int?>(boundTarget),
          source: 'bangumi',
          subjectId: '200',
          title: '某作品 第二季',
        ),
        CollectionRelationsCompanion.insert(
          collectionId: collectionId,
          relationType: 'movie',
          sortIndex: const Value<int>(1),
          targetCollectionId: const Value<int?>(null),
          source: 'bangumi',
          subjectId: '300',
          title: '某作品 剧场版',
        ),
      ]);

  Widget buildApp({
    void Function(int targetCollectionId)? onOpenCollection,
    void Function(CollectionRelationRow relation)? onDownload,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CollectionRelationsSection(
                database: db,
                collectionId: collectionId,
                onOpenCollection: onOpenCollection ?? (int _) {},
                onDownload: onDownload ?? (CollectionRelationRow _) {},
              ),
            ),
          ),
        ),
      );

  testWidgets('无关系边 → 整块不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('collection-relations-section')),
      findsNothing,
    );
    expect(find.text('相关作品'), findsNothing);
  });

  testWidgets('有关系边 → 区块渲染：标题 + 类型徽标 + 条目名', (WidgetTester tester) async {
    await seedRelations();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('collection-relations-section')),
      findsOneWidget,
    );
    expect(find.text('相关作品'), findsOneWidget);
    expect(find.text('某作品 第二季'), findsOneWidget);
    expect(find.text('某作品 剧场版'), findsOneWidget);
    expect(find.text('续作'), findsOneWidget, reason: 'sequel → 续作徽标');
    expect(find.text('剧场版'), findsOneWidget, reason: 'movie → 剧场版徽标');
  });

  testWidgets('已绑定边点击 → onOpenCollection(target)', (WidgetTester tester) async {
    await seedRelations(boundTarget: otherCollectionId);
    int? opened;
    await tester
        .pumpWidget(buildApp(onOpenCollection: (int id) => opened = id));
    await tester.pumpAndSettle();

    await tester.tap(find.text('某作品 第二季'));
    await tester.pumpAndSettle();

    expect(opened, otherCollectionId);
  });

  testWidgets('未绑定边点击 → 菜单「绑定到已有合集」真写穿 targetCollectionId',
      (WidgetTester tester) async {
    await seedRelations();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('某作品 剧场版'));
    await tester.pumpAndSettle();
    expect(find.text('去下载'), findsOneWidget);
    expect(find.text('绑定到已有合集'), findsOneWidget);

    await tester.tap(find.text('绑定到已有合集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('续篇合集'));
    await tester.pumpAndSettle();

    final List<CollectionRelationRow> rows =
        await db.getCollectionRelations(collectionId);
    final CollectionRelationRow movie =
        rows.firstWhere((CollectionRelationRow r) => r.relationType == 'movie');
    expect(movie.targetCollectionId, otherCollectionId,
        reason: '绑定必须真写穿 collection_relations.target_collection_id');
  });

  testWidgets('未绑定边菜单「去下载」→ onDownload(relation)', (WidgetTester tester) async {
    await seedRelations();
    CollectionRelationRow? downloaded;
    await tester.pumpWidget(
      buildApp(onDownload: (CollectionRelationRow r) => downloaded = r),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('某作品 剧场版'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去下载'));
    await tester.pumpAndSettle();

    expect(downloaded?.title, '某作品 剧场版');
  });

  // ---------------------------------------------------------------------
  // BUG-1536：横滚行不得抢走整页纵向滚动（用户实报「视频主页的横向滚动要按住
  // shift+滚轮才行，不然会把上下滚动行为抢走」）。本区与视频首页横滚行是同一套
  // 包装（HorizontalDragScrollable + 横向 ListView，无滚轮投轴桥），在这里钉住
  // 行为：裸滚轮 → 外层纵滚；Shift + 滚轮 → 横滚（Flutter 内建翻轴）。
  // ---------------------------------------------------------------------

  Future<void> seedManyRelations({int count = 10}) =>
      db.replaceCollectionRelations(
        collectionId,
        List<CollectionRelationsCompanion>.generate(
          count,
          (int i) => CollectionRelationsCompanion.insert(
            collectionId: collectionId,
            relationType: 'sequel',
            sortIndex: Value<int>(i),
            targetCollectionId: const Value<int?>(null),
            source: 'bangumi',
            subjectId: '${400 + i}',
            title: '相关作品 $i',
          ),
        ),
      );

  /// 把本区放进一个**真的能纵向滚动**的页面（合集详情页同构）：只有外层有滚动
  /// 余量，「滚轮被谁吃掉」才是可观测的。
  Widget buildScrollHarness() => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  CollectionRelationsSection(
                    database: db,
                    collectionId: collectionId,
                    onOpenCollection: (int _) {},
                    onDownload: (CollectionRelationRow _) {},
                  ),
                  const SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        ),
      );

  ScrollableState scrollableTowards(WidgetTester tester, AxisDirection dir) =>
      tester.state<ScrollableState>(find.byWidgetPredicate(
        (Widget w) => w is Scrollable && w.axisDirection == dir,
      ));

  testWidgets('BUG-1536：裸滚轮停在横滚行上 → 整页纵滚，横向纹丝不动', (WidgetTester tester) async {
    await seedManyRelations();
    await tester.pumpWidget(buildScrollHarness());
    await tester.pumpAndSettle();

    final ScrollableState row = scrollableTowards(tester, AxisDirection.right);
    final ScrollableState page = scrollableTowards(tester, AxisDirection.down);
    // 前置条件：两个方向都必须有滚动余量，否则本用例是假绿。
    expect(row.position.maxScrollExtent, greaterThan(0), reason: '横向内容必须超出视口');
    expect(page.position.maxScrollExtent, greaterThan(0),
        reason: '页面必须有纵向滚动余量');

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset onRow = tester.getCenter(find.text('相关作品 0'));
    await tester.sendEventToBinding(mouse.hover(onRow));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();

    expect(row.position.pixels, 0,
        reason: '裸滚轮不得横滚（回归判据：包回 WheelToHorizontalScroll 这里就 >0）');
    expect(page.position.pixels, greaterThan(0), reason: '滚轮必须冒泡给外层纵向滚动');
  });

  testWidgets('BUG-1536：Shift + 滚轮 → 横滚该行，整页不动', (WidgetTester tester) async {
    await seedManyRelations();
    await tester.pumpWidget(buildScrollHarness());
    await tester.pumpAndSettle();

    final ScrollableState row = scrollableTowards(tester, AxisDirection.right);
    final ScrollableState page = scrollableTowards(tester, AxisDirection.down);

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset onRow = tester.getCenter(find.text('相关作品 0'));
    await tester.sendEventToBinding(mouse.hover(onRow));
    await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(row.position.pixels, greaterThan(0),
        reason: 'Shift + 滚轮必须横滚（Flutter 内建 pointerAxisModifiers 翻轴）');
    expect(page.position.pixels, 0, reason: '横滚时整页不得跟着动');
  });
}

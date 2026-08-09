import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
}

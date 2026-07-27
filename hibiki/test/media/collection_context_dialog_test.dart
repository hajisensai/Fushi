import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/collections/collection_context_dialog.dart';
import 'package:hibiki/utils.dart';

/// 三库页统一合集上下文菜单的**行为**守卫（破坏性分支优先）。
///
/// 该弹窗是书/视频/游戏三页共用的唯一合集菜单，含「删除合集」这条不可撤销动作，
/// 且删除有两条语义完全不同的路径：
///   1. 只删合集容器（解链）——成员媒体一条不动；
///   2. 勾选「连同成员一起删」——先由调用方注入的 `onDeleteMembersMedia` 删成员
///      本体，再解散容器。
/// 两条路径混淆 = 用户数据丢失，故必须有行为测试钉死，而不是只靠源码扫描。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<(HibikiDatabase, MediaCollectionRow)> buildCollection({
    bool withMembers = true,
  }) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int id = await db.createMediaCollection('collection-a');
    if (withMembers) {
      await db.addToCollection(id, MediaKind.epub, 'book-1');
      await db.addToCollection(id, MediaKind.epub, 'book-2');
    }
    final MediaCollectionRow row = (await db.getAllMediaCollections())
        .firstWhere((MediaCollectionRow r) => r.id == id);
    return (db, row);
  }

  /// 挂一个真页面 context 打开被测弹窗，返回收集到的回调证据。
  Future<_Probe> pumpAndOpen(
    WidgetTester tester, {
    required HibikiDatabase db,
    required MediaCollectionRow collection,
    required bool injectDeleteMembers,
  }) async {
    final _Probe probe = _Probe();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => showCollectionContextDialog(
                  context: ctx,
                  db: db,
                  collection: collection,
                  onOpenDetail: () => probe.openedDetail = true,
                  onChanged: () => probe.changedCount++,
                  onDeleteMembersMedia: injectDeleteMembers
                      ? (List<MediaCollectionItemRow> members) async {
                          probe.deletedMembers = members
                              .map((MediaCollectionItemRow m) => m.entryKey)
                              .toList();
                        }
                      : null,
                  deleteMembersCheckboxLabel: injectDeleteMembers
                      ? t.delete_collection_also_books
                      : null,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return probe;
  }

  /// 点菜单里的「删除合集」危险动作 → 进确认框。菜单项渲染成 TextButton，
  /// 确认框的确认键是 isDestructiveAction 的 FilledButton，两者同文案不同控件，
  /// 各自按控件类型定位就不会认错。
  Future<void> tapDeleteAction(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, t.delete_collection));
    await tester.pumpAndSettle();
  }

  /// 点确认框里的「删除合集」确认键（销毁按钮 = FilledButton）。
  Future<void> tapConfirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, t.delete_collection));
    await tester.pumpAndSettle();
  }

  testWidgets('删合集不勾选：只解散容器，成员本体回调一次都不调', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection();
    final _Probe probe = await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: true,
    );

    await tapDeleteAction(tester);
    // 有成员 + 注入了删成员回调 → 确认框必须给出勾选行（默认不勾）。
    expect(
      find.text(t.delete_collection_also_books),
      findsOneWidget,
      reason: '有成员且调用方支持删本体时必须提供勾选，否则用户无从选择。',
    );

    await tapConfirm(tester);

    // 成员本体一条没删；合集容器已解散；页面被通知刷新。
    expect(probe.deletedMembers, isNull, reason: '不勾选绝不能删成员媒体本体。');
    expect(await db.getAllMediaCollections(), isEmpty);
    expect(probe.changedCount, 1);
  });

  testWidgets('删合集勾选「连同成员一起删」：先删成员本体再解散容器', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection();
    final _Probe probe = await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: true,
    );

    await tapDeleteAction(tester);
    // 勾选行整行可点（Checkbox 本身 IgnorePointer）。
    await tester.tap(find.text(t.delete_collection_also_books));
    await tester.pumpAndSettle();
    await tapConfirm(tester);

    // 成员快照在解散容器之前取得——否则 deleteMediaCollection 清完引用行就取不到了。
    expect(probe.deletedMembers, <String>['book-1', 'book-2']);
    expect(await db.getAllMediaCollections(), isEmpty);
    expect(probe.changedCount, 1);
  });

  testWidgets('取消确认框：合集与成员都不动，页面也不刷新', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection();
    final _Probe probe = await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: true,
    );

    await tapDeleteAction(tester);
    await tester.tap(find.widgetWithText(TextButton, t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(probe.deletedMembers, isNull);
    expect((await db.getAllMediaCollections()).length, 1);
    expect(await db.getCollectionItems(collection.id), hasLength(2));
    expect(probe.changedCount, 0);
  });

  testWidgets('调用方未注入删成员回调：确认框不给勾选（不许暗示能删本体）', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection();
    await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: false,
    );

    await tapDeleteAction(tester);
    expect(find.text(t.delete_collection_also_books), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('空合集：即使注入了删成员回调也不给勾选（无成员可删）', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection(withMembers: false);
    await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: true,
    );

    await tapDeleteAction(tester);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('顶部主按钮 = 打开详情（不写库、不触发 onChanged）', (WidgetTester tester) async {
    final (HibikiDatabase db, MediaCollectionRow collection) =
        await buildCollection();
    final _Probe probe = await pumpAndOpen(
      tester,
      db: db,
      collection: collection,
      injectDeleteMembers: true,
    );

    await tester.tap(find.text(t.collection_view_all));
    await tester.pumpAndSettle();

    expect(probe.openedDetail, isTrue);
    expect(probe.changedCount, 0);
    expect((await db.getAllMediaCollections()).length, 1);
  });

  // ---------------------------------------------------------------------------
  // 三库页接线对账（源码扫描）：合集菜单只有一份实现，但「删成员本体」这条支线
  // 靠调用方注入，漏注入就静默退化成「只能解散合集」——正是游戏页此前的状态。
  // 逐页钉住三件事：走统一菜单、注入了 onDeleteMembersMedia、给了对应勾选文案。
  // ---------------------------------------------------------------------------
  group('三库页合集菜单接线对账', () {
    const Map<String, String> pages = <String, String>{
      'lib/src/pages/implementations/reader_hibiki_history_page.dart':
          't.delete_collection_also_books',
      'lib/src/pages/implementations/home_video_page.dart':
          't.delete_collection_also_videos',
      'lib/src/pages/implementations/games_library_page.dart':
          't.delete_collection_also_games',
    };

    pages.forEach((String path, String checkboxLabel) {
      test('$path 走统一合集菜单并注入删成员本体支线', () {
        final String src = File(path).readAsStringSync();
        expect(
          src,
          contains('showCollectionContextDialog('),
          reason: '合集入口的右键/长按菜单必须走唯一实现，不许各页自建。',
        );
        expect(
          src,
          contains('onDeleteMembersMedia:'),
          reason: '漏注入 onDeleteMembersMedia = 该页删合集永远无法连成员一起删，'
              '与另外两页行为不一致（游戏页曾漏）。',
        );
        expect(
          src,
          contains('deleteMembersCheckboxLabel: $checkboxLabel'),
          reason: '勾选文案必须按媒体域给，否则用户看不清会删掉什么。',
        );
      });
    });
  });
}

/// 回调证据收集器（比一堆散落局部变量更好读）。
class _Probe {
  bool openedDetail = false;
  int changedCount = 0;
  List<String>? deletedMembers;
}

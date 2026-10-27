import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart'
    show CollectionMemberInfo;
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/components/library_reorder.dart';
import 'package:fushi_core/fushi_core.dart';

/// 书籍合集详情页（[MediaCollectionGridDetailPage]）网格拖排 + 长按/右键上下文菜单
/// 真穿库验证：
///  - 长按整卡拖到新坑位 → `getCollectionItems` 的 sortIndex 真写穿（与库页合集行同源）；
///  - 长按原地松手弹上下文菜单（移出 + 打开）→ 移出真调 `removeFromCollection`；
///  - 菜单「打开」真回调 onOpenMember。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<({FushiDatabase db, MediaCollectionRow col})> seed() async {
    final FushiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('C');
    await db.addToCollection(cid, MediaKind.epub, 'k1');
    await db.addToCollection(cid, MediaKind.epub, 'k2');
    await db.addToCollection(cid, MediaKind.epub, 'k3');
    // 默认排序是卷号；拖排只在手动序下开放——模拟「用户保存过手动顺序」。
    await db.setPref(
      collectionDetailSortPrefKey(cid),
      kCollectionDetailManualSortValue,
    );
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
    return (db: db, col: col);
  }

  /// 成员卡：纯视觉带 Key 的方块（真实调用方的卡片被详情页包进 IgnorePointer，
  /// 这里给个可定位的 Key 即可）。签名带可选 [onRemoveFromCollection] 注入点（详情页
  /// 会传 `() => _removeMember(row)`，供真实调用方把「移出合集」接进长按对话框）。
  Widget? cardBuilder(
    String mediaType,
    String entryKey, {
    VoidCallback? onRemoveFromCollection,
  }) => Container(
    key: ValueKey<String>('member-$entryKey'),
    color: Colors.blue,
    alignment: Alignment.center,
    child: Text(entryKey),
  );

  Widget wrapPage(
    MediaCollectionRow col,
    FushiDatabase db, {
    void Function(String mediaType, String entryKey)? onOpenMember,
  }) => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionGridDetailPage(
        database: db,
        collection: col,
        memberCardBuilder: cardBuilder,
        onOpenMember: onOpenMember,
        onChanged: () {},
      ),
    ),
  );

  /// M3E 详情页（8853cd4fc75）顶部是叠层封面 hero + 工具行，默认 800x600 测试
  /// 视口里成员网格整片落在可视区外（卡片中心 y≈728 > 600），触摸手势命中不到。
  /// 给一个桌面级视口，让成员网格与确认弹窗都在可视区内。
  void useDesktopView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('长按整卡拖到新坑位 → sortIndex 真写穿 getCollectionItems', (
    WidgetTester tester,
  ) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db));
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> before = await s.db.getCollectionItems(
      s.col.id,
    );
    expect(
      before.map((MediaCollectionItemRow r) => r.entryKey).toList(),
      <String>['k1', 'k2', 'k3'],
    );

    // 把 k1 长按拖到 k3 的坑位（同一行横向相邻）。
    final Offset start = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k1')),
    );
    final Offset target = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k3')),
    );
    // 触屏长按现在直接弹菜单（与库页同一时机），拖排走鼠标按住即拖；触屏拖排
    // 经菜单「排序」进入排序模式，见下方排序模式用例。
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after = await s.db.getCollectionItems(
      s.col.id,
    );
    expect(
      after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
      <String>['k2', 'k3', 'k1'],
      reason: 'k1 拖到末位后成员序真变（getCollectionItems 按 sortIndex 升序）',
    );
    expect(after.map((MediaCollectionItemRow r) => r.sortIndex).toList(), <int>[
      0,
      1,
      2,
    ], reason: 'reorderCollectionItems 应把全表 sortIndex 回写成致密 0..n-1');
  });

  testWidgets('长按原地松手弹菜单（移出 + 打开）；移出真调 removeFromCollection', (
    WidgetTester tester,
  ) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db, onOpenMember: (_, __) {}));
    await tester.pumpAndSettle();

    final Offset center = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k2')),
    );
    final TestGesture gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up(); // 原地松手（未移动）→ 上下文菜单
    await tester.pumpAndSettle();

    // 菜单含移出 + 打开两项。
    expect(find.text(t.collection_remove_member), findsOneWidget);
    expect(find.text(t.collection_open), findsOneWidget);

    await tester.tap(find.text(t.collection_remove_member));
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after = await s.db.getCollectionItems(
      s.col.id,
    );
    expect(
      after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
      <String>['k1', 'k3'],
      reason: '菜单「移出合集」应真把 k2 从合集移除（removeFromCollection）',
    );
  });

  testWidgets('继续阅读随 memberInfoRefresh 重算：读完另一本回来，目标换成最近在读的那本'
      '（4h4uGUck4k）', (WidgetTester tester) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final Map<String, int> lastRead = <String, int>{'k1': 200, 'k2': 100};
    final ChangeNotifier refresh = ChangeNotifier();
    addTearDown(refresh.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: s.db,
            collection: s.col,
            memberCardBuilder: cardBuilder,
            onOpenMember: (String mediaType, String entryKey) {},
            onChanged: () {},
            memberInfoOf: (String mediaType, String entryKey) =>
                CollectionMemberInfo(
                  title: 'T-$entryKey',
                  lastReadAt: lastRead[entryKey],
                ),
            memberInfoRefresh: refresh,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('T-k1'), findsWidgets);

    // 在阅读器里读了 k2（详情页压在阅读器之下，没有任何重建）；回来后调用方通知。
    lastRead['k2'] = 300;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    refresh.notifyListeners();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('T-k2'),
      findsWidgets,
      reason: '继续阅读目标应换成最近在读的 k2',
    );
    expect(find.textContaining('T-k1'), findsNothing);
  });

  testWidgets('菜单「打开」真回调 onOpenMember', (WidgetTester tester) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      wrapPage(
        s.col,
        s.db,
        onOpenMember: (String mediaType, String entryKey) =>
            opened.add('$mediaType|$entryKey'),
      ),
    );
    await tester.pumpAndSettle();

    final Offset center = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k2')),
    );
    final TestGesture gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.collection_open));
    await tester.pumpAndSettle();

    expect(opened, <String>[
      'epub|k2',
    ], reason: '菜单「打开」应回调 onOpenMember(mediaType, entryKey)');
  });

  testWidgets('筛选态拖拽保序合并：隐藏成员留在原下标（不被挤到表尾）', (WidgetTester tester) async {
    useDesktopView(tester);
    final FushiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('C');
    for (final String k in <String>['k1', 'k2', 'k3', 'k4', 'k5']) {
      await db.addToCollection(cid, MediaKind.epub, k);
    }
    // 默认排序是卷号（89481bfd8b2）；拖排只在手动序下开放。
    await db.setPref(
      collectionDetailSortPrefKey(cid),
      kCollectionDetailManualSortValue,
    );
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;

    // 模拟书架标签筛选：k2/k4 被过滤（builder 返回 null → 详情页跳过，不可见）。
    Widget? filteredBuilder(
      String mediaType,
      String entryKey, {
      VoidCallback? onRemoveFromCollection,
    }) {
      if (entryKey == 'k2' || entryKey == 'k4') return null;
      return Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
        alignment: Alignment.center,
        child: Text(entryKey),
      );
    }

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: col,
            memberCardBuilder: filteredBuilder,
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 可见成员：k1, k3, k5。把 k1 拖到 k5 的坑位（可见序 0 → 2）。
    final Offset start = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k1')),
    );
    final Offset target = tester.getCenter(
      find.byKey(const ValueKey<String>('member-k5')),
    );
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after = await db.getCollectionItems(
      col.id,
    );
    final List<String> keys = after
        .map((MediaCollectionItemRow r) => r.entryKey)
        .toList();
    // 可见 [k1,k3,k5] → 拖成 [k3,k5,k1]；保序合并回全表，隐藏 k2/k4 原地不动。
    expect(keys, <String>[
      'k3',
      'k2',
      'k5',
      'k4',
      'k1',
    ], reason: '保序合并：可见槽按新可见序回填，隐藏成员留在原下标');
    expect(keys.indexOf('k2'), 1, reason: '隐藏成员 k2 下标不变（不被挤到表尾）');
    expect(keys.indexOf('k4'), 3, reason: '隐藏成员 k4 下标不变（不被挤到表尾）');
  });

  testWidgets('详情页给成员卡 builder 注入可用的「移出合集」回调（键盘/手柄移出入口）', (
    WidgetTester tester,
  ) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final Map<String, VoidCallback> injected = <String, VoidCallback>{};
    Widget? capturingBuilder(
      String mediaType,
      String entryKey, {
      VoidCallback? onRemoveFromCollection,
    }) {
      expect(
        onRemoveFromCollection,
        isNotNull,
        reason: '详情页必须给每个成员卡注入「移出合集」回调',
      );
      injected['$mediaType|$entryKey'] = onRemoveFromCollection!;
      return Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
      );
    }

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: s.db,
            collection: s.col,
            memberCardBuilder: capturingBuilder,
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(injected.containsKey('epub|k2'), isTrue);
    // 调用注入的回调 = 键盘/手柄用户在长按对话框点「移出合集」的等效路径。
    injected['epub|k2']!();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after = await s.db.getCollectionItems(
      s.col.id,
    );
    expect(
      after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
      <String>['k1', 'k3'],
      reason: '注入的移出回调应真把 k2 从合集移除（removeFromCollection）',
    );
  });

  // ── 「删除合集」连同成员本体一起删（复选框，默认不删=只解链老行为）───────────
  Widget wrapPageWithDelete(
    MediaCollectionRow col,
    FushiDatabase db, {
    Future<void> Function(
      List<MediaCollectionItemRow> members,
      bool deleteLocalFiles,
      bool deleteStatistics,
    )?
    onDeleteMembersMedia,
  }) => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionGridDetailPage(
        database: db,
        collection: col,
        memberCardBuilder: cardBuilder,
        onChanged: () {},
        onDeleteMembersMedia: onDeleteMembersMedia,
      ),
    ),
  );

  testWidgets('删除合集：未注入删本体回调 → 弹窗无复选框，仅解散容器（老行为零变化）', (
    WidgetTester tester,
  ) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db)); // 不传 onDeleteMembersMedia
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    expect(
      find.text(t.delete_collection_also_books),
      findsNothing,
      reason: '无删本体回调时不应出现「同时删除其中的书」复选框',
    );

    await tester.tap(find.text(t.delete_collection).last); // 确认删除
    await tester.pumpAndSettle();
    expect(
      await s.db.getMediaCollectionById(s.col.id),
      isNull,
      reason: '删合集仍只解散容器（deleteMediaCollection）',
    );
  });

  testWidgets('删除合集：复选框默认不勾 → 回调不触发，只解散容器', (WidgetTester tester) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<MediaCollectionItemRow> passed = <MediaCollectionItemRow>[];
    await tester.pumpWidget(
      wrapPageWithDelete(
        s.col,
        s.db,
        onDeleteMembersMedia:
            (
              List<MediaCollectionItemRow> members,
              bool deleteLocalFiles,
              bool deleteStatistics,
            ) async => passed.addAll(members),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    expect(
      find.text(t.delete_collection_also_books),
      findsOneWidget,
      reason: '注入删本体回调后应出现复选框',
    );

    await tester.tap(find.text(t.delete_collection).last); // 不勾直接删
    await tester.pumpAndSettle();
    expect(passed, isEmpty, reason: '未勾选复选框不应删成员本体');
    expect(await s.db.getMediaCollectionById(s.col.id), isNull);
  });

  testWidgets('删除合集：勾选「同时删除其中的书」→ 回调收到全部成员再解散容器', (WidgetTester tester) async {
    useDesktopView(tester);
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<String> passed = <String>[];
    await tester.pumpWidget(
      wrapPageWithDelete(
        s.col,
        s.db,
        onDeleteMembersMedia:
            (
              List<MediaCollectionItemRow> members,
              bool deleteLocalFiles,
              bool deleteStatistics,
            ) async => passed.addAll(
              members.map(
                (MediaCollectionItemRow r) => '${r.mediaType}|${r.entryKey}',
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection_also_books)); // 勾选
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection).last); // 确认删除
    await tester.pumpAndSettle();

    expect(passed, <String>[
      'epub|k1',
      'epub|k2',
      'epub|k3',
    ], reason: '勾选后应把全部成员按 (mediaType,entryKey) 传给删本体回调');
    expect(
      await s.db.getMediaCollectionById(s.col.id),
      isNull,
      reason: '删成员本体后仍解散容器',
    );
  });

  group('长按与库页一致 + 触屏排序模式', () {
    testWidgets('触屏长按到时即弹成员菜单（不等松手），菜单里有「排序」', (WidgetTester tester) async {
      useDesktopView(tester);
      final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
      await tester.pumpWidget(wrapPage(s.col, s.db, onOpenMember: (_, __) {}));
      await tester.pumpAndSettle();

      final TestGesture press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('member-k2'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      // 手指还按着：菜单已经出来。
      expect(find.text(t.collection_remove_member), findsOneWidget);
      expect(find.text(t.library_reorder_action), findsOneWidget);
      await press.up();
      await tester.pumpAndSettle();
      expect(find.text(t.collection_remove_member), findsOneWidget);
    });

    testWidgets('菜单「排序」进入排序模式：触屏按住即拖、落盘，「完成」退出', (WidgetTester tester) async {
      useDesktopView(tester);
      final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
      await tester.pumpWidget(wrapPage(s.col, s.db, onOpenMember: (_, __) {}));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey<String>('member-k1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.library_reorder_action));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('library_reorder_bar')),
        findsOneWidget,
      );

      final Offset start = tester.getCenter(
        find.byKey(const ValueKey<String>('member-k1')),
      );
      final Offset target = tester.getCenter(
        find.byKey(const ValueKey<String>('member-k3')),
      );
      final TestGesture gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        (await s.db.getCollectionItems(
          s.col.id,
        )).map((MediaCollectionItemRow r) => r.entryKey).toList(),
        <String>['k2', 'k3', 'k1'],
      );
      expect(
        find.text(t.collection_remove_member),
        findsNothing,
        reason: '排序模式下长按不弹菜单',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('library_reorder_done')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('library_reorder_bar')),
        findsNothing,
      );
    });

    testWidgets('成员菜单交给调用方构建时，「排序」入口指向本页', (WidgetTester tester) async {
      useDesktopView(tester);
      final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
      VoidCallback? entry;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaCollectionGridDetailPage(
              database: s.db,
              collection: s.col,
              memberCardBuilder: cardBuilder,
              onShowMemberMenu:
                  (
                    String mediaType,
                    String entryKey, {
                    required VoidCallback onRemoveFromCollection,
                  }) async {
                    // 调用方（库页）用自己的 context 弹菜单：同步派发期间读到的
                    // 必须是合集页的入口。
                    entry = libraryReorderEntryOf(
                      tester.element(find.byType(MaterialApp)),
                    );
                  },
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey<String>('member-k2')));
      await tester.pumpAndSettle();
      expect(entry, isNotNull);
      entry!();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('library_reorder_bar')),
        findsOneWidget,
      );
    });
  });

  group('iPad 合集反馈（2026-10-18）', () {
    /// 四卷合集、默认排序（卷号，非手动序 → 走非拖排网格）。
    Future<({FushiDatabase db, MediaCollectionRow col})> seedSeries() async {
      final FushiDatabase db = await openDb();
      final int cid = await db.createMediaCollection('S');
      for (final String k in <String>['k1', 'k2', 'k3', 'k4']) {
        await db.addToCollection(cid, MediaKind.epub, k);
      }
      return (db: db, col: (await db.getMediaCollectionById(cid))!);
    }

    /// 1、2 卷读完（2 最后读），3、4 卷没有进度信息（未下载 / 远端占位 → resolver
    /// 返回 null）——用户截图的数据形状。
    CollectionMemberInfo? seriesInfo(String mediaType, String entryKey) =>
        switch (entryKey) {
          'k1' => const CollectionMemberInfo(
            title: 'T-k1',
            completed: true,
            lastReadAt: 100,
          ),
          'k2' => const CollectionMemberInfo(
            title: 'T-k2',
            completed: true,
            lastReadAt: 200,
          ),
          _ => null,
        };

    Widget seriesPage(
      ({FushiDatabase db, MediaCollectionRow col}) s, {
      List<String>? opened,
      List<String>? menus,
    }) => TranslationProvider(
      child: MaterialApp(
        home: MediaCollectionGridDetailPage(
          database: s.db,
          collection: s.col,
          memberCardBuilder: cardBuilder,
          onOpenMember: (String mediaType, String entryKey) =>
              opened?.add(entryKey),
          onShowMemberMenu:
              (
                String mediaType,
                String entryKey, {
                required VoidCallback onRemoveFromCollection,
              }) async => menus?.add(entryKey),
          onChanged: () {},
          memberInfoOf: seriesInfo,
        ),
      ),
    );

    testWidgets('整体进度分母是全部成员：2 / 4 读完显示 50%（不是 100%）', (
      WidgetTester tester,
    ) async {
      useDesktopView(tester);
      await tester.pumpWidget(seriesPage(await seedSeries()));
      await tester.pumpAndSettle();

      final Text percent = tester.widget<Text>(
        find.byKey(const ValueKey<String>('collection_detail_hero_percent')),
      );
      expect(percent.data, '50%');
    });

    testWidgets('读完第二卷后「继续」指向最后读的第二卷，不回落第一卷', (WidgetTester tester) async {
      useDesktopView(tester);
      await tester.pumpWidget(seriesPage(await seedSeries()));
      await tester.pumpAndSettle();

      final Finder button = find.byKey(
        const ValueKey<String>('collection_detail_continue'),
      );
      expect(
        find.descendant(of: button, matching: find.textContaining('T-k2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: button, matching: find.textContaining('T-k1')),
        findsNothing,
      );
    });

    testWidgets('非拖排网格触屏长按弹库页同一份卡片菜单，不进多选', (WidgetTester tester) async {
      useDesktopView(tester);
      final List<String> opened = <String>[];
      final List<String> menus = <String>[];
      await tester.pumpWidget(
        seriesPage(await seedSeries(), opened: opened, menus: menus),
      );
      await tester.pumpAndSettle();

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('member-k3'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(menus, <String>['k3'], reason: '长按应弹调用方的卡片菜单');

      // 没进多选：再轻点另一张卡是「打开」，不是切换勾选。
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey<String>('member-k4'))),
      );
      await tester.pumpAndSettle();
      expect(opened, <String>['k4']);
    });

    testWidgets('默认卷号排序下也能拖：拖完按显示序落盘并切到手动序', (WidgetTester tester) async {
      // 用户实报「合集不能拖动排序」：默认排序是卷号，此前只有手动序才进拖排网格。
      useDesktopView(tester);
      final ({FushiDatabase db, MediaCollectionRow col}) s = await seedSeries();
      await tester.pumpWidget(seriesPage(s));
      await tester.pumpAndSettle();

      final Offset start = tester.getCenter(
        find.byKey(const ValueKey<String>('member-k1')),
      );
      final Offset target = tester.getCenter(
        find.byKey(const ValueKey<String>('member-k3')),
      );
      final TestGesture gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        (await s.db.getCollectionItems(
          s.col.id,
        )).map((MediaCollectionItemRow r) => r.entryKey).toList(),
        // 卷号序下显示为 k3、k4、T-k1、T-k2（k3 / k4 无标题信息，按键名排在
        // 「T-」前）；k1 拖到 k3 的格子 → 按拖完的**显示序**落盘。
        <String>['k1', 'k3', 'k4', 'k2'],
      );
      expect(
        await s.db.getPref(collectionDetailSortPrefKey(s.col.id)),
        kCollectionDetailManualSortValue,
        reason: '拖过一次即记为手动序，下次进来仍是拖完的顺序',
      );
    });

    testWidgets('成员右键把指针锚点交给库页菜单，长按不给（右键菜单 / 长按抽屉分流）', (
      WidgetTester tester,
    ) async {
      useDesktopView(tester);
      final List<Offset?> anchors = <Offset?>[];
      final ({FushiDatabase db, MediaCollectionRow col}) s = await seedSeries();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaCollectionGridDetailPage(
              database: s.db,
              collection: s.col,
              memberCardBuilder: cardBuilder,
              onOpenMember: (_, __) {},
              onShowMemberMenu:
                  (
                    String mediaType,
                    String entryKey, {
                    required VoidCallback onRemoveFromCollection,
                  }) async => anchors.add(activeContextMenuAnchor),
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Offset k2 = tester.getCenter(
        find.byKey(const ValueKey<String>('member-k2')),
      );
      final TestGesture mouse = await tester.startGesture(
        k2,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();

      final TestGesture touch = await tester.startGesture(k2);
      await tester.pump(const Duration(milliseconds: 600));
      await touch.up();
      await tester.pumpAndSettle();

      expect(anchors, hasLength(2));
      expect(anchors[0], isNotNull, reason: '右键要弹在指针处');
      expect(anchors[1], isNull, reason: '长按走抽屉 / 对话框');
    });

    testWidgets('顶栏不再有与 hero「编辑标签」重复的标签按钮', (WidgetTester tester) async {
      useDesktopView(tester);
      await tester.pumpWidget(seriesPage(await seedSeries()));
      await tester.pumpAndSettle();

      expect(find.byTooltip(t.collection_detail_edit_tags), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('collection_detail_edit_tags')),
        findsOneWidget,
      );
    });
  });
}

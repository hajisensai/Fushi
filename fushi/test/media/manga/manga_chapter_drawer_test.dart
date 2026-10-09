import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/reader/manga_chapter_drawer.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 zRXJNN2Zp-：漫画目录是逆序、太长难翻。阅读器章节抽屉要能切正 / 逆序（记住
/// 选择）、打开即定位到当前章、并有跳到当前 / 顶部 / 底部与快速滚动条。
void main() {
  // 200 话，源按新→旧：下标 0 = 第 200 话。
  final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    for (int n = 200; n >= 1; n--)
      OnlineMangaChapter(
        key: '/c/$n',
        name: 'Rating $n',
        number: n.toDouble(),
        raw: const <String, Object?>{},
      ),
  ];
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/s',
      title: 'Fixture',
      raw: <String, Object?>{},
    ),
    chapters: chapters,
  );

  Finder row(int n) => find.byKey(ValueKey<String>('manga_chapter_/c/$n'));

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<List<bool>> pumpDrawer(
    WidgetTester tester, {
    double width = 312,
    bool newestFirst = true,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    final List<bool> sortChanges = <bool>[];
    tester.view.physicalSize = Size(width, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: MangaChapterDrawer(
            entry: entry,
            states: const <String, MangaChapterStateRow>{},
            currentChapterKey: '/c/20',
            initialNewestFirst: newestFirst,
            onNewestFirstChanged: sortChanges.add,
            onChapterTap: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await settle(tester);
    return sortChanges;
  }

  ScrollPosition drawerScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  bool visible(WidgetTester tester, Finder finder) {
    if (finder.evaluate().isEmpty) return false;
    final Rect rect = tester.getRect(finder);
    return rect.top >= 0 && rect.bottom <= 640;
  }

  testWidgets('打开即滚到当前章（新→旧时第 20 话在表尾附近）', (WidgetTester tester) async {
    await pumpDrawer(tester);
    expect(drawerScroll(tester).pixels, greaterThan(0));
    expect(visible(tester, row(20)), isTrue, reason: '当前章必须在视口里');
    expect(visible(tester, row(200)), isFalse);
  });

  testWidgets('排序初值来自偏好：旧→新时第 1 话在最前，仍定位到当前章', (
    WidgetTester tester,
  ) async {
    await pumpDrawer(tester, newestFirst: false);
    expect(visible(tester, row(20)), isTrue);
    expect(
      tester.getRect(row(20)).top,
      greaterThan(tester.getRect(row(19)).top),
      reason: '旧→新：第 19 话排在第 20 话之前',
    );
  });

  testWidgets('切换排序：列表反转、回写偏好、跟到当前章', (WidgetTester tester) async {
    final List<bool> changes = await pumpDrawer(tester);
    expect(
      tester.getRect(row(20)).top,
      lessThan(tester.getRect(row(19)).top),
      reason: '新→旧：第 20 话在第 19 话之前',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_chapter_drawer_sort')),
    );
    await settle(tester);
    expect(changes, <bool>[false]);
    expect(tester.getRect(row(20)).top, greaterThan(tester.getRect(row(19)).top));
    expect(visible(tester, row(20)), isTrue);
  });

  testWidgets('窄抽屉：排序与跳到当前平铺，顶部 / 底部收进「⋯」并可用', (
    WidgetTester tester,
  ) async {
    await pumpDrawer(tester);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_drawer_sort')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_drawer_jump_current')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_drawer_jump_top')),
      findsNothing,
    );
    final Finder more = find.byKey(
      const ValueKey<String>('fushi_floating_toolbar_overflow'),
    );
    expect(more, findsOneWidget);

    await tester.tap(more);
    await settle(tester);
    await tester.tap(find.text(t.manga_chapter_list_jump_top));
    await settle(tester);
    expect(drawerScroll(tester).pixels, 0);
    expect(visible(tester, row(200)), isTrue);

    await tester.tap(more);
    await settle(tester);
    await tester.tap(find.text(t.manga_chapter_list_jump_bottom));
    await settle(tester);
    expect(
      drawerScroll(tester).pixels,
      drawerScroll(tester).maxScrollExtent,
    );
    expect(visible(tester, row(1)), isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_chapter_drawer_jump_current')),
    );
    await settle(tester);
    expect(visible(tester, row(20)), isTrue);
  });

  testWidgets('宽抽屉：四个动作全部平铺，不画「⋯」', (WidgetTester tester) async {
    await pumpDrawer(tester, width: 600);
    for (final String key in <String>[
      'manga_chapter_drawer_sort',
      'manga_chapter_drawer_jump_current',
      'manga_chapter_drawer_jump_top',
      'manga_chapter_drawer_jump_bottom',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    expect(
      find.byKey(const ValueKey<String>('fushi_floating_toolbar_overflow')),
      findsNothing,
    );
  });

  testWidgets('快速滚动条：移动端补一条可拖动的，桌面端交给 ScrollBehavior', (
    WidgetTester tester,
  ) async {
    await pumpDrawer(tester);
    final Finder bar = find.byKey(
      const ValueKey<String>('manga_chapter_fast_scrollbar'),
    );
    expect(bar, findsOneWidget);
    final Scrollbar scrollbar = tester.widget<Scrollbar>(bar);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.thumbVisibility, isTrue);

    await pumpDrawer(tester, platform: TargetPlatform.windows);
    expect(bar, findsNothing);
  });

  testWidgets('作品页章节区：「跳到当前章节」把当前章滚进视口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey anchor = GlobalKey();
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: MangaChapterList(
              entry: entry,
              states: const <String, MangaChapterStateRow>{},
              newestFirst: true,
              unreadOnly: false,
              currentChapterKey: '/c/20',
              currentChapterAnchorKey: anchor,
              onSortToggled: () {},
              onJumpToCurrent: () => scrollToMangaChapterAnchor(anchor),
              onChapterTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(scroll.offset, 0);
    expect(visible(tester, row(20)), isFalse);
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_chapter_jump_current')),
    );
    await settle(tester);
    expect(visible(tester, row(20)), isTrue);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_sort')),
      findsOneWidget,
    );
  });

  test('没有当前章行时定位什么都不做', () {
    expect(scrollToMangaChapterAnchor(GlobalKey()), isFalse);
  });
}

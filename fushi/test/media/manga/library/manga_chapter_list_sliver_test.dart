import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// #x2m35Gfrjh ANR：作品页把上千话一次性建成 Column，每次重建 / 重排都把每一行的文字
/// 排版一遍，低端机主线程被吃满（ANR 现场主线程在 Skia `ParagraphImpl::layout`）。
/// sliver 形态必须只建视口附近的行，且「跳到当前章节」对还没建出来的行也要能到位。
void main() {
  const int total = 2000;
  final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    for (int n = total; n >= 1; n--)
      OnlineMangaChapter(
        key: '/c/$n',
        name: 'Chapter $n',
        number: n.toDouble(),
        // 行高不一：每三话有一行带副标题，估位不能假设等高。
        scanlator: n % 3 == 0 ? 'Fixture scans' : null,
        raw: const <String, Object?>{},
      ),
  ];
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.fixture',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/s',
      title: 'Fixture',
      raw: <String, Object?>{},
    ),
    chapters: chapters,
  );

  Future<ScrollController> pumpSliver(
    WidgetTester tester, {
    required GlobalKey anchor,
    required GlobalKey rowsKey,
    String? currentChapterKey,
  }) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: <Widget>[
              const SliverToBoxAdapter(child: SizedBox(height: 300)),
              MangaChapterList(
                sliver: true,
                rowsKey: rowsKey,
                entry: entry,
                states: const <String, MangaChapterStateRow>{},
                newestFirst: true,
                unreadOnly: false,
                currentChapterKey: currentChapterKey,
                currentChapterAnchorKey: anchor,
                onChapterTap: (OnlineMangaChapter _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('sliver 形态只建视口附近的行，不把两千话全建出来', (WidgetTester tester) async {
    await pumpSliver(tester, anchor: GlobalKey(), rowsKey: GlobalKey());
    final int built = find
        .byType(MediaDetailItemRow, skipOffstage: false)
        .evaluate()
        .length;
    expect(built, greaterThan(0));
    expect(built, lessThan(100));
    expect(find.text('Chapter 2000'), findsOneWidget);
    expect(find.text('Chapter 1', skipOffstage: false), findsNothing);
  });

  testWidgets('跳到当前章节：还没建出来的远端一话也能滚进视口', (WidgetTester tester) async {
    final GlobalKey anchor = GlobalKey();
    final GlobalKey rowsKey = GlobalKey();
    // 新→旧排列，第 37 话在第 1963 行，远在已建范围之外。
    await pumpSliver(
      tester,
      anchor: anchor,
      rowsKey: rowsKey,
      currentChapterKey: '/c/37',
    );
    expect(anchor.currentContext, isNull);
    final int index = MangaChapterList.visibleChapters(
      chapters: chapters,
      states: const <String, MangaChapterStateRow>{},
      newestFirst: true,
      unreadOnly: false,
    ).indexWhere((OnlineMangaChapter c) => c.key == '/c/37');
    expect(index, total - 37);
    expect(
      scrollToMangaChapter(anchor: anchor, rowsKey: rowsKey, index: index),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(anchor.currentContext, isNotNull);
    expect(find.text('Chapter 37'), findsOneWidget);
    final Rect row = tester.getRect(find.text('Chapter 37'));
    final Rect view = tester.getRect(find.byType(CustomScrollView));
    expect(row.top, greaterThanOrEqualTo(view.top));
    expect(row.bottom, lessThanOrEqualTo(view.bottom));
  });
}

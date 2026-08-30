import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/utils.dart';

/// 章节列表被**两个**界面共用（作品页正文 + 阅读器里的章节弹层）。两处对
/// 「已读怎么显示、当前章怎么高亮、排序默认哪个方向」的答案必须一致，所以这些
/// 语义钉在组件上而不是各自的宿主页面上。
void main() {
  const OnlineMangaChapter newest = OnlineMangaChapter(
    key: '/c/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{},
  );
  const OnlineMangaChapter middle = OnlineMangaChapter(
    key: '/c/2',
    name: 'Chapter 2',
    number: 2,
    scanlator: 'Fixture scans',
    raw: <String, Object?>{},
  );
  const OnlineMangaChapter oldest = OnlineMangaChapter(
    key: '/c/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{},
  );

  // 源按新→旧返回，列表 0 是最新一话。
  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    newest,
    middle,
    oldest,
  ];

  OnlineMangaLibraryEntry entryWith(List<OnlineMangaChapter> items) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: const OnlineMangaSeries(
          key: '/s',
          title: 'Fixture',
          raw: <String, Object?>{},
        ),
        chapters: items,
      );

  Future<void> pumpList(
    WidgetTester tester, {
    required OnlineMangaLibraryEntry? entry,
    Map<String, MangaChapterStateRow> states =
        const <String, MangaChapterStateRow>{},
    bool newestFirst = true,
    bool unreadOnly = false,
    String? currentChapterKey,
    void Function(OnlineMangaChapter)? onChapterTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MangaChapterList(
              entry: entry,
              states: states,
              newestFirst: newestFirst,
              unreadOnly: unreadOnly,
              currentChapterKey: currentChapterKey,
              onChapterTap: onChapterTap ?? (OnlineMangaChapter _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 按屏幕纵坐标读出当前可见的章节标题顺序。
  List<String> visibleTitles(WidgetTester tester) {
    final List<({double dy, String text})> found = <({double dy, String text})>[];
    for (final Element element in find.byType(Text).evaluate()) {
      final Text widget = element.widget as Text;
      final String? data = widget.data;
      if (data == null || !data.startsWith('Chapter ')) continue;
      found.add((dy: tester.getTopLeft(find.byWidget(widget)).dy, text: data));
    }
    found.sort((({double dy, String text}) a, ({double dy, String text}) b) =>
        a.dy.compareTo(b.dy));
    return found.map((({double dy, String text}) e) => e.text).toList();
  }

  testWidgets('默认保持源顺序（新→旧）；翻转后第 1 话在前', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(chapters));
    expect(visibleTitles(tester), <String>['Chapter 3', 'Chapter 2', 'Chapter 1']);

    await pumpList(tester, entry: entryWith(chapters), newestFirst: false);
    expect(
      visibleTitles(tester),
      <String>['Chapter 1', 'Chapter 2', 'Chapter 3'],
      reason: '「最早在前」必须真的翻转，而不是只改按钮文案',
    );
  });

  testWidgets('已读 / 读了一半 / 未读三态各有自己的图标', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
        '/c/2': _state(chapterKey: '/c/2', lastPage: 5),
      },
    );

    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget,
        reason: 'readAt != null = 已读');
    expect(find.byIcon(Icons.incomplete_circle), findsOneWidget,
        reason: '有状态行、没读完、且真的翻过页 = 读了一半');
    expect(find.byIcon(Icons.circle_outlined), findsOneWidget,
        reason: '没有状态行 = 未读');
  });

  testWidgets('lastPage 为 0 不算「读了一半」', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(<OnlineMangaChapter>[oldest]),
      states: <String, MangaChapterStateRow>{
        '/c/1': _state(chapterKey: '/c/1'),
      },
    );
    expect(
      find.byIcon(Icons.incomplete_circle),
      findsNothing,
      reason: '开了一下就退出不该显示成「读到第 1 页」，那是误导',
    );
    expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
  });

  testWidgets('当前章有播放角标', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
    );
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('只看未读会滤掉已读的章', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
      },
    );
    expect(visibleTitles(tester), <String>['Chapter 2', 'Chapter 1']);
  });

  testWidgets('全读完 + 只看未读 → 提示「都读完了」，而不是空白', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      states: <String, MangaChapterStateRow>{
        for (final OnlineMangaChapter chapter in chapters)
          chapter.key: _state(chapterKey: chapter.key, readAt: 1),
      },
    );
    expect(visibleTitles(tester), isEmpty);
    expect(find.text(t.manga_series_all_read), findsOneWidget);
  });

  testWidgets('没有章节时给出明确提示', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(const <OnlineMangaChapter>[]));
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
  });

  testWidgets('entry 为 null（还没加载出来）不崩，走空态', (WidgetTester tester) async {
    await pumpList(tester, entry: null);
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
  });

  testWidgets('副标题带上翻译组与章内进度', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(<OnlineMangaChapter>[middle]),
      states: <String, MangaChapterStateRow>{
        '/c/2': _state(chapterKey: '/c/2', lastPage: 7, pageCount: 24),
      },
    );
    // lastPage 是 0-based，显示要 +1。
    expect(
      find.textContaining('Fixture scans'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        t.manga_series_read_progress(page: '8', total: '24'),
      ),
      findsOneWidget,
      reason: 'lastPage 是 0-based，显示必须 +1，否则用户看到的页码永远少一页',
    );
  });

  testWidgets('点某一行回调的是那一行对应的章', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await pumpList(
      tester,
      entry: entryWith(chapters),
      onChapterTap: (OnlineMangaChapter chapter) => tapped.add(chapter.key),
    );
    await tester.tap(find.text('Chapter 2'));
    await tester.pump();
    expect(tapped, <String>['/c/2']);
  });
}

MangaChapterStateRow _state({
  required String chapterKey,
  int lastPage = 0,
  int? pageCount,
  int? readAt,
  int updatedAt = 1,
}) =>
    MangaChapterStateRow(
      bookUid: 'uid',
      chapterKey: chapterKey,
      lastPage: lastPage,
      lastFraction: -1,
      pageCount: pageCount,
      readAt: readAt,
      updatedAt: updatedAt,
    );

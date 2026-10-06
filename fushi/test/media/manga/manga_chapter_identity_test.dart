import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

void main() {
  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: '/chapter/2',
      name: 'Chapter 2',
      raw: <String, Object?>{},
    ),
    OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      raw: <String, Object?>{},
    ),
  ];
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.identity',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/series',
      title: 'Chapter identity',
      raw: <String, Object?>{},
    ),
    chapters: chapters,
  );

  Future<void> pumpChapters(
    WidgetTester tester, {
    bool newestFirst = true,
    Set<String> downloaded = const <String>{},
    void Function(OnlineMangaChapter)? onChapterTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MangaChapterList(
              entry: entry,
              states: const {},
              newestFirst: newestFirst,
              unreadOnly: false,
              downloadedChapterKeys: downloaded,
              onChapterTap: onChapterTap ?? (OnlineMangaChapter _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('相同下载状态的章节能同时显示，状态更新后仍保留每章身份', (WidgetTester tester) async {
    await pumpChapters(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('manga_chapter_download_notDownloaded'),
      ),
      findsNWidgets(2),
    );
    final Finder first = find.byKey(
      const ValueKey<String>('manga_chapter_/chapter/1'),
    );
    final State<FushiStaggeredEntrance> before = tester.state(first);

    await pumpChapters(
      tester,
      downloaded: <String>{'/chapter/1', '/chapter/2'},
    );
    expect(tester.takeException(), isNull);
    expect(tester.state(first), same(before));
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsNWidgets(2),
    );
  });

  testWidgets('同状态章节重排保留各自状态，点击仍打开对应章节', (WidgetTester tester) async {
    String? opened;
    void openChapter(OnlineMangaChapter chapter) => opened = chapter.key;

    await pumpChapters(tester, onChapterTap: openChapter);
    expect(tester.takeException(), isNull);
    final Finder first = find.byKey(
      const ValueKey<String>('manga_chapter_/chapter/1'),
    );
    final Finder second = find.byKey(
      const ValueKey<String>('manga_chapter_/chapter/2'),
    );
    final State<FushiStaggeredEntrance> firstState = tester.state(first);
    final State<FushiStaggeredEntrance> secondState = tester.state(second);
    expect(tester.getTopLeft(second).dy, lessThan(tester.getTopLeft(first).dy));

    await pumpChapters(tester, newestFirst: false, onChapterTap: openChapter);
    expect(tester.takeException(), isNull);
    expect(tester.state(first), same(firstState));
    expect(tester.state(second), same(secondState));
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
    await tester.tap(find.text('Chapter 1'));
    expect(opened, '/chapter/1');
    await tester.tap(find.text('Chapter 2'));
    expect(opened, '/chapter/2');
  });
}

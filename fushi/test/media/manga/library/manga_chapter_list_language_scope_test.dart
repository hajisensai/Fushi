import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/utils.dart';

/// BUG-2510：源按语言取章时，空章节列表要说清「该源只收录 X 语言」并给出同扩展
/// 其它语言源的出路；没有语言范围（Aidoku / 互联）时空态文案不变。
void main() {
  const OnlineMangaLibraryEntry empty = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.mangadex',
    sourceId: '1',
    series: OnlineMangaSeries(
      key: '/manga/x',
      title: 'Fixture',
      raw: <String, Object?>{},
    ),
    chapters: <OnlineMangaChapter>[],
  );

  const OnlineMangaSiblingSource en = OnlineMangaSiblingSource(
    sourceId: '2',
    name: 'MangaDex (EN)',
    language: 'en',
  );
  const OnlineMangaSiblingSource ko = OnlineMangaSiblingSource(
    sourceId: '3',
    name: 'MangaDex (KO)',
    language: 'ko',
  );

  Future<void> pumpList(
    WidgetTester tester, {
    OnlineMangaSourceLanguageScope? scope,
    void Function(OnlineMangaSiblingSource)? onSiblingSourceTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MangaChapterList(
              entry: empty,
              states: const <String, MangaChapterStateRow>{},
              newestFirst: true,
              unreadOnly: false,
              onChapterTap: (OnlineMangaChapter _) {},
              languageScope: scope,
              onSiblingSourceTap: onSiblingSourceTap,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('没有语言范围：空态只有「还没有章节」，不出现语言解释', (WidgetTester tester) async {
    await pumpList(tester);
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_language_scope')),
      findsNothing,
    );
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('有语言范围：解释该源只收录该语言，并按 sibling 列出「试试 X」', (
    WidgetTester tester,
  ) async {
    await pumpList(
      tester,
      scope: const OnlineMangaSourceLanguageScope(
        language: 'ja',
        siblings: <OnlineMangaSiblingSource>[en, ko],
      ),
    );
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
    expect(
      find.text(t.manga_series_no_chapters_in_language(language: 'JA')),
      findsOneWidget,
    );
    expect(
      find.text(t.manga_series_try_sibling_language(language: 'EN')),
      findsOneWidget,
    );
    expect(
      find.text(t.manga_series_try_sibling_language(language: 'KO')),
      findsOneWidget,
    );
  });

  testWidgets('没有 sibling：只解释，不出 chip', (WidgetTester tester) async {
    await pumpList(
      tester,
      scope: const OnlineMangaSourceLanguageScope(
        language: 'ja',
        siblings: <OnlineMangaSiblingSource>[],
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_language_scope')),
      findsOneWidget,
    );
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('点 chip 回调对应的 sibling', (WidgetTester tester) async {
    final List<OnlineMangaSiblingSource> tapped = <OnlineMangaSiblingSource>[];
    await pumpList(
      tester,
      scope: const OnlineMangaSourceLanguageScope(
        language: 'ja',
        siblings: <OnlineMangaSiblingSource>[en, ko],
      ),
      onSiblingSourceTap: tapped.add,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_series_sibling_3')),
    );
    await tester.pump();
    expect(tapped.map((OnlineMangaSiblingSource s) => s.sourceId), <String>[
      '3',
    ]);
  });
}

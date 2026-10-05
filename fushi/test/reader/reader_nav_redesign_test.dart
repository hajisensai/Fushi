import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/reader/reader_navigation_widgets.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/utils.dart';

/// 2026-10 导航侧板 M3E 重做：目录层级（parent 链 / 旧 depth 口径）、当前章
/// 高亮、搜索命中高亮、分段页签与 TabController 同步。
Widget _host(Widget child, {bool apple = false}) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[
      FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
    ],
  ),
  home: Scaffold(body: child),
);

void main() {
  group('readerTocHierarchy', () {
    test('真实 EPUB 压平后只有 parent：按 parent 链算层级与父项', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 0, label: '表紙'),
        TtuTocEntry(index: 1, label: '第一章'),
        TtuTocEntry(index: 2, label: '第一話', parent: '第一章'),
        TtuTocEntry(index: 3, label: '一', parent: '第一話'),
        TtuTocEntry(index: 4, label: '第二話', parent: '第一章'),
        TtuTocEntry(index: 5, label: '第二章'),
      ];
      final ({List<int> levels, List<int> parents}) tree = readerTocHierarchy(
        toc,
      );
      expect(tree.levels, <int>[0, 0, 1, 2, 1, 0]);
      expect(tree.parents, <int>[-1, -1, 1, 2, 1, -1]);
    });

    test('父项不在目录里（href 解析不到被跳过）时按顶层处理，不会被折叠藏掉', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 0, label: '第一話', parent: '本巻（未解析）'),
        TtuTocEntry(index: 1, label: '第二話', parent: '本巻（未解析）'),
      ];
      final ({List<int> levels, List<int> parents}) tree = readerTocHierarchy(
        toc,
      );
      expect(tree.levels, <int>[0, 0]);
      expect(tree.parents, <int>[-1, -1]);
    });

    test('旧口径 depth >= 2 仍是子项', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 0, label: 'A'),
        TtuTocEntry(index: 1, label: 'A-1', depth: 2, parent: 'A'),
        TtuTocEntry(index: 2, label: 'B'),
      ];
      final ({List<int> levels, List<int> parents}) tree = readerTocHierarchy(
        toc,
      );
      expect(tree.levels, <int>[0, 1, 0]);
      expect(tree.parents, <int>[-1, 0, -1]);
    });
  });

  group('ReaderTocRow 当前章高亮', () {
    for (final bool apple in <bool>[false, true]) {
      testWidgets('当前章有强调色块 + 形状图标，其余行没有（apple=$apple）', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _host(
            Column(
              children: <Widget>[
                ReaderTocRow(
                  title: '第三話',
                  state: ReaderTocRowState.read,
                  onTap: () {},
                ),
                ReaderTocRow(
                  title: '第四話',
                  state: ReaderTocRowState.current,
                  onTap: () {},
                ),
                ReaderTocRow(title: '第五話', onTap: () {}),
              ],
            ),
            apple: apple,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey<String>('reader_toc_current_fill')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey<String>('reader_toc_current_fill')),
            matching: find.text('第四話'),
          ),
          findsOneWidget,
          reason: '色块必须落在当前章那一行',
        );
        expect(find.byType(ReaderShapeBadge), findsOneWidget);
        final Text current = tester.widget<Text>(find.text('第四話'));
        expect(current.style?.fontWeight, FontWeight.w700);
      });
    }

    testWidgets('已读章节淡化（onSurfaceVariant），未读用 onSurface', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            children: <Widget>[
              ReaderTocRow(title: '已读', state: ReaderTocRowState.read),
              ReaderTocRow(title: '未读'),
            ],
          ),
        ),
      );
      final ColorScheme cs = Theme.of(
        tester.element(find.text('已读')),
      ).colorScheme;
      expect(
        tester.widget<Text>(find.text('已读')).style?.color,
        cs.onSurfaceVariant,
      );
      expect(tester.widget<Text>(find.text('未读')).style?.color, cs.onSurface);
    });

    testWidgets('章节名最多 4 行（长章节名在手机上要能读全）', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const ReaderTocRow(title: '長い章題')));
      expect(
        tester.widget<Text>(find.text('長い章題')).maxLines,
        ReaderTocRow.titleMaxLines,
      );
      expect(ReaderTocRow.titleMaxLines, greaterThan(2));
    });
  });

  group('搜索命中高亮', () {
    testWidgets('M3E：命中段 tertiaryContainer 底 + 加粗，前后文原样', (
      WidgetTester tester,
    ) async {
      late TextSpan span;
      late ColorScheme cs;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) {
              cs = Theme.of(context).colorScheme;
              span = readerHighlightSpans(
                context,
                text: 'シルフィは友達だった。',
                start: 5,
                end: 7,
              );
              return ReaderQuoteCard(
                overline: '第四話「友達」',
                quote: Text.rich(span),
                onTap: () {},
              );
            },
          ),
        ),
      );
      final List<InlineSpan> parts = span.children!;
      expect(parts, hasLength(3));
      expect((parts[0] as TextSpan).text, 'シルフィは');
      final TextSpan hit = parts[1] as TextSpan;
      expect(hit.text, '友達');
      expect(hit.style?.backgroundColor, cs.tertiaryContainer);
      expect(hit.style?.fontWeight, FontWeight.w700);
      expect((parts[2] as TextSpan).text, 'だった。');
      expect(find.text('第四話「友達」'), findsOneWidget);
    });

    testWidgets('Apple：命中段用强调色淡底', (WidgetTester tester) async {
      late TextSpan span;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) {
              span = readerHighlightSpans(
                context,
                text: 'abcdef',
                start: 2,
                end: 4,
              );
              return const SizedBox();
            },
          ),
          apple: true,
        ),
      );
      final TextSpan hit = span.children![1] as TextSpan;
      expect(hit.text, 'cd');
      expect(hit.style?.backgroundColor, isNotNull);
      expect(hit.style?.backgroundColor!.a, lessThan(0.5));
    });

    testWidgets('引文卡整卡可点', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(ReaderQuoteCard(quote: const Text('引用'), onTap: () => taps++)),
      );
      await tester.tap(find.text('引用'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  testWidgets('分段页签与 TabController 双向同步', (WidgetTester tester) async {
    final TabController controller = TabController(
      length: 3,
      vsync: const TestVSync(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        ReaderPanelTabs(
          controller: controller,
          tabs: const <ReaderPanelTab>[
            ReaderPanelTab(label: '目录', icon: Icons.toc_rounded),
            ReaderPanelTab(label: '收藏', icon: Icons.star_rounded),
            ReaderPanelTab(label: '搜索', icon: Icons.search_rounded),
          ],
        ),
      ),
    );
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(controller.index, 2);

    controller.index = 1;
    await tester.pumpAndSettle();
    final FushiSegmentedButton<int> group = tester
        .widget<FushiSegmentedButton<int>>(
          find.byType(FushiSegmentedButton<int>),
        );
    expect(group.selected, <int>{1});
  });

  testWidgets('进度 hero：Display 级百分比 + 波浪条；矮面板收成单行', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ReaderNavProgressHero(
          fraction: 0.286,
          chapter: '第四話「友達」',
          fallbackTitle: '阅读进度',
          caption: '全书',
          readouts: <String>['第 9 / 13 章'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('reader_nav_progress_percent')),
      findsOneWidget,
    );
    expect(find.textContaining('28.6'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('reader_nav_progress_bar')),
      findsOneWidget,
    );
    expect(find.text('第 9 / 13 章'), findsOneWidget);
    final double fullHeight = tester
        .getSize(find.byKey(const ValueKey<String>('reader_nav_progress_card')))
        .height;

    await tester.pumpWidget(
      _host(
        const ReaderNavProgressHero(
          fraction: 0.286,
          chapter: '第四話「友達」',
          fallbackTitle: '阅读进度',
          readouts: <String>['第 9 / 13 章'],
          compact: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 9 / 13 章'), findsNothing, reason: '单行档不放读数');
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('reader_nav_progress_card')),
          )
          .height,
      lessThan(fullHeight),
    );
  });
}

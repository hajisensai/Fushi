import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_entry.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 顶栏「问 AI」（spec `2026-10-26-ai-operations-agent-design.md` D4 ③）：
///
/// * 库页（书架 / 视频库 / 游戏库）页头用 [aiAgentAskHeaderActions]：宽度够时平铺，
///   宽度不够时**最先**收进「⋯」（优先级低于页头里所有既有动作），AI 模块关着时
///   不出；
/// * 漫画阅读器顶栏把它排在动作表最后：[MangaReaderTopBar] 从尾部收，所以同样最先
///   收起。
void main() {
  const ModuleVisibility aiOn = ModuleVisibility(<ModuleId>{ModuleId.ai});
  const ModuleVisibility aiOff = ModuleVisibility(<ModuleId>{});

  // 与视频库页头同档的既有动作（最低的「刷新」是 5）。
  const List<IconData> others = <IconData>[
    Icons.looks_one_outlined,
    Icons.looks_two_outlined,
    Icons.looks_3_outlined,
    Icons.looks_4_outlined,
  ];

  Widget libraryHost({
    required double width,
    required ModuleVisibility visibility,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Builder(
              builder: (BuildContext context) => FushiPageHeader(
                title: 'Books',
                actions: <Widget>[
                  for (int i = 0; i < others.length; i++)
                    FushiIconButton(
                      icon: others[i],
                      tooltip: 'action $i',
                      overflowPriority: <int>[50, 40, 15, 5][i],
                      onTap: () {},
                    ),
                  ...aiAgentAskHeaderActions(
                    context,
                    visibility: visibility,
                    page: 'books',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool hasOverflow() =>
      find.byKey(kFushiHeaderOverflowMenuKey).evaluate().isNotEmpty;
  bool askVisible() => find.byKey(kAiAgentAskKey).evaluate().isNotEmpty;
  bool highPriorityVisible() => others
      .take(others.length - 1)
      .every((IconData icon) => find.byIcon(icon).evaluate().isNotEmpty);
  int visibleOthers() => <IconData>[
    for (final IconData icon in others)
      if (find.byIcon(icon).evaluate().isNotEmpty) icon,
  ].length;

  testWidgets('库页：宽度够时「问 AI」平铺、不画 ⋯', (WidgetTester tester) async {
    await tester.pumpWidget(libraryHost(width: 1200, visibility: aiOn));
    await tester.pumpAndSettle();
    expect(askVisible(), isTrue);
    expect(hasOverflow(), isFalse);
    expect(visibleOthers(), others.length);
  });

  testWidgets('库页：宽度刚好不够时第一个收进 ⋯ 的就是「问 AI」', (WidgetTester tester) async {
    // 从宽往窄扫，找到第一次出现 ⋯ 的宽度：那时只收起了一颗，必须是「问 AI」。
    double width = 1200;
    while (width > 200) {
      await tester.pumpWidget(libraryHost(width: width, visibility: aiOn));
      await tester.pumpAndSettle();
      if (hasOverflow()) break;
      width -= 8;
    }
    expect(hasOverflow(), isTrue, reason: '扫到 200 都没收起，测试宿主太宽');
    expect(askVisible(), isFalse, reason: '「问 AI」优先级最低，应最先收进 ⋯');
    // 「⋯」自己要占一格，所以收起「问 AI」时最多再带走优先级次低的那颗；
    // 更高优先级的动作都还平铺。
    expect(highPriorityVisible(), isTrue, reason: '高优先级动作此时都还平铺');

    // 收起后在 ⋯ 菜单里能找到它。
    await tester.tap(find.byKey(kFushiHeaderOverflowMenuKey));
    await tester.pumpAndSettle();
    expect(find.text(aiAgentAskLabel), findsOneWidget);
  });

  testWidgets('库页：AI 模块关着时不出「问 AI」', (WidgetTester tester) async {
    await tester.pumpWidget(libraryHost(width: 1200, visibility: aiOff));
    await tester.pumpAndSettle();
    expect(askVisible(), isFalse);
    expect(hasOverflow(), isFalse);
    expect(visibleOthers(), others.length);
  });

  group('漫画阅读器顶栏', () {
    Widget mangaHost(double width) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: MangaReaderTopBar(
              title: 'Chapter 1',
              onBack: () {},
              backTooltip: 'Back',
              floating: true,
              actions: <MangaChromeAction>[
                for (int i = 0; i < others.length; i++)
                  MangaChromeAction(
                    icon: others[i],
                    label: 'action $i',
                    slot: MangaChromeSlot.top,
                    onPressed: () {},
                  ),
                // 与 manga_fushi_page 的 `_buildTopChrome` 同一摆法：排最后。
                MangaChromeAction(
                  key: kAiAgentAskKey,
                  icon: kAiAgentAskIcon,
                  label: aiAgentAskLabel,
                  slot: MangaChromeSlot.top,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    bool mangaOverflow() => find
        .byKey(const ValueKey<String>('manga_chrome_overflow'))
        .evaluate()
        .isNotEmpty;

    testWidgets('宽时平铺，刚好不够时最先收起「问 AI」', (WidgetTester tester) async {
      await tester.pumpWidget(mangaHost(1200));
      await tester.pumpAndSettle();
      expect(askVisible(), isTrue);

      double width = 1200;
      bool folded = false;
      while (width > 200) {
        await tester.pumpWidget(mangaHost(width));
        await tester.pumpAndSettle();
        if (!askVisible()) {
          folded = true;
          break;
        }
        width -= 8;
      }
      expect(folded, isTrue);
      // 「⋯」自己要占一格，所以收起「问 AI」时最多再带走优先级次低的那颗；
      // 更高优先级的动作都还平铺。
      expect(highPriorityVisible(), isTrue, reason: '高优先级动作此时都还平铺');
      expect(mangaOverflow(), isTrue, reason: '收起的「问 AI」在 ⋯ 里');
    });
  });
}

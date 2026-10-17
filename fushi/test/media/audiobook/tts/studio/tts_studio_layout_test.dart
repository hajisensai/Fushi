import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_layout.dart';
import 'package:material_ui/material_ui.dart';

/// 制作台版面骨架：宽屏双栏（步骤侧栏 + 内容）、窄屏步骤选择片 + 底部固定条。
void main() {
  const List<TtsStudioStepEntry> steps = <TtsStudioStepEntry>[
    TtsStudioStepEntry(
      step: TtsStudioStep.content,
      icon: Icons.list,
      title: 'Content',
      summary: '12/20 · Voice A',
    ),
    TtsStudioStepEntry(
      step: TtsStudioStep.cast,
      icon: Icons.person,
      title: 'Cast',
      summary: 'To review (5)',
      attention: true,
    ),
    TtsStudioStepEntry(
      step: TtsStudioStep.generate,
      icon: Icons.tune,
      title: 'Generate',
      summary: 'Standard',
    ),
    TtsStudioStepEntry(
      step: TtsStudioStep.result,
      icon: Icons.audiotrack,
      title: 'Result',
    ),
  ];

  Future<List<TtsStudioStep>> pumpLayout(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<TtsStudioStep> picked = <TtsStudioStep>[];
    TtsStudioStep selected = TtsStudioStep.content;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                TtsStudioLayout(
                  steps: steps,
                  selected: selected,
                  onSelect: (TtsStudioStep step) {
                    picked.add(step);
                    setState(() => selected = step);
                  },
                  body: ListView.builder(
                    key: ValueKey<String>('body-${selected.name}'),
                    itemCount: 200,
                    itemBuilder: (BuildContext context, int i) =>
                        Text('${selected.name} row $i'),
                  ),
                  footerBuilder: (BuildContext context, bool wide) =>
                      FilledButton(
                        key: ValueKey<String>(
                          'start-${wide ? 'wide' : 'narrow'}',
                        ),
                        onPressed: () {},
                        child: const Text('Start'),
                      ),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picked;
  }

  // 设置页壳以 bodyConsumesTopPadding 把页头让位交给正文：骨架顶上的固定步骤
  // 导航（选择片 / 侧栏）整体让开一次，正文滚动视图不再重复让位。
  for (final Size size in <Size>[const Size(400, 800), const Size(1280, 800)]) {
    testWidgets('${size.width.toInt()}: consumes the shell top inset once', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      double? bodyTop;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: const EdgeInsets.only(top: 120),
            ),
            child: Scaffold(
              body: TtsStudioLayout(
                steps: steps,
                selected: TtsStudioStep.content,
                onSelect: (TtsStudioStep _) {},
                body: Builder(
                  builder: (BuildContext context) {
                    bodyTop = MediaQuery.paddingOf(context).top;
                    return const SizedBox.expand();
                  },
                ),
                footerBuilder: (BuildContext context, bool wide) =>
                    const SizedBox(height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder nav = find.byKey(
        ValueKey<String>(
          size.width >= 840 ? 'tts-studio-sidebar' : 'tts-studio-step-tabs',
        ),
      );
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(120));
      expect(bodyTop, 0);
    });
  }

  test('breakpoint follows the MD3 expanded width class', () {
    expect(ttsStudioUsesWideLayout(839), isFalse);
    expect(ttsStudioUsesWideLayout(840), isTrue);
    expect(ttsStudioUsesWideLayout(1280), isTrue);
  });

  testWidgets('1280x800: sidebar with steps + summaries, footer in sidebar', (
    WidgetTester tester,
  ) async {
    final List<TtsStudioStep> picked = await pumpLayout(
      tester,
      const Size(1280, 800),
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-layout-wide')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-layout-narrow')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-step-tabs')),
      findsNothing,
    );

    final Finder sidebar = find.byKey(
      const ValueKey<String>('tts-studio-sidebar'),
    );
    expect(tester.getSize(sidebar).width, kTtsStudioSidebarWidth);
    // 四步都在侧栏，带一行摘要；主按钮在侧栏底部。
    for (final String title in <String>[
      '1. Content',
      '2. Cast',
      '3. Generate',
      '4. Result',
    ]) {
      expect(
        find.descendant(of: sidebar, matching: find.text(title)),
        findsOne,
      );
    }
    expect(find.text('12/20 · Voice A'), findsOne);
    expect(find.text('To review (5)'), findsOne);
    expect(
      find.descendant(
        of: sidebar,
        matching: find.byKey(const ValueKey<String>('start-wide')),
      ),
      findsOne,
    );
    // 内容在侧栏右侧，独立滚动（懒构建：只建出可见的几行）。
    expect(
      tester.getTopLeft(find.text('content row 0')).dx,
      greaterThanOrEqualTo(tester.getTopRight(sidebar).dx),
    );
    expect(find.text('content row 199'), findsNothing);

    // 焦点导航：Tab 落到侧栏步骤项，Enter 切换步骤。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, <TtsStudioStep>[TtsStudioStep.cast]);
    expect(find.text('cast row 0'), findsOne);
    expect(find.text('content row 0'), findsNothing);
  });

  testWidgets('400x800: step chips on top, bottom bar with the footer', (
    WidgetTester tester,
  ) async {
    final List<TtsStudioStep> picked = await pumpLayout(
      tester,
      const Size(400, 800),
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-layout-narrow')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-layout-wide')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-sidebar')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('tts-studio-step-tabs')),
      findsOne,
    );

    final Finder bar = find.byKey(
      const ValueKey<String>('tts-studio-bottom-bar'),
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey<String>('start-narrow')),
      ),
      findsOne,
    );
    // 底栏贴底，内容夹在选择片与底栏之间。
    expect(tester.getBottomLeft(bar).dy, 800);
    expect(
      tester.getTopLeft(find.text('content row 0')).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey<String>('tts-studio-step-tabs')),
            )
            .dy,
      ),
    );

    final Finder resultChip = find.byKey(
      const ValueKey<String>('tts-studio-step-result'),
    );
    // 选择片横向滚动：最后一项先滚进视口。
    await tester.ensureVisible(resultChip);
    await tester.pumpAndSettle();
    await tester.tap(resultChip);
    await tester.pumpAndSettle();
    expect(picked, <TtsStudioStep>[TtsStudioStep.result]);
    expect(find.text('result row 0'), findsOne);
  });
}

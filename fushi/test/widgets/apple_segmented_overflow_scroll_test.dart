import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// BUG-3631：iPhone（402 pt 宽）上 Apple 设计系统的分段条放不下时右侧被裁、
/// 横拖也滚不动——[FushiAppleSegmentedControl] 的滑块横拖识别器在手势竞技里
/// 先于外层横向滚动区过 slop，整条分段条上的横拖全被它吃掉。
///
/// 修复后：控件比横向滚动视口宽时，只有从选中滑块起手的横拖才拖滑块，其余横拖
/// 交给滚动区；放得下 / 不在横向滚动区时手势分工不变。宿主形态照词典页
/// `_buildCategorySelector`（HorizontalDragScrollable + 横向 SingleChildScrollView
/// + minWidth 撑满）。
void main() {
  const List<String> labels = <String>[
    'Term 5',
    'Kanji dictionaries 1',
    'Frequency 2',
    'Pitch accent 0',
  ];

  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: glass,
  );

  Future<void> pumpStrip(
    WidgetTester tester, {
    required bool glass,
    required Size logicalSize,
    required ValueGetter<int> selected,
    required ValueChanged<int> onSelected,
    bool scrollHost = true,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = logicalSize * 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass),
        home: FushiGlassScope(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  final Widget button = adaptiveSegmentedButton<int>(
                    context: context,
                    segments: <ButtonSegment<int>>[
                      for (int i = 0; i < labels.length; i++)
                        ButtonSegment<int>(value: i, label: Text(labels[i])),
                    ],
                    selected: <int>{selected()},
                    onSelectionChanged: (Set<int> next) {
                      if (next.isEmpty) return;
                      setState(() => onSelected(next.first));
                    },
                  );
                  if (!scrollHost) return Center(child: button);
                  return Align(
                    alignment: Alignment.topCenter,
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        return HorizontalDragScrollable(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(minWidth: c.maxWidth),
                              child: button,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ScrollPosition stripPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  const Size iPhone = Size(402, 874);

  testWidgets('Apple：iPhone 宽度放不下时横拖分段条会滚动，末段可滚到并点选（BUG-3631）', (
    WidgetTester tester,
  ) async {
    int selected = 2;
    await pumpStrip(
      tester,
      glass: true,
      logicalSize: iPhone,
      selected: () => selected,
      onSelected: (int v) => selected = v,
    );
    expect(find.byType(FushiAppleSegmentedControl), findsOneWidget);
    final ScrollPosition position = stripPosition(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: '长英文段名在 402 pt 宽下必须溢出（否则本测试没测到裁切场景）',
    );
    final double viewportRight = tester
        .getRect(find.byType(SingleChildScrollView))
        .right;
    expect(
      tester.getRect(find.text(labels.last)).left,
      greaterThan(viewportRight),
      reason: '起始时末段在视口外',
    );

    // 从首段（非选中滑块）起手向左横拖：应滚动分段条，而不是拖滑块改选中。
    await tester.dragFrom(
      tester.getCenter(find.text(labels.first)),
      const Offset(-3000, 0),
    );
    await tester.pumpAndSettle();
    expect(selected, 2, reason: '滚动不应改动选中段');
    expect(position.pixels, position.maxScrollExtent);

    final Rect last = tester.getRect(find.text(labels.last));
    expect(last.right, lessThanOrEqualTo(viewportRight + 0.5));
    await tester.tap(find.text(labels.last));
    await tester.pumpAndSettle();
    expect(selected, 3, reason: '滚到后末段可点选');
  });

  testWidgets('Apple：溢出时从选中滑块起手的横拖仍拖动滑块（iOS 语义）', (WidgetTester tester) async {
    int selected = 0;
    await pumpStrip(
      tester,
      glass: true,
      logicalSize: iPhone,
      selected: () => selected,
      onSelected: (int v) => selected = v,
    );
    final ScrollPosition position = stripPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    final Rect first = tester.getRect(find.text(labels.first));
    final Rect second = tester.getRect(find.text(labels[1]));
    await tester.dragFrom(first.center, second.center - first.center);
    await tester.pumpAndSettle();
    expect(selected, 1, reason: '滑块被拖到第二段');
    expect(position.pixels, 0, reason: '拖滑块不滚动分段条');
  });

  testWidgets('Apple：宽度够时不出现滚动，横拖任意位置照旧拖滑块', (WidgetTester tester) async {
    int selected = 0;
    await pumpStrip(
      tester,
      glass: true,
      logicalSize: const Size(1600, 900),
      selected: () => selected,
      onSelected: (int v) => selected = v,
    );
    final ScrollPosition position = stripPosition(tester);
    expect(position.maxScrollExtent, 0, reason: '放得下时没有可滚动距离');
    final Rect second = tester.getRect(find.text(labels[1]));
    final Rect last = tester.getRect(find.text(labels.last));
    // 从非选中段起手横拖：放得下时行为不变，滑块跟手、落到松手处的段。
    await tester.dragFrom(second.center, last.center - second.center);
    await tester.pumpAndSettle();
    expect(selected, 3);
  });

  testWidgets('Apple：不在横向滚动区时横拖任意位置照旧拖滑块', (WidgetTester tester) async {
    int selected = 0;
    await pumpStrip(
      tester,
      glass: true,
      logicalSize: iPhone,
      selected: () => selected,
      onSelected: (int v) => selected = v,
      scrollHost: false,
    );
    expect(find.byType(Scrollable), findsNothing);
    final Rect bar = tester.getRect(find.byType(FushiAppleSegmentedControl));
    // 有界宽下撑满、段名省略：从第二段位置起手拖到最右。
    final double segment = (bar.width - 6) / labels.length;
    final Offset start = Offset(bar.left + 3 + segment * 1.5, bar.center.dy);
    await tester.dragFrom(start, Offset(segment * 2, 0));
    await tester.pumpAndSettle();
    expect(selected, 3);
  });

  testWidgets('Material（M3E）：同宽度下横拖分段条同样能滚到末段', (WidgetTester tester) async {
    int selected = 0;
    await pumpStrip(
      tester,
      glass: false,
      logicalSize: iPhone,
      selected: () => selected,
      onSelected: (int v) => selected = v,
    );
    expect(find.byType(FushiAppleSegmentedControl), findsNothing);
    final ScrollPosition position = stripPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.dragFrom(
      tester.getCenter(find.text(labels.first).first),
      const Offset(-3000, 0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(selected, 0);
  });
}

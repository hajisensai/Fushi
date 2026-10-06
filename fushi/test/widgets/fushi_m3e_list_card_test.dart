import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// 列表与卡片的 M3E 共享规格（2026-10-05「列表和卡片也统一成 m3e」）：
// 形状分级（卡 20）、分段列表的交互形变（悬停 12 / 按下·选中 16）、卡片三类
// 容器与饱和配色变体、列表三档高度、行首形状底、滑动操作底。Apple 设计系统用
// 同一 API 落到 inset grouped / 彩色圆角方块。

final ColorScheme _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool glass = false,
  bool reduceMotion = false,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: _scheme,
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: FushiGlassScope(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(children: <Widget>[child]),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ShapeDecoration _cardDecoration(WidgetTester tester, Finder card) {
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find.descendant(of: card, matching: find.byType(AnimatedContainer)).first,
  );
  return container.decoration! as ShapeDecoration;
}

BorderRadius _cardRadius(WidgetTester tester, Finder card) =>
    (_cardDecoration(tester, card).shape as RoundedRectangleBorder).borderRadius
        as BorderRadius;

void main() {
  group('fushiM3eMorphRadius', () {
    const BorderRadius segment = BorderRadius.vertical(
      top: Radius.circular(24),
      bottom: Radius.circular(4),
    );

    test('静止原样、悬停内侧角到 12、按下 / 选中到 16，外侧大角不动', () {
      expect(fushiM3eMorphRadius(segment, 0), segment);
      final BorderRadius hover = fushiM3eMorphRadius(segment, 1);
      expect(hover.topLeft.x, 24);
      expect(hover.bottomLeft.x, FushiM3eShape.listHover);
      final BorderRadius active = fushiM3eMorphRadius(segment, 2);
      expect(active.topRight.x, 24);
      expect(active.bottomRight.x, FushiM3eShape.listActive);
    });

    test('弹簧过冲不越过 16', () {
      final BorderRadius over = fushiM3eMorphRadius(segment, 2.4);
      expect(over.bottomLeft.x, FushiM3eShape.listActive);
    });
  });

  group('FushiCard（M3E）', () {
    testWidgets('默认填充卡：20 圆角、surfaceContainerLow、无描边无投影', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const FushiCard(child: SizedBox(height: 40)));
      final Finder card = find.byType(FushiCard);
      final ShapeDecoration d = _cardDecoration(tester, card);
      expect(_cardRadius(tester, card), FushiM3eShape.cardRadius);
      expect(d.color, _scheme.surfaceContainerLow);
      expect((d.shape as RoundedRectangleBorder).side, BorderSide.none);
      expect(d.shadows, isNull);
    });

    testWidgets('描边卡 = surface + outlineVariant；抬升卡带 level1 投影', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            FushiCard(
              key: ValueKey<String>('o'),
              variant: FushiCardVariant.outlined,
              child: SizedBox(height: 40),
            ),
            FushiCard(
              key: ValueKey<String>('e'),
              variant: FushiCardVariant.elevated,
              child: SizedBox(height: 40),
            ),
          ],
        ),
      );
      final ShapeDecoration outlined = _cardDecoration(
        tester,
        find.byKey(const ValueKey<String>('o')),
      );
      expect(outlined.color, _scheme.surface);
      expect(
        (outlined.shape as RoundedRectangleBorder).side.color,
        _scheme.outlineVariant,
      );
      final ShapeDecoration elevated = _cardDecoration(
        tester,
        find.byKey(const ValueKey<String>('e')),
      );
      expect(elevated.shadows, isNotEmpty);
    });

    testWidgets('饱和配色变体：primaryContainer 底 + 未着色文字取 onPrimaryContainer', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiCard(tone: FushiCardTone.primary, child: Text('进度')),
      );
      final Finder card = find.byType(FushiCard);
      expect(_cardDecoration(tester, card).color, _scheme.primaryContainer);
      final RichText text = tester.widget<RichText>(
        find.descendant(of: card, matching: find.byType(RichText)),
      );
      expect(text.text.style?.color, _scheme.onPrimaryContainer);
    });

    testWidgets('独立可点卡不形变（只抬升 + 按压回弹）', (WidgetTester tester) async {
      await _pump(
        tester,
        FushiCard(onTap: () {}, child: const SizedBox(height: 40)),
      );
      final Finder card = find.byType(FushiCard);
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(card));
      await tester.pumpAndSettle();
      expect(_cardRadius(tester, card), FushiM3eShape.cardRadius);
      await mouse.removePointer();
    });
  });

  group('FushiGroupedListItem（M3E 分段列表）', () {
    Widget group({int selected = -1, VoidCallback? onTap}) => Column(
      children: <Widget>[
        for (int i = 0; i < 3; i++)
          FushiGroupedListItem(
            key: ValueKey<int>(i),
            index: i,
            count: 3,
            selected: i == selected,
            onTap: onTap,
            child: SizedBox(height: 48, child: Text('行 $i')),
          ),
      ],
    );

    Finder card(int i) => find.descendant(
      of: find.byKey(ValueKey<int>(i)),
      matching: find.byType(FushiCard),
    );

    // 分段面本身（行间缝是 FushiCard 的外边距，量面与面之间）。
    Finder surface(int i) => find
        .descendant(of: card(i), matching: find.byType(AnimatedContainer))
        .first;

    testWidgets('组首尾外侧大圆角、中间小圆角、行间 2px', (WidgetTester tester) async {
      await _pump(tester, group());
      expect(_cardRadius(tester, card(0)).topLeft.x, 24);
      expect(_cardRadius(tester, card(0)).bottomLeft.x, 4);
      expect(_cardRadius(tester, card(1)).topLeft.x, 4);
      expect(_cardRadius(tester, card(2)).bottomRight.x, 24);
      final double gap =
          tester.getTopLeft(surface(1)).dy -
          tester.getBottomLeft(surface(0)).dy;
      expect(gap, closeTo(2, 0.01));
    });

    testWidgets('选中项 secondaryContainer 底，内侧角弹到 16', (
      WidgetTester tester,
    ) async {
      await _pump(tester, group(selected: 1));
      final ShapeDecoration d = _cardDecoration(tester, card(1));
      expect(d.color, _scheme.secondaryContainer);
      expect(_cardRadius(tester, card(1)).topLeft.x, FushiM3eShape.listActive);
      expect(_cardRadius(tester, card(0)).bottomLeft.x, 4);
    });

    testWidgets('悬停时内侧角形变到 12，移开回到 4', (WidgetTester tester) async {
      await _pump(tester, group(onTap: () {}));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(card(1)));
      await tester.pumpAndSettle();
      expect(
        _cardRadius(tester, card(1)).topLeft.x,
        closeTo(FushiM3eShape.listHover, 0.5),
      );
      await mouse.moveTo(const Offset(-50, -50));
      await tester.pumpAndSettle();
      expect(_cardRadius(tester, card(1)).topLeft.x, closeTo(4, 0.5));
      await mouse.removePointer();
    });

    testWidgets('减弱动态效果下选中形变瞬间到位（不建弹簧动画）', (WidgetTester tester) async {
      await _pump(tester, group(selected: 2), reduceMotion: true);
      expect(_cardRadius(tester, card(2)).topLeft.x, FushiM3eShape.listActive);
    });

    testWidgets('Apple：inset grouped，行间无缝', (WidgetTester tester) async {
      await _pump(tester, group(), glass: true);
      final double gap =
          tester.getTopLeft(card(1)).dy - tester.getBottomLeft(card(0)).dy;
      expect(gap, closeTo(0, 0.01));
    });
  });

  group('FushiListItem（M3E）', () {
    BorderRadius highlight(WidgetTester tester) =>
        (tester
                        .widget<AnimatedContainer>(
                          find
                              .descendant(
                                of: find.byType(FushiListItem),
                                matching: find.byType(AnimatedContainer),
                              )
                              .first,
                        )
                        .decoration!
                    as BoxDecoration)
                .borderRadius!
            as BorderRadius;

    testWidgets('未选中 12、选中 16（corner-large）', (WidgetTester tester) async {
      await _pump(tester, FushiListItem(title: const Text('a'), onTap: () {}));
      expect(highlight(tester).topLeft.x, kFushiMd3RowRadius);
      await _pump(
        tester,
        FushiListItem(title: const Text('a'), selected: true, onTap: () {}),
      );
      expect(highlight(tester).topLeft.x, FushiM3eShape.listActive);
    });

    testWidgets('三档高度：单行 56 / 双行 72 / 三行 88', (WidgetTester tester) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            FushiListItem(key: ValueKey<int>(1), title: Text('a')),
            FushiListItem(
              key: ValueKey<int>(2),
              title: Text('a'),
              subtitle: Text('b'),
            ),
            FushiListItem(
              key: ValueKey<int>(3),
              title: Text('a'),
              subtitle: Text('b'),
              isThreeLine: true,
            ),
          ],
        ),
      );
      // 行外恒有 1px 透明描边（选中不跳高），所以绝对高 = 档位 + 2；量档差。
      double h(int k) => tester.getSize(find.byKey(ValueKey<int>(k))).height;
      expect(h(1), 56 + 2);
      expect(h(2) - h(1), 16);
      expect(h(3) - h(2), 16);
    });
  });

  group('FushiListLeadingIcon', () {
    testWidgets('MD3：40 的 secondaryContainer 形状底；cookie 形状可选', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Row(
          children: <Widget>[
            FushiListLeadingIcon(Icons.book, key: ValueKey<String>('c')),
            FushiListLeadingIcon(
              Icons.star,
              key: ValueKey<String>('k'),
              shape: FushiLeadingShape.flower,
              tone: FushiCardTone.tertiary,
            ),
          ],
        ),
      );
      final Finder circle = find.byKey(const ValueKey<String>('c'));
      expect(tester.getSize(circle), const Size(40, 40));
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(of: circle, matching: find.byType(DecoratedBox)),
      );
      final ShapeDecoration d = box.decoration as ShapeDecoration;
      expect(d.color, _scheme.secondaryContainer);
      expect(d.shape, isA<CircleBorder>());
      final DecoratedBox flower = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('k')),
          matching: find.byType(DecoratedBox),
        ),
      );
      final ShapeDecoration fd = flower.decoration as ShapeDecoration;
      expect(fd.shape, isA<FushiCookieBorder>());
      expect(fd.color, _scheme.tertiaryContainer);
    });

    test('cookie 外形落在外接正方形内且有凹凸', () {
      const FushiCookieBorder border = FushiCookieBorder(lobes: 4);
      final Rect rect = Rect.fromLTWH(0, 0, 40, 40);
      final Path path = border.getOuterPath(rect);
      final Rect bounds = path.getBounds();
      expect(rect.inflate(0.01).contains(bounds.topLeft), isTrue);
      expect(rect.inflate(0.01).contains(bounds.bottomRight), isTrue);
      // 瓣尖在轴上（顶点）触到外接框，对角方向凹进去。
      expect(path.contains(const Offset(20, 0.5)), isTrue);
      expect(path.contains(const Offset(6.5, 6.5)), isFalse);
    });

    testWidgets('Apple：强调色圆角方块', (WidgetTester tester) async {
      await _pump(tester, const FushiListLeadingIcon(Icons.book), glass: true);
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(FushiListLeadingIcon),
          matching: find.byType(DecoratedBox),
        ),
      );
      final ShapeDecoration d = box.decoration as ShapeDecoration;
      expect(d.shape, isA<RoundedSuperellipseBorder>());
      final BuildContext context = tester.element(
        find.byType(FushiListLeadingIcon),
      );
      expect(d.color, appleColorsOf(context).accent);
    });
  });

  testWidgets('FushiSwipeActionBackground：删除 = errorContainer 圆角底', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const SizedBox(
        height: 56,
        child: FushiSwipeActionBackground(
          icon: Icons.delete_outline,
          label: '删除',
          destructive: true,
        ),
      ),
    );
    final DecoratedBox box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(FushiSwipeActionBackground),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final BoxDecoration d = box.decoration as BoxDecoration;
    expect(d.color, _scheme.errorContainer);
    expect(d.borderRadius, FushiM3eShape.cardRadius);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('FushiCardControl 默认形状 = M3E 卡 20', (WidgetTester tester) async {
    await _pump(tester, const FushiCardControl(child: SizedBox(height: 40)));
    final Card card = tester.widget<Card>(find.byType(Card));
    expect(
      (card.shape! as RoundedRectangleBorder).borderRadius,
      FushiM3eShape.cardRadius,
    );
  });
}

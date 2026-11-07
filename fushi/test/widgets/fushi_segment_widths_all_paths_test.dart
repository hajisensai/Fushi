import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_manga_panels.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 GaI5uPQEbF（BUG-4205）：PR #2694 只把 MD3 胶囊分段与 Apple 分段接到
/// `fushiSegmentWidths`，其余分段路径仍是「等宽取最宽段，放不下整体等比缩窄」，
/// 最长段先被截断 / 折行，短段里却空着：
/// - MD3 `FushiSegmentedButton` = `FushiConnectedButtonGroup`；
/// - 墨水屏 `FushiSegmentedButton`（原生 `SegmentedButton`）；
/// - Apple 退回形态（多选 / 允许空选 / 竖排 / 富文本段）；
/// - Cupertino 设计系统但非 Apple 设计（如墨水屏）下的 `adaptiveSegmentedButton`
///   （原生 `CupertinoSlidingSegmentedControl`）。
/// 这里每条路径都用睡眠定时那组文案在窄宽下布局，断言每段文字完整单行。
void main() {
  // flutter_test 字体每字 1em：「15 分钟」= 5em。
  const List<String> labels = <String>['关闭', '播完本曲', '15 分钟', '30 分钟', '60 分钟'];

  List<ButtonSegment<int>> segments() => <ButtonSegment<int>>[
    for (int i = 0; i < labels.length; i++)
      ButtonSegment<int>(value: i, label: Text(labels[i])),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required WidgetBuilder builder,
    bool eink = false,
    bool glassDesign = false,
    FushiDesignSystem designSystem = FushiDesignSystem.auto,
    TargetPlatform? platform,
  }) async {
    final ThemeData base = buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      eink: eink,
      designSystem: designSystem,
      glass: FushiGlassMaterial.off,
      glassDesign: glassDesign,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: platform == null ? base : base.copyWith(platform: platform),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 每段文字：没被省略、没被压窄到折行（宽 ≥ 单行自然宽、高 = 单行高）。
  void expectLabelsWhole(WidgetTester tester, Finder root) {
    expect(tester.takeException(), isNull);
    for (final String label in labels) {
      final RenderParagraph p = tester.renderObject<RenderParagraph>(
        find.descendant(of: root, matching: find.text(label)),
      );
      expect(p.didExceedMaxLines, isFalse, reason: '「$label」被省略号截断');
      final double singleLineWidth = p.getMaxIntrinsicWidth(double.infinity);
      final double singleLineHeight = p.getMaxIntrinsicHeight(double.infinity);
      expect(
        p.size.width,
        greaterThanOrEqualTo(singleLineWidth - 0.5),
        reason: '「$label」被压窄（${p.size.width} < $singleLineWidth）',
      );
      expect(
        p.size.height,
        closeTo(singleLineHeight, 0.5),
        reason: '「$label」折成了多行',
      );
    }
  }

  for (final double width in <double>[620, 400]) {
    testWidgets('MD3 FushiSegmentedButton（连接式按钮组）$width 宽下五段完整单行', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        width: width,
        builder: (BuildContext context) => FushiSegmentedButton<int>(
          segments: segments(),
          selected: const <int>{1},
          onSelectionChanged: (_) {},
        ),
      );
      final Finder root = find.byType(FushiConnectedButtonGroup<int>);
      expect(root, findsOneWidget);
      expectLabelsWhole(tester, root);
      expect(tester.getSize(root).width, lessThanOrEqualTo(width));
    });

    testWidgets('墨水屏 FushiSegmentedButton $width 宽下五段完整单行', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        width: width,
        eink: true,
        builder: (BuildContext context) => FushiSegmentedButton<int>(
          segments: segments(),
          selected: const <int>{1},
          onSelectionChanged: (_) {},
        ),
      );
      final Finder root = find.byType(FushiSegmentedButton<int>);
      expect(root, findsOneWidget);
      expectLabelsWhole(tester, root);
      expect(tester.getSize(root).width, lessThanOrEqualTo(width));
    });
  }

  testWidgets('MD3 连接式按钮组：放得下时仍等宽（选中切换不跳宽）', (WidgetTester tester) async {
    await pump(
      tester,
      width: 780,
      builder: (BuildContext context) => Align(
        child: FushiSegmentedButton<int>(
          segments: segments(),
          selected: const <int>{1},
          onSelectionChanged: (_) {},
        ),
      ),
    );
    final Set<double> widths = <double>{
      for (final String label in labels)
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(TextButton),
                  )
                  .first,
            )
            .width,
    };
    expect(widths, hasLength(1));
  });

  testWidgets('MD3 连接式按钮组：expandedInsets 撑满时等分整行', (WidgetTester tester) async {
    await pump(
      tester,
      width: 700,
      builder: (BuildContext context) => FushiSegmentedButton<int>(
        segments: segments(),
        selected: const <int>{1},
        onSelectionChanged: (_) {},
        expandedInsets: EdgeInsets.zero,
      ),
    );
    final Finder root = find.byType(FushiConnectedButtonGroup<int>);
    expect(tester.getSize(root).width, closeTo(700, 0.01));
    final Set<double> widths = <double>{
      for (final String label in labels)
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(TextButton),
                  )
                  .first,
            )
            .width,
    };
    expect(widths, hasLength(1));
  });

  testWidgets('Apple 退回形态（多选）400 宽撑满下五段完整单行', (WidgetTester tester) async {
    await pump(
      tester,
      width: 400,
      glassDesign: true,
      builder: (BuildContext context) => FushiSegmentedButton<int>(
        segments: segments(),
        selected: const <int>{1},
        multiSelectionEnabled: true,
        onSelectionChanged: (_) {},
        expandedInsets: EdgeInsets.zero,
      ),
    );
    final Finder root = find.byType(FushiSegmentedButton<int>);
    expect(find.byType(FushiAppleSegmentedControl), findsNothing);
    expectLabelsWhole(tester, root);
  });

  testWidgets('Apple 退回形态（多选）宽松宿主下不溢出、五段完整单行', (WidgetTester tester) async {
    await pump(
      tester,
      width: 400,
      glassDesign: true,
      builder: (BuildContext context) => Align(
        child: FushiSegmentedButton<int>(
          segments: segments(),
          selected: const <int>{1},
          multiSelectionEnabled: true,
          onSelectionChanged: (_) {},
        ),
      ),
    );
    final Finder root = find.byType(FushiSegmentedButton<int>);
    expectLabelsWhole(tester, root);
    expect(tester.getSize(root).width, lessThanOrEqualTo(400));
  });

  testWidgets('Cupertino 设计系统 + 墨水屏下 adaptiveSegmentedButton 390 宽完整单行', (
    WidgetTester tester,
  ) async {
    late bool cupertino;
    late bool glass;
    await pump(
      tester,
      width: 390,
      eink: true,
      designSystem: FushiDesignSystem.cupertino,
      glassDesign: true,
      platform: TargetPlatform.iOS,
      builder: (BuildContext context) {
        cupertino = isCupertinoPlatform(context);
        glass = isGlassDesign(context);
        return adaptiveSegmentedButton<int>(
          context: context,
          segments: segments(),
          selected: const <int>{1},
          onSelectionChanged: (_) {},
        );
      },
    );
    // 前提：这正是「Cupertino 平台、非 Apple 设计」那条分支。
    expect(cupertino, isTrue);
    expect(glass, isFalse);
    expectLabelsWhole(tester, find.byType(Scaffold));
    expect(find.byType(FushiPillSegmentedButton<int>), findsOneWidget);
  });

  // 审查补漏（PR #2987）：Apple 分段式页签的铺满档以前「各页签 Expanded 等分
  // 整行 + 单行省略号」，窄屏最长页签先变省略号。
  testWidgets('Apple FushiTabBar 铺满档 440 宽下五个页签完整单行', (
    WidgetTester tester,
  ) async {
    late bool glass;
    await pump(
      tester,
      width: 440,
      glassDesign: true,
      builder: (BuildContext context) {
        glass = isGlassDesign(context);
        return DefaultTabController(
          length: labels.length,
          initialIndex: 1,
          child: FushiTabBar(
            tabs: <Widget>[for (final String l in labels) Tab(text: l)],
          ),
        );
      },
    );
    expect(glass, isTrue);
    expect(find.byType(TabBar), findsNothing);
    expectLabelsWhole(tester, find.byType(FushiTabBar));
    expect(
      tester.getSize(find.byType(FushiTabBar)).width,
      lessThanOrEqualTo(440),
    );
  });

  testWidgets('Apple FushiTabBar 铺满档放得下时等宽撑满', (WidgetTester tester) async {
    await pump(
      tester,
      width: 700,
      glassDesign: true,
      builder: (BuildContext context) => DefaultTabController(
        length: labels.length,
        child: FushiTabBar(
          tabs: <Widget>[for (final String l in labels) Tab(text: l)],
        ),
      ),
    );
    final List<double> widths = <double>[
      for (final String l in labels)
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(l),
                    matching: find.byType(FocusableActionDetector),
                  )
                  .first,
            )
            .width,
    ];
    for (final double w in widths) {
      expect(w, closeTo(widths.first, 0.5));
    }
    // 整行（减去左右各 8 的页签栏内边距）被等分。
    expect(widths.first * labels.length, closeTo(700 - 16, 0.5));
  });

  // 审查补漏（PR #2987）：漫画取景分段以前手写「Expanded 等分 + FittedBox
  // 缩小」，短段空着时最长段的字号被单独缩小。现在段宽走共用分宽，只有所有
  // 退让都用尽才缩字号。
  testWidgets('漫画取景分段 600 宽下各段原字号完整单行、撑满整行', (WidgetTester tester) async {
    const List<MangaCropChoice> choices = <MangaCropChoice>[
      MangaCropChoice.wholePage,
      MangaCropChoice.textArea,
      MangaCropChoice.custom,
      MangaCropChoice.none,
    ];
    await pump(
      tester,
      width: 600,
      builder: (BuildContext context) => MangaCropChoiceSegments(
        choices: choices,
        selected: MangaCropChoice.textArea,
        onSelected: (_) {},
      ),
    );
    final Finder root = find.byType(MangaCropChoiceSegments);
    expect(tester.takeException(), isNull);
    for (final MangaCropChoice c in choices) {
      final Finder text = find.descendant(
        of: root,
        matching: find.text(mangaCropChoiceLabel(c)),
      );
      final RenderParagraph p = tester.renderObject<RenderParagraph>(text);
      expect(p.didExceedMaxLines, isFalse);
      final double natural = p.getMaxIntrinsicWidth(double.infinity);
      // 画出来的宽（含祖先变换）= 单行自然宽：没被压窄也没被缩小字号。
      expect(tester.getRect(text).width, closeTo(natural, 0.5));
      expect(
        p.size.height,
        closeTo(p.getMaxIntrinsicHeight(double.infinity), 0.5),
      );
    }
    expect(tester.getSize(root).width, closeTo(600, 0.5));
  });
}

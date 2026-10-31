import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_dial_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:material_ui/material_ui.dart';

// 底栏原型的「逐项经过就轻震」与多边形高亮（2026-10-24 用户：模式条拖动要
// 预览目标模块、换项震一次；转盘每经过一个模块都震）。2026-10-25：圆柱滚筒
// 删除，模式条改为铺满胶囊宽度、首尾贴边不留白、高亮下带底标。

const double _kWidth = 360;
const double _kHeight = 64;

List<AdaptiveNavItem> _items(int count) => <AdaptiveNavItem>[
  for (int i = 0; i < count; i++)
    AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Item $i'),
];

void main() {
  late List<String> haptics;

  setUp(() {
    haptics = <String>[];
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<List<int>> pumpVariant(
    WidgetTester tester,
    Widget Function(NavOverflowSpec spec) build, {
    int count = 8,
    int current = 0,
  }) async {
    final List<int> selected = <int>[];
    final NavOverflowSpec spec = NavOverflowSpec(
      items: _items(count),
      indices: <int>[for (int i = 0; i < count; i++) i],
      currentIndex: current,
      onSelect: selected.add,
      cellBuilder: (int i, double w) => SizedBox(width: w),
      width: _kWidth,
      height: _kHeight,
    );
    await tester.pumpWidget(
      MaterialApp(
        // fushiSelectionHaptic 只在手机平台发。
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: _kWidth,
              height: _kHeight,
              child: build(spec),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return selected;
  }

  /// 按 10px 一步横移 [total]，每步 pump 一帧。
  Future<void> dragBy(
    TestGesture gesture,
    WidgetTester tester,
    double total,
  ) async {
    final int steps = (total.abs() / 10).round();
    for (int i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(total.sign * 10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('mode strip previews the release target while dragging and '
      'buzzes once per new target', (WidgetTester tester) async {
    final List<int> selected = await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavModeStripBar(spec: spec),
    );
    // 当前项没有文字名字：名字只在 Tooltip / Semantics。
    expect(find.text('Item 0'), findsNothing);
    expect(find.byType(NavMorphShape), findsOneWidget);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(NavModeStripBar)),
    );
    await dragBy(gesture, tester, -120);
    // 往左拨约两格：预览目标 0 → 1 → 2，换一次震一次；松手前不跳转。
    expect(haptics, <String>[
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.selectionClick',
    ]);
    expect(selected, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, <int>[2]);
    // 松手本身不再额外震（onSelect 自带的那一下由宿主发）。
    expect(haptics, hasLength(2));
  });

  testWidgets('dial buzzes once per slot passing the pointer', (
    WidgetTester tester,
  ) async {
    final List<int> selected = await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavDialBar(spec: spec),
    );
    final Finder knob = find.descendant(
      of: find.byType(NavDialBar),
      matching: find.byType(FocusableActionDetector),
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(knob),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // 48px 一格：横拖 150px ≈ 3.1 格，指针依次对准 1、2、3。
    await dragBy(gesture, tester, 150);
    expect(haptics, hasLength(3));
    expect(selected, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, <int>[3]);
    expect(haptics, hasLength(3));
  });

  testWidgets('dial arrow keys buzz once per step', (
    WidgetTester tester,
  ) async {
    await pumpVariant(tester, (NavOverflowSpec spec) => NavDialBar(spec: spec));
    final Finder knob = find.descendant(
      of: find.byType(NavDialBar),
      matching: find.byType(FocusableActionDetector),
    );
    // 轻点旋钮：转盘停在打开状态，焦点交给转盘。
    await tester.tap(knob);
    await tester.pumpAndSettle();
    expect(haptics, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(haptics, hasLength(2));
  });

  /// 模式条里各项（按 Semantics 标签找）的中心横坐标，按序号排。
  List<double> stripCenters(WidgetTester tester, int count) => <double>[
    for (int i = 0; i < count; i++)
      tester
          .getCenter(
            find.descendant(
              of: find.byType(NavModeStripBar),
              matching: find.byWidgetPredicate(
                (Widget w) => w is Semantics && w.properties.label == 'Item $i',
              ),
            ),
          )
          .dx,
  ];

  testWidgets('mode strip spreads few items across the full capsule width', (
    WidgetTester tester,
  ) async {
    await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavModeStripBar(spec: spec),
      count: 4,
    );
    // 4 项放得下：按项数等分 360，第一项贴左、最后一项贴右，当前项不居中。
    final double left = tester.getTopLeft(find.byType(NavModeStripBar)).dx;
    final List<double> xs = stripCenters(tester, 4);
    for (int i = 0; i < 4; i++) {
      expect(xs[i] - left, moreOrLessEquals(_kWidth / 4 * (i + 0.5)));
    }
    // 全部放得下时两端不渐隐。
    expect(
      find.descendant(
        of: find.byType(NavModeStripBar),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
  });

  testWidgets('mode strip leaves no blank at either end when scrolling', (
    WidgetTester tester,
  ) async {
    // 12 项、360 宽：6 格放得下，格宽 60。
    final List<int> selected = await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavModeStripBar(spec: spec),
      count: 12,
    );
    final double left = tester.getTopLeft(find.byType(NavModeStripBar)).dx;
    // 当前是第一项：它贴左边，不居中留出半条空白。
    expect(stripCenters(tester, 12).first - left, moreOrLessEquals(30));

    // 往左拨几次走到末项：末项贴右边。
    for (int step = 0; step < 4; step++) {
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(NavModeStripBar)),
      );
      await dragBy(gesture, tester, -180);
      await gesture.up();
      await tester.pumpAndSettle();
    }
    expect(selected.last, 11);
    expect(
      left + _kWidth - stripCenters(tester, 12).last,
      moreOrLessEquals(30),
    );
  });

  testWidgets('mode strip draws no bottom marker under the highlight', (
    WidgetTester tester,
  ) async {
    await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavModeStripBar(spec: spec),
      count: 4,
      current: 2,
    );
    final Finder marker = find.descendant(
      of: find.byType(NavModeStripBar),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(2),
      ),
    );
    // 2026-10-30 用户：高亮多边形已经标明当前项，底部短横两套设计系统都去掉。
    expect(marker, findsNothing);
  });
}

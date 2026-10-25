import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_dial_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_drum_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:material_ui/material_ui.dart';

// 底栏原型的「逐项经过就轻震」与多边形高亮（2026-10-24 用户：模式条拖动要
// 预览目标模块、换项震一次；转盘 / 滚筒每经过一个模块都震；滚筒铺满宽度）。

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

  testWidgets('drum buzzes once per slot while dragging', (
    WidgetTester tester,
  ) async {
    final List<int> selected = await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavDrumBar(spec: spec),
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(NavDrumBar)),
    );
    // 42px 一格：往左拨约 130px 转过 3 格。
    await dragBy(gesture, tester, -130);
    expect(haptics, hasLength(3));

    // 慢慢停住再松手，不带惯性。
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(haptics, hasLength(3));
    // 滚筒横拨只浏览、不切页。
    expect(selected, isEmpty);
  });

  testWidgets('drum fills the capsule width', (WidgetTester tester) async {
    await pumpVariant(
      tester,
      (NavOverflowSpec spec) => NavDrumBar(spec: spec),
      count: 12,
      current: 6,
    );
    // 固定 24° 角距 + 118 半径时 360 宽只露 7 项、两侧空着；按宽度推导后
    // 当前项两侧各铺到胶囊边缘。
    final Finder cells = find.descendant(
      of: find.byType(NavDrumBar),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is Semantics && (w.properties.label ?? '').startsWith('Item'),
      ),
    );
    final int visible = cells.evaluate().length;
    expect(visible, greaterThanOrEqualTo(9));
    final List<double> xs = <double>[
      for (int i = 0; i < visible; i++) tester.getCenter(cells.at(i)).dx,
    ]..sort();
    final double left = tester.getTopLeft(find.byType(NavDrumBar)).dx;
    expect(xs.first - left, lessThan(_kWidth * 0.15));
    expect(left + _kWidth - xs.last, lessThan(_kWidth * 0.15));
  });
}

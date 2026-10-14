import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_launcher_fan.dart';

// 2026-10-14 底栏「中央展开」原型：目的地多于 5 个时胶囊只留首尾各两项 +
// 正中「+」，其余点「+」后从它弧形弹出，点遮罩 / 「×」收回。
void main() {
  List<AdaptiveNavItem> itemsOf(int n) => <AdaptiveNavItem>[
    for (int i = 0; i < n; i++)
      AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Tab$i'),
  ];

  Future<List<int>> pumpBar(
    WidgetTester tester, {
    required int count,
    int currentIndex = 0,
  }) async {
    final List<int> taps = <int>[];
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: currentIndex,
                onTap: taps.add,
                items: itemsOf(count),
                centerLauncher: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return taps;
  }

  Finder shown(String label) => find.text(label).hitTestable();

  testWidgets('9 个入口：栏上只有首尾各两项 + 中央「+」', (WidgetTester tester) async {
    await pumpBar(tester, count: 9);
    for (final String label in <String>['Tab0', 'Tab1', 'Tab7', 'Tab8']) {
      expect(shown(label), findsOneWidget, reason: label);
    }
    for (int i = 2; i <= 6; i++) {
      expect(shown('Tab$i'), findsNothing, reason: 'Tab$i');
    }
    expect(shown(t.home_nav_more), findsOneWidget);
    // 「+」在正中：五格等分，第三格的中心就是栏的中心。
    final double barCenter = tester.getCenter(find.byType(Scaffold)).dx;
    expect(
      tester.getCenter(shown(t.home_nav_more)).dx,
      moreOrLessEquals(barCenter, epsilon: 1),
    );
  });

  testWidgets('点「+」弹出其余入口，点其中一个切过去并收回', (WidgetTester tester) async {
    final List<int> taps = await pumpBar(tester, count: 9);
    await tester.tap(shown(t.home_nav_more));
    await tester.pumpAndSettle();
    for (int i = 2; i <= 6; i++) {
      expect(shown('Tab$i'), findsOneWidget, reason: 'Tab$i');
    }
    // 弹出项（连同标签）整个浮在底栏胶囊的图标行之上，弧两端也不压住左右
    // 常驻项：「+」标签上沿再往上 32（药丸高）就是图标行顶。
    final double iconRowTop =
        tester.getTopLeft(find.text(t.home_nav_more)).dy - 32;
    for (int i = 2; i <= 6; i++) {
      expect(
        tester.getBottomLeft(shown('Tab$i')).dy,
        lessThan(iconRowTop),
        reason: 'Tab$i',
      );
    }
    await tester.tap(shown('Tab4'));
    await tester.pumpAndSettle();
    expect(taps, <int>[4]);
    expect(shown('Tab4'), findsNothing);
  });

  testWidgets('点遮罩空白处收回，不切换', (WidgetTester tester) async {
    final List<int> taps = await pumpBar(tester, count: 9);
    await tester.tap(shown(t.home_nav_more));
    await tester.pumpAndSettle();
    expect(shown('Tab3'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(shown('Tab3'), findsNothing);
    expect(taps, isEmpty);
  });

  // 「按住『+』直接划过去」（像手机图案解锁）：按下即弹出，不抬手划到某项上
  // 松开即选中；底栏的长按 / 横拖拖选同时开着，从「+」起手不能被它抢走。
  Future<(List<int>, List<int>)> pumpDragBar(WidgetTester tester) async {
    final List<int> taps = <int>[];
    final List<int> dragSelects = <int>[];
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: 0,
                onTap: taps.add,
                onDragSelect: dragSelects.add,
                items: itemsOf(9),
                centerLauncher: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (taps, dragSelects);
  }

  testWidgets('按住「+」划到某项上松手：直接切过去', (WidgetTester tester) async {
    final (List<int> taps, List<int> dragSelects) = await pumpDragBar(tester);
    // 弹出后「+」被扇面的「×」盖住、自身透明，起手点先记下。
    final Offset plus = tester.getCenter(shown(t.home_nav_more));
    final TestGesture gesture = await tester.startGesture(plus);
    await tester.pumpAndSettle();
    expect(shown('Tab4'), findsOneWidget, reason: '按下即弹出，不必先抬手');
    // 圆钮圆心在标签上方约 40。
    final Offset target = tester.getCenter(shown('Tab4')) - const Offset(0, 40);
    await gesture.moveTo(Offset.lerp(plus, target, 0.5)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, <int>[4]);
    expect(dragSelects, isEmpty, reason: '从「+」起手的拖动不归底栏拖选');
    expect(shown('Tab4'), findsNothing);
  });

  testWidgets('按住「+」划到空处松手：收回、不切换', (WidgetTester tester) async {
    final (List<int> taps, List<int> dragSelects) = await pumpDragBar(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(shown(t.home_nav_more)),
    );
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(30, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(shown('Tab4'), findsNothing);
    expect(taps, isEmpty);
    expect(dragSelects, isEmpty);
  });

  testWidgets('不多于 5 个入口时照常平铺，没有「+」', (WidgetTester tester) async {
    await pumpBar(tester, count: 5);
    for (int i = 0; i < 5; i++) {
      expect(shown('Tab$i'), findsOneWidget, reason: 'Tab$i');
    }
    expect(shown(t.home_nav_more), findsNothing);
  });

  test('弧形落点：全在圆心上方，单圈左右对称', () {
    const int count = 5;
    final List<Offset> slots = <Offset>[
      for (int i = 0; i < count; i++) navLauncherSlotOffset(i, count),
    ];
    for (final Offset o in slots) {
      expect(o.dy, lessThan(0));
    }
    expect(slots.first.dx, moreOrLessEquals(-slots.last.dx, epsilon: 1e-9));
    expect(slots[2].dx, moreOrLessEquals(0, epsilon: 1e-9));
    // 第 6 个起进第二圈，离圆心更远。
    expect(
      navLauncherSlotOffset(5, 7).distance,
      greaterThan(navLauncherSlotOffset(0, 7).distance),
    );
  });
}

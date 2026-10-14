import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
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
                barStyle: AdaptiveNavBarStyle.launcher,
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
                barStyle: AdaptiveNavBarStyle.launcher,
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

  // 分页形态：底栏上左右滑翻页（跟手 + 吸附），小圆点提示页数。
  Future<List<int>> pumpStyled(
    WidgetTester tester,
    AdaptiveNavBarStyle style, {
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
                items: itemsOf(9),
                barStyle: style,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return taps;
  }

  List<String> barLabels() => <String>[
    for (int i = 0; i < 9; i++)
      if (shown('Tab$i').evaluate().isNotEmpty) 'Tab$i',
  ];

  Future<void> swipeBar(WidgetTester tester, double dx) async {
    final double y = tester.getCenter(find.byType(Scaffold)).dy + 360;
    await tester.dragFrom(Offset(200 - dx / 2, y), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('分页滑动：一页 5 个，左滑翻到下一页，点第二页的项照常切', (WidgetTester tester) async {
    final List<int> taps = await pumpStyled(tester, AdaptiveNavBarStyle.pager);
    expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab4']);
    expect(shown(t.home_nav_more), findsNothing);
    await swipeBar(tester, -220);
    expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
    await tester.tap(shown('Tab6'));
    await tester.pumpAndSettle();
    expect(taps, <int>[6]);
    // 右滑回第一页；首页再右滑不动。
    await swipeBar(tester, 220);
    expect(barLabels().first, 'Tab0');
    await swipeBar(tester, 220);
    expect(barLabels().first, 'Tab0');
  });

  // 真 app 里实测：慢拖不到半页（没有甩速）曾被吸回原页，窄胶囊上手感发涩。
  // 现在从按下点起算位移、拖过 1/4 页即翻。
  testWidgets('分页滑动：慢拖约 30% 宽、不甩，也翻页', (WidgetTester tester) async {
    await pumpStyled(tester, AdaptiveNavBarStyle.pager);
    final double y = tester.getCenter(shown('Tab0')).dy;
    await tester.timedDragFrom(
      Offset(300, y),
      const Offset(-120, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
    // 只蹭 15%：弹回原页。
    await tester.timedDragFrom(
      Offset(100, y),
      const Offset(60, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
  });

  testWidgets('分页滑动：当前项在第二页时直接停在第二页', (WidgetTester tester) async {
    await pumpStyled(tester, AdaptiveNavBarStyle.pager, currentIndex: 7);
    expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
  });

  testWidgets('中央展开 + 翻页：两侧 4 个随页翻，「+」里是当前页之外的全部', (WidgetTester tester) async {
    await pumpStyled(tester, AdaptiveNavBarStyle.launcherPager);
    expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3']);
    final Offset plus = tester.getCenter(shown(t.home_nav_more));
    expect(
      plus.dx,
      moreOrLessEquals(tester.getCenter(find.byType(Scaffold)).dx, epsilon: 1),
    );
    await tester.tap(shown(t.home_nav_more));
    await tester.pumpAndSettle();
    expect(barLabels(), <String>['Tab4', 'Tab5', 'Tab6', 'Tab7', 'Tab8']);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await swipeBar(tester, -220);
    expect(barLabels(), <String>['Tab4', 'Tab5', 'Tab6', 'Tab7']);
    // 「+」不随页移动。
    expect(
      tester.getCenter(shown(t.home_nav_more)).dx,
      moreOrLessEquals(plus.dx, epsilon: 1),
    );
    await tester.tap(shown(t.home_nav_more));
    await tester.pumpAndSettle();
    expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab8']);
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

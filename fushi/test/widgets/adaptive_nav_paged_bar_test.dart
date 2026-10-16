import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';

// 2026-10-15 底栏「分页滑动」：查词并进胶囊、所有目的地同级，每页 5 个；
// 底栏横滑翻页（跟手、过 1/4 页或甩一下就翻）；按住约 0.3 秒进入拖选，手指
// 罩着哪一格就选哪一格，拖到边缘停一下自动翻页，松手切过去。
void main() {
  List<AdaptiveNavItem> itemsOf(int n) => <AdaptiveNavItem>[
    for (int i = 0; i < n; i++)
      AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Tab$i'),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    int count = 9,
    int currentIndex = 0,
    ValueChanged<int>? onTap,
    ValueChanged<int>? onDragSelect,
    AdaptiveNavBarStyle style = AdaptiveNavBarStyle.pager,
  }) async {
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
                onTap: onTap ?? (_) {},
                onDragSelect: onDragSelect,
                items: itemsOf(count),
                barStyle: style,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder shown(String label) => find.text(label).hitTestable();

  List<String> barLabels() => <String>[
    for (int i = 0; i < 9; i++)
      if (shown('Tab$i').evaluate().isNotEmpty) 'Tab$i',
  ];

  double barY(WidgetTester tester) => tester.getCenter(shown('Tab0')).dy;

  Future<void> swipeBar(WidgetTester tester, double dx) async {
    final double y = tester.getCenter(find.byType(Scaffold)).dy + 360;
    await tester.dragFrom(Offset(200 - dx / 2, y), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  group('翻页', () {
    testWidgets('一页 5 个，左滑翻到下一页，点第二页的项照常切；首页再右滑不动', (
      WidgetTester tester,
    ) async {
      final List<int> taps = <int>[];
      await pumpBar(tester, onTap: taps.add);
      expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab4']);
      expect(shown(t.home_nav_more), findsNothing, reason: '分页样式没有「更多」');
      await swipeBar(tester, -220);
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
      await tester.tap(shown('Tab6'));
      await tester.pumpAndSettle();
      expect(taps, <int>[6]);
      await swipeBar(tester, 220);
      expect(barLabels().first, 'Tab0');
      await swipeBar(tester, 220);
      expect(barLabels().first, 'Tab0');
    });

    // 真 app 实测：慢拖不到半页（没有甩速）曾被吸回原页，窄胶囊上手感发涩。
    testWidgets('慢拖约 30% 宽、不甩也翻页；只蹭 15% 弹回', (WidgetTester tester) async {
      await pumpBar(tester);
      final double y = barY(tester);
      await tester.timedDragFrom(
        Offset(300, y),
        const Offset(-120, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
      await tester.timedDragFrom(
        Offset(100, y),
        const Offset(60, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
    });

    testWidgets('当前项在第二页时直接停在第二页', (WidgetTester tester) async {
      await pumpBar(tester, currentIndex: 7);
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
    });

    // 真 app 实测（原型期切样式时）：分组变了还沿用旧页号，会停在不该停的页。
    testWidgets('分组变了（开关模块）落回当前项所在页，不沿用旧页号', (WidgetTester tester) async {
      final ValueNotifier<int> count = ValueNotifier<int>(9);
      addTearDown(count.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: ValueListenableBuilder<int>(
                valueListenable: count,
                builder: (BuildContext context, int n, Widget? _) =>
                    adaptiveBottomBar(
                      context: context,
                      currentIndex: 1,
                      onTap: (_) {},
                      items: itemsOf(n),
                      barStyle: AdaptiveNavBarStyle.pager,
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await swipeBar(tester, -220);
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
      count.value = 8;
      await tester.pumpAndSettle();
      expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab4']);
    });

    testWidgets('不多于 5 个入口时与平铺相同、不分页', (WidgetTester tester) async {
      await pumpBar(tester, count: 5);
      expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab4']);
    });
  });

  group('按住拖选', () {
    testWidgets('按住 0.3 秒后拖到别的格松手：切过去（走 onDragSelect）', (
      WidgetTester tester,
    ) async {
      final List<int> taps = <int>[];
      final List<int> drags = <int>[];
      await pumpBar(tester, onTap: taps.add, onDragSelect: drags.add);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(shown('Tab0')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      // 来回拖：先到 Tab4，再回到 Tab3 松手，以最后罩着的为准。
      await gesture.moveTo(tester.getCenter(shown('Tab4')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(shown('Tab3')));
      await tester.pump();
      // 拖选中整排不跟着翻页。
      expect(barLabels(), <String>['Tab0', 'Tab1', 'Tab2', 'Tab3', 'Tab4']);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(drags, <int>[3]);
      expect(taps, isEmpty);
    });

    testWidgets('没接 onDragSelect 时拖选落地走 onTap', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pumpBar(tester, onTap: taps.add);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(shown('Tab0')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.moveTo(tester.getCenter(shown('Tab2')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, <int>[2]);
    });

    testWidgets('拖回当前项上松手 = 取消', (WidgetTester tester) async {
      final List<int> drags = <int>[];
      await pumpBar(tester, onDragSelect: drags.add);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(shown('Tab0')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.moveTo(tester.getCenter(shown('Tab3')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(shown('Tab0')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(drags, isEmpty);
    });

    testWidgets('没按够 0.3 秒就横拖 = 翻页，不是拖选', (WidgetTester tester) async {
      final List<int> drags = <int>[];
      await pumpBar(tester, onDragSelect: drags.add);
      await swipeBar(tester, -220);
      expect(drags, isEmpty);
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
    });

    testWidgets('拖到右边缘停一下自动翻页，接着选第二页的项', (WidgetTester tester) async {
      final List<int> drags = <int>[];
      await pumpBar(tester, onDragSelect: drags.add);
      final Offset tab1 = tester.getCenter(shown('Tab1'));
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(shown('Tab3')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      // 拖出胶囊右缘外停住。
      await gesture.moveTo(Offset(398, tab1.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(barLabels(), <String>['Tab5', 'Tab6', 'Tab7', 'Tab8']);
      // 第二页第 2 格（原 Tab1 的位置）是 Tab6。
      await gesture.moveTo(tab1);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(drags, <int>[6]);
    });
  });
}

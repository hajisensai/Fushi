// BUG-3064：移动端查词页往下滑底部栏不收起。
//
// 查词是 MD3 悬浮底栏右侧那颗 FAB（不在胶囊里）。底栏收起原本写死「FAB 那一项
// 选中时不收起」——查词页滑到天荒地老底栏都不动。现在 FAB 是当前项时收起 =
// 整条胶囊让位（不吃指针、不进焦点 / 语义），FAB 留下；回滚展开后一切照旧。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:material_ui/material_ui.dart';

const List<AdaptiveNavItem> _items = <AdaptiveNavItem>[
  AdaptiveNavItem(icon: Icons.home_outlined, label: 'Home'),
  AdaptiveNavItem(icon: Icons.menu_book_outlined, label: 'Books'),
  AdaptiveNavItem(icon: Icons.search, label: 'Lookup'),
];

const int _lookup = 2;

Future<void> _pump(
  WidgetTester tester, {
  required int current,
  required bool minimized,
  bool leading = false,
}) async {
  tester.view.physicalSize = const Size(412, 892);
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
              currentIndex: current,
              onTap: (int _) {},
              items: _items,
              glassMinimized: minimized,
              onGlassExpand: () {},
              glassSearchIndex: _lookup,
              searchLeading: leading,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _hittableIcon(IconData icon) => find.byIcon(icon).hitTestable();

void main() {
  testWidgets(
    'lookup (FAB) current + minimized: capsule gives way, FAB stays',
    (WidgetTester tester) async {
      await _pump(tester, current: _lookup, minimized: false);
      expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
      expect(_hittableIcon(Icons.menu_book_outlined), findsOneWidget);
      expect(_hittableIcon(Icons.search), findsOneWidget);

      await _pump(tester, current: _lookup, minimized: true);
      expect(_hittableIcon(Icons.home_outlined), findsNothing);
      expect(_hittableIcon(Icons.menu_book_outlined), findsNothing);
      expect(_hittableIcon(Icons.search), findsOneWidget);
      // 胶囊淡到 0：没有留下一块空底色。
      final Iterable<Opacity> faded = tester
          .widgetList<Opacity>(
            find.ancestor(
              of: find.byIcon(Icons.home_outlined),
              matching: find.byType(Opacity),
            ),
          )
          .where((Opacity o) => o.opacity == 0);
      expect(faded, isNotEmpty);
      // 让位后的胶囊不进语义树（读屏不会念出看不见的目的地），也不进焦点遍历。
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pump();
      expect(find.semantics.byLabel('Home'), findsNothing);
      expect(find.semantics.byLabel('Books'), findsNothing);
      expect(find.semantics.byLabel('Lookup'), findsWidgets);
      semantics.dispose();
      final Iterable<ExcludeFocus> excluded = tester
          .widgetList<ExcludeFocus>(
            find.ancestor(
              of: find.byIcon(Icons.home_outlined),
              matching: find.byType(ExcludeFocus),
            ),
          )
          .where((ExcludeFocus e) => e.excluding);
      expect(excluded, isNotEmpty);
    },
  );

  testWidgets('scrolling back expands the capsule again', (
    WidgetTester tester,
  ) async {
    await _pump(tester, current: _lookup, minimized: true);
    expect(_hittableIcon(Icons.home_outlined), findsNothing);
    await _pump(tester, current: _lookup, minimized: false);
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
    expect(_hittableIcon(Icons.menu_book_outlined), findsOneWidget);
  });

  testWidgets('capsule destination current: minimized keeps the mini pill', (
    WidgetTester tester,
  ) async {
    await _pump(tester, current: 0, minimized: true);
    // 小胶囊里只剩当前项（Home），其余目的地收起。
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
    expect(_hittableIcon(Icons.menu_book_outlined), findsNothing);
    expect(_hittableIcon(Icons.search), findsOneWidget);
  });

  // 与「反转底栏方向」（查词 FAB 在左）叠加：收起照样整条胶囊让位，FAB 留在左边。
  testWidgets('reversed bar (FAB leading): capsule gives way, FAB stays left', (
    WidgetTester tester,
  ) async {
    await _pump(tester, current: _lookup, minimized: false, leading: true);
    final double fabX = tester.getCenter(find.byIcon(Icons.search)).dx;
    final double homeX = tester.getCenter(find.byIcon(Icons.home_outlined)).dx;
    expect(fabX, lessThan(homeX));

    await _pump(tester, current: _lookup, minimized: true, leading: true);
    expect(_hittableIcon(Icons.home_outlined), findsNothing);
    expect(_hittableIcon(Icons.menu_book_outlined), findsNothing);
    expect(_hittableIcon(Icons.search), findsOneWidget);
    expect(tester.getCenter(find.byIcon(Icons.search)).dx, fabX);

    await _pump(tester, current: _lookup, minimized: false, leading: true);
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
  });
}

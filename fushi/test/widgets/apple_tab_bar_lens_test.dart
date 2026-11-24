import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiAppleSelectionLens;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show AnimatedGlassIndicator;

// 2026-11-24 用户：Cupertino 宽窗顶部主导航「看看用什么样式可以有液态玻璃
// 一样，跟分段选择器一样」。顶部标签栏的选中块改走与 Apple 分段选择器同一套
// [FushiAppleSelectionLens]：静止实色 lens 底，换项滑动 / 按住 / 拖动时浮起
// 液态玻璃透镜（着色器档），实色档只滑实色底；M3E 主导航仍是 navShapeOf 多边形。
const List<AdaptiveNavItem> _items = <AdaptiveNavItem>[
  AdaptiveNavItem(icon: Icons.home_outlined, label: 'Home'),
  AdaptiveNavItem(icon: Icons.book_outlined, label: 'Books'),
  AdaptiveNavItem(icon: Icons.movie_outlined, label: 'Videos'),
  AdaptiveNavItem(icon: Icons.settings_outlined, label: 'Settings'),
];

Future<ValueNotifier<int>> _pumpTabBar(
  WidgetTester tester, {
  required GlobalKey rootKey,
  FushiGlassMaterial material = FushiGlassMaterial.standard,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ValueNotifier<int> index = ValueNotifier<int>(0);
  addTearDown(index.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        textTheme: Typography.material2021().black,
        glassDesign: true,
        glass: material,
      ).copyWith(platform: TargetPlatform.windows),
      home: FushiGlassScope(
        child: FushiFocusRoot(
          child: ValueListenableBuilder<int>(
            key: rootKey,
            valueListenable: index,
            builder: (BuildContext context, int current, _) =>
                AppleSidebarTabsShell(
                  items: _items,
                  currentIndex: current,
                  onTap: (int i) => index.value = i,
                  sections: const <AppleSidebarSection>[
                    AppleSidebarSection(indices: <int>[0, 1, 2]),
                  ],
                  footer: const <int>[3],
                  tabBar: true,
                  onToggle: () {},
                  child: const SizedBox.expand(),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return index;
}

FushiAppleSelectionLens _lens(WidgetTester tester) => tester
    .widget<FushiAppleSelectionLens>(find.byType(FushiAppleSelectionLens));

void _expectLensOver(WidgetTester tester, String label) {
  final FushiAppleSelectionLens lens = _lens(tester);
  final Rect text = tester.getRect(find.text(label));
  expect(lens.visible, isTrue);
  expect(lens.left, lessThanOrEqualTo(text.left));
  expect(lens.left + lens.width, greaterThanOrEqualTo(text.right));
  expect(lens.top, lessThanOrEqualTo(text.top));
  expect(lens.top + lens.height, greaterThanOrEqualTo(text.bottom));
}

void main() {
  group('Apple 宽窗顶部标签栏选中 lens', () {
    testWidgets('选中块是液态玻璃 lens：静止实色底，换项时透镜浮起滑到新项', (WidgetTester tester) async {
      final GlobalKey rootKey = GlobalKey();
      final ValueNotifier<int> index = await _pumpTabBar(
        tester,
        rootKey: rootKey,
      );
      expect(find.byType(FushiAppleSelectionLens), findsOneWidget);
      _expectLensOver(tester, 'Home');
      // 静止：没有透镜，只有实色 lens 底。
      expect(find.byType(AnimatedGlassIndicator), findsNothing);

      index.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // 滑动途中：着色器档浮起液态玻璃透镜。
      expect(find.byType(AnimatedGlassIndicator), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byType(AnimatedGlassIndicator), findsNothing);
      _expectLensOver(tester, 'Videos');
    });

    testWidgets('焦点 + Enter 切换目的地，lens 跟到新项', (WidgetTester tester) async {
      final GlobalKey rootKey = GlobalKey();
      final ValueNotifier<int> index = await _pumpTabBar(
        tester,
        rootKey: rootKey,
      );
      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        rootKey.currentContext!,
      );
      expect(controller.requestById(const FushiFocusId('nav-rail-1')), isTrue);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(index.value, 1);
      _expectLensOver(tester, 'Books');
      // 读屏语义与 tooltip 仍在目的地上（lens 层不吃语义）。
      final SemanticsHandle semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Books'), findsOneWidget);
      // Apple 档 FushiTooltip 的内层 Tooltip 只带玻璃气泡 WidgetSpan（message 为空），
      // find.byTooltip 认不出，按 FushiTooltip.message 找。
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is FushiTooltip && w.message == 'Books',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('实色档不出透镜，只滑实色 lens 底', (WidgetTester tester) async {
      final GlobalKey rootKey = GlobalKey();
      final ValueNotifier<int> index = await _pumpTabBar(
        tester,
        rootKey: rootKey,
        material: FushiGlassMaterial.off,
      );
      index.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(AnimatedGlassIndicator), findsNothing);
      await tester.pumpAndSettle();
      _expectLensOver(tester, 'Videos');
    });
  });

  testWidgets('M3E 主导航仍是 navShapeOf 多边形高亮，不出 Apple lens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: Row(
              children: <Widget>[
                Builder(
                  builder: (BuildContext context) => adaptiveNavRail(
                    context: context,
                    currentIndex: 1,
                    onTap: (_) {},
                    items: _items,
                  ),
                ),
                const Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FushiAppleSelectionLens), findsNothing);
    expect(
      tester
          .widgetList<NavMorphShape>(find.byType(NavMorphShape))
          .where((NavMorphShape w) => w.visible),
      hasLength(1),
    );
  });
}

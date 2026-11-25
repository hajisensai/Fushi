import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// Android app_smoke（Pixel 6 窄屏，MD3 悬浮底栏 + 出厂默认「相机模式条」）的
// 焦点陷阱复现：胶囊里 9 个目的地放不下（9 × 52 > 胶囊宽），条带溢出的格子
// 摆在胶囊右侧、与查词 FAB 同一列；焦点停到哪格条带就滚到哪格。底栏只有一个
// 阅读顺序（几何）遍历组时，FAB 在 Tab 序里的名次随条带滚动位置变化——焦点在
// nav-bar-8 → nav-bar-9 → FAB → nav-bar-8 里打转，当前项之前的目的地永远到不了。
//
// 底栏的遍历顺序必须是结构性的：胶囊里的目的地按条带顺序走完，再到 FAB（反转
// 底栏方向时 FAB 在前），与条带此刻滚到哪里无关。
void main() {
  // 与 CI 失败现场同形：10 个 tab，查词（第 8 个）拆成 FAB，其余 9 个进胶囊。
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.collections_outlined, label: '漫画'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.music_note_outlined, label: '音乐'),
    AdaptiveNavItem(icon: Icons.headphones_outlined, label: '听书'),
    AdaptiveNavItem(icon: Icons.sports_esports_outlined, label: '游戏'),
    AdaptiveNavItem(icon: Icons.search, label: '查词'),
    AdaptiveNavItem(icon: Icons.school_outlined, label: '复习'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];
  const int searchIndex = 7;

  /// 胶囊目的地 + FAB 的焦点 id（按视觉顺序，不含查词本身的 `nav-bar-7`）。
  /// Apple 设计系统里查词是胶囊旁的圆钮，焦点 id 仍是 `nav-bar-<序号>`。
  List<String> barIds({required bool reversed, bool glass = false}) {
    final int search = reversed ? items.length - 1 - searchIndex : searchIndex;
    final List<String> capsule = <String>[
      for (int i = 0; i < items.length; i++)
        if (i != search) 'nav-bar-$i',
    ];
    final String fab = glass ? 'nav-bar-$search' : 'nav-bar-fab';
    return reversed ? <String>[fab, ...capsule] : <String>[...capsule, fab];
  }

  /// 期望的底栏视觉顺序。相机模式条的溢出格摆在胶囊外（与 FAB 同列），静止
  /// 几何不代表视觉顺序，按结构给出；平铺样式不滚动，按静止时的横坐标排
  /// （放不下的目的地收进「更多」，`nav-bar-more` 也是一站）。
  List<String> expectedBarOrder(
    WidgetTester tester, {
    required AdaptiveNavBarStyle style,
    required bool reversed,
    bool glass = false,
  }) {
    if (style == AdaptiveNavBarStyle.modeStrip) {
      return barIds(reversed: reversed, glass: glass);
    }
    final List<FushiFocusTarget> targets = tester
        .widgetList<FushiFocusTarget>(
          find.descendant(
            of: find.byKey(fushiMaterialNavKey),
            matching: find.byType(FushiFocusTarget),
          ),
        )
        .where((FushiFocusTarget t) => t.id.value.startsWith('nav-bar-'))
        .toList();
    double x(FushiFocusTarget t) => tester
        .getCenter(
          find.byWidgetPredicate(
            (Widget w) => w is FushiFocusTarget && w.id == t.id,
          ),
        )
        .dx;
    targets.sort(
      (FushiFocusTarget a, FushiFocusTarget b) => x(a).compareTo(x(b)),
    );
    return <String>[for (final FushiFocusTarget t in targets) t.id.value];
  }

  /// 按首页 `_buildMobileLayout` 的组装方式泵出 Pixel 6 宽度（411dp）的壳：
  /// FushiFocusRoot 包在 Navigator 外（与 app 同构），正文顶部一排按钮，底栏
  /// 套 FocusTraversalGroup。[reversed] 对应「反转底栏方向」。
  Future<ValueNotifier<int>> pumpShell(
    WidgetTester tester, {
    required AdaptiveNavBarStyle style,
    required bool reversed,
    bool glass = false,
  }) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<AdaptiveNavItem> display = reversed
        ? items.reversed.toList()
        : items;
    final int search = reversed ? items.length - 1 - searchIndex : searchIndex;
    // 当前页 = 书架（第二个目的地），与 smoke 切到第二个 tab 后的状态一致。
    final ValueNotifier<int> current = ValueNotifier<int>(
      reversed ? items.length - 2 : 1,
    );
    addTearDown(current.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: glass ? FushiGlassMaterial.premium : FushiGlassMaterial.off,
          glassDesign: glass,
        ),
        themeAnimationDuration: Duration.zero,
        builder: (BuildContext context, Widget? child) =>
            FushiGlassScope(child: FushiFocusRoot(child: child!)),
        home: Scaffold(
          extendBody: true,
          body: FocusTraversalGroup(
            child: SafeArea(
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < 3; i++)
                    TextButton(onPressed: () {}, child: Text('head $i')),
                ],
              ),
            ),
          ),
          bottomNavigationBar: ValueListenableBuilder<int>(
            valueListenable: current,
            builder: (BuildContext context, int index, Widget? _) =>
                FocusTraversalGroup(
                  child: adaptiveBottomBar(
                    context: context,
                    currentIndex: index,
                    onTap: (int i) => current.value = i,
                    items: display,
                    glassSearchIndex: search,
                    showLabels: false,
                    searchLeading: reversed,
                    barStyle: style,
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return current;
  }

  FushiFocusController controllerOf(WidgetTester tester) =>
      FushiFocusRoot.controllerOf(tester.element(find.byType(Scaffold)));

  /// 从当前焦点连按 [steps] 次 Tab（每步等条带滚动动画落定），返回途经的
  /// 底栏焦点 id 序列（正文按钮记 `body`）。
  Future<List<String>> tabWalk(
    WidgetTester tester, {
    required int steps,
    bool backward = false,
  }) async {
    final FushiFocusController controller = controllerOf(tester);
    final List<String> seen = <String>[];
    for (int i = 0; i < steps; i++) {
      if (backward) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      if (backward) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.pumpAndSettle();
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      final FushiFocusId? id = controller.activeId;
      final bool onBar =
          id != null &&
          primary != null &&
          primary.context?.findAncestorWidgetOfExactType<FushiFocusTarget>() !=
              null &&
          id.value.startsWith('nav-bar-');
      seen.add(onBar ? id.value : 'body');
    }
    return seen;
  }

  for (final (AdaptiveNavBarStyle style, bool glass)
      in <(AdaptiveNavBarStyle, bool)>[
        (AdaptiveNavBarStyle.modeStrip, false),
        (AdaptiveNavBarStyle.flat, false),
        (AdaptiveNavBarStyle.modeStrip, true),
      ]) {
    for (final bool reversed in <bool>[false, true]) {
      final String name =
          '${glass ? 'Apple' : 'MD3'} ${style.name} / 反转${reversed ? '开' : '关'}';
      testWidgets('$name：Tab 一圈按视觉顺序走遍底栏全部目的地（含当前项之前的）', (
        WidgetTester tester,
      ) async {
        await pumpShell(tester, style: style, reversed: reversed, glass: glass);
        final List<String> expected = expectedBarOrder(
          tester,
          style: style,
          reversed: reversed,
          glass: glass,
        );
        final FushiFocusController controller = controllerOf(tester);
        // 从正文最后一个按钮出发：下一步进底栏，走完底栏再回到正文。
        expect(controller.requestById(FushiFocusId(expected.first)), isTrue);
        await tester.pumpAndSettle();
        final List<String> walk = await tabWalk(
          tester,
          steps: (expected.length + 3) * 2,
        );
        final List<String> bar = <String>[expected.first];
        for (final String id in walk) {
          if (id == 'body') {
            if (bar.length >= expected.length) break;
            continue;
          }
          bar.add(id);
          if (bar.length == expected.length) break;
        }
        expect(bar, expected, reason: 'Tab 序必须是结构性的视觉顺序；实际路径 $walk');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name：Shift+Tab 反向也能回到当前项之前的目的地', (
        WidgetTester tester,
      ) async {
        await pumpShell(tester, style: style, reversed: reversed, glass: glass);
        final List<String> expected = expectedBarOrder(
          tester,
          style: style,
          reversed: reversed,
          glass: glass,
        );
        final FushiFocusController controller = controllerOf(tester);
        expect(controller.requestById(FushiFocusId(expected.last)), isTrue);
        await tester.pumpAndSettle();
        final List<String> walk = await tabWalk(
          tester,
          steps: (expected.length + 3) * 2,
          backward: true,
        );
        final List<String> bar = <String>[expected.last];
        for (final String id in walk) {
          if (id == 'body') {
            if (bar.length >= expected.length) break;
            continue;
          }
          bar.add(id);
          if (bar.length == expected.length) break;
        }
        expect(
          bar,
          expected.reversed.toList(),
          reason: 'Shift+Tab 序必须是视觉顺序的逆序；实际路径 $walk',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}

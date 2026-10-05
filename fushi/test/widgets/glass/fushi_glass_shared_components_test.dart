import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

// 共享组件层「玻璃」设计系统分支的契约：
// ① MD3 下树里没有任何 liquid_glass_widgets 组件（MD3 路径零回归）；
// ② 玻璃下控件 / 浮层是 liquid 组件族、MD3 控件不出现；内容层（卡片、列表
//    行、设置分组、分隔线）按 Apple 26 规则是实色，不是玻璃；
// ③ 玻璃下焦点 + Enter 仍经同一条 ActivateIntent 链路激活；
// ④ 切换设计系统时，带 key 的导航节点与工具条里带 GlobalKey 的动作 Element
//    不被重建（结构恒定，见 FushiGlassBackdrop / _NavSurfaceBackdrop）。
void main() {
  ThemeData theme({required bool glass}) => buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
        glassDesign: glass,
      );

  /// liquid_glass_widgets 的组件 / 渲染类型（按类名前缀）。GlassTheme 是挂在
  /// app 根部的主题作用域，不是组件，排除在外。
  final RegExp liquidType = RegExp(
    r'^(Glass|Liquid|AdaptiveGlass|AdaptiveLiquid|LightweightLiquid|InheritedLiquid)',
  );
  Finder liquidWidgets() => find.byWidgetPredicate((Widget w) {
        final String name = w.runtimeType.toString();
        return liquidType.hasMatch(name) && !name.startsWith('GlassTheme');
      });

  Widget host(
    ThemeData data,
    Widget child, {
    bool focusRoot = false,
  }) {
    final Widget body = focusRoot ? FushiFocusRoot(child: child) : child;
    return MaterialApp(
      theme: data,
      themeAnimationDuration: Duration.zero,
      home: FushiGlassScope(
        child: Scaffold(body: body),
      ),
    );
  }

  Widget gallery() {
    final TextEditingController search = TextEditingController();
    final FocusNode searchFocus = FocusNode();
    return ListView(
      children: <Widget>[
        FushiCard(onTap: () {}, child: const Text('card')),
        FushiListItem(title: const Text('item'), onTap: () {}),
        FushiSearchField(
          controller: search,
          focusNode: searchFocus,
          hintText: 'search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
        const FushiTextField(hintText: 'text', labelText: 'label'),
        FushiSelectableChip(
          label: 'chip',
          selected: true,
          onSelected: (_) {},
        ),
        FushiActionChip(label: 'act', icon: Icons.add, onPressed: () {}),
        FushiTagChip(label: 'tag', onTap: () {}),
        const FushiTagChip(label: 'static-tag'),
        const FushiBadge(icon: Icons.star),
        const FushiPreviewSwitch(
          trackColor: Colors.teal,
          thumbColor: Colors.white,
        ),
        FushiOverflowMenu<int>(
          items: <PopupMenuEntry<int>>[
            FushiPopupMenuItem<int>(label: 'one', value: 1),
          ],
          onSelected: (_) {},
        ),
        const FushiPopupSurface(child: Text('popup')),
        SizedBox(
          height: 200,
          child: FushiModalSheetFrame(
            title: 'sheet',
            leadingIcon: Icons.info,
            footer: const Text('footer'),
            body: const Text('sheet body'),
          ),
        ),
        Builder(
          builder: (BuildContext context) => Row(
            children: <Widget>[
              adaptiveDialogAction(
                context: context,
                onPressed: () {},
                isDefaultAction: true,
                child: const Text('ok'),
              ),
              adaptiveSwitch(context: context, value: true, onChanged: (_) {}),
              SizedBox(
                width: 36,
                height: 36,
                child: adaptiveIndicator(context: context, value: 0.5),
              ),
            ],
          ),
        ),
        Builder(
          builder: (BuildContext context) => adaptiveSlider(
            context: context,
            value: 0.5,
            onChanged: (_) {},
          ),
        ),
        Builder(
          builder: (BuildContext context) => adaptiveSegmentedButton<int>(
            context: context,
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('A')),
              ButtonSegment<int>(value: 1, label: Text('B')),
            ],
            selected: const <int>{0},
            onSelectionChanged: (_) {},
          ),
        ),
        AdaptiveSettingsSection(
          title: 'section',
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              title: 'switch row',
              value: false,
              onChanged: (_) {},
            ),
            AdaptiveSettingsStepperRow(
              title: 'stepper row',
              value: 2,
              step: 1,
              min: 0,
              max: 10,
              format: (double v) => v.toStringAsFixed(0),
              onChanged: (_) {},
            ),
            AdaptiveSettingsPickerRow<int>(
              title: 'picker row',
              options: const <AdaptiveSettingsPickerOption<int>>[
                AdaptiveSettingsPickerOption<int>(value: 0, label: 'zero'),
                AdaptiveSettingsPickerOption<int>(value: 1, label: 'one'),
              ],
              selected: 0,
              onChanged: (_) {},
            ),
            AdaptiveSettingsNavigationRow(title: 'nav row', onTap: () {}),
          ],
        ),
        SettingsFormField(label: 'form', onChanged: (_) {}),
      ],
    );
  }

  Future<void> pumpGallery(WidgetTester tester, {required bool glass}) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(theme(glass: glass), gallery()));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('① MD3 renders no liquid_glass_widgets component', (
    WidgetTester tester,
  ) async {
    await pumpGallery(tester, glass: false);
    expect(liquidWidgets(), findsNothing);
    // MD3 原控件照旧在。
    expect(find.byType(Switch), findsWidgets);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.byType(ChoiceChip), findsOneWidget);
    // MD3 进度是 M3 Expressive 波浪环（自绘）。
    expect(find.byType(FushiWavyCircularProgress), findsOneWidget);
    // 溢出菜单是 FushiPopupMenuButton（PopupMenuButton 子类，MD3 下走父类
    // build 的 Material 按钮）。
    expect(
      find.byWidgetPredicate((Widget w) => w is PopupMenuButton<int>),
      findsOneWidget,
    );
  });

  testWidgets('② glass renders the liquid component family, no MD3 controls', (
    WidgetTester tester,
  ) async {
    await pumpGallery(tester, glass: true);
    // 内容层实色：卡片 / 设置分组 = FushiAppleGroupSurface，列表行 =
    // FushiAppleRow，没有 GlassCard / GlassListTile / 玻璃分隔线。
    expect(find.byType(GlassCard), findsNothing);
    expect(find.byType(GlassListTile), findsNothing);
    expect(find.byType(FushiAppleGroupSurface), findsWidgets);
    // 卡片点击面 / 设置行 / 列表行都是 FushiAppleRow；列表项本身也在其中。
    expect(find.byType(FushiAppleRow), findsWidgets);
    expect(
      find.ancestor(of: find.text('item'), matching: find.byType(FushiAppleRow)),
      findsOneWidget,
    );
    // 输入框与 chip 也是内容层实色控件（FushiTextFieldControl /
    // fushiAppleChip），不是玻璃。
    expect(find.byType(GlassChip), findsNothing);
    expect(find.byType(GlassContainer), findsWidgets);
    expect(find.byType(FushiAppleSwitch), findsWidgets);
    expect(find.byType(FushiAppleSlider), findsOneWidget);
    // 分段控件两处：adaptiveSegmentedButton 本身 + 选项短、放得下的设置
    // 选择行（iOS 设置口径：短选项行内分段，长选项才是弹出菜单按钮）。
    expect(find.byType(FushiAppleSegmentedControl), findsNWidgets(2));
    expect(find.byType(GlassStepper), findsOneWidget);
    // 设置行的选择器是 Apple 分段控件 / 弹出菜单按钮（当前值 + 上下箭头 →
    // 玻璃菜单），不再是 GlassPicker 玻璃字段。
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('picker row'),
          matching: find.byType(AdaptiveSettingsPickerRow<int>),
        ),
        matching: find.byType(AppleSettingsSegmentedControl),
      ),
      findsOneWidget,
    );
    expect(find.byType(GlassPicker), findsNothing);
    // 确定进度是 Apple 细圆环（内容层，不是玻璃）。
    expect(find.byType(FushiAppleProgressRing), findsOneWidget);
    // 溢出菜单：FushiPopupMenuButton 的 Apple 分支是纯图标触发器（FushiIcon，
    // 打开 showFushiMenu 的玻璃菜单路由），没有 Material IconButton。
    final Finder overflow = find.byWidgetPredicate(
      (Widget w) => w is FushiPopupMenuButton<int>,
    );
    expect(overflow, findsOneWidget);
    expect(
      find.descendant(of: overflow, matching: find.byType(FushiIcon)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overflow, matching: find.byType(IconButton)),
      findsNothing,
    );
    expect(find.byType(GlassDivider), findsNothing);
    expect(find.byType(GlassButton), findsWidgets);

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  group('③ glass focus + Enter activates', () {
    FocusNode targetNodeOf(WidgetTester tester, Finder target) {
      final Focus focus = tester.widget<Focus>(
        find
            .descendant(
              of: find
                  .ancestor(of: target, matching: find.byType(FushiFocusTarget))
                  .first,
              matching: find.byType(Focus),
            )
            .first,
      );
      return focus.focusNode!;
    }

    testWidgets('FushiListItem', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          theme(glass: true),
          FushiListItem(
            title: const Text('row'),
            onTap: () => taps++,
          ),
          focusRoot: true,
        ),
      );
      await tester.pump();
      expect(find.byType(FushiAppleRow), findsOneWidget);
      targetNodeOf(tester, find.text('row')).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('adaptiveDialogAction', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          theme(glass: true),
          Builder(
            builder: (BuildContext context) => adaptiveDialogAction(
              context: context,
              onPressed: () => taps++,
              isDefaultAction: true,
              child: const Text('confirm'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(GlassButton), findsOneWidget);
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byType(GlassButton),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
    });

    testWidgets('settings switch row', (WidgetTester tester) async {
      bool value = false;
      await tester.pumpWidget(
        host(
          theme(glass: true),
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                AdaptiveSettingsSwitchRow(
              title: 'toggle me',
              value: value,
              onChanged: (bool next) => setState(() => value = next),
            ),
          ),
          focusRoot: true,
        ),
      );
      await tester.pump();
      expect(find.byType(FushiAppleSwitch), findsOneWidget);
      targetNodeOf(tester, find.text('toggle me')).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(value, isTrue);
    });
  });

  testWidgets(
    '④ switching the design system keeps keyed nav / toolbar elements',
    (WidgetTester tester) async {
      final GlobalKey actionKey = GlobalKey(debugLabel: 'toolbar-action');
      late StateSetter setOuter;
      bool glass = false;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return MaterialApp(
              theme: theme(glass: glass),
              themeAnimationDuration: Duration.zero,
              home: FushiGlassScope(
                child: FushiFocusRoot(
                  child: FushiToolScaffold(
                    title: 'tool',
                    actions: <Widget>[
                      SizedBox(key: actionKey, width: 24, height: 24),
                    ],
                    body: const SizedBox.expand(),
                    bottomNavigationBar: Builder(
                      builder: (BuildContext context) => adaptiveBottomBar(
                        context: context,
                        currentIndex: 0,
                        onTap: (_) {},
                        items: const <AdaptiveNavItem>[
                          AdaptiveNavItem(icon: Icons.book, label: 'Books'),
                          AdaptiveNavItem(icon: Icons.search, label: 'Dict'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final Element navBefore = tester.element(find.byKey(fushiMaterialNavKey));
      final Element actionBefore = tester.element(find.byKey(actionKey));
      final Rect navRect = tester.getRect(find.byKey(fushiMaterialNavKey));
      expect(liquidWidgets(), findsNothing);

      setOuter(() => glass = true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GlassContainer), findsWidgets);
      expect(
        identical(tester.element(find.byKey(fushiMaterialNavKey)), navBefore),
        isTrue,
      );
      expect(identical(tester.element(find.byKey(actionKey)), actionBefore),
          isTrue);
      // 玻璃底栏是悬浮胶囊（离底 ≥16、胶囊 62 高），比 MD3 底栏高；同一个
      // Material 元素只是换了几何。
      expect(
        tester.getRect(find.byKey(fushiMaterialNavKey)).height,
        greaterThanOrEqualTo(kGlassNavBarCapsuleHeight + 16),
      );

      setOuter(() => glass = false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        identical(tester.element(find.byKey(fushiMaterialNavKey)), navBefore),
        isTrue,
      );
      expect(identical(tester.element(find.byKey(actionKey)), actionBefore),
          isTrue);
      expect(tester.getRect(find.byKey(fushiMaterialNavKey)), navRect);
      expect(liquidWidgets(), findsNothing);
    },
  );

  group('⑤ glass navigation shell (Apple 26)', () {
    const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
      AdaptiveNavItem(icon: Icons.home, label: 'Home'),
      AdaptiveNavItem(icon: Icons.book, label: 'Books'),
      AdaptiveNavItem(icon: Icons.settings, label: 'Settings'),
    ];

    Future<int> pumpRail(
      WidgetTester tester, {
      required bool glass,
      required bool extended,
    }) async {
      int tapped = -1;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(glass: glass),
          themeAnimationDuration: Duration.zero,
          home: FushiGlassScope(
            child: FushiFocusRoot(
              child: Scaffold(
                body: Row(
                  children: <Widget>[
                    Builder(
                      builder: (BuildContext context) => adaptiveNavRail(
                        context: context,
                        currentIndex: 0,
                        onTap: (int i) => tapped = i,
                        items: items,
                        extended: extended,
                      ),
                    ),
                    const Expanded(child: SizedBox.expand()),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      return tapped;
    }

    // MD3 Expressive：宽窗口是图标 + 文字横排的展开 rail（200），窄窗口收成
    // 80 宽的收起 rail；与标题栏缩进用的 adaptiveNavRailWidthFor 同一口径。
    testWidgets('MD3 rail: expanded 200 when extended, 80 when collapsed', (
      WidgetTester tester,
    ) async {
      await pumpRail(tester, glass: false, extended: true);
      expect(
        tester.getSize(find.byKey(fushiMaterialNavKey)).width,
        kMaterialNavRailExpandedWidth,
      );
      expect(liquidWidgets(), findsNothing);
      await pumpRail(tester, glass: false, extended: false);
      expect(
        tester.getSize(find.byKey(fushiMaterialNavKey)).width,
        kAdaptiveNavRailWidth,
      );
      expect(liquidWidgets(), findsNothing);
    });

    testWidgets('glass extended sidebar: floating panel, icon + label rows', (
      WidgetTester tester,
    ) async {
      await pumpRail(tester, glass: true, extended: true);
      expect(
        tester.getSize(find.byKey(fushiMaterialNavKey)).width,
        kGlassNavSidebarWidth,
      );
      // 悬浮玻璃面板离窗口边 8。
      final Rect panel = tester.getRect(find.byType(GlassContainer).first);
      expect(panel.left, 8);
      expect(panel.top, 8);
      // 行是横排：图标在文字左边、同一水平线。
      final Rect icon = tester.getRect(_fushiIcon(Icons.book));
      final Rect label = tester.getRect(find.text('Books'));
      expect(icon.right, lessThan(label.left));
      expect((icon.center.dy - label.center.dy).abs(), lessThan(2));
    });

    testWidgets('glass collapsed sidebar is an icon-only strip', (
      WidgetTester tester,
    ) async {
      await pumpRail(tester, glass: true, extended: false);
      expect(
        tester.getSize(find.byKey(fushiMaterialNavKey)).width,
        kAdaptiveNavRailWidth,
      );
      expect(find.text('Books'), findsNothing);
      expect(_fushiIcon(Icons.book), findsOneWidget);
    });

    testWidgets('glass sidebar row: focus + Enter selects', (
      WidgetTester tester,
    ) async {
      int tapped = -1;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(glass: true),
          themeAnimationDuration: Duration.zero,
          home: FushiGlassScope(
            child: FushiFocusRoot(
              child: Scaffold(
                body: Row(
                  children: <Widget>[
                    Builder(
                      builder: (BuildContext context) => adaptiveNavRail(
                        context: context,
                        currentIndex: 0,
                        onTap: (int i) => tapped = i,
                        items: items,
                      ),
                    ),
                    const Expanded(child: SizedBox.expand()),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final Focus focus = tester.widget<Focus>(
        find
            .descendant(
              of: find
                  .ancestor(
                    of: find.text('Settings'),
                    matching: find.byType(FushiFocusTarget),
                  )
                  .first,
              matching: find.byType(Focus),
            )
            .first,
      );
      focus.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tapped, 2);
    });
  });
}

/// 玻璃设计系统下 [FushiIcon] 把 Material 图标映射成 SF 风格字形，按调用点
/// 传入的原始图标找它。
Finder _fushiIcon(IconData icon) => find.byWidgetPredicate(
      (Widget w) => w is FushiIcon && w.icon == icon,
    );

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 共享组件层「玻璃」设计系统分支的契约：
// ① MD3 下树里没有任何 liquid_glass_widgets 组件（MD3 路径零回归）；
// ② 玻璃下渲染的是 liquid 组件族，MD3 控件不出现；
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
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(PopupMenuButton<int>), findsOneWidget);
  });

  testWidgets('② glass renders the liquid component family, no MD3 controls', (
    WidgetTester tester,
  ) async {
    await pumpGallery(tester, glass: true);
    expect(find.byType(GlassCard), findsWidgets);
    expect(find.byType(GlassListTile), findsOneWidget);
    expect(find.byType(GlassTextField), findsWidgets);
    expect(find.byType(GlassChip), findsWidgets);
    expect(find.byType(GlassContainer), findsWidgets);
    expect(find.byType(GlassSwitch), findsWidgets);
    expect(find.byType(GlassSlider), findsOneWidget);
    expect(find.byType(GlassSegmentedControl), findsOneWidget);
    expect(find.byType(GlassStepper), findsOneWidget);
    expect(find.byType(GlassPicker), findsOneWidget);
    expect(find.byType(GlassProgressIndicator), findsOneWidget);
    expect(find.byType(GlassMenu), findsWidgets);
    expect(find.byType(GlassDivider), findsWidgets);
    expect(find.byType(GlassButton), findsWidgets);

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PopupMenuButton<int>), findsNothing);
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
      expect(find.byType(GlassListTile), findsOneWidget);
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
      expect(find.byType(GlassSwitch), findsOneWidget);
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
      expect(tester.getRect(find.byKey(fushiMaterialNavKey)), navRect);

      setOuter(() => glass = false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        identical(tester.element(find.byKey(fushiMaterialNavKey)), navBefore),
        isTrue,
      );
      expect(identical(tester.element(find.byKey(actionKey)), actionBefore),
          isTrue);
      expect(liquidWidgets(), findsNothing);
    },
  );
}

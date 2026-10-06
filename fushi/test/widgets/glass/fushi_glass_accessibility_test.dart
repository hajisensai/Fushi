import 'dart:ui' show Tristate;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassButton;

// 「玻璃」设计系统的可达性契约：
// ① 焦点导航实验开关关闭（树里没有 FushiFocusRoot）时，可点卡片、纯导航设置
//    行、折叠分组头与 MD3（InkWell）一样是原生 Tab 停靠点，Enter 激活，并画
//    强调色焦点描边（FushiAppleRow）；
// ② 内部 GestureDetector 排除了语义的控件（分段单元格、多选分段、菜单行、液态
//    玻璃 chip），外层按钮语义自带 tap 动作，读屏可激活；禁用时不给 tap；
// ③ 玻璃 chip 语义带 selected；禁用的复选框语义带 enabled=false。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.liquid,
          glassDesign: true,
        ),
        themeAnimationDuration: Duration.zero,
        home: FushiGlassScope(
          child: Scaffold(body: ListView(children: <Widget>[child])),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tabThenEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// [finder] 所在的按钮语义节点：文字可能落在按钮节点下的子节点里（液态
  /// 玻璃 chip 的 GlassButton 内部自带一个可聚焦节点），向上找到第一个
  /// isButton 节点；找不到就返回文字自己的节点。
  SemanticsNode buttonNodeOf(WidgetTester tester, Finder finder) {
    final SemanticsNode start = tester.getSemantics(finder);
    SemanticsNode? node = start;
    while (node != null) {
      if (node.getSemanticsData().flagsCollection.isButton) return node;
      node = node.parent;
    }
    return start;
  }

  SemanticsData semanticsOf(WidgetTester tester, Finder finder) =>
      buttonNodeOf(tester, finder).getSemanticsData();

  void performTap(WidgetTester tester, Finder finder) {
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      buttonNodeOf(tester, finder).id,
      SemanticsAction.tap,
    );
  }

  group('① no FushiFocusRoot: Tab reaches, Enter activates', () {
    testWidgets('FushiCard', (WidgetTester tester) async {
      int taps = 0;
      await pump(
        tester,
        FushiCard(onTap: () => taps++, child: const Text('card')),
      );
      expect(
        find.ancestor(
          of: find.text('card'),
          matching: find.byType(FushiAppleRow),
        ),
        findsOneWidget,
      );
      await tabThenEnter(tester);
      expect(taps, 1);
      expect(
        Focus.of(tester.element(find.text('card'))).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('settings navigation row', (WidgetTester tester) async {
      int taps = 0;
      await pump(
        tester,
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsNavigationRow(
              title: 'nav row',
              onTap: () => taps++,
            ),
          ],
        ),
      );
      await tabThenEnter(tester);
      expect(taps, 1);
    });

    testWidgets('collapsible section header', (WidgetTester tester) async {
      final List<bool> changes = <bool>[];
      await pump(
        tester,
        AdaptiveSettingsSection(
          title: 'Group',
          titlePlacement: SettingsSectionTitlePlacement.inside,
          collapsible: true,
          onExpansionChanged: changes.add,
          children: const <Widget>[AdaptiveSettingsRow(title: 'static row')],
        ),
      );
      await tabThenEnter(tester);
      expect(changes, <bool>[false]);
    });
  });

  group('② button semantics carry a tap action', () {
    testWidgets('segmented control cell (single select)', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      Set<String> selected = <String>{'a'};
      await pump(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              FushiSegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'a', label: Text('Alpha')),
                  ButtonSegment<String>(value: 'b', label: Text('Beta')),
                ],
                selected: selected,
                onSelectionChanged: (Set<String> s) =>
                    setState(() => selected = s),
              ),
        ),
      );
      expect(find.byType(FushiAppleSegmentedControl), findsOneWidget);
      final SemanticsData beta = semanticsOf(tester, find.text('Beta'));
      expect(beta.hasAction(SemanticsAction.tap), isTrue);
      performTap(tester, find.text('Beta'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected, <String>{'b'});
      handle.dispose();
    });

    testWidgets('multi-select segment', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      Set<String> selected = <String>{'a'};
      await pump(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              FushiSegmentedButton<String>(
                multiSelectionEnabled: true,
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'a', label: Text('Alpha')),
                  ButtonSegment<String>(value: 'b', label: Text('Beta')),
                ],
                selected: selected,
                onSelectionChanged: (Set<String> s) =>
                    setState(() => selected = s),
              ),
        ),
      );
      expect(find.byType(FushiAppleSegmentedControl), findsNothing);
      final SemanticsData beta = semanticsOf(tester, find.text('Beta'));
      expect(beta.hasAction(SemanticsAction.tap), isTrue);
      performTap(tester, find.text('Beta'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected, <String>{'a', 'b'});
      handle.dispose();
    });

    testWidgets('menu row (FushiSimpleDialogOption)', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      int taps = 0;
      await pump(
        tester,
        Column(
          children: <Widget>[
            FushiSimpleDialogOption(
              onPressed: () => taps++,
              child: const Text('pick'),
            ),
            const FushiSimpleDialogOption(child: Text('disabled')),
          ],
        ),
      );
      expect(
        semanticsOf(tester, find.text('pick')).hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(
        semanticsOf(
          tester,
          find.text('disabled'),
        ).hasAction(SemanticsAction.tap),
        isFalse,
      );
      performTap(tester, find.text('pick'));
      await tester.pump();
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('liquid glass chip: tap + selected', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<bool> picks = <bool>[];
      await pump(
        tester,
        Wrap(
          children: <Widget>[
            FushiChoiceChip(
              label: const Text('on'),
              selected: true,
              onSelected: picks.add,
            ),
            FushiChoiceChip(
              label: const Text('off'),
              selected: false,
              onSelected: picks.add,
            ),
          ],
        ),
      );
      expect(find.byType(GlassButton), findsNWidgets(2));
      final SemanticsData on = semanticsOf(tester, find.text('on'));
      final SemanticsData off = semanticsOf(tester, find.text('off'));
      expect(on.hasAction(SemanticsAction.tap), isTrue);
      expect(on.flagsCollection.isSelected, Tristate.isTrue);
      expect(off.flagsCollection.isSelected, Tristate.isFalse);
      performTap(tester, find.text('off'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(picks, <bool>[true]);
      handle.dispose();
    });
  });

  testWidgets('③ disabled glass checkbox reports enabled=false', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pump(
      tester,
      const Row(
        children: <Widget>[FushiCheckbox(value: true, onChanged: null)],
      ),
    );
    final SemanticsData data = semanticsOf(tester, find.byType(FushiCheckbox));
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    handle.dispose();
  });
}

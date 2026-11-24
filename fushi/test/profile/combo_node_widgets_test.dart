import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/profile/combo/combo_node_widgets.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:material_ui/material_ui.dart';

/// 组合阶段 6 的节点件：MD3 与 Apple 两套都能渲染、带按压动效、点行展开生效值、动作可点；树上每个
/// 子组都有界面名。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget host(Widget child, {required bool apple}) => TranslationProvider(
    child: MaterialApp(
      theme: apple
          ? ThemeData(
              platform: TargetPlatform.iOS,
              extensions: const <ThemeExtension<dynamic>>[
                FushiDesignSystemTheme(FushiDesignSystem.cupertino),
              ],
            )
          : ThemeData(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  for (final bool apple in <bool>[false, true]) {
    testWidgets('叶子行：状态胶囊 + 动作 + 点开看值（${apple ? 'Apple' : 'MD3'}）', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          ComboLeafTile(
            leafId: FushiComboNode.appearanceTheme,
            split: true,
            values: <SettingKey, String>{
              const SettingKey('pref', 'design_system'): 's:glass',
            },
            subtitle: 'Work: Book',
            actionLabel: t.profile_combo_action_restore,
            onAction: () => taps++,
          ),
          apple: apple,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(FushiPressScale), findsWidgets);
      expect(find.text(t.profile_combo_state_split), findsOneWidget);
      expect(find.text(t.profile_combo_leaf_appearance_theme), findsOneWidget);
      expect(find.textContaining('design_system = glass'), findsNothing);

      await tester.tap(find.text(t.profile_combo_leaf_appearance_theme));
      await tester.pumpAndSettle();
      expect(find.textContaining('design_system = glass'), findsOneWidget);

      await tester.tap(find.text(t.profile_combo_action_restore));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  }

  testWidgets('继承中的叶子显示「继承」，没有值显示未设置', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        const ComboLeafTile(
          leafId: FushiComboNode.dictionary,
          split: false,
          values: <SettingKey, String>{},
        ),
        apple: false,
      ),
    );
    expect(find.text(t.profile_combo_state_inherited), findsOneWidget);
    await tester.tap(find.text(t.profile_combo_leaf_dictionary));
    await tester.pumpAndSettle();
    expect(find.text(t.profile_combo_value_unset), findsOneWidget);
  });

  test('树上每个子组都有界面名', () {
    for (final SettingsNode root in fushiSettingsTree.roots) {
      if (root.isLeaf) continue;
      expect(comboGroupLabel(root.id), isNot(root.id), reason: root.id);
    }
  });
}

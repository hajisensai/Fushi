import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

Widget _buildHarness({
  required TargetPlatform platform,
  required Widget child,
}) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: platform,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: child,
  );
}

void _noopString(String value) {}

void _noopDouble(double value) {}

String _formatNumber(double value) => value.round().toString();

void main() {
  test('settings shared chrome uses design token radii and typography', () {
    final String source = File('lib/src/utils/components/settings_shared.dart')
        .readAsStringSync();

    expect(source, contains('tokens.radii.groupRadius'));
    expect(source, contains('tokens.radii.controlRadius'));
    expect(source, contains('tokens.type.metadata'));
    expect(source, isNot(contains('BorderRadius.circular(12)')));
    expect(source, isNot(contains('BorderRadius.circular(7)')));
    expect(source, isNot(contains('fontSize: 12')));
    expect(source, isNot(contains('fontSize: 16')));
  });

  test('settings sections can opt into putting the title inside the surface',
      () {
    final String source = File('lib/src/utils/components/settings_shared.dart')
        .readAsStringSync();

    expect(source, contains('class AdaptiveSettingsSurface'),
        reason: 'shared settings surfaces should be reusable beyond row lists');
    expect(source, contains('enum SettingsSectionTitlePlacement'));
    expect(source, contains('SettingsSectionTitlePlacement.inside'));
  });

  testWidgets('switch rows use Material switch on Android', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              title: 'Behavior',
              children: [
                AdaptiveSettingsSwitchRow(
                  title: 'Highlight on tap',
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(CupertinoSwitch), findsNothing);
  });

  testWidgets('Material settings sections use shared MD3 card shell',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: Scaffold(
          body: AdaptiveSettingsSection(
            title: 'Behavior',
            children: [
              AdaptiveSettingsSwitchRow(
                title: 'Highlight on tap',
                value: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    final ColorScheme scheme = Theme.of(
      tester.element(find.byType(AdaptiveSettingsSection)),
    ).colorScheme;
    final HibikiCard card = tester.widget<HibikiCard>(find.byType(HibikiCard));
    expect(card.color, scheme.surfaceContainer);
    expect(card.borderColor, scheme.outlineVariant);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('Material contained section title shares the row surface',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: Scaffold(
          body: AdaptiveSettingsSection(
            title: 'Behavior',
            titlePlacement: SettingsSectionTitlePlacement.inside,
            children: [
              AdaptiveSettingsSwitchRow(
                title: 'Highlight on tap',
                value: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(HibikiCard), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Behavior'),
        matching: find.byType(HibikiCard),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Highlight on tap'),
        matching: find.byType(HibikiCard),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Material setting leading icons use shared MD3 badge shell',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: Scaffold(
          body: AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsNavigationRow(
                title: 'Advanced',
                icon: Icons.tune_outlined,
                showIcon: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(HibikiBadge), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
  });

  testWidgets('leaf setting rows omit leading icons by default',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsSwitchRow(
                  title: 'Highlight on tap',
                  icon: Icons.touch_app_outlined,
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.touch_app_outlined), findsNothing);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('navigation rows omit leading icons by default', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsNavigationRow(
                  title: 'Advanced',
                  icon: Icons.tune_outlined,
                  onTap: () {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.tune_outlined), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('navigation rows can opt in to leading icons', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsNavigationRow(
                  title: 'Advanced',
                  icon: Icons.tune_outlined,
                  showIcon: true,
                  onTap: () {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
  });

  testWidgets('switch rows use Cupertino switch on iOS', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.iOS,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              title: 'Behavior',
              children: [
                AdaptiveSettingsSwitchRow(
                  title: 'Highlight on tap',
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(HibikiCard), findsNothing);
    expect(find.byType(CupertinoPageScaffold), findsOneWidget);
    expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);
    expect(find.text('完成'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('segmented rows use Material segmented button on Android',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsSegmentedRow<String>(
                  title: 'Spread mode',
                  segments: const [
                    ButtonSegment(
                        value: 'off', label: Text('Off'), tooltip: 'Off'),
                    ButtonSegment(
                        value: 'on', label: Text('On'), tooltip: 'On'),
                    ButtonSegment(
                        value: 'auto', label: Text('Auto'), tooltip: 'Auto'),
                  ],
                  selected: 'auto',
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CupertinoSlidingSegmentedControl,
      ),
      findsNothing,
    );
  });

  testWidgets('segmented rows use Cupertino segmented control on iOS',
      (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.iOS,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsSegmentedRow<String>(
                  title: 'Spread mode',
                  segments: const [
                    ButtonSegment(
                        value: 'off', label: Text('Off'), tooltip: 'Off'),
                    ButtonSegment(
                        value: 'on', label: Text('On'), tooltip: 'On'),
                    ButtonSegment(
                        value: 'auto', label: Text('Auto'), tooltip: 'Auto'),
                  ],
                  selected: 'auto',
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is CupertinoSlidingSegmentedControl,
      ),
      findsOneWidget,
    );
    expect(find.byType(SegmentedButton<String>), findsNothing);
  });

  testWidgets('picker rows use Material dropdown on Android', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsPickerRow<String>(
                  title: 'Deck',
                  selected: 'default',
                  options: const [
                    AdaptiveSettingsPickerOption(
                      value: 'default',
                      label: 'Default',
                    ),
                    AdaptiveSettingsPickerOption(
                      value: 'news',
                      label: 'News',
                    ),
                  ],
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byType(DropdownMenu<int>), findsOneWidget);
    expect(find.byType(CupertinoButton), findsNothing);
  });

  testWidgets('narrow non-flex trailing rows stack without overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.android,
        child: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(2),
          ),
          child: const Scaffold(
            body: SizedBox(
              width: 320,
              child: AdaptiveSettingsSection(
                children: [
                  AdaptiveSettingsPickerRow<String>(
                    title: 'Picture fit',
                    selected: 'cover',
                    options: [
                      AdaptiveSettingsPickerOption(
                        value: 'cover',
                        label: 'Cover',
                      ),
                      AdaptiveSettingsPickerOption(
                        value: 'contain',
                        label: 'Contain',
                      ),
                    ],
                    onChanged: _noopString,
                  ),
                  AdaptiveSettingsStepperRow(
                    title: 'Maximum active comments',
                    value: 30,
                    step: 10,
                    min: 10,
                    max: 100,
                    format: _formatNumber,
                    onChanged: _noopDouble,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final Rect label = tester.getRect(find.text('Picture fit').first);
    final Rect dropdown = tester.getRect(find.byType(DropdownMenu<int>));
    expect(dropdown.top, greaterThanOrEqualTo(label.bottom - 0.5),
        reason: 'narrow picker trailing should move below the label');
  });

  testWidgets('picker rows use Cupertino action sheet on iOS', (tester) async {
    String selected = 'default';

    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.iOS,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsPickerRow<String>(
                  title: 'Deck',
                  selected: selected,
                  options: const [
                    AdaptiveSettingsPickerOption(
                      value: 'default',
                      label: 'Default',
                    ),
                    AdaptiveSettingsPickerOption(
                      value: 'news',
                      label: 'News',
                    ),
                  ],
                  onChanged: (value) => selected = value,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.byType(DropdownMenu<int>), findsNothing);
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.text('Deck'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoActionSheet), findsOneWidget);

    await tester.tap(find.text('News').last);
    await tester.pumpAndSettle();

    expect(selected, 'news');
  });

  testWidgets('desktop picker uses a gamepad-enterable MenuAnchor dropdown',
      (tester) async {
    String selected = 'news';
    await tester.pumpWidget(
      _buildHarness(
        platform: TargetPlatform.windows,
        child: AdaptiveSettingsScaffold(
          title: const Text('Reader settings'),
          children: [
            AdaptiveSettingsSection(
              children: [
                AdaptiveSettingsPickerRow<String>(
                  title: 'Deck',
                  selected: selected,
                  options: const [
                    AdaptiveSettingsPickerOption(
                        value: 'default', label: 'Default'),
                    AdaptiveSettingsPickerOption(value: 'news', label: 'News'),
                    AdaptiveSettingsPickerOption(value: 'work', label: 'Work'),
                  ],
                  onChanged: (value) => selected = value,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    // Desktop must NOT use the stock DropdownMenu (gamepad can't enter it) nor
    // the Cupertino sheet — it uses a MenuAnchor inline dropdown.
    expect(find.byType(DropdownMenu<int>), findsNothing);
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.byType(MenuAnchor), findsOneWidget);

    // Open the dropdown (the trigger shows the selected label).
    await tester.tap(find.widgetWithText(OutlinedButton, 'News'));
    await tester.pumpAndSettle();

    // The selected entry autofocuses so a gamepad lands INSIDE the menu; others
    // do not. (autofocus is what drives focus into the menu on open.)
    final MenuItemButton newsItem =
        tester.widget(find.widgetWithText(MenuItemButton, 'News'));
    final MenuItemButton defaultItem =
        tester.widget(find.widgetWithText(MenuItemButton, 'Default'));
    expect(newsItem.autofocus, isTrue);
    expect(defaultItem.autofocus, isFalse);

    // A non-B button is NOT consumed by the per-item Actions (returns null), so
    // the GamepadService fallback still runs (A→ActivateIntent, dpad→focus).
    final BuildContext itemCtx = tester.element(find.text('Work'));
    expect(
      Actions.invoke(itemCtx, const GamepadButtonIntent(GamepadButton.a)),
      isNull,
    );

    // Gamepad B IS consumed (returns true so the GamepadService skips maybePop —
    // i.e. it must NOT pop the whole settings page) and closes the menu,
    // returning focus to the trigger.
    final Object? bResult =
        Actions.invoke(itemCtx, const GamepadButtonIntent(GamepadButton.b));
    expect(bResult, isTrue);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Work'), findsNothing);
  });
}

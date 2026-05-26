import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
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
                    ButtonSegment(value: 'off', label: Text('Off'), tooltip: 'Off'),
                    ButtonSegment(value: 'on', label: Text('On'), tooltip: 'On'),
                    ButtonSegment(value: 'auto', label: Text('Auto'), tooltip: 'Auto'),
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
                    ButtonSegment(value: 'off', label: Text('Off'), tooltip: 'Off'),
                    ButtonSegment(value: 'on', label: Text('On'), tooltip: 'On'),
                    ButtonSegment(value: 'auto', label: Text('Auto'), tooltip: 'Auto'),
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
}

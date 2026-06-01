import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

SettingsDestination _fixtureDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: 'Appearance',
    icon: Icons.palette_outlined,
    summary: 'Visual style',
    sections: <SettingsSection>[
      SettingsSection(
        title: 'Controls',
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'advanced',
            title: 'Advanced',
            icon: Icons.tune_outlined,
            builder: (_) => const SizedBox.shrink(),
          ),
          SettingsNavigationItem(
            id: 'advanced_with_icon',
            title: 'Advanced with icon',
            icon: Icons.settings_suggest_outlined,
            showIcon: true,
            builder: (_) => const SizedBox.shrink(),
          ),
          SettingsActionItem(
            id: 'action',
            title: 'Action',
            icon: Icons.play_arrow_outlined,
            onTap: (_) {},
          ),
          SettingsSwitchItem(
            id: 'toggle',
            title: 'Toggle',
            icon: Icons.toggle_on_outlined,
            value: (_) => true,
            onChanged: (_, __) {},
          ),
          SettingsSegmentedItem<String>(
            id: 'segmented',
            title: 'Mode',
            options: <SettingsSegmentOption<String>>[
              const SettingsSegmentOption<String>(
                value: 'auto',
                label: 'Auto',
                icon: Icons.brightness_auto_outlined,
              ),
              const SettingsSegmentOption<String>(
                value: 'on',
                label: 'On',
                icon: Icons.check_outlined,
              ),
            ],
            selected: (_) => 'auto',
            onChanged: (_, __) {},
          ),
          SettingsSliderItem(
            id: 'slider',
            title: 'Slider',
            icon: Icons.linear_scale_outlined,
            value: (_) => 0.5,
            divisions: 4,
            label: (double value) => value.toStringAsFixed(1),
            onChanged: (_, __) {},
          ),
          SettingsStepperItem(
            id: 'stepper',
            title: 'Stepper',
            icon: Icons.exposure_outlined,
            value: (_) => 2,
            step: 1,
            min: 0,
            max: 4,
            format: (double value) => value.toStringAsFixed(0),
            onChanged: (_, __) {},
          ),
          SettingsCustomItem(
            id: 'custom',
            title: 'Custom',
            builder: (_) => const Text('Custom builder content'),
          ),
        ],
      ),
    ],
  );
}

Widget _buildHome(
  CupertinoThemeData? cupertinoTheme,
  Widget Function(SettingsContext) builder,
) {
  Widget child = Consumer(
    builder: (BuildContext context, WidgetRef ref, _) {
      return builder(
        SettingsContext(
          context: context,
          appModel: ref.read(appProvider),
          ref: ref,
          readerSource: ReaderHibikiSource.instance,
          refresh: () {},
        ),
      );
    },
  );
  if (cupertinoTheme != null) {
    child = CupertinoTheme(data: cupertinoTheme, child: child);
  }
  return child;
}

Widget _harness({
  required TargetPlatform platform,
  required Widget Function(SettingsContext) builder,
  CupertinoThemeData? cupertinoTheme,
  String designSystem = 'auto',
}) {
  final HibikiDatabase db = _testDb();
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode(designSystem),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: platform,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: _buildHome(cupertinoTheme, builder),
    ),
  );
}

void main() {
  testWidgets('material renderer maps schema to Material controls',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        builder: (SettingsContext settingsContext) {
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: _fixtureDestination(),
          );
        },
      ),
    );

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsRow &&
            widget.title == 'Action' &&
            widget.icon == Icons.play_arrow_outlined &&
            widget.showIcon,
      ),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_suggest_outlined), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsSwitchRow &&
            widget.title == 'Toggle' &&
            widget.icon == Icons.toggle_on_outlined,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((Widget widget) => widget is SegmentedButton),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Stepper'), findsOneWidget);
    expect(find.text('Custom builder content'), findsOneWidget);
    expect(find.byType(CupertinoPageScaffold), findsNothing);
  });

  testWidgets('cupertino renderer maps schema to Cupertino controls',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        builder: (SettingsContext settingsContext) {
          return CupertinoSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: _fixtureDestination(),
          );
        },
      ),
    );

    expect(find.byType(CupertinoPageScaffold), findsOneWidget);
    expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
    expect(find.byType(AdaptiveSettingsSection), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_outlined), findsNothing);
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsNothing);
    expect(find.byIcon(Icons.settings_suggest_outlined), findsOneWidget);
    expect(find.byIcon(Icons.toggle_on_outlined), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is CupertinoSlidingSegmentedControl,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((Widget widget) => widget is SegmentedButton),
      findsNothing,
    );
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.text('Stepper'), findsOneWidget);
    expect(find.text('Custom builder content'), findsOneWidget);
  });

  testWidgets('material design system keeps Material rows on iOS',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        designSystem: 'material',
        builder: (SettingsContext settingsContext) {
          expect(isCupertinoPlatform(settingsContext.context), isFalse);
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: _fixtureDestination(),
          );
        },
      ),
    );

    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      find.byWidgetPredicate((Widget widget) => widget is SegmentedButton),
      findsOneWidget,
    );
    expect(find.byType(CupertinoPageScaffold), findsNothing);
    expect(find.byType(CupertinoSlidingSegmentedControl<String>), findsNothing);
  });

  testWidgets('cupertino switch uses theme primary color', (
    WidgetTester tester,
  ) async {
    const Color customPrimary = Color(0xFFE91E63);
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        cupertinoTheme: const CupertinoThemeData(primaryColor: customPrimary),
        builder: (SettingsContext settingsContext) {
          return CupertinoSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: _fixtureDestination(),
          );
        },
      ),
    );

    final CupertinoSwitch sw = tester.widget<CupertinoSwitch>(
      find.byType(CupertinoSwitch),
    );
    expect(sw.activeTrackColor, customPrimary);
  });

  testWidgets('cupertino destination icons use theme primary color', (
    WidgetTester tester,
  ) async {
    const Color customPrimary = Color(0xFFE91E63);
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        cupertinoTheme: const CupertinoThemeData(primaryColor: customPrimary),
        builder: (SettingsContext settingsContext) {
          return CupertinoSettingsRenderer().buildDestinationList(
            settingsContext: settingsContext,
            destinations: <SettingsDestination>[_fixtureDestination()],
            selectedDestinationId: SettingsDestinationId.appearance,
            onDestinationSelected: (_) {},
          );
        },
      ),
    );

    final Icon icon = tester.widget<Icon>(
      find.byIcon(Icons.palette_outlined),
    );
    expect(icon.color, customPrimary);
  });

  testWidgets('settings schema keeps icons on destinations',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        builder: (SettingsContext settingsContext) {
          final List<SettingsDestination> destinations =
              buildSettingsSchema(settingsContext);
          final List<String> missingDestinationIcons = <String>[];
          for (final SettingsDestination destination in destinations) {
            if (destination.icon == Icons.help_outline) {
              missingDestinationIcons.add(destination.id.name);
            }
          }

          expect(missingDestinationIcons, isEmpty);
          return const SizedBox.shrink();
        },
      ),
    );
  });

  testWidgets('appearance settings exposes app UI size slider',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination appearance =
              buildSettingsSchema(settingsContext).firstWhere(
            (SettingsDestination destination) =>
                destination.id == SettingsDestinationId.appearance,
          );
          final SettingsDestination interfaceOnly = SettingsDestination(
            id: appearance.id,
            title: appearance.title,
            icon: appearance.icon,
            sections: <SettingsSection>[appearance.sections.first],
          );
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: interfaceOnly,
          );
        },
      ),
    );

    expect(find.text(t.app_ui_scale), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsSliderRow &&
            widget.title == t.app_ui_scale &&
            widget.value == 1.0,
      ),
      findsOneWidget,
    );
  });

  testWidgets('appearance custom rows omit Cupertino leading icons',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination appearance =
              buildSettingsSchema(settingsContext).firstWhere(
            (SettingsDestination destination) =>
                destination.id == SettingsDestinationId.appearance,
          );
          final SettingsDestination firstSectionOnly = SettingsDestination(
            id: appearance.id,
            title: appearance.title,
            icon: appearance.icon,
            sections: <SettingsSection>[appearance.sections.first],
          );

          return CupertinoSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: firstSectionOnly,
          );
        },
      ),
    );

    expect(find.byIcon(Icons.devices_outlined), findsNothing);
    expect(find.byIcon(Icons.color_lens_outlined), findsNothing);
    expect(find.byIcon(Icons.contrast_outlined), findsNothing);
  });

  test('settings renderers route navigation rows through shared component', () {
    final String material =
        File('lib/src/settings/material_settings_renderer.dart')
            .readAsStringSync();
    final String cupertino =
        File('lib/src/settings/cupertino_settings_renderer.dart')
            .readAsStringSync();

    expect(material, contains('AdaptiveSettingsNavigationRow('));
    expect(cupertino, contains('AdaptiveSettingsNavigationRow('));
    for (final String row in <String>[
      'AdaptiveSettingsRow(',
      'AdaptiveSettingsSwitchRow(',
      'AdaptiveSettingsSegmentedRow<',
      'AdaptiveSettingsSliderRow(',
      'AdaptiveSettingsStepperRow(',
    ]) {
      expect(material, contains(row));
      expect(cupertino, contains(row));
    }
    expect(material,
        isNot(contains('SettingsNavigationItem navigation => _navigation')));
    expect(cupertino,
        isNot(contains('SettingsNavigationItem navigation => _navigation')));
    expect(cupertino, isNot(contains('segmented.onChanged as Function')));
  });
}

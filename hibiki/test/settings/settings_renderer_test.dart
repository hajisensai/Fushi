import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
        ],
      ),
    ],
  );
}

Widget _harness({
  required TargetPlatform platform,
  required Widget Function(SettingsContext) builder,
}) {
  final HibikiDatabase db = _testDb();
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('auto'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel()..themeNotifier = themeNotifier;
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
      ),
      home: Consumer(
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
      ),
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
    expect(find.byType(Switch), findsOneWidget);
    expect(
      find.byWidgetPredicate((Widget widget) => widget is SegmentedButton),
      findsOneWidget,
    );
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
    expect(find.byType(CupertinoListSection), findsOneWidget);
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(find.byIcon(Icons.toggle_on_outlined), findsOneWidget);
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
  });

  testWidgets('settings schema gives every visible row a leading icon',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        builder: (SettingsContext settingsContext) {
          final List<SettingsDestination> destinations =
              buildSettingsSchema(settingsContext);
          final List<String> missingIcons = <String>[];
          for (final SettingsDestination destination in destinations) {
            for (final SettingsSection section
                in destination.visibleSections(settingsContext)) {
              for (final SettingsItem item in section.items) {
                if (item.icon == null) {
                  missingIcons.add('${destination.id.name}/${item.id}');
                }
              }
            }
          }

          expect(missingIcons, isEmpty);
          return const SizedBox.shrink();
        },
      ),
    );
  });

  testWidgets('appearance custom rows expose Cupertino leading icons',
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

    expect(find.byIcon(Icons.devices_outlined), findsOneWidget);
    expect(find.byIcon(Icons.color_lens_outlined), findsOneWidget);
    expect(find.byIcon(Icons.contrast_outlined), findsOneWidget);
  });
}

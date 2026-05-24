import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

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
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => AppModel()),
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
}

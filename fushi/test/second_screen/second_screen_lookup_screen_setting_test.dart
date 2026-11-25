import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart' show CtlBodyPage;
import 'package:fushi/src/ops/ctl_settings_values.dart' show CtlSettingType;
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'fake_second_screen_platform.dart';

const String _rowId = 'appearance.second_screen_lookup_screen';

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

class _Fixture {
  _Fixture(this.settingsContext, this.controller, this.prefs);

  final SettingsContext settingsContext;
  final SecondScreenController controller;
  final Map<String, Object?> prefs;

  SettingsIndexEntry entry() => buildSettingsIndex(
    settingsContext,
    destinations: <SettingsDestination>[buildAppearanceDestination()],
    bodyPages: const <CtlBodyPage>[],
  )[_rowId]!;
}

/// The "Lookups open on" row in Appearance next to "Second screen", built
/// from the real appearance schema with a second screen present or not.
Future<_Fixture> _pump(
  WidgetTester tester, {
  required List<SecondScreenDisplayInfo> displays,
}) async {
  final Map<String, Object?> prefs = <String, Object?>{};
  final FakeSecondScreenPlatform platform = FakeSecondScreenPlatform(
    displays: displays,
  );
  final SecondScreenHost host = SecondScreenHost(platform);
  final SecondScreenController controller = SecondScreenController(
    readPref: (String k) => prefs[k],
    writePref: (String k, Object? v) async => prefs[k] = v,
    host: host,
  );
  // The provider scope disposes the controller (ChangeNotifierProvider).
  addTearDown(host.dispose);
  await tester.runAsync(controller.start);

  late SettingsContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secondScreenControllerProvider.overrideWith((Ref ref) => controller),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            ctx = SettingsContext(
              context: context,
              appModel: _TestAppModel(),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return _Fixture(ctx, controller, prefs);
}

void main() {
  testWidgets('sits right after "Second screen" as a segmented choice, '
      'default Bottom screen', (WidgetTester tester) async {
    final List<String> ids = <String>[
      for (final SettingsSection section
          in buildAppearanceDestination().sections)
        for (final SettingsItem item in section.items) item.id,
    ];
    expect(
      ids.indexOf(_rowId),
      ids.indexOf('appearance.second_screen_mode') + 1,
    );
    final SettingsItem item = buildAppearanceDestination().sections
        .expand((SettingsSection s) => s.items)
        .firstWhere((SettingsItem i) => i.id == _rowId);
    expect(item, isA<SettingsSegmentedItem<SecondScreenLookupScreen>>());
    expect(
      (item as SettingsSegmentedItem<SecondScreenLookupScreen>).defaultValue,
      SecondScreenLookupScreen.bottom,
    );
  });

  testWidgets('in the settings index as a choice the companion can set '
      'directly; writes go through the controller (device-local pref)', (
    WidgetTester tester,
  ) async {
    final _Fixture f = await _pump(
      tester,
      displays: <SecondScreenDisplayInfo>[thorBottomScreen],
    );
    final SettingsIndexEntry entry = f.entry();
    expect(entry.visible, isTrue);
    expect(entry.type, CtlSettingType.choice);
    expect(
      settingsIndexChoices(
        entry,
        f.settingsContext,
      )!.map((SettingsIndexChoice c) => '${c.token}=${c.label}').toList(),
      <String>[
        'bottom=${t.second_screen_lookup_screen_bottom}',
        'top=${t.second_screen_lookup_screen_top}',
      ],
    );
    expect(f.controller.lookupScreen, SecondScreenLookupScreen.bottom);

    await tester.runAsync(
      () => applySettingsIndexValue(entry, f.settingsContext, 'top'),
    );
    expect(f.controller.lookupScreen, SecondScreenLookupScreen.top);
    expect(f.prefs[kSecondScreenLookupScreenPrefKey], 'top');
    expect(
      settingsIndexValueLabel(
        entry,
        f.settingsContext,
        f.controller.lookupScreen.name,
      ),
      t.second_screen_lookup_screen_top,
    );
  });

  testWidgets('hidden without a second screen, like "Second screen"', (
    WidgetTester tester,
  ) async {
    final _Fixture f = await _pump(
      tester,
      displays: const <SecondScreenDisplayInfo>[],
    );
    expect(f.entry().visible, isFalse);
  });
}

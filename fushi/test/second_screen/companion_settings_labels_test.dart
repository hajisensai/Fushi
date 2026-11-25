import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart' show CtlBodyPage;
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_settings_service.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// Appearance values without a ThemeNotifier behind them.
class _AppearanceAppModel extends AppModel {
  _AppearanceAppModel() : super(testPlatformServices());

  String themeKey = 'm3-teal';
  String brightness = 'dark';
  final List<CustomThemeEntry> themes = <CustomThemeEntry>[
    const CustomThemeEntry(id: 'a', name: 'Sakura', seed: 0xFFE91E63),
    const CustomThemeEntry(id: 'b', name: '  ', seed: 0xFF3F51B5),
  ];

  @override
  String get appThemeKey => themeKey;

  @override
  List<CustomThemeEntry> get customThemes => themes;

  @override
  CustomThemeEntry? get activeCustomThemeEntry => themes.last;

  @override
  String get brightnessMode => brightness;

  @override
  Locale get appLocale => const Locale('ja');
}

/// The drawn appearance rows the index reads as choices (their ids pick the
/// index's virtual read / write), plus a segmented row.
List<SettingsDestination> _schema(SettingsContext _) => <SettingsDestination>[
  SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: 'Appearance',
    icon: Icons.palette,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.theme',
            searchTitle: 'Theme',
            builder: (SettingsContext _) => const SizedBox.shrink(),
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            searchTitle: 'Dark mode',
            builder: (SettingsContext _) => const SizedBox.shrink(),
          ),
          SettingsCustomItem(
            id: 'appearance.language',
            searchTitle: 'Language',
            builder: (SettingsContext _) => const SizedBox.shrink(),
          ),
          SettingsSegmentedItem<int>(
            id: 'appearance.density',
            title: 'Density',
            options: const <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(value: 0, label: 'Compact'),
              SettingsSegmentOption<int>(value: 1, label: 'Comfortable'),
            ],
            selected: (SettingsContext _) => 1,
            onChanged: (SettingsContext _, int _) async {},
          ),
        ],
      ),
    ],
  ),
];

Future<(SettingsContext, _AppearanceAppModel)> _pump(
  WidgetTester tester,
) async {
  late SettingsContext ctx;
  final _AppearanceAppModel appModel = _AppearanceAppModel();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            ctx = SettingsContext(
              context: context,
              appModel: appModel,
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
  return (ctx, appModel);
}

CompanionSettingsService _service(SettingsContext ctx) =>
    CompanionSettingsService(
      settingsContext: () => ctx,
      currentContext: () => CompanionContext.none,
      destinations: _schema,
      bodyPages: const <CtlBodyPage>[],
      open:
          (
            SettingsContext _, {
            SettingsSearchEntry? entry,
            SettingsDestination? destination,
          }) {},
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('companion rows show the settings page labels, not the raw '
      'values (theme names, brightness, segmented labels)', (
    WidgetTester tester,
  ) async {
    final (SettingsContext ctx, _AppearanceAppModel appModel) = await _pump(
      tester,
    );
    final CompanionSettingsService service = _service(ctx);
    final Map<String, CompanionSettingRow> rows = <String, CompanionSettingRow>{
      for (final CompanionSettingRow r in service.category('appearance').rows)
        r.key: r,
    };

    final CompanionSettingRow theme = rows['appearance.theme']!;
    expect(theme.control, CompanionSettingControl.open);
    expect(theme.display, t.theme_preset_teal);

    final CompanionSettingRow brightness = rows['appearance.brightness']!;
    expect(brightness.control, CompanionSettingControl.choice);
    expect(brightness.display, t.dark_mode_dark);
    expect(brightness.options, <CompanionSettingOption>[
      CompanionSettingOption(value: 'light', label: t.dark_mode_light),
      CompanionSettingOption(value: 'system', label: t.dark_mode_system),
      CompanionSettingOption(value: 'dark', label: t.dark_mode_dark),
    ]);

    final CompanionSettingRow language = rows['appearance.language']!;
    expect(language.display, '日本語');
    expect(
      language.options.first,
      const CompanionSettingOption(value: 'en-US', label: 'English'),
    );

    final CompanionSettingRow density = rows['appearance.density']!;
    expect(density.display, 'Comfortable');

    // Custom themes: their name, or the swatch's "Custom n" when unnamed;
    // the bare `custom-theme` key names the active custom theme.
    appModel.themeKey = 'custom-theme:a';
    expect(service.get('appearance.theme').display, 'Sakura');
    appModel.themeKey = 'custom-theme';
    expect(
      service.get('appearance.theme').display,
      t.custom_theme_default_name(n: 2),
    );
    appModel.themeKey = 'system-theme';
    expect(service.get('appearance.theme').display, t.theme_preset_system);

    // Labels follow the main screen's language (resolved where the row is
    // built, i.e. in the main process).
    LocaleSettings.setLocale(AppLocale.ja);
    expect(service.get('appearance.brightness').display, t.dark_mode_dark);
    expect(t.dark_mode_dark, isNot('Dark'));
  });

  testWidgets('fushi_cli config JSON keeps the raw tokens', (
    WidgetTester tester,
  ) async {
    final (SettingsContext ctx, _) = await _pump(tester);
    final Map<String, SettingsIndexEntry> index = buildSettingsIndex(
      ctx,
      destinations: _schema(ctx),
      bodyPages: const <CtlBodyPage>[],
    );
    final Map<String, Object?> theme = settingsIndexEntryJson(
      index['appearance.theme']!,
      ctx,
    );
    expect(theme['value'], 'm3-teal');
    expect(theme['display'], 'm3-teal');
    expect((theme['options']! as List<Object?>).take(1), <Object?>[
      'system-theme',
    ]);
    expect(theme['options'], contains('custom-theme:a'));
    final Map<String, Object?> brightness = settingsIndexEntryJson(
      index['appearance.brightness']!,
      ctx,
    );
    expect(brightness['display'], 'dark');
    expect(brightness['options'], <Object?>['light', 'system', 'dark']);

    // The labels are exposed separately, typed.
    expect(
      settingsIndexChoices(
        index['appearance.brightness']!,
        ctx,
      )!.map((SettingsIndexChoice c) => '${c.token}=${c.label}').toList(),
      <String>[
        'light=${t.dark_mode_light}',
        'system=${t.dark_mode_system}',
        'dark=${t.dark_mode_dark}',
      ],
    );
    expect(
      settingsIndexChoices(index['appearance.density']!, ctx),
      hasLength(2),
    );
  });
}

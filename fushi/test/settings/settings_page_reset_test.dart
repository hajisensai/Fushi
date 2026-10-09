import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 页级「恢复本页默认」：普通 schema 设置行不再有「改过默认值」圆点与行尾撤销钮，
/// 改由详情页页头溢出菜单统一恢复；判据只有 settingsResetSpecFor 一份。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _appModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_page_reset_',
  );
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

/// 测试内的「偏好」：键 → 值，项的 getter / setter 直接读写它。
class _Values {
  bool autoplay = true; // 默认 true
  bool compact = false; // 默认 false
  double speed = 1.0; // 默认 1.0
  String mode = 'auto'; // 默认 auto
  bool hidden = false; // 折叠分组里的项，默认 false
  bool noDefault = true; // 没声明 defaultValue
}

SettingsDestination _destination(_Values v, {bool withDefaults = true}) {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: 'Test page',
    icon: FushiIcons.settings,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'main',
        title: 'Main',
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'autoplay',
            title: 'Autoplay',
            defaultValue: withDefaults ? true : null,
            value: (_) => v.autoplay,
            onChanged: (_, bool value) => v.autoplay = value,
          ),
          SettingsSwitchItem(
            id: 'compact',
            title: 'Compact',
            defaultValue: withDefaults ? false : null,
            value: (_) => v.compact,
            onChanged: (_, bool value) => v.compact = value,
          ),
          SettingsSliderItem(
            id: 'speed',
            title: 'Speed',
            min: 0.5,
            max: 2,
            divisions: 6,
            defaultValue: withDefaults ? 1.0 : null,
            label: (double value) => '${value.toStringAsFixed(2)}x',
            value: (_) => v.speed,
            onChanged: (_, double value) => v.speed = value,
          ),
          SettingsSegmentedItem<String>(
            id: 'mode',
            title: 'Mode',
            defaultValue: withDefaults ? 'auto' : null,
            options: const <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(value: 'auto', label: 'Auto'),
              SettingsSegmentOption<String>(value: 'manual', label: 'Manual'),
            ],
            selected: (_) => v.mode,
            onChanged: (_, String value) => v.mode = value,
          ),
          SettingsSwitchItem(
            id: 'noDefault',
            title: 'No default',
            value: (_) => v.noDefault,
            onChanged: (_, bool value) => v.noDefault = value,
          ),
        ],
      ),
      SettingsSection(
        id: 'advanced',
        title: 'Advanced',
        presentation: SettingsSectionPresentation.collapsed,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'hidden',
            title: 'Hidden toggle',
            defaultValue: withDefaults ? false : null,
            value: (_) => v.hidden,
            onChanged: (_, bool value) => v.hidden = value,
          ),
        ],
      ),
    ],
  );
}

class _Host extends ConsumerStatefulWidget {
  const _Host({required this.destination});

  final SettingsDestination Function() destination;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  Widget build(BuildContext context) {
    final SettingsContext sctx = SettingsContext(
      context: context,
      appModel: ref.read(appProvider),
      ref: ref,
      readerSource: ReaderFushiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );
    return const MaterialSettingsRenderer().buildDetailPage(
      settingsContext: sctx,
      destination: widget.destination(),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  SettingsDestination Function() destination,
) async {
  final FushiDatabase db = _testDb();
  addTearDown(db.close);
  final AppModel appModel = await _appModel(db);
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(themeNotifier.dispose);
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: _Host(destination: destination),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
}

Finder _menu() =>
    find.byKey(const ValueKey<String>('settings-page-reset-menu'));
Finder _menuItem() =>
    find.byKey(const ValueKey<String>('settings-page-reset-item'));
Finder _dialogRow(String id) =>
    find.byKey(ValueKey<String>('settings-page-reset.$id'));

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: _menu(), matching: find.byType(IconButton)).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => debugSettingsForceExpandAllSections = true);
  tearDown(() => debugSettingsForceExpandAllSections = false);

  testWidgets('modified rows carry no inline dot or reset button', (
    WidgetTester tester,
  ) async {
    final _Values v = _Values()
      ..autoplay = false
      ..speed = 1.5;
    await _pump(tester, () => _destination(v));

    expect(find.text('Autoplay'), findsOneWidget);
    expect(find.byType(SettingsModifiedRow), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('settings-reset-default')),
      findsNothing,
    );
    expect(find.byTooltip(t.settings_reset_to_default), findsNothing);
    // 页级入口在页头。
    expect(_menu(), findsOneWidget);
  });

  testWidgets('menu lists exactly the modified items, including collapsed '
      'sections, and resets only the checked ones', (
    WidgetTester tester,
  ) async {
    final _Values v = _Values()
      ..autoplay = false
      ..speed = 1.5
      ..mode = 'manual'
      ..hidden = true
      ..noDefault = false;
    // 不强制展开：折叠分组真收起时，里面改过的项也必须进恢复列表（判据读
    // schema 数据，不读渲染出来的行）。
    debugSettingsForceExpandAllSections = false;
    await _pump(tester, () => _destination(v));
    expect(find.text('Hidden toggle'), findsNothing, reason: '折叠分组默认收起，行不在页面上');

    await _openMenu(tester);
    final PopupMenuItem<int> item = tester.widget<PopupMenuItem<int>>(
      _menuItem(),
    );
    expect(item.enabled, isTrue);
    expect(find.text(t.settings_page_reset_menu), findsOneWidget);
    await tester.tap(_menuItem());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('settings-page-reset-dialog')),
      findsOneWidget,
    );
    // 改过的四项（含折叠分组里的 hidden）都在，默认全选。
    for (final String id in <String>['autoplay', 'speed', 'mode', 'hidden']) {
      expect(_dialogRow(id), findsOneWidget, reason: id);
      expect(
        tester.widget<FushiCheckboxListTile>(_dialogRow(id)).value,
        isTrue,
        reason: '$id 默认勾选',
      );
    }
    // 没改过的、没声明默认值的不列。
    expect(_dialogRow('compact'), findsNothing);
    expect(_dialogRow('noDefault'), findsNothing);
    // 当前值 → 默认值的简述。
    expect(
      find.text(
        '${t.settings_page_reset_value_off} → '
        '${t.settings_page_reset_value_on}',
      ),
      findsOneWidget,
    );
    expect(find.text('1.50x → 1.00x'), findsOneWidget);
    expect(find.text('Manual → Auto'), findsOneWidget);

    // 取消勾选 speed：确认后它不恢复。
    await tester.tap(_dialogRow('speed'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FushiCheckboxListTile>(_dialogRow('speed')).value,
      isFalse,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-page-reset-confirm')),
    );
    await tester.pumpAndSettle();

    expect(v.autoplay, isTrue);
    expect(v.mode, 'auto');
    expect(v.hidden, isFalse);
    expect(v.speed, 1.5, reason: '取消勾选的项不恢复');
    expect(v.noDefault, isFalse, reason: '没声明默认值的项不受影响');
  });

  testWidgets('cancel leaves every value untouched', (
    WidgetTester tester,
  ) async {
    final _Values v = _Values()..autoplay = false;
    await _pump(tester, () => _destination(v));
    await _openMenu(tester);
    await tester.tap(_menuItem());
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(v.autoplay, isFalse);
  });

  testWidgets('all-default page disables the item and says so', (
    WidgetTester tester,
  ) async {
    final _Values v = _Values();
    await _pump(tester, () => _destination(v));
    expect(_menu(), findsOneWidget);
    await _openMenu(tester);
    final PopupMenuItem<int> item = tester.widget<PopupMenuItem<int>>(
      _menuItem(),
    );
    expect(item.enabled, isFalse);
    expect(find.text(t.settings_page_reset_all_default), findsOneWidget);
    await tester.tap(_menuItem(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('settings-page-reset-dialog')),
      findsNothing,
    );
  });

  testWidgets('page without any declared defaults shows no overflow menu', (
    WidgetTester tester,
  ) async {
    final _Values v = _Values()..autoplay = false;
    await _pump(tester, () => _destination(v, withDefaults: false));
    expect(find.text('Autoplay'), findsOneWidget);
    expect(_menu(), findsNothing);
  });

  testWidgets('custom rows join through SettingsCustomItem.reset', (
    WidgetTester tester,
  ) async {
    int color = 0xFFFF0000;
    const int defaultColor = 0xFF000000;
    await _pump(
      tester,
      () => SettingsDestination(
        id: SettingsDestinationId.appearance,
        title: 'Custom page',
        icon: FushiIcons.settings,
        sections: <SettingsSection>[
          SettingsSection(
            items: <SettingsItem>[
              SettingsCustomItem(
                id: 'color',
                searchTitle: 'Caption color',
                reset: SettingsCustomReset(
                  isModified: (_) => color != defaultColor,
                  reset: (_) async => color = defaultColor,
                  currentLabel: (_) => 'Red',
                  defaultLabel: (_) => 'Follows theme',
                ),
                builder: (_) => const Text('Caption color row'),
              ),
            ],
          ),
        ],
      ),
    );
    await _openMenu(tester);
    await tester.tap(_menuItem());
    await tester.pumpAndSettle();
    expect(find.text('Caption color'), findsOneWidget);
    expect(find.text('Red → Follows theme'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-page-reset-confirm')),
    );
    await tester.pumpAndSettle();
    expect(color, defaultColor);
  });

  test('schema rows no longer wrap SettingsModifiedRow; shortcut page keeps '
      'its per-binding reset', () {
    final String schemaWidgets = File(
      'lib/src/settings/settings_schema_widgets.dart',
    ).readAsStringSync();
    expect(schemaWidgets.contains('SettingsModifiedRow('), isFalse);
    final String gameSchema = File(
      'lib/src/settings/settings_schema_game.dart',
    ).readAsStringSync();
    expect(gameSchema.contains('SettingsModifiedRow('), isFalse);
    final String shortcutTile = File(
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart',
    ).readAsStringSync();
    expect(shortcutTile.contains("'shortcut-reset-"), isTrue);
    expect(shortcutTile.contains('w.modified'), isTrue);
  });
}

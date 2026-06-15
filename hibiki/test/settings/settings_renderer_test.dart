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
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_home_page.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  AppModel? appModel,
  HibikiDatabase? database,
  Map<String, String> extraThemePrefs = const <String, String>{},
}) {
  final HibikiDatabase db = database ?? _testDb();
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode(designSystem),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
      ...extraThemePrefs,
    });
  final AppModel resolvedAppModel = appModel ?? _RendererTestAppModel();
  resolvedAppModel.themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    if (database == null) await db.close();
  });

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => resolvedAppModel),
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

Future<AppModel> _prefsBackedAppModel(
  HibikiDatabase db, {
  PackageInfo? packageInfo,
}) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir =
      Directory.systemTemp.createTempSync('hibiki_settings_renderer_');
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final AppModel appModel = packageInfo == null
      ? _RendererTestAppModel()
      : _VersionedRendererTestAppModel(packageInfo);
  return appModel
    ..wireLocalAudioForTesting(
      prefsRepo: prefsRepo,
      databaseDirectory: tempDir,
    )
    ..wireDatabaseForTesting(db);
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

  testWidgets('system settings exposes the runtime app version',
      (WidgetTester tester) async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(
      db,
      packageInfo: PackageInfo(
        appName: 'Hibiki',
        packageName: 'jp.hibiki.test',
        version: '9.8.7',
        buildNumber: '654',
      ),
    );

    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        database: db,
        appModel: appModel,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination system =
              buildSettingsSchema(settingsContext).firstWhere(
            (SettingsDestination destination) =>
                destination.id == SettingsDestinationId.system,
          );
          final List<SettingsItem> versionItems = system.sections
              .expand((SettingsSection section) => section.items)
              .where((SettingsItem item) => item.id == 'system.app_version')
              .toList(growable: false);
          final SettingsDestination versionOnly = SettingsDestination(
            id: system.id,
            title: system.title,
            icon: system.icon,
            sections: <SettingsSection>[
              SettingsSection(items: versionItems),
            ],
          );
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: versionOnly,
          );
        },
      ),
    );

    expect(find.text('App version'), findsOneWidget);
    expect(find.text('9.8.7+654'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsRow &&
            widget.title == 'App version' &&
            widget.subtitle == '9.8.7+654' &&
            widget.onTap == null,
      ),
      findsOneWidget,
      reason: 'version must be displayed as a read-only settings row',
    );
  });

  test('system app version row is sourced from runtime PackageInfo', () {
    final String source =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();

    expect(source, contains("id: 'system.app_version'"));
    expect(source, contains('settingsContext.appModel.packageInfo'));
    expect(source, isNot(contains('pubspec.yaml')));
  });

  // TODO-323: 自动/自定义不再是独立全权重行，而是「界面大小」标题行尾的内联切换；
  // 自动模式不再渲染无用滑条，只读展示当前自动百分比。
  Widget interfaceSettingsHarness({
    Map<String, String> extraThemePrefs = const <String, String>{},
  }) {
    return _harness(
      platform: TargetPlatform.android,
      extraThemePrefs: extraThemePrefs,
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
    );
  }

  testWidgets(
      'TODO-374: app UI size has no auto/custom toggle, only the slider',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      interfaceSettingsHarness(
        extraThemePrefs: <String, String>{
          'app_ui_scale': PrefCodec.encode(1.5),
        },
      ),
    );

    // 界面大小已无模式概念：不存在任何 auto/custom 分段切换行（标题为界面大小的
    // AdaptiveSettingsSegmentedRow）。
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsSegmentedRow<String> &&
            widget.title == t.app_ui_scale,
      ),
      findsNothing,
      reason: 'TODO-374 删除了界面大小的自动/自定义模式切换',
    );

    // 恒渲染一条可拖的具体百分比滑条。
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsSliderRow &&
            widget.title == t.app_ui_scale &&
            widget.value == 1.5 &&
            widget.min == 0.3 &&
            widget.max == 3.0 &&
            widget.divisions == 27,
      ),
      findsOneWidget,
    );
  });

  testWidgets('lookup settings can edit the Yomitan API key', (
    WidgetTester tester,
  ) async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);

    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        database: db,
        appModel: appModel,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination lookup =
              buildSettingsSchema(settingsContext).firstWhere(
            (SettingsDestination destination) =>
                destination.id == SettingsDestinationId.lookup,
          );
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: lookup,
          );
        },
      ),
    );

    final Finder field = find.descendant(
      of: find.widgetWithText(AdaptiveSettingsRow, t.yomitan_api_key),
      matching: find.byType(TextFormField),
    );
    expect(field, findsOneWidget);
    final EditableText editable = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(editable.obscureText, isTrue);

    await tester.enterText(field, 'mpv-token');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(appModel.yomitanApiKey, 'mpv-token');
  });

  testWidgets('lookup settings exposes lookup audio volume slider', (
    WidgetTester tester,
  ) async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderHibikiSource.readerSettings = null);

    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        database: db,
        appModel: appModel,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination lookup =
              buildSettingsSchema(settingsContext).firstWhere(
            (SettingsDestination destination) =>
                destination.id == SettingsDestinationId.lookup,
          );
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: lookup,
          );
        },
      ),
    );

    Finder sliderFinder() => find.byWidgetPredicate(
          (Widget widget) =>
              widget is AdaptiveSettingsSliderRow &&
              widget.title == t.lookup_audio_volume,
        );

    // 标题带实时百分比读数（与有声书音量行同款）；row.title 保持裸标题作身份。
    expect(find.text('${t.lookup_audio_volume} (100%)'), findsOneWidget);
    expect(sliderFinder(), findsOneWidget);
    AdaptiveSettingsSliderRow row =
        tester.widget<AdaptiveSettingsSliderRow>(sliderFinder());
    expect(row.value, 100);
    expect(row.min, 0);
    expect(row.max, 100);
    expect(row.divisions, 100,
        reason: '0–100% 共 100 档 = 拖动 1% 一档（旧 20 档 = 5% 太粗）');
    expect(row.step, 5, reason: '键盘/手柄左右键 5% 一步，与拖动档位解耦');
    expect(row.readout, '100%');
    expect(row.label, '100%');

    row.onChanged(35);
    await tester.pump();

    expect(ReaderHibikiSource.instance.lookupAudioVolume, 35);
  });

  testWidgets('app UI scale slider commits only on drag end, not during drag',
      (WidgetTester tester) async {
    late AppModel appModel;
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        // TODO-374: 滑条恒渲染；以一个具体值起步即可驱动其拖动语义。
        extraThemePrefs: <String, String>{
          'app_ui_scale': PrefCodec.encode(1.0),
        },
        builder: (SettingsContext settingsContext) {
          appModel = settingsContext.appModel;
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

    AdaptiveSettingsSliderRow row() => tester.widget<AdaptiveSettingsSliderRow>(
          find.byType(AdaptiveSettingsSliderRow),
        );

    expect(appModel.appUiScale, 1.0);

    // 拖动中：onChanged 只更新本地显示值，绝不提交真实缩放——否则全局
    // HibikiAppUiScale 的 Transform 会实时重排，滑块在手指下被缩放位移导致
    // 拖动断裂（本次修复的根因）。
    row().onChanged(2.0);
    await tester.pump();
    expect(appModel.appUiScale, 1.0, reason: '拖动期间不得提交真实缩放');
    expect(row().value, 2.0, reason: '滑条显示跟手到本地拖动值');

    // 松手：onChangeEnd 一次性提交真实缩放并回落到已提交值。
    row().onChangeEnd!(2.0);
    await tester.pump();
    expect(appModel.appUiScale, 2.0, reason: '松手提交真实缩放');
    expect(row().value, 2.0);
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

    // segmented 派发改用类型安全的 SettingsSegmentedItem.dispatchChange，
    // 不再用 `(segmented as dynamic).onChanged` 绕过泛型逆变类型检查。
    expect(material, isNot(contains('as dynamic).onChanged')));
    expect(cupertino, isNot(contains('as dynamic).onChanged')));
    expect(material, contains('.dispatchChange('));
    expect(cupertino, contains('.dispatchChange('));
    final String destination =
        File('lib/src/settings/settings_destination.dart').readAsStringSync();
    expect(destination, contains('dispatchChange('),
        reason: 'SettingsSegmentedItem 应提供类型安全的 dispatchChange 方法');
  });

  // 回归：改 String 型 segmented 设置时，渲染器派发处把 SettingsSegmentedItem
  // <String> 经 `as SettingsSegmentedItem<Object>` 转型，闭包静态读
  // `segmented.onChanged` 会因函数参数逆变抛 _TypeError（书写方向/视图模式/振
  // 假名等改一下就崩）。两个渲染器都用 dynamic 调用绕开。
  SettingsDestination segmentedFixture(void Function(String) onValue) {
    return SettingsDestination(
      id: SettingsDestinationId.appearance,
      title: 'Appearance',
      icon: Icons.palette_outlined,
      sections: <SettingsSection>[
        SettingsSection(
          items: <SettingsItem>[
            SettingsSegmentedItem<String>(
              id: 'mode',
              title: 'Mode',
              options: const <SettingsSegmentOption<String>>[
                SettingsSegmentOption<String>(value: 'auto', label: 'Auto'),
                SettingsSegmentOption<String>(value: 'on', label: 'On'),
              ],
              selected: (_) => 'auto',
              onChanged: (_, String value) => onValue(value),
            ),
          ],
        ),
      ],
    );
  }

  testWidgets('material segmented change fires onChanged without _TypeError',
      (WidgetTester tester) async {
    String received = '';
    await tester.pumpWidget(_harness(
      platform: TargetPlatform.android,
      builder: (SettingsContext sctx) => MaterialSettingsRenderer()
          .buildDetailPage(
              settingsContext: sctx,
              destination: segmentedFixture((String v) => received = v)),
    ));
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '改 String 型 segmented 设置不得抛 _TypeError');
    expect(received, 'on', reason: 'onChanged 必须以正确的 String 值触发');
  });

  testWidgets('cupertino segmented change fires onChanged without _TypeError',
      (WidgetTester tester) async {
    String received = '';
    await tester.pumpWidget(_harness(
      platform: TargetPlatform.iOS,
      builder: (SettingsContext sctx) => CupertinoSettingsRenderer()
          .buildDetailPage(
              settingsContext: sctx,
              destination: segmentedFixture((String v) => received = v)),
    ));
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '改 String 型 segmented 设置不得抛 _TypeError');
    expect(received, 'on', reason: 'onChanged 必须以正确的 String 值触发');
  });

  // BUG-009 R1：宽屏 master-detail 的 primary 是有限高度的 Expanded；cupertino
  // 详情过去返回裸 Column，内容超高 → RenderFlex 溢出（真机右下角黄黑条纹）。
  // 详情必须像 Material 渲染器一样自带滚动视口。
  testWidgets(
      'BUG-009: cupertino detail content scrolls in a bounded pane instead of '
      'overflowing', (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.iOS,
        builder: (SettingsContext settingsContext) {
          // 模拟宽屏 primary：固定矮高度面板，内容远超其高度。
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: 250,
              width: 600,
              child: const CupertinoSettingsRenderer().buildDetailContent(
                settingsContext: settingsContext,
                destination: _fixtureDestination(),
              ),
            ),
          );
        },
      ),
    );

    expect(
      tester.takeException(),
      isNull,
      reason: 'cupertino 详情在有限高度面板里必须可滚动，不得 RenderFlex 溢出（BUG-009 R1）',
    );
    // 详情自身提供可滚动视口（宽屏 primary 与 reader 设置弹窗都复用此路径）。
    expect(find.byType(Scrollable), findsWidgets);
  });

  // BUG-009 R2：Windows 桌面把外观切到 iOS(Cupertino) 后，设置标签曾退化成
  // 「3 图标 rail + 嵌入 Cupertino 设置」三栏混排、无返回出口、详情溢出。修复后
  // cupertino 桌面复用 Material 全屏外壳：宽屏二栏 + 顶部返回箭头出口，不溢出。
  testWidgets(
      'BUG-009 R2: cupertino desktop embedded settings expose a back-arrow exit '
      'and do not overflow', (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        // 复现用户场景：Windows 主机 + 外观强制 iOS(Cupertino) 覆盖。
        platform: TargetPlatform.windows,
        designSystem: 'cupertino',
        builder: (SettingsContext _) =>
            SettingsHomePage(embedded: true, onBack: () {}),
      ),
    );
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'cupertino 桌面嵌入设置不得 RenderFlex 溢出（BUG-009）',
    );
    // 退化态完全没有出口；修复后必须有返回箭头（由统一嵌入页头提供）。
    expect(
      find.byIcon(Icons.arrow_back),
      findsOneWidget,
      reason: 'cupertino 桌面全屏设置必须提供返回箭头出口（BUG-009 R2）',
    );
  });
}

/// 渲染器测试用的轻量 AppModel：未跑 initialise()、prefsRepo 为空。阅读设置里
/// 「反转阅读器底栏」开关读 appModel.reverseReaderBottomBar（→ prefsRepo），故显式
/// 后备，避免渲染该开关时 _prefsRepo! 空指针（同 _SettingsDialogTestAppModel）。
class _RendererTestAppModel extends AppModel {
  _RendererTestAppModel() : super(testPlatformServices());

  @override
  bool get reverseReaderBottomBar => false;
}

class _VersionedRendererTestAppModel extends _RendererTestAppModel {
  _VersionedRendererTestAppModel(this._packageInfo);

  final PackageInfo _packageInfo;

  @override
  PackageInfo get packageInfo => _packageInfo;
}

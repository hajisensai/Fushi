import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// 「在线服务」「漫画」两页沿用 AI 页（#2042）的折叠形态：默认折叠状态、分组头
/// 摘要计数、以及设置搜索命中被折叠的项时自动展开并定位到该行。
void main() {
  SettingsSection section(SettingsDestination d, String id) =>
      d.sections.firstWhere((SettingsSection s) => s.id == id);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsSearchReveal.pendingItemId = null;
  });
  tearDown(() => SettingsSearchReveal.pendingItemId = null);

  group('默认折叠状态', () {
    test('漫画：最常用的「浏览与翻页」展开，其余分组收起；15 项一项不少', () {
      final SettingsDestination manga = buildMangaDestination();
      expect(
        <String, SettingsSectionPresentation>{
          for (final SettingsSection s in manga.sections) s.id!: s.presentation,
        },
        <String, SettingsSectionPresentation>{
          'manga.section.viewing': SettingsSectionPresentation.expanded,
          'manga.section.display': SettingsSectionPresentation.collapsed,
          'manga.section.spread_panels': SettingsSectionPresentation.collapsed,
          'manga.section.ocr': SettingsSectionPresentation.alwaysExpanded,
          'manga.section.catalog': SettingsSectionPresentation.collapsed,
        },
      );
      final Set<String> regrouped = <String>{
        for (final String id in <String>[
          'manga.section.viewing',
          'manga.section.display',
          'manga.section.spread_panels',
        ])
          ...section(manga, id).items.map((SettingsItem i) => i.id),
      };
      expect(regrouped, <String>{
        'manga.reader_mode',
        'manga.reader_scale',
        'manga.reading_direction',
        'manga.default_zoom',
        'manga.zoom_sensitivity',
        'manga.page_animation',
        'manga.spread_offset',
        'manga.wide_page_solo',
        'manga.panel_model',
        'manga.panel_navigation',
        'manga.background',
        'manga.tap_zone_paging',
        'manga.tap_zone_layout',
        'manga.chrome_floating',
        'manga.volume_key_paging',
      });
      for (final SettingsSection s in manga.sections) {
        if (s.presentation == SettingsSectionPresentation.alwaysExpanded) {
          continue;
        }
        expect(s.summaryBuilder, isNotNull, reason: '${s.id} 收起时要报摘要');
      }
    });

    test('在线服务：字幕来源展开，资源索引器 / 元数据收起，顺序不变', () {
      final SettingsDestination services = buildServicesDestination();
      expect(services.sections.map((SettingsSection s) => s.id), <String>[
        'services.subtitles',
        'services.resources',
        'services.metadata',
        'services.media',
      ]);
      expect(
        services.sections.map((SettingsSection s) => s.presentation),
        <SettingsSectionPresentation>[
          SettingsSectionPresentation.expanded,
          SettingsSectionPresentation.collapsed,
          SettingsSectionPresentation.collapsed,
          SettingsSectionPresentation.alwaysExpanded,
        ],
      );
    });
  });

  group('摘要计数与真实页面', () {
    late FushiDatabase db;
    late AppModel appModel;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      final Directory tempDir = Directory.systemTemp.createTempSync(
        'hibiki_settings_fold_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      appModel = _TestAppModel()
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
        ..wireDatabaseForTesting(db);
    });
    tearDown(() async => db.close());

    testWidgets('漫画摘要数「N 项已修改」，没改过就不显示', (WidgetTester tester) async {
      final SettingsContext c = await _pumpContext(tester, db, appModel);
      final SettingsDestination manga = buildMangaDestination();
      String? summary(String id) => section(manga, id).summaryBuilder!(c);

      expect(summary('manga.section.display'), isNull);
      expect(summary('manga.section.viewing'), isNull);

      await tester.runAsync(() async {
        await appModel.setMangaBackground('white');
        await appModel.setMangaZoomPercent(150);
        await appModel.setMangaPageAnimation('fade');
      });
      expect(
        summary('manga.section.display'),
        t.settings_section_modified_count(n: 2),
      );
      expect(
        summary('manga.section.viewing'),
        t.settings_section_modified_count(n: 1),
      );
      expect(summary('manga.section.spread_panels'), isNull);
    });

    testWidgets('在线服务摘要数「N 项已配置」与行上状态同口径', (WidgetTester tester) async {
      final SettingsContext c = await _pumpContext(tester, db, appModel);
      String? summary(String id) =>
          section(buildServicesDestination(), id).summaryBuilder!(c);

      expect(summary('services.subtitles'), isNull);
      await tester.runAsync(() async {
        await appModel.setJimakuEnabled(true);
        await appModel.setJimakuApiKey('key');
        await appModel.setVideoSubtitleAjattEnabled(false);
      });
      expect(
        summary('services.subtitles'),
        '${t.settings_services_configured_count(n: 1)} · '
        '${t.settings_section_modified_count(n: 1)}',
      );
      // 只用内置配置（TMDB）不算「已配置」。
      expect(summary('services.metadata'), isNull);
    });

    testWidgets('页面上收起的分组不渲染行，分组头显示摘要', (WidgetTester tester) async {
      await tester.runAsync(() => appModel.setMangaBackground('white'));
      await _pumpPage(tester, db, appModel, buildMangaDestination());
      expect(find.text(t.manga_reading_direction), findsOneWidget);
      // 分组头 + 顶部分区跳转条各一处。
      expect(find.text(t.manga_section_display), findsWidgets);
      expect(find.text(t.manga_background), findsNothing);
      expect(find.text(t.settings_section_modified_count(n: 1)), findsWidgets);
    });

    for (final (SettingsDestination Function(), String, String Function())
        target
        in <(SettingsDestination Function(), String, String Function())>[
          (buildMangaDestination, 'manga.background', () => t.manga_background),
          (buildServicesDestination, 'services.metadata.tmdb', () => 'TMDB'),
        ]) {
      testWidgets('设置搜索命中被折叠的 ${target.$2}：自动展开并定位', (
        WidgetTester tester,
      ) async {
        final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
        late SettingsContext settingsContext;
        await tester.pumpWidget(
          _harness(
            db: db,
            appModel: appModel,
            navigatorKey: navigator,
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                settingsContext = SettingsContext(
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
        );
        final SettingsSearchEntry entry = flattenVisibleSettings(
          <SettingsDestination>[target.$1()],
          settingsContext,
        ).firstWhere((SettingsSearchEntry e) => e.item.id == target.$2);
        expect(entry.hasRevealTarget, isTrue);
        expect(entry.subPagePath, isEmpty);

        openSettingsSearchEntry(navigator.currentState!, entry);
        await _settle(tester);

        expect(find.text(target.$3()), findsOneWidget);
        expect(find.byType(SettingsRevealTarget), findsOneWidget);
        expect(
          SettingsSearchReveal.pendingItemId,
          isNull,
          reason: '目标行已消费这次定位请求',
        );
      });
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pumpAndSettle();
}

Future<SettingsContext> _pumpContext(
  WidgetTester tester,
  FushiDatabase db,
  AppModel appModel,
) async {
  late SettingsContext settingsContext;
  await tester.pumpWidget(
    _harness(
      db: db,
      appModel: appModel,
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          settingsContext = SettingsContext(
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
  );
  return settingsContext;
}

Future<void> _pumpPage(
  WidgetTester tester,
  FushiDatabase db,
  AppModel appModel,
  SettingsDestination destination,
) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _harness(
      db: db,
      appModel: appModel,
      child: SettingsDetailPage(destination: destination),
    ),
  );
  await _settle(tester);
}

Widget _harness({
  required FushiDatabase db,
  required AppModel appModel,
  required Widget child,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('auto'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(themeNotifier.dispose);
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: child,
      ),
    ),
  );
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

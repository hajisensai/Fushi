import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

class _SearchTestAppModel extends AppModel {
  _SearchTestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'jp.fushi.test',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  bool get reverseReaderBottomBar => false;
}

Future<AppModel> _buildAppModel(String designSystem) async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_settings_search_',
  );
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final ThemeNotifier notifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode(designSystem),
      'brightness_mode': PrefCodec.encode('light'),
    });
  addTearDown(notifier.dispose);
  return _SearchTestAppModel()
    ..themeNotifier = notifier
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsSearchReveal.pendingItemId = null;
  });
  tearDown(() => SettingsSearchReveal.pendingItemId = null);

  // 双栏门槛钉在设置页自身宽度（不是窗口宽度）的 600dp：11 寸平板竖屏 711dp、
  // 640dp 这类 600~719 宽度必须一级直接双栏（旧门槛 720 在这里是单列）；599 仍单列。
  // 左栏宽按分支各自的契约：MD3 / 玻璃定宽 240，Cupertino 按
  // [supportingPaneWidthForLayout]（600 宽时 280，右详情 320）。Cupertino 是隐藏
  // 设计系统（偏好只认 auto / material / glass，见
  // ThemeNotifier.normalizeDesignSystemPreference），这里在 MD3 主题上直接挂
  // [FushiDesignSystemTheme] 进 SettingsHomePage 的 Cupertino 分支。
  for (final String designSystem in <String>[
    'material',
    'glass',
    'cupertino',
  ]) {
    for (final double width in <double>[599, 600, 640, 711]) {
      testWidgets(
        '$designSystem settings home at ${width.toInt()}dp is '
        '${width >= kFushiSettingsHomeTwoPaneMinWidth ? 'two-pane' : 'single-column'}',
        (WidgetTester tester) async {
          final AppModel model = (await tester.runAsync<AppModel>(
            () => _buildAppModel(
              designSystem == 'cupertino' ? 'material' : designSystem,
            ),
          ))!;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(900, 1000);
          addTearDown(() {
            tester.view.resetDevicePixelRatio();
            tester.view.resetPhysicalSize();
          });
          final ThemeData baseTheme = model.themeNotifier.theme;
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                appProvider.overrideWith((Ref ref) => model),
                platformServicesProvider.overrideWithValue(
                  model.platformServices,
                ),
              ],
              child: TranslationProvider(
                child: MaterialApp(
                  theme: baseTheme.copyWith(
                    splashFactory: NoSplash.splashFactory,
                    extensions: <ThemeExtension<dynamic>>[
                      ...baseTheme.extensions.values.cast(),
                      if (designSystem == 'cupertino')
                        const FushiDesignSystemTheme(
                          FushiDesignSystem.cupertino,
                        ),
                    ],
                  ),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        child: const SettingsHomePage(embedded: true),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final Finder home = find.byType(SettingsHomePage);
          expect(tester.getSize(home).width, width);
          expect(
            isCupertinoPlatform(tester.element(home)),
            designSystem == 'cupertino',
          );
          final Finder split = find.byType(MaterialSupportingPaneLayout);
          if (width < kFushiSettingsHomeTwoPaneMinWidth) {
            expect(split, findsNothing);
          } else {
            expect(split, findsOneWidget);
            // 双栏真的铺开了（不是外层判宽、内层 minSplitWidth 又退回单列）：
            // 分栏 Row 的第一个孩子就是定宽左栏。
            final Finder supporting = find
                .descendant(of: split, matching: find.byType(SizedBox))
                .first;
            final double expectedSupporting = designSystem == 'cupertino'
                ? supportingPaneWidthForLayout(width)
                : 240;
            expect(tester.getSize(supporting).width, expectedSupporting);
            expect(
              width - expectedSupporting,
              greaterThanOrEqualTo(designSystem == 'cupertino' ? 320 : 360),
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  }

  for (final String designSystem in <String>['material', 'glass']) {
    for (final bool submit in <bool>[true, false]) {
      testWidgets(
        '$designSystem ${submit ? 'Enter' : 'click'} opens a result when '
        'the window is wide but settings are narrow',
        (WidgetTester tester) async {
          // Drift 首次打开真实 SQLite 需要事件循环；不能在 widget fakeAsync
          // 中直接 await 宿主 I/O。后续布局、输入与导航仍由 tester 的时钟驱动。
          final AppModel model = (await tester.runAsync<AppModel>(
            () => _buildAppModel(designSystem),
          ))!;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(900, 1000);
          addTearDown(() {
            tester.view.resetDevicePixelRatio();
            tester.view.resetPhysicalSize();
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                appProvider.overrideWith((Ref ref) => model),
                // 全局搜索会求值制卡设置的可见性，进而创建 Anki 仓库；与真实
                // 宿主一样装配平台服务，复用 AppModel 已持有的测试服务实例。
                platformServicesProvider.overrideWithValue(
                  model.platformServices,
                ),
              ],
              child: TranslationProvider(
                child: MaterialApp(
                  theme: model.themeNotifier.theme.copyWith(
                    splashFactory: NoSplash.splashFactory,
                  ),
                  home: const Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 560,
                        child: SettingsHomePage(embedded: true),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final Finder home = find.byType(SettingsHomePage);
          expect(MediaQuery.sizeOf(tester.element(home)).width, 900);
          expect(tester.getSize(home).width, 560);
          expect(find.byType(MaterialSupportingPaneLayout), findsNothing);

          await tester.enterText(find.byType(EditableText), t.eink_mode);
          await tester.pumpAndSettle();
          final Finder result = find.byKey(
            const ValueKey<String>(
              'settings-search-result.appearance.eink_mode',
            ),
          );
          expect(result, findsOneWidget);
          if (submit) {
            await tester.testTextInput.receiveAction(TextInputAction.search);
          } else {
            await tester.ensureVisible(result);
            await tester.tap(result);
          }
          await tester.pumpAndSettle();

          final SettingsDetailPage detail = tester.widget<SettingsDetailPage>(
            find.byType(SettingsDetailPage),
          );
          expect(detail.destination!.id, SettingsDestinationId.appearance);
          expect(SettingsSearchReveal.pendingItemId, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  }
}

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/utils.dart';
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
    appName: 'Hibiki',
    packageName: 'jp.hibiki.test',
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
    'hibiki_settings_search_',
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
                        width: 680,
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
          expect(tester.getSize(home).width, 680);
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

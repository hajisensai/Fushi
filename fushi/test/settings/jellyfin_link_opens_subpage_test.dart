import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2485：在线服务 → 「Jellyfin · Emby」行点开后渲染的是整页「在线服务」而不是
/// Jellyfin 配置页。根因：`_JellyfinSettingsLink._open` 用 `SettingsDetailPage(
/// destination:)` 推一个合成的、复用父分类 `services` id 的 destination，而默认
/// 构造器按 id 回顶层 schema 找「最新声明」，找回来的正是父页。合成子页必须走
/// `SettingsDetailPage.subPage`。
///
/// 本测试真渲染 schema 里那一行、真点击、真 push，断言落地页的内容——不是断言
/// 构造器名字：只要有人再把它换回按 id 找回父页的路径，`JellyfinConfigWidget`
/// 就不在树里、而父页的 Dandanplay 行会出现。
void main() {
  testWidgets('点「Jellyfin · Emby」行推出的是 Jellyfin 配置页，不是在线服务根页', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);

    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        builder: (SettingsContext settingsContext) {
          final SettingsDestination services =
              buildSettingsSchema(settingsContext).firstWhere(
                (SettingsDestination d) =>
                    d.id == SettingsDestinationId.services,
              );
          final SettingsCustomItem link =
              services.sections
                      .expand((SettingsSection s) => s.items)
                      .firstWhere(
                        (SettingsItem i) =>
                            i.id == 'services.media_server.jellyfin',
                      )
                  as SettingsCustomItem;
          return Scaffold(body: link.builder(settingsContext));
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(JellyfinConfigWidget), findsNothing);
    await tester.tap(find.text('Jellyfin · Emby'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(
      find.text('Dandanplay'),
      findsNothing,
      reason: 'Dandanplay 是在线服务根页的行；它出现即说明落地页被换成了父页',
    );
    expect(find.byType(JellyfinConfigWidget), findsOneWidget);
    final SettingsDetailPage page = tester.widget<SettingsDetailPage>(
      find.byType(SettingsDetailPage),
    );
    expect(
      page.subPageBuilder,
      isNotNull,
      reason: '合成的子页 destination 复用父分类 id，必须走 .subPage 才不会被按 id 换成父页',
    );
  });
}

Future<AppModel> _appModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'hibiki_jellyfin_link_',
  );
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return _TestAppModel()
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

Widget _harness({
  required FushiDatabase db,
  required AppModel appModel,
  required Widget Function(SettingsContext) builder,
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
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) => builder(
            SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');
}

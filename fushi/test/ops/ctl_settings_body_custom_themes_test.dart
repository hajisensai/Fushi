import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart' show ThemeNotifier;
import 'package:fushi/src/ops/ctl_settings_body_custom_themes.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 自定义主题控制通道条目：新建 / 改界面底色 / 清除 / 删除真写穿 ThemeNotifier
/// 的主题列表与当前主题键。
void main() {
  late FushiDatabase db;
  late AppModel appModel;
  late SettingsContext sc;
  late Directory tempDir;

  SettingsCliList cli() =>
      (buildCtlCustomThemesBodyPages()
                  .expand((CtlBodyPage p) => p.items)
                  .singleWhere(
                    (SettingsItem i) =>
                        i.id == '${kCtlCustomThemesIdPrefix}themes',
                  )
              as SettingsCustomItem)
          .cliList!;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tempDir = Directory.systemTemp.createTempSync('fushi_theme_cli_');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
    appModel.themeNotifier = ThemeNotifier(db, () => const TextTheme());
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
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
  }

  testWidgets('add selects theme, set surface, clear, remove falls back', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList list = cli();

    final Map<String, Object?> added =
        await list.add!(sc, <String, String>{
              'name': '柔和蓝',
              'accent': '#0B57D0',
              'surface': '#DCDFE6',
            })
            as Map<String, Object?>;
    final String id = added['id']! as String;
    expect(added['surface'], '#DCDFE6');
    expect(added['active'], isTrue);
    expect(appModel.appThemeKey, 'custom-theme:$id');
    final CustomThemeEntry stored = appModel.customThemeById(id)!;
    expect(stored.surfaceColor, 0xFFDCDFE6);
    expect(stored.primaryColor, 0xFF0B57D0);
    expect(stored.seed, 0xFF0B57D0);

    await list.update!(sc, id, <String, String>{'surface': '#CFD3DC'});
    expect(appModel.customThemeById(id)!.surfaceColor, 0xFFCFD3DC);
    // 没给的字段不动。
    expect(appModel.customThemeById(id)!.name, '柔和蓝');

    await list.update!(sc, id, <String, String>{'surface': 'none'});
    expect(appModel.customThemeById(id)!.surfaceColor, isNull);

    await expectLater(
      list.update!(sc, id, <String, String>{'surface': 'blue'}),
      throwsArgumentError,
    );
    await expectLater(
      list.update!(sc, id, <String, String>{'bogus': '1'}),
      throwsArgumentError,
    );

    final List<Map<String, Object?>> rows = await list.list(sc);
    expect(rows.single['id'], id);

    await list.remove!(sc, id);
    expect(appModel.customThemes, isEmpty);
    expect(appModel.appThemeKey, 'system-theme');
  });

  testWidgets('add with select=false keeps current theme key', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await appModel.setAppThemeKey('m3-blue');
    await cli().add!(sc, <String, String>{
      'surface': '#DCDFE6',
      'select': 'false',
    });
    expect(appModel.appThemeKey, 'm3-blue');
    expect(appModel.customThemes.single.surfaceColor, 0xFFDCDFE6);
  });
}

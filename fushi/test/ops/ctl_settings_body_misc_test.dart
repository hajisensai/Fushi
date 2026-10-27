import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/lookup/browser_extension_setup.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_body_browser_extension.dart';
import 'package:fushi/src/ops/ctl_settings_body_dict_style.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_body_misc.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _DictAppModel extends AppModel {
  _DictAppModel() : super(testPlatformServices());

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
    Dictionary(name: 'JMdict', formatKey: 'yomichan', order: 0),
  ];
}

/// 组 E 逃生口页面的控制通道条目：应用图标 / 浏览器扩展安装助手 / 词典样式
/// 可视化规则。值与动作都真写穿 prefs（不是只校验声明）。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;

  T itemOf<T extends SettingsItem>(List<CtlBodyPage> pages, String id) =>
      pages
              .expand((CtlBodyPage p) => p.items)
              .singleWhere((SettingsItem i) => i.id == id)
          as T;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_misc_cli_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = _DictAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() => db.close());

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

  group('应用图标', () {
    testWidgets('icon 读当前预设；未知 key / 相对路径在任何原生调用前被拒', (
      WidgetTester tester,
    ) async {
      await pumpContext(tester);
      final List<CtlBodyPage> pages = buildCtlMiscBodyPages();
      final SettingsCustomItem icon = itemOf<SettingsCustomItem>(
        pages,
        '${kCtlAppIconIdPrefix}icon',
      );
      expect(icon.cliValue!.read(sc), currentAppIconSelection.value.presetKey);
      expect(icon.cliValue!.options!(sc), presetIconAssets.keys.toList());
      await expectLater(
        icon.cliValue!.write(sc, 'no-such-icon'),
        throwsArgumentError,
      );

      final SettingsActionItem custom = itemOf<SettingsActionItem>(
        pages,
        '${kCtlAppIconIdPrefix}set_custom',
      );
      final SettingsCliAction cli = custom.cli!;
      expect(cli.params.single.path, isTrue);
      await expectLater(
        cli.run!(sc, <String, String>{'path': 'relative.png'}),
        throwsArgumentError,
      );
      if (Platform.isWindows || Platform.isAndroid) {
        await expectLater(
          cli.run!(sc, <String, String>{
            'path': '${Directory.systemTemp.path}/fushi_missing_icon.png',
          }),
          throwsArgumentError,
          reason: '文件不存在先拒，不碰原生窗口图标',
        );
        // 已是当前预设：幂等成功，不触发原生切换。
        await icon.cliValue!.write(sc, currentAppIconSelection.value.presetKey);
      }
    });
  });

  group('浏览器扩展', () {
    test('连接判据与轮询：近期见过即连上，没见过超时返回 false', () async {
      final DateTime now = DateTime(2026, 10, 16, 12);
      expect(isBrowserExtensionRecentlySeen(null, now: now), isFalse);
      expect(
        isBrowserExtensionRecentlySeen(
          now.subtract(const Duration(seconds: 149)),
          now: now,
        ),
        isTrue,
      );
      expect(
        isBrowserExtensionRecentlySeen(
          now.subtract(const Duration(seconds: 151)),
          now: now,
        ),
        isFalse,
      );
      expect(
        await waitForBrowserExtensionConnection(lastSeen: DateTime.now),
        isTrue,
      );
      expect(
        await waitForBrowserExtensionConnection(
          lastSeen: () => null,
          timeout: const Duration(milliseconds: 60),
          pollInterval: const Duration(milliseconds: 10),
        ),
        isFalse,
      );
    });

    testWidgets('status 不泄露 token；prepare 用当前 server 真值解压；verify 校验 timeout', (
      WidgetTester tester,
    ) async {
      await pumpContext(tester);
      await tester.runAsync(() async {
        await appModel.setFushiApiKey('SECRET-KEY-123');
        await appModel.setFushiApiServerEnabled(true);

        final Map<String, Object?> status =
            (await browserExtensionStatusForCli(sc, const <String, String>{}))!
                as Map<String, Object?>;
        expect(status['serverEnabled'], isTrue);
        expect(status['hasToken'], isTrue);
        expect(status['connected'], isFalse);
        expect(status['port'], appModel.fushiApiPort);
        expect(jsonEncode(status), isNot(contains('SECRET-KEY-123')));

        BrowserExtensionServerConfig? injected;
        final BrowserExtensionPrepareResult result =
            await prepareBrowserExtensionForInstall(
              appModel,
              extract:
                  ({required BrowserExtensionServerConfig serverConfig}) async {
                    injected = serverConfig;
                    return '/tmp/fushi-ext';
                  },
            );
        expect(result.directory, '/tmp/fushi-ext');
        expect(result.serverEnabled, isTrue);
        expect(result.portConflict, isFalse);
        expect(injected!.token, 'SECRET-KEY-123', reason: '已有 token 不覆盖');
        expect(injected!.port, appModel.fushiApiPort);

        final SettingsActionItem verify = itemOf<SettingsActionItem>(
          buildCtlBrowserExtensionBodyPages(),
          '${kCtlBrowserExtensionIdPrefix}verify',
        );
        await expectLater(
          verify.cli!.run!(sc, <String, String>{'timeout': '0'}),
          throwsArgumentError,
        );
        final Map<String, Object?> verified =
            (await verify.cli!.run!(sc, <String, String>{'timeout': '1'}))!
                as Map<String, Object?>;
        expect(verified['connected'], isFalse);

        final SettingsActionItem open = itemOf<SettingsActionItem>(
          buildCtlBrowserExtensionBodyPages(),
          '${kCtlBrowserExtensionIdPrefix}open_extensions_page',
        );
        await expectLater(
          open.cli!.run!(sc, <String, String>{'browser': 'netscape'}),
          throwsArgumentError,
        );
      });
    });
  });

  group('词典样式可视化规则', () {
    testWidgets('add / set / rm 真写穿规则表与 CSS 编译缓存', (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsCliList cli = itemOf<SettingsCustomItem>(
        buildCtlDictStyleBodyPages(),
        kCtlDictStyleRulesId,
      ).cliList!;
      await tester.runAsync(() async {
        expect(await cli.list(sc), isEmpty);

        final Map<String, Object?> added =
            (await cli.add!(sc, <String, String>{
                  'part': 'expression',
                  'text_color': '#FF0000',
                  'bold': 'true',
                }))!
                as Map<String, Object?>;
        expect(added['id'], 'expression');
        expect(added['text_color'], '#FFFF0000');
        expect(prefs.dictStyleRulesRaw, contains('expression'));

        await cli.add!(sc, <String, String>{
          'part': 'glossaryContent',
          'dictionary': 'JMdict',
          'font_scale': '1.2',
        });
        final List<Map<String, Object?>> rows = await cli.list(sc);
        expect(
          rows.map((Map<String, Object?> r) => r['id']),
          containsAll(<String>['expression', 'glossaryContent@JMdict']),
        );

        // 非释义部位不能限定到单本词典；未装的词典被拒；重复 add 被拒。
        await expectLater(
          cli.add!(sc, <String, String>{
            'part': 'expression',
            'dictionary': 'JMdict',
            'bold': 'true',
          }),
          throwsArgumentError,
        );
        await expectLater(
          cli.add!(sc, <String, String>{
            'part': 'glossaryTag',
            'dictionary': 'Nope',
            'bold': 'true',
          }),
          throwsArgumentError,
        );
        await expectLater(
          cli.add!(sc, <String, String>{
            'part': 'expression',
            'italic': 'true',
          }),
          throwsArgumentError,
        );
        await expectLater(
          cli.update!(sc, 'expression', <String, String>{'font_scale': '9'}),
          throwsArgumentError,
        );

        await cli.update!(sc, 'expression', <String, String>{
          'text_color': 'none',
          'underline': 'false',
        });
        final DictStyleProps props = dictStylePropsFor(
          appModel.dictStyleRules,
          DictStylePart.expression,
          null,
        );
        expect(props.textColor, isNull);
        expect(props.bold, isTrue);
        expect(props.underline, isFalse);

        // 属性全清空 = 整条移除。
        final Map<String, Object?> cleared =
            (await cli.update!(sc, 'expression', <String, String>{
                  'bold': 'none',
                  'underline': 'none',
                }))!
                as Map<String, Object?>;
        expect(cleared['removed'], isTrue);

        await cli.remove!(sc, 'glossaryContent@JMdict');
        expect(appModel.dictStyleRules, isEmpty);
        expect(prefs.dictStyleRulesRaw, isEmpty);
        await expectLater(cli.remove!(sc, 'expression'), throwsArgumentError);
      });
    });
  });
}

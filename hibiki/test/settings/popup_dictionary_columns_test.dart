import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-776「查词弹窗配置一行显示 N 个词典（实验性）」。一个词条内多词典块原本是
/// 纵向单列；新功能改为同一词条内每行并排 N 个（N=1 退化为现状单列）。列数由
/// PreferencesRepository.popupDictionaryColumns（1..4）经 CSS 变量 --dict-columns
/// 注入 popup 文档，CSS grid `repeat(var(--dict-columns,1), minmax(0,1fr))` 渲染。
///
/// 这里验证三层契约：
///  1. 源码守卫：popup.css 的 grid 规则真实存在、只用 column-gap（不含 row-gap/
///     裸 gap，避免 N=1 时 gap+margin 叠成双倍纵向间距破坏老用户默认观感）。
///  2. 源码守卫：dictionary_popup_webview.dart 真把 --dict-columns 注入文档。
///  3. UI 行为：真实 schema 的 Result Display 组里有这条滑块，min1/max4/divisions3，
///     副标题带「实验性」后缀。
void main() {
  HibikiDatabase testDb() {
    return HibikiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
  }

  /// 轻量 AppModel：不跑 initialise()，但用真实 PreferencesRepository 接上
  /// prefsRepo，让 appModel.popupDictionaryColumns 读到真实偏好（默认 1）。
  Future<AppModel> prefsBackedAppModel(HibikiDatabase db) async {
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_popup_columns_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final AppModel appModel = AppModel(testPlatformServices());
    return appModel
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tempDir,
      )
      ..wireDatabaseForTesting(db);
  }

  /// 从真实 schema 里取出 lookup.popup_dictionary_columns 这一条（保证测的是生产
  /// 配置，不是测试自拟副本），包成单 section destination 渲染。
  SettingsSliderItem columnsItem(SettingsContext settingsContext) {
    return buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsSliderItem>()
        .firstWhere((SettingsSliderItem i) =>
            i.id == 'lookup.popup_dictionary_columns');
  }

  SettingsDestination columnsOnlyDestination(SettingsContext settingsContext) {
    return SettingsDestination(
      id: SettingsDestinationId.lookup,
      title: t.popup_dictionary_columns,
      icon: Icons.view_column_outlined,
      sections: <SettingsSection>[
        SettingsSection(items: <SettingsItem>[columnsItem(settingsContext)]),
      ],
    );
  }

  Widget buildHarness(AppModel appModel) {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    return ProviderScope(
      child: MaterialApp(
        navigatorKey: navKey,
        theme: ThemeData.light(useMaterial3: true),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
        home: Scaffold(
          body: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              return StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  final SettingsContext live = SettingsContext(
                    context: context,
                    appModel: appModel,
                    ref: ref,
                    readerSource: ReaderHibikiSource.instance,
                    refresh: () => setState(() {}),
                  );
                  return const MaterialSettingsRenderer().buildDetailContent(
                    settingsContext: live,
                    destination: columnsOnlyDestination(live),
                    shrinkWrap: true,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  late HibikiDatabase db;

  setUp(() async {
    db = testDb();
    MediaSource.setDatabase(db);
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
  });

  tearDown(() async {
    ReaderHibikiSource.readerSettings = null;
    await db.close();
  });

  group('popup dictionary columns slider (Result Display group)', () {
    testWidgets('renders a 1..4 slider with the experimental subtitle suffix',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildHarness(await prefsBackedAppModel(db)));
      await tester.pump();

      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 1, reason: 'N=1 是退化的经典单列下界');
      expect(slider.max, 4);
      expect(slider.divisions, 3, reason: '1..4 共 4 档 = 3 个 division');

      // 标题 + 实时读数（titleReadout）。
      expect(find.text('${t.popup_dictionary_columns} (1)'), findsOneWidget,
          reason: '默认 1 列，标题带实时读数');

      // 副标题 = hint + 实验性后缀，渲染成单个 Text。
      final String expectedSubtitle =
          t.popup_dictionary_columns_hint + t.settings_experimental_suffix;
      expect(find.text(expectedSubtitle), findsOneWidget,
          reason: '副标题展示 hint 文案并标注实验性后缀');
      expect(expectedSubtitle, contains(t.settings_experimental_suffix.trim()),
          reason: '后缀确实进了副标题');
    });

    testWidgets('schema item is the production lookup.popup_dictionary_columns',
        (WidgetTester tester) async {
      final AppModel appModel = await prefsBackedAppModel(db);
      late SettingsContext probe;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                probe = SettingsContext(
                  context: context,
                  appModel: appModel,
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
                  refresh: () {},
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final SettingsSliderItem item = columnsItem(probe);
      expect(item.min, 1);
      expect(item.max, 4);
      expect(item.divisions, 3);
      expect(item.titleReadout, isTrue);
      expect(item.label?.call(2), '2');
      // value bridges the int preference into the slider's double space.
      expect(item.value(probe), appModel.popupDictionaryColumns.toDouble());
    });
  });

  group('source guard (anti-regression)', () {
    test('popup.css grid uses --dict-columns and column-gap only (no gap)', () {
      final String css =
          File('assets/popup/popup.css').readAsStringSync().replaceAll(
                '\r\n',
                '\n',
              );

      final int ruleStart = css.indexOf('.glossary-section > .category-body {');
      expect(ruleStart, isNonNegative, reason: 'glossary 词典容器必须是 grid 容器');
      final int ruleEnd = css.indexOf('}', ruleStart);
      expect(ruleEnd, greaterThan(ruleStart));
      final String rule = css.substring(ruleStart, ruleEnd);

      expect(rule, contains('display: grid'));
      expect(rule, contains('repeat(var(--dict-columns'),
          reason: '列数由 --dict-columns 驱动，缺省回退 1');
      expect(rule, contains('minmax(0, 1fr)'));
      expect(rule, contains('column-gap'),
          reason: '只用 column-gap（列间），纵向 margin 不碰');

      // C 维度必修：该规则块绝对不能出现 row-gap 或裸 gap —— 否则 grid 不塌缩
      // margin，N=1 时纵向间距 = gap + margin(3px) = 双倍，破坏所有用户默认观感。
      expect(rule, isNot(contains('row-gap')),
          reason: 'row-gap 会和 .glossary-group 的 margin-top:3px 叠成双倍纵向间距');
      expect(RegExp(r'(^|[^-])gap\s*:').hasMatch(rule), isFalse,
          reason: '裸 gap（行+列）同样会引入双倍纵向间距，只允许 column-gap');
    });

    test('popup.css keeps the inherited row margin + narrow-column guards', () {
      final String css =
          File('assets/popup/popup.css').readAsStringSync().replaceAll(
                '\r\n',
                '\n',
              );
      // 行内纵向间距仍由 .glossary-group margin-top:3px 提供（N=1 与现状一致）。
      expect(css,
          contains('.glossary-section > .category-body > .glossary-group {'),
          reason: 'glossary-group 行 margin 规则不得消失');
      expect(css, contains('margin-top: 3px'));
      expect(css, contains('min-width: 0'), reason: '长内容不得撑破 1fr 列');
      expect(css, contains('.glossary-group img {'),
          reason: '宽图必须 max-width:100% 收进窄列');
    });

    test('dictionary_popup_webview injects --dict-columns from the preference',
        () {
      final String dart = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(dart, contains('popupDictionaryColumns'), reason: '必须读偏好的列数');
      expect(dart, contains("setProperty('--dict-columns'"),
          reason: '必须把列数注入 --dict-columns CSS 变量');
      // 注入点蹭 theme 变量重注（live theme-switch 也重应用），而不是单独属性路径。
      final int themeFnStart = dart.indexOf('String _themeVariablesJs()');
      expect(themeFnStart, isNonNegative);
      final int injectAt = dart.indexOf("setProperty('--dict-columns'");
      expect(injectAt, greaterThan(themeFnStart),
          reason: '--dict-columns 应在 _themeVariablesJs 内随主题变量一起注入');
    });

    test('schema slider bridges the int preference (no double in storage)', () {
      final String source = File('lib/src/settings/settings_schema_lookup.dart')
          .readAsStringSync();
      final int start = source.indexOf("id: 'lookup.popup_dictionary_columns'");
      expect(start, isNonNegative);
      // 取到下一条 item 的 id 或本 SettingsSliderItem 结束之前的块。
      final int end = source.indexOf("id: 'lookup.", start + 10);
      final String block =
          end > start ? source.substring(start, end) : source.substring(start);

      expect(block, contains('min: 1'));
      expect(block, contains('max: 4'));
      expect(block, contains('divisions: 3'));
      expect(block, contains('titleReadout: true'));
      expect(block, contains('settings_experimental_suffix'),
          reason: '副标题必须标注实验性');
      // int↔double 桥接：value 用 .toDouble()，onChanged 用 .round()。
      expect(block, contains('.toDouble()'),
          reason: 'value 把 int 偏好桥接成滑条 double');
      expect(block, contains('.round()'),
          reason: 'onChanged 把滑条 double 收回 int 偏好');
    });
  });
}

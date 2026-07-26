import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/popup_settings_injection.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-717 ③：查词静态注入串的 build 去重。
///
/// in-app 每次查词都重建整个静态设置负载（含 MB 级字体 data:URL 串的 join /
/// jsonEncode 转义扫描 / 模板插值），再与上一次的全串比较后大多丢弃——BUG-712 ③
/// 只去掉了重复 eval，没去掉重复 build。修复后 [buildPopupStaticSettingsJs] 按
/// 全部输入的廉价投影 memo：命中返回同一实例（同 revision，零 MB 级操作），
/// 失效路径覆盖「换字体 / 改主题 / 改偏好 / 切语言 / 换词典集」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    debugResetPopupSettingsInjectionCaches();
    ReaderHibikiSource.readerSettings = null;
  });

  tearDown(() {
    ReaderHibikiSource.readerSettings = null;
    debugResetPopupSettingsInjectionCaches();
    LocaleSettings.setLocale(AppLocale.en);
  });

  PopupStaticSettingsJs build(
    MemoAppModel appModel, {
    ThemeData? theme,
    PopupSettingsOptions options = const PopupSettingsOptions(),
  }) =>
      buildPopupStaticSettingsJs(
        appModel: appModel,
        theme: theme ?? ThemeData(brightness: Brightness.light),
        options: options,
      );

  group('memo hit', () {
    test('unchanged inputs return the identical product (same revision)', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs first = build(appModel);
      final PopupStaticSettingsJs second = build(appModel);
      expect(identical(first, second), isTrue,
          reason: '同输入必须命中 memo 返回同一实例——命中路径不得再有 MB 级串重建');
      expect(second.revision, first.revision);
    });

    test('per-options slots do not thrash each other', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs inApp1 = build(appModel);
      final PopupStaticSettingsJs global1 = build(appModel,
          options: const PopupSettingsOptions(globalLookup: true));
      // 交替调用（in-app 弹窗与 app 外剪贴板面板并存的真实形态）不得互相冲刷。
      final PopupStaticSettingsJs inApp2 = build(appModel);
      final PopupStaticSettingsJs global2 = build(appModel,
          options: const PopupSettingsOptions(globalLookup: true));
      expect(identical(inApp1, inApp2), isTrue,
          reason: 'options 组合各占一个 memo 槽，交替调用仍须命中');
      expect(identical(global1, global2), isTrue);
      expect(inApp1.revision, isNot(global1.revision));
    });

    test('composed buildPopupSettingsJs == head + entries + tail (byte parity)',
        () {
      final MemoAppModel appModel = MemoAppModel();
      final DictionarySearchResult result = DictionarySearchResult(
        searchTerm: '語',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'd',
            word: '語',
            reading: 'ご',
            meaning: '"def"',
          ),
        ],
      );
      final ThemeData theme = ThemeData(brightness: Brightness.light);
      final PopupStaticSettingsJs staticJs = buildPopupStaticSettingsJs(
        appModel: appModel,
        theme: theme,
        options: const PopupSettingsOptions(globalLookup: true),
      );
      final String composed = buildPopupSettingsJs(
        appModel: appModel,
        theme: theme,
        result: result,
        options: const PopupSettingsOptions(globalLookup: true),
      );
      expect(
        composed,
        '${staticJs.head}${buildPopupEntriesJs(result)}${staticJs.tail}',
        reason: '全局查词栈 / 剪贴板面板的整帧路径必须保持逐字节一致（host 以 '
            'settingsJs 变更为重渲判据）',
      );
    });
  });

  group('memo invalidation', () {
    test('改偏好：flipping a window.* pref rebuilds with a new revision', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs before = build(appModel);
      expect(before.head, contains('window.collapseDictionaries = false'));

      appModel.collapseDictionariesValue = true;
      final PopupStaticSettingsJs after = build(appModel);
      expect(after.revision, isNot(before.revision),
          reason: '偏好变化必须换 revision（in-app 据此重发静态段）');
      expect(after.head, contains('window.collapseDictionaries = true'));

      // 翻回去：允许失效过度（重建一次），但内容必须回到原值。
      appModel.collapseDictionariesValue = false;
      final PopupStaticSettingsJs back = build(appModel);
      expect(back.combined, before.combined);
    });

    test('切语言：locale switch rebuilds and carries the new i18n strings', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs en = build(appModel);

      LocaleSettings.setLocale(AppLocale.ja);
      final PopupStaticSettingsJs ja = build(appModel);
      expect(ja.revision, isNot(en.revision),
          reason: '静态段内嵌 i18n 文案，语言切换必须失效重建');
      expect(ja.combined, isNot(en.combined));

      LocaleSettings.setLocale(AppLocale.en);
      final PopupStaticSettingsJs enAgain = build(appModel);
      expect(enAgain.combined, en.combined, reason: '切回原语言内容必须与最初一致（重建但不串味）');
    });

    test('改主题：brightness change rebuilds the theme vars', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs light =
          build(appModel, theme: ThemeData(brightness: Brightness.light));
      final PopupStaticSettingsJs dark =
          build(appModel, theme: ThemeData(brightness: Brightness.dark));
      expect(dark.revision, isNot(light.revision));
      expect(dark.head, contains("setAttribute('data-theme', 'dark')"));
      expect(light.head, contains("setAttribute('data-theme', 'light')"));
    });

    test('换词典集：hidden/collapsed name lists rebuild the payload', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs before = build(appModel);

      appModel.dictionariesValue = <Dictionary>[
        Dictionary(
          name: 'HiddenDict',
          formatKey: 'yomichan',
          order: 0,
          hiddenLanguages: <String>[JapaneseLanguage.instance.languageCode],
        ),
      ];
      final PopupStaticSettingsJs after = build(appModel);
      expect(after.revision, isNot(before.revision),
          reason: '词典集（隐藏/折叠名单）变化必须失效重建');
      expect(after.head, contains('HiddenDict'));
    });

    test('自定义 CSS：customDictCSS / globalDictCSS changes rebuild', () {
      final MemoAppModel appModel = MemoAppModel();
      final PopupStaticSettingsJs before = build(appModel);

      appModel.customDictCSSValue = <String, String>{'d': '.entry{color:red}'};
      final PopupStaticSettingsJs after = build(appModel);
      expect(after.revision, isNot(before.revision));
      expect(after.tail, contains('.entry{color:red}'));
    });
  });

  group('换字体：dictionary font JS memo（(name,path,mtime,size) 指纹键）', () {
    late Directory tempDir;
    late HibikiDatabase db;
    late MemoAppModel appModel;
    late File fontFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_fontmemo');
      final Directory fontsDir =
          await Directory('${tempDir.path}/custom_fonts').create();
      fontFile = File('${fontsDir.path}/MemoFont.ttf');
      await fontFile.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]); // AAECAw==

      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      final ReaderSettings settings = ReaderSettings(db);
      await settings.loadFromPrefsSnapshot(<String, String>{
        'src:reader_ttu:dict_fonts': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'MemoFont',
            'path': fontFile.path,
            'enabled': true,
          },
        ]),
      });
      ReaderHibikiSource.readerSettings = settings;

      appModel = MemoAppModel()..appDirectoryOverride = tempDir;
    });

    tearDown(() async {
      ReaderHibikiSource.readerSettings = null;
      await db.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('unchanged font state returns the identical JS instance', () {
      final String first = dictionaryFontStyleJs(appModel);
      expect(first, contains('AAECAw=='), reason: '前置：字体已内联进注入串');
      final String second = dictionaryFontStyleJs(appModel);
      expect(identical(first, second), isTrue,
          reason: '同 (name,path,mtime,size) 必须命中 memo 返回同一实例——'
              '这正是被丢弃 4~5 遍的那个 MB 级串');
      // 静态设置产物同样命中（字体键是其 memo 键的一部分）。
      final PopupStaticSettingsJs s1 = build(appModel);
      final PopupStaticSettingsJs s2 = build(appModel);
      expect(identical(s1, s2), isTrue);
    });

    test(
        'overwriting the font file (mtime bump) rebuilds font JS and the '
        'static payload', () async {
      final String before = dictionaryFontStyleJs(appModel);
      final PopupStaticSettingsJs staticBefore = build(appModel);
      expect(before, contains('AAECAw=='));

      await fontFile.writeAsBytes(<int>[0x09, 0x09, 0x09, 0x09]); // CQkJCQ==
      await fontFile
          .setLastModified(DateTime.now().add(const Duration(seconds: 2)));

      final String after = dictionaryFontStyleJs(appModel);
      expect(after, contains('CQkJCQ=='),
          reason: '文件原地覆盖（mtime/size 变）必须失效 memo 并注入新内容');
      expect(after, isNot(contains('AAECAw==')));
      final PopupStaticSettingsJs staticAfter = build(appModel);
      expect(staticAfter.revision, isNot(staticBefore.revision),
          reason: '字体键失效必须传导到静态设置产物（换 revision → in-app 重发）');
      expect(staticAfter.head, contains('CQkJCQ=='));
    });
  });
}

/// 覆盖注入路径读到的全部 getter 的裸 [AppModel] 替身（prefsRepo 未初始化，
/// 真 getter 会抛 Null check），可变字段供失效用例翻转。
class MemoAppModel extends AppModel {
  MemoAppModel() : super(testPlatformServices());

  bool collapseDictionariesValue = false;
  List<Dictionary> dictionariesValue = <Dictionary>[];
  Map<String, String> customDictCSSValue = <String, String>{};
  Directory? appDirectoryOverride;

  @override
  double get appUiScale => 1.0;
  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  int get popupDictionaryColumns => 1;
  @override
  int get popupAutoExpandDictionaries => 0;
  @override
  bool get deduplicatePitchAccents => false;
  @override
  bool get harmonicFrequency => false;
  @override
  bool get showExpressionTags => false;
  @override
  bool get collapseDictionaries => collapseDictionariesValue;
  @override
  List<Dictionary> get dictionaries => dictionariesValue;
  @override
  Map<String, String> get customDictCSS => customDictCSSValue;
  @override
  String get globalDictCSS => '';
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  Directory get appDirectory => appDirectoryOverride ?? super.appDirectory;
}

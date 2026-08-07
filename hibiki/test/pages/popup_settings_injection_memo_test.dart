import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/popup_settings_injection.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
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

    // 审查修复：原版把实现体（head + entries + tail 拼接）抄成期望值，无论
    // 实现怎么改都恒真。改成断言可观察行为：整帧路径里三段负载的**顺序**
    // （用注入串里的独立标记定位）、词条真的进了整帧、同输入整帧稳定、改输入
    // 整帧必变（host 以 settingsJs 变更为重渲判据，memo 不得把变更吞掉）。
    test('整帧 buildPopupSettingsJs：词条负载夹在静态 head/tail 之间且随输入变化', () {
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
      const PopupSettingsOptions options =
          PopupSettingsOptions(globalLookup: true);
      String compose() => buildPopupSettingsJs(
            appModel: appModel,
            theme: theme,
            result: result,
            options: options,
          );
      final String composed = compose();

      final int headMarker = composed.indexOf('window.audioSources =');
      final int entriesMarker = composed.indexOf('window.lookupEntries =');
      final int tailMarker = composed.indexOf('window.dictionaryStyles =');
      expect(headMarker, greaterThanOrEqualTo(0),
          reason: '整帧必须带静态 head（设置/主题/字体）');
      expect(entriesMarker, greaterThan(headMarker), reason: '词条负载插在 head 之后');
      expect(tailMarker, greaterThan(entriesMarker),
          reason: '词典样式/自定义 CSS 的 tail 在词条负载之后（popup.js '
              '依此顺序着色）');
      expect(composed.substring(entriesMarker, tailMarker), contains('語'),
          reason: '词条内容必须真的进了整帧，不是空壳');

      expect(compose(), composed,
          reason: '同输入整帧必须逐字节稳定——host 以串变更作重渲判据，'
              '抽风会变成无休止重渲');

      appModel.globalDictCSSValue = 'body{color:red}';
      final String afterCssChange = compose();
      expect(afterCssChange, isNot(composed),
          reason: '静态输入变了整帧必须跟着变——memo 把真变更吞掉就是 '
              'BUG（用户改了设置弹窗不生效）');
      expect(afterCssChange, contains('body{color:red}'));
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

    // 审查修复：memo 命中判据是一长串 `cached.X == 现值` 比较行，删掉其中任一行都会
    // 让对应设置「改了不生效」且不报错。下面逐字段各一条：先确认 memo 真的在命中
    // （否则用例会因「从不命中」而假绿），再只翻这一个字段，断言 revision 必变 +
    // 新值真的进了注入串。每个用例只动一个 memo 键字段，所以删掉它对应的比较行
    // 就只有它会红。
    final List<
        ({
          String name,
          void Function(MemoAppModel model) mutate,
          String marker,
        })> scalarCases = <({
      String name,
      void Function(MemoAppModel model) mutate,
      String marker,
    })>[
      (
        name: 'appUiScale（界面大小 → zoom）',
        mutate: (MemoAppModel m) => m.appUiScaleValue = 1.5,
        marker: 'window.__hoshiPopupUiScale = 1.5',
      ),
      (
        name: 'dictionaryFontSize（词典字号 → zoom）',
        mutate: (MemoAppModel m) => m.dictionaryFontSizeValue = 24,
        marker: 'window.__hoshiPopupFontSize = 24.0',
      ),
      (
        name: 'popupWheelSpeed（BUG-1026 滚轮速度）',
        mutate: (MemoAppModel m) => m.popupWheelSpeedValue = 2.5,
        marker: 'window.__hoshiPopupWheelSpeed = 2.5',
      ),
      (
        name: 'enabledAudioSources（音源列表）',
        mutate: (MemoAppModel m) =>
            m.enabledAudioSourcesValue = const <String>['jpod101'],
        marker: 'window.audioSources = ["jpod101"]',
      ),
      (
        name: 'deduplicatePitchAccents',
        mutate: (MemoAppModel m) => m.deduplicatePitchAccentsValue = true,
        marker: 'window.deduplicatePitchAccents = true',
      ),
      (
        name: 'harmonicFrequency',
        mutate: (MemoAppModel m) => m.harmonicFrequencyValue = true,
        marker: 'window.harmonicFrequency = true',
      ),
      (
        name: 'showExpressionTags',
        mutate: (MemoAppModel m) => m.showExpressionTagsValue = true,
        marker: 'window.showExpressionTags = true',
      ),
      (
        name: 'popupAutoExpandDictionaries（autoExpandRows）',
        mutate: (MemoAppModel m) => m.popupAutoExpandDictionariesValue = 3,
        marker: 'window.autoExpandRows = 3',
      ),
      (
        name: 'popupDictionaryColumns（经 themeVarsJs）',
        mutate: (MemoAppModel m) => m.popupDictionaryColumnsValue = 3,
        marker: "'--dict-columns', '3'",
      ),
      (
        name: 'collapsedDictionaryNames（折叠名单）',
        mutate: (MemoAppModel m) => m.dictionariesValue = <Dictionary>[
              Dictionary(
                name: 'CollapsedDict',
                formatKey: 'yomichan',
                order: 0,
                collapsedLanguages: <String>[
                  JapaneseLanguage.instance.languageCode,
                ],
              ),
            ],
        marker: 'window.collapsedDictionaryNames = ["CollapsedDict"]',
      ),
      (
        name: 'globalDictCSS',
        mutate: (MemoAppModel m) => m.globalDictCSSValue = '.g{color:blue}',
        marker: '.g{color:blue}',
      ),
    ];

    for (final ({
      String name,
      void Function(MemoAppModel model) mutate,
      String marker,
    }) c in scalarCases) {
      test('memo 键字段失效：${c.name}', () {
        final MemoAppModel appModel = MemoAppModel();
        final PopupStaticSettingsJs before = build(appModel);
        expect(identical(build(appModel), before), isTrue,
            reason: '前置：未改任何输入时 memo 必须命中（否则下面的失效断言假绿）');
        expect(before.combined, isNot(contains(c.marker)),
            reason: '前置：翻转前不应已含新值标记');

        c.mutate(appModel);
        final PopupStaticSettingsJs after = build(appModel);
        expect(after.revision, isNot(before.revision),
            reason: '${c.name} 是 memo 键的一部分，变了必须重建 + 换 revision；'
                '漏比这个字段 = 用户改了设置弹窗不生效');
        expect(after.combined, contains(c.marker), reason: '重建后新值必须真的进了注入串');
      });
    }

    test('memo 键字段失效：wheelBindingsJson（词条滚轮绑定）', () {
      final MemoAppModel appModel = MemoAppModel();
      appModel.shortcutRegistry.loadDefaults(TargetPlatform.windows);
      final PopupStaticSettingsJs before = build(appModel);
      expect(identical(build(appModel), before), isTrue);

      appModel.shortcutRegistry.updateBinding(
        ShortcutAction.popupNextEntry,
        const ShortcutBindingSet(
          wheelBindings: <WheelBinding>[
            WheelBinding(
              WheelDirection.down,
              modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift},
            ),
          ],
        ),
      );
      final PopupStaticSettingsJs after = build(appModel);
      expect(after.revision, isNot(before.revision),
          reason: '改键后弹窗必须收到新绑定——漏比 wheelBindingsJson '
              '会让「改了快捷键不生效」');
      expect(after.head, contains('"ctrl"'));
      expect(after.head, contains('"shift"'));
      expect(before.head, isNot(contains('"shift"')));
    });

    test('memo 键字段失效：lookupAudioVolume（查词发音音量）', () async {
      final Directory tempDir =
          await Directory.systemTemp.createTemp('hibiki_volmemo');
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      final ReaderSettings settings = ReaderSettings(db);
      await settings.loadFromPrefsSnapshot(const <String, String>{});
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() async {
        ReaderHibikiSource.readerSettings = null;
        await db.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final MemoAppModel appModel = MemoAppModel()
        ..appDirectoryOverride = tempDir;
      final PopupStaticSettingsJs before = build(appModel);
      expect(identical(build(appModel), before), isTrue);
      expect(before.head, contains('window.lookupAudioVolume = 1.0000'));

      await settings.setLookupAudioVolume(40);
      final PopupStaticSettingsJs after = build(appModel);
      expect(after.revision, isNot(before.revision),
          reason: '音量是 memo 键的一部分，改了必须重建（否则弹窗里的发音'
              '一直用旧音量）');
      expect(after.head, contains('window.lookupAudioVolume = 0.4000'));
    });
  });

  /// 审查修复：memo 对词典样式用的是 `identical(cached.stylesJson, stylesJson)`——
  /// 它成立的前提是 [HoshiDicts] 的 `_stylesCache` **永远整体重赋值、从不就地
  /// mutate**（一旦有人改成 `_stylesCache[name] = css` 之类的就地修改，map 身份
  /// 不变 → `dictionaryStylesJson()` 不重编码 → memo 恒命中 → 用户导入/删词典后
  /// 弹窗永远用旧样式，且全链静默）。这个前提之前零覆盖。
  group('stylesJson identity 前提（memo 正确性最脆的一环）', () {
    test('dictionaryStyles / dictionaryStylesJson 未变时返回同一实例', () {
      final Map<String, String> first = FushiDicts.dictionaryStyles;
      final Map<String, String> second = FushiDicts.dictionaryStyles;
      expect(identical(first, second), isTrue,
          reason: 'dictionaryStyles 不得每次返回防御性副本——memo 靠 map 身份判'
              '变化，每次新实例会让 memo 永远不命中（性能修复失效）');

      final String json1 = DictionaryPopupWebViewState.dictionaryStylesJson();
      final String json2 = DictionaryPopupWebViewState.dictionaryStylesJson();
      expect(identical(json1, json2), isTrue,
          reason: 'map 身份未变时必须返回同一 String 实例——'
              'buildPopupStaticSettingsJs 用 identical() 比它');
    });

    test('_stylesCache 只允许整体重赋值，禁止就地 mutate', () {
      final String src = File(
        '../packages/hibiki_dictionary/lib/src/engine/fushidicts.dart',
      ).readAsStringSync();

      // 所有就地修改形态（下标写 / add* / remove* / clear / update* / putIfAbsent）一律禁止。
      final RegExp mutation = RegExp(
        r'_stylesCache\s*(?:\[|\.\s*(?:add|addAll|addEntries|remove|removeWhere|'
        r'clear|update|updateAll|putIfAbsent))',
      );
      expect(mutation.hasMatch(src), isFalse,
          reason: '就地修改不换 map 身份 → dictionaryStylesJson() 不重编码 → '
              'popup 静态段 memo 恒命中 → 导入/删除词典后弹窗永远用旧样式');

      // 重建路径的两个分支都必须赋一个**新** map 字面量。
      final int rebuildAt = src.indexOf('static void _rebuildStylesCache()');
      expect(rebuildAt, greaterThanOrEqualTo(0));
      final String rebuild =
          src.substring(rebuildAt, src.indexOf('\n  }', rebuildAt));
      expect(RegExp(r'_stylesCache\s*=\s*\{').allMatches(rebuild).length, 2,
          reason: '空分支与重建分支都要整体赋新 map（身份变 = 内容变）');
    });

    test('注入侧的 identical 判据与编码缓存键没被改成内容比较', () {
      final String injection = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(injection, contains('identical(cached.stylesJson, stylesJson)'),
          reason: '词典样式 JSON 可能是 MB 级，memo 命中判据必须是身份比较；'
              '改成 == 内容比较就把本次性能修复抵消了');

      final String webview = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();
      final int jsonAt =
          webview.indexOf('static String dictionaryStylesJson()');
      expect(jsonAt, greaterThanOrEqualTo(0));
      final String body =
          webview.substring(jsonAt, webview.indexOf('\n  }', jsonAt));
      expect(body, contains('identical(styles, _cachedStylesRef)'),
          reason: 'JSON 编码缓存的失效键就是 styles map 的身份（与 '
              '_rebuildStylesCache 整体重赋值同语义）');
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

  // 每个可变字段恰好对应 _PopupStaticSettingsMemo 的一个比较项，供「逐字段失效」
  // 用例只翻一个输入（这样删掉某一行比较就只有它对应的用例会红）。
  double appUiScaleValue = 1.0;
  double dictionaryFontSizeValue = 16;
  double popupWheelSpeedValue = 1.0;
  int popupDictionaryColumnsValue = 1;
  int popupAutoExpandDictionariesValue = 0;
  bool deduplicatePitchAccentsValue = false;
  bool harmonicFrequencyValue = false;
  bool showExpressionTagsValue = false;
  bool collapseDictionariesValue = false;
  List<Dictionary> dictionariesValue = <Dictionary>[];
  Map<String, String> customDictCSSValue = <String, String>{};
  String globalDictCSSValue = '';
  List<String> enabledAudioSourcesValue = const <String>[];
  Directory? appDirectoryOverride;

  @override
  double get appUiScale => appUiScaleValue;
  @override
  double get dictionaryFontSize => dictionaryFontSizeValue;
  @override
  double get popupWheelSpeed => popupWheelSpeedValue;
  @override
  int get popupDictionaryColumns => popupDictionaryColumnsValue;
  @override
  int get popupAutoExpandDictionaries => popupAutoExpandDictionariesValue;
  @override
  bool get deduplicatePitchAccents => deduplicatePitchAccentsValue;
  @override
  bool get harmonicFrequency => harmonicFrequencyValue;
  @override
  bool get showExpressionTags => showExpressionTagsValue;
  @override
  bool get collapseDictionaries => collapseDictionariesValue;
  @override
  List<Dictionary> get dictionaries => dictionariesValue;
  @override
  Map<String, String> get customDictCSS => customDictCSSValue;
  @override
  String get globalDictCSS => globalDictCSSValue;
  @override
  List<String> get enabledAudioSources => enabledAudioSourcesValue;
  @override
  Directory get appDirectory => appDirectoryOverride ?? super.appDirectory;
}

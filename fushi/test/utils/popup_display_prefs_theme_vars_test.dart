import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/popup_theme_css.dart';

/// BUG-4935：浏览器扩展查词弹窗不跟随 App 的「自动展开行数」「词频聚合」等显示偏好。
///
/// popup.js 读的 `window.autoExpandRows` / `collapseDictionaries` / `harmonicFrequency` …
/// 在 app 内由 popup_settings_injection 注入，扩展只能经查词响应 theme 拿；此前 theme 里
/// 只有音调去重一项，其余在扩展里恒 undefined（词典全展开、词频不聚合）。
///
/// 本测试钉 app 侧唯一编码点 [buildPopupDisplayPrefsThemeVars] 的输出，以及它与扩展唯一
/// 解码点（vendor/dict-media.js `applyFushiPopupDisplayPrefs`，两份镜像）键集合一致——
/// 任一侧加 / 删键而另一侧没跟，这里就红。解码行为由
/// tools/browser-extension/popup-display-prefs.test.js 用真 popup.js 钉住。
void main() {
  const PopupDisplayPrefs prefs = (
    dedupPitch: true,
    harmonicFrequency: true,
    showExpressionTags: false,
    collapseDictionaries: true,
    compactGlossaries: false,
    autoExpandRows: 2,
    collapsedDictionaryNames: <String>['明鏡', 'say "hi"'],
    expandedDictionaryNames: <String>['JMdict'],
    kanjiCollapsedDictionaryNames: <String>['KANJIDIC'],
    kanjiExpandedDictionaryNames: <String>['現代新国語辞典'],
  );

  test('display prefs are encoded as the extension decoder expects', () {
    final Map<String, String> vars = buildPopupDisplayPrefsThemeVars(prefs);
    expect(vars['--fushi-dedup-pitch'], '1');
    expect(vars['--fushi-harmonic-frequency'], '1');
    expect(vars['--fushi-expression-tags'], '0');
    expect(vars['--fushi-collapse-dicts'], '1');
    expect(vars['--fushi-compact-glossaries'], '0');
    expect(vars['--fushi-auto-expand-rows'], '2');
    expect(jsonDecode(vars['--fushi-collapsed-dicts']!), <String>[
      '明鏡',
      'say "hi"',
    ]);
    expect(jsonDecode(vars['--fushi-expanded-dicts']!), <String>['JMdict']);
    expect(jsonDecode(vars['--fushi-kanji-collapsed-dicts']!), <String>[
      'KANJIDIC',
    ]);
    expect(jsonDecode(vars['--fushi-kanji-expanded-dicts']!), <String>[
      '現代新国語辞典',
    ]);
  });

  test('booleans flip to 0 and empty name lists encode as []', () {
    final Map<String, String> vars = buildPopupDisplayPrefsThemeVars((
      dedupPitch: false,
      harmonicFrequency: false,
      showExpressionTags: true,
      collapseDictionaries: false,
      compactGlossaries: true,
      autoExpandRows: 0,
      collapsedDictionaryNames: const <String>[],
      expandedDictionaryNames: const <String>[],
      kanjiCollapsedDictionaryNames: const <String>[],
      kanjiExpandedDictionaryNames: const <String>[],
    ));
    expect(vars['--fushi-dedup-pitch'], '0');
    expect(vars['--fushi-harmonic-frequency'], '0');
    expect(vars['--fushi-expression-tags'], '1');
    expect(vars['--fushi-collapse-dicts'], '0');
    expect(vars['--fushi-compact-glossaries'], '1');
    expect(vars['--fushi-auto-expand-rows'], '0');
    expect(vars['--fushi-collapsed-dicts'], '[]');
    expect(vars['--fushi-expanded-dicts'], '[]');
  });

  test('encoder keys == keys decoded by both dict-media.js mirrors', () {
    final Set<String> encoded = buildPopupDisplayPrefsThemeVars(
      prefs,
    ).keys.toSet();
    for (final String relPath in <String>[
      '../tools/browser-extension/vendor/dict-media.js',
      'assets/browser_extension/vendor/dict-media.js',
    ]) {
      final String js = File(relPath).readAsStringSync();
      final int start = js.indexOf('function applyFushiPopupDisplayPrefs(');
      expect(start, greaterThanOrEqualTo(0), reason: '$relPath decoder');
      final int end = js.indexOf('\n}\n', start);
      final String body = js.substring(start, end);
      final Set<String> decoded = RegExp(
        r"theme\['(--fushi-[a-z-]+)'\]",
      ).allMatches(body).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(decoded, encoded, reason: '$relPath must decode every key');
    }
  });

  test('app_model sends the display prefs on both theme input paths', () {
    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    expect(
      appModel,
      contains('...buildPopupDisplayPrefsThemeVars(inputs.displayPrefs),'),
    );
    // App 当前设置一路 + 扩展所选配置的只读视图一路（反馈 biLEesNqWb）。
    expect(appModel, contains('autoExpandRows: popupAutoExpandDictionaries,'));
    expect(
      appModel,
      contains('autoExpandRows: p.popupAutoExpandDictionaries,'),
    );
    expect(appModel, contains('harmonicFrequency: harmonicFrequency,'));
    expect(appModel, contains('harmonicFrequency: p.harmonicFrequency,'));
  });
}

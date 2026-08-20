import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-804: a dictionary disabled in 词典管理 (its show/hide switch off) must not
/// appear in the lookup popup results.
///
/// 根因：term 词典即使被隐藏（disabled）也仍注册进 FFI 引擎——`AppModel.bucketDictPaths`
/// 的 term 分支故意不按 hidden 过滤（注释「term 在渲染期按 hidden 过滤，故隐藏仍进
/// 桶」）。但真正的查词弹窗走 WebView（`dictionary_popup_webview.dart` 注入 popup.js），
/// 它此前只注入 `collapsedDictionaryNames`、从不注入隐藏名单，于是被禁用词典的释义照样
/// 从 FFI 结果里冒出来显示。修复：宿主注入 `window.hiddenDictionaryNames`，popup.js 在
/// 唯一的词条义项分组点 `createGlossarySectionWrapper` 剔除（与 collapsedDictionaryNames
/// 同源）。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createGlossarySectionWrapper`，断言隐藏词典
///    被排除、且仅隐藏词典的词条不产生义项区。无 node 时 skip。
/// ② 源码级——静态扫描 popup.js + 宿主注入，保证过滤点与注入都在位（即便无 node 也守得住）。
void main() {
  test(
    'popup excludes disabled dictionaries (executes createGlossarySectionWrapper via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_hidden_dictionary_filter_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'popup hidden-dictionary filter JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js drops hidden dictionaries at the glossary grouping point', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // The single grouping point for term glossaries must consult the hidden
    // names list and skip those dictionaries (mirror of how createGlossarySection
    // consumes collapsedDictionaryNames).
    final int wrapper = js.indexOf('function createGlossarySectionWrapper(');
    expect(wrapper, greaterThanOrEqualTo(0),
        reason: 'createGlossarySectionWrapper must exist');

    final int hiddenRead = js.indexOf('window.hiddenDictionaryNames', wrapper);
    expect(hiddenRead, greaterThanOrEqualTo(0),
        reason: 'the grouping point must read window.hiddenDictionaryNames');

    final int forEach = js.indexOf('entry.glossaries.forEach(', wrapper);
    final int skip = js.indexOf(
        'hiddenDictionaryNames.includes(g.dictionary)) return;', wrapper);
    expect(forEach, greaterThanOrEqualTo(0));
    expect(skip, greaterThan(forEach),
        reason:
            'hidden dictionaries must be skipped inside the glossary forEach');
  });

  test('host injects hiddenDictionaryNames from isHidden on word inject', () {
    // TODO-895: collapsed/hidden name injection moved into the single source of
    // truth popup_settings_injection.dart (shared in-app + app-outside body).
    final String dart = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();

    // The host must compute the hidden set from Dictionary.isHidden(targetLanguage)
    // — the exact same predicate the management switch toggles — and inject it as
    // window.hiddenDictionaryNames, right next to collapsedDictionaryNames.
    final int collapsedInject =
        dart.indexOf('window.collapsedDictionaryNames =');
    expect(collapsedInject, greaterThanOrEqualTo(0));

    final int hiddenInject = dart.indexOf('window.hiddenDictionaryNames =');
    expect(hiddenInject, greaterThan(collapsedInject),
        reason: 'hiddenDictionaryNames injection must sit next to '
            'collapsedDictionaryNames');

    // 注入侧消费真相源 getter，而不是自己抄一份 where/map 表达式。
    // 断言字面量：'appModel.hiddenDictionaryNames'
    expect(
      dart.contains('appModel.hiddenDictionaryNames'),
      isTrue,
      reason: 'the injection host must consume AppModel.hiddenDictionaryNames '
          'instead of re-deriving the hidden set locally',
    );

    // 真相源本身仍必须由 isHidden(targetLanguage) 推导——与管理页显示/隐藏开关
    // 拨的是同一个判据。断言字面量：'d.isHidden(JapaneseLanguage.instance)'
    final String appModelSrc =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final int getterAt =
        appModelSrc.indexOf('Set<String> get hiddenDictionaryNames');
    expect(getterAt, greaterThanOrEqualTo(0),
        reason: 'AppModel must expose hiddenDictionaryNames as the single '
            'source of truth for the hidden dictionary set');
    expect(
      appModelSrc
          .substring(getterAt, getterAt + 400)
          .contains('d.isHidden(JapaneseLanguage.instance)'),
      isTrue,
      reason: 'the hidden set must be derived from isHidden(targetLanguage), '
          'the same predicate the management show/hide switch toggles',
    );
  });

  test('popupJson drops hidden dictionaries at the source (all hosts)', () {
    // 这条守的是本次修复的核心不变式：过滤下沉到 popupJson 生成期这个唯一数据
    // 出口。此前过滤只活在渲染期 JS 里，靠宿主注入 window.hiddenDictionaryNames
    // 驱动——app 内 WebView 注入了，浏览器扩展走的 HTTP 路径从来不下发它，于是
    // 被关掉的词典在扩展弹窗里照旧出释义、还一并写进 Anki 卡片。只要过滤留在
    // 生成器里，任何新宿主（不经 JS 注入的）都自动正确。
    final String lang = File(
      '../packages/fushi_dictionary/lib/src/language/language.dart',
    ).readAsStringSync();

    // 断言字面量：'required Set<String> hiddenDictionaries'
    // 必填（不是可选带默认值）——可选参数等于允许调用点漏传。
    expect(
      lang.contains('required Set<String> hiddenDictionaries'),
      isTrue,
      reason: 'buildPopupJsonFromLookup must take the hidden set as a REQUIRED '
          'parameter so no host can silently skip the filter',
    );

    final int builderAt = lang.indexOf('String buildPopupJsonFromLookup(');
    expect(builderAt, greaterThanOrEqualTo(0));
    final int glossaryLoop =
        lang.indexOf('for (final g in r.term.glossaries) {', builderAt);
    expect(glossaryLoop, greaterThan(builderAt));

    // 断言字面量：'if (hiddenDictionaries.contains(g.dictName)) continue;'
    // 必须 continue 整个 glossary 迭代，而不是只跳 groupGlossaries.add——
    // 只有隐藏词典释义的词头不该撑起空卡片，也不该占 maximumTerms 词头预算。
    final int skipAt = lang.indexOf(
        'if (hiddenDictionaries.contains(g.dictName)) continue;', glossaryLoop);
    expect(skipAt, greaterThan(glossaryLoop),
        reason: 'hidden dictionaries must be skipped at the top of the '
            'glossary loop inside buildPopupJsonFromLookup');

    final int groupCreate =
        lang.indexOf('if (!groupExpression.containsKey(key)) {', glossaryLoop);
    expect(groupCreate, greaterThan(skipAt),
        reason: 'the skip must precede group creation, otherwise a headword '
            'whose only glossaries are hidden still renders an empty card');
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

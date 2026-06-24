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
    final String dart = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
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

    expect(
      dart.contains('d.isHidden(appModel.targetLanguage)'),
      isTrue,
      reason: 'the hidden set must be derived from isHidden(targetLanguage), '
          'the same predicate the management show/hide switch toggles',
    );
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

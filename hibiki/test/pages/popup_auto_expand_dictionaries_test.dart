import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-845: the lookup popup auto-expands the leading N dictionary blocks
/// (force-open `<details>`) even when "collapse dictionaries" is on. The count
/// is the new `popup_auto_expand_dictionaries` preference (default 1 = the
/// historical "only the first dictionary expanded" behaviour, clamped 0..6).
///
/// 三层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createGlossarySection`，断言每个词典块的
///    `<details>.open` 随 `window.autoExpandDictionaries` 与折叠开关正确变化。无 node 时 skip。
/// ② popup.js 源码级——保证渲染循环与增量路径都按 `dictIdx < autoExpandN` 计算，
///    而不是退回硬编码 `dictIdx === 0` / 裸 `false`。
/// ③ 宿主/偏好源码级——保证 webview 注入了 `window.autoExpandDictionaries`、偏好
///    clamp 与 Slider 范围都是 0..6 默认 1。
void main() {
  test(
    'popup auto-expands leading N dictionaries (executes createGlossarySection via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_auto_expand_dictionaries_test.js',
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
        reason: 'popup auto-expand JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js drives expand from dictIdx < autoExpandN (no bare false)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // The expand decision must read the threshold and compare the block index.
    expect(js.contains('window.autoExpandDictionaries'), isTrue,
        reason:
            'createGlossarySection must read window.autoExpandDictionaries');
    expect(js.contains('dictIdx < autoExpandN'), isTrue,
        reason: 'expand must be index-driven, not first-only');

    // First-paint render loop must forward the real index, not `dictIdx === 0`.
    expect(
      js.contains(
          'createGlossarySection(dictNames[dictIdx], grouped[dictNames[dictIdx]], dictIdx, idx)'),
      isTrue,
      reason: 'the render loop must pass the real dictIdx (regression: '
          '`dictIdx === 0` collapses everything past the first dictionary)',
    );

    // The incremental (load-more) path must compute a global append index, not
    // hardcode `false`, so appended blocks honour the same threshold.
    expect(
      js.contains("body.querySelectorAll(':scope > .glossary-group').length"),
      isTrue,
      reason:
          'incremental path must seed appendIndex from rendered block count',
    );
    expect(
      js.contains(
          'createGlossarySection(dictName, grouped[dictName], appendIndex, idx)'),
      isTrue,
      reason: 'incremental path must pass a real index, never a bare false '
          '(regression: appended blocks could never auto-expand)',
    );
  });

  test(
      'host injects window.autoExpandDictionaries next to collapseDictionaries',
      () {
    final String dart = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();

    final int collapseInject = dart.indexOf('window.collapseDictionaries =');
    expect(collapseInject, greaterThanOrEqualTo(0));

    final int autoExpandInject =
        dart.indexOf('window.autoExpandDictionaries =');
    expect(autoExpandInject, greaterThan(collapseInject),
        reason: 'autoExpandDictionaries injection must sit next to '
            'collapseDictionaries (per-lookup scalar, not the CSS theme path)');

    expect(dart.contains('appModel.popupAutoExpandDictionaries'), isTrue,
        reason: 'injected value must come from the appModel proxy');
  });

  test('preference clamps 0..6 with default 1 (backward compatible)', () {
    final String prefs = File(
      'lib/src/models/preferences_repository.dart',
    ).readAsStringSync();

    expect(prefs.contains("'popup_auto_expand_dictionaries'"), isTrue);
    expect(prefs.contains('.clamp(0, 6)'), isTrue,
        reason: 'read+write must clamp to the 0..6 slider range');
    expect(prefs.contains('defaultValue: 1'), isTrue,
        reason:
            'default 1 preserves the legacy "first dictionary only" expand');
  });

  test('lookup settings slider min/max match the 0..6 clamp', () {
    final String schema = File(
      'lib/src/settings/settings_schema_lookup.dart',
    ).readAsStringSync();

    final int item =
        schema.indexOf("id: 'lookup.popup_auto_expand_dictionaries'");
    expect(item, greaterThanOrEqualTo(0),
        reason: 'the auto-expand slider item must exist');

    // The slider min/max must equal the repository clamp range.
    final String window = schema.substring(item, item + 400);
    expect(window.contains('min: 0'), isTrue);
    expect(window.contains('max: 6'), isTrue);
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

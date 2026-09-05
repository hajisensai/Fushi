import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-845: the lookup popup auto-expands the leading N *rows* of dictionary
/// blocks (force-open `<details>`) even when "collapse dictionaries" is on. The
/// row count is the `popup_auto_expand_dictionaries` preference (legacy storage
/// key kept for compatibility; default 1, clamped 0..6).
///
/// 单位是「行」而不是「本」：展开数 = 行数 × 有效列数（popup.js `autoExpandCount`），
/// 与 `--dict-columns` masonry 的 `cols = min(configured, items.length)` 同源。历史设计
/// 用的是与列数毫无关联的绝对本数，于是本数不是列数整数倍时顶部参差（1 本 + 2 列 →
/// 一列一张大卡、另一列一摞折叠条）。默认列数 1 时 行数 × 1 === 旧本数，老用户零改变。
///
/// 三层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createGlossarySection`，断言每个词典块的
///    `<details>.open` 随 `window.autoExpandRows` × 列数与折叠开关正确变化。无 node 时 skip。
/// ② popup.js 源码级——保证渲染循环与增量路径都按 `dictIdx < autoExpandN` 计算、且都把
///    该词条真实卡片数传给列数封顶，而不是退回硬编码 `dictIdx === 0` / 裸 `false`，
///    也不是退回与列数无关的绝对本数。
/// ③ 宿主/偏好源码级——保证 webview 注入了 `window.autoExpandRows`、偏好
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

    // The expand decision must read the row count and compare the block index.
    expect(js.contains('window.autoExpandRows'), isTrue,
        reason: 'autoExpandCount must read window.autoExpandRows');
    expect(js.contains('dictIdx < autoExpandN'), isTrue,
        reason: 'expand must be index-driven, not first-only');

    // First-paint render loop must forward the real index, not `dictIdx === 0`,
    // AND the entry's real block count so the column cap matches masonry.
    expect(
      js.contains(
          'createGlossarySection(dictNames[dictIdx], grouped[dictNames[dictIdx]], dictIdx, idx, dictNames.length)'),
      isTrue,
      reason: 'the render loop must pass the real dictIdx (regression: '
          '`dictIdx === 0` collapses everything past the first dictionary) '
          'and dictNames.length for the column cap',
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
          'createGlossarySection(dictName, grouped[dictName], appendIndex, idx, totalDicts)'),
      isTrue,
      reason: 'incremental path must pass a real index, never a bare false '
          '(regression: appended blocks could never auto-expand), plus the '
          'post-append total for the column cap',
    );
    // The incremental total must count the blocks that are ABOUT to be appended,
    // not just the already-rendered ones — otherwise the column cap under-reports
    // and collapses cards the finished layout has room to expand.
    expect(
      js.contains('const totalDicts = appendIndex + appendDictNames.length;'),
      isTrue,
      reason: 'incremental totalDicts must be the POST-append block count',
    );
  });

  test('expanded count is rows x effective columns, capped like masonry', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    final int fn = js.indexOf('function autoExpandCount(');
    expect(fn, greaterThanOrEqualTo(0),
        reason: 'the row->block threshold must live in autoExpandCount()');
    final int fnEnd = js.indexOf('\n}', fn);
    expect(fnEnd, greaterThan(fn));
    final String body = js.substring(fn, fnEnd);

    // rows x columns is the whole point: a bare row count (or a bare block
    // count) would reintroduce the ragged half-row the fix removes.
    expect(RegExp(r'rows\s*\*\s*cols').hasMatch(body), isTrue,
        reason: 'expanded count must be rows * cols, not a column-blind count');
    // Columns must come from the same source masonry uses (dictColumns() =
    // effectiveDictColumns(), i.e. viewport-converged), and be capped by the
    // entry's real card count exactly like layoutMasonry's
    // `cols = Math.min(configured, items.length)`.
    expect(body.contains('dictColumns()'), isTrue,
        reason: 'columns must come from dictColumns() (masonry single source)');
    expect(
        RegExp(r'Math\.min\(\s*dictColumns\(\)\s*,\s*total\s*\)')
            .hasMatch(body),
        isTrue,
        reason: 'columns must be capped by the entry block count like masonry');
    // rows <= 0 must expand nothing at all (0 = collapse everything).
    expect(RegExp(r'rows\s*>\s*0').hasMatch(body), isTrue,
        reason: 'rows <= 0 must short-circuit to zero expanded blocks');
  });

  test('host injects window.autoExpandRows next to collapseDictionaries', () {
    // TODO-895: the shared popup settings body (theme vars + every window.* flag)
    // moved to the single source of truth popup_settings_injection.dart.
    final String dart = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();

    final int collapseInject = dart.indexOf('window.collapseDictionaries =');
    expect(collapseInject, greaterThanOrEqualTo(0));

    final int autoExpandInject = dart.indexOf('window.autoExpandRows =');
    expect(autoExpandInject, greaterThan(collapseInject),
        reason: 'autoExpandRows injection must sit next to '
            'collapseDictionaries (per-lookup scalar, not the CSS theme path)');

    expect(dart.contains('appModel.popupAutoExpandDictionaries'), isTrue,
        reason: 'injected value must come from the appModel proxy '
            '(legacy getter name, value is the row count)');

    // BUG-2158：两个名单必须成对注入。只注入 collapsed 的那一半，popup.js 就只能在
    // 「显式折叠」和「没表态」之间二选一，用户点的「展开」无处可去。
    expect(dart.indexOf('window.expandedDictionaryNames ='),
        greaterThan(dart.indexOf('window.collapsedDictionaryNames =')),
        reason: 'expandedDictionaryNames must be injected alongside '
            'collapsedDictionaryNames');
    expect(dart.contains('d.isExplicitlyExpanded(JapaneseLanguage.instance)'),
        isTrue,
        reason: '展开名单必须来自「显式展开」判据，而不是 !isCollapsed —— '
            '后者会把「没表态」也算成展开，等于把全局折叠开关废掉');
  });

  // BUG-1264: the per-dictionary collapse flag (词典管理 行首开关 →
  // window.collapsedDictionaryNames) is an EXPLICIT per-book decision;
  // autoExpandRows is a bulk default for books carrying no such decision.
  // Ranking auto-expand first silently voided the toggle on the leading
  // rows × columns blocks (3×3 in the shipped default = the first NINE books).
  // Asserted on all three popup.js mirrors, and read out of the函数体 (not the
  // whole file) so a stray comment restating the expression can never fake it.
  test('per-dictionary collapse outranks auto-expand (three mirrors)', () {
    const Map<String, String> mirrors = <String, String>{
      'app popup': 'assets/popup/popup.js',
      'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
      'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
    };

    for (final MapEntry<String, String> mirror in mirrors.entries) {
      final File file = File(mirror.value);
      expect(file.existsSync(), isTrue,
          reason: '${mirror.key}: ${mirror.value} must exist');
      final String js = file.readAsStringSync();

      final int fn = js.indexOf('function createGlossarySection(');
      expect(fn, greaterThanOrEqualTo(0),
          reason: '${mirror.key}: createGlossarySection must exist');
      // 切片锚到「决策块结尾」（`const summary = el(`）而不是一个魔数字符窗口：
      // 窗口一旦被上面新增的注释顶出去，断言就会以「表达式不见了」的名义假红
      // （BUG-2158 加注释时实测踩到过）。再用 maskJsComments 把注释换成等长空白，
      // 保住原意——注释里复述一遍表达式不能把守卫骗绿。
      final int decisionEnd = js.indexOf('const summary = el(', fn);
      expect(decisionEnd, greaterThan(fn),
          reason: '${mirror.key}: createGlossarySection 的决策块结尾锚点没了');
      final String body = maskJsComments(js.substring(fn, decisionEnd));

      expect(
        body.contains(
            'if (!perDictCollapsed && (autoExpanded || !window.collapseDictionaries))'),
        isTrue,
        reason: '${mirror.key}: the per-dict collapse flag must short-circuit '
            'the open decision BEFORE auto-expand / the global switch '
            '(regression: `autoExpanded || (!collapseDictionaries && '
            '!perDictCollapsed)` made the per-book toggle a no-op for the '
            'leading rows x columns blocks)',
      );
      // The flag itself must still be sourced from the injected name list.
      expect(
        body.contains(
            'const perDictCollapsed = (window.collapsedDictionaryNames || []).includes(dictName)'),
        isTrue,
        reason: '${mirror.key}: perDictCollapsed must read the injected '
            'collapsedDictionaryNames list',
      );
      // BUG-2158：第三个态。显式展开必须**先于**上面那条判断，否则它只是又一个
      // 「不在 collapsed 名单里」，照样被全局折叠开关关掉 —— 那正是修复前的形态。
      expect(
        body.contains(
            'const perDictExpanded = (window.expandedDictionaryNames || []).includes(dictName)'),
        isTrue,
        reason: '${mirror.key}: perDictExpanded must read the injected '
            'expandedDictionaryNames list',
      );
      expect(
        body.indexOf('if (perDictExpanded) {'),
        allOf(
          greaterThanOrEqualTo(0),
          lessThan(body.indexOf(
              'if (!perDictCollapsed && (autoExpanded || !window.collapseDictionaries))')),
        ),
        reason: '${mirror.key}: 显式展开必须排在自动展开 / 全局开关那条判断之前，'
            '否则「用户点了展开」和「用户没表态」又会退化成同一个行为',
      );
    }
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

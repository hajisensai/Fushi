import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1898：四字熟語等**紧邻**的两个带注音基字，振假名互相重叠糊成一团
/// （用户 2026-08-28 报「明鏡国語辞典 第三版 四字词语带振假名重叠」）。
///
/// 根因不是某一处写错，而是同一个开关被来回拨：
/// * BUG-850 让 `.ruby-reserve` **永远 in-flow**（每个基字撑到 max(基字, 读音)）——
///   相邻读音不再碰，但短基字配长读音时正文字距被拉开；
/// * BUG-1778 又把它改成**永远 absolute**——字距自然了，BUG-850 防的碰撞原样回来；
/// * BUG-1655 把注音从 0.5em 放大到 0.6em，读音再宽两成，碰得更狠。
///
/// 真正的判据在「隔壁是不是也有注音」：注音悬出到**普通文字**上是原生 ruby 的参考
/// 行为、也正是 BUG-1778 要保住的；只有隔壁也是带注音的单元时才必须让出空间。
/// 所以 `postProcessRuby` 现在用纯 DOM 判定相邻并打 `.ruby-tight`，popup.css 只对
/// 这些单元把孪生体放回 in-flow。
///
/// 语料来自 2026-08-28 对「明鏡国語辞典 第三版」`term_bank_1.json` 的实测：
/// 205,702 个 ruby 元素里有 7,832 处紧邻 ruby 对，真实样本 `曲学(きょくがく)+
/// 阿世(あせい)`、`阿諛(あゆ)+追従(ついしょう)`、`外国(がいこく)+語(ご)`。
///
/// 两层守护：
/// ① 行为级——node 真执行 popup.js 的 `postProcessRuby`，断言相邻标记 / 隔着普通
///    文字不标记 / 幂等。无 node 时 skip。
/// ② 源码级——popup.css 必须只在 `.ruby-tight` 下把孪生体放回 in-flow（不能退回
///    「永远 in-flow」而复发 BUG-1778，也不能没有这条而复发 BUG-850）。
void main() {
  test(
    'touching ruby units get .ruby-tight while units separated by plain text '
    'keep BUG-1778 overhang (executes popup.js via node, BUG-1898)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/pages/popup_glossary_ruby_touching_units_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(
          nodeExe,
          <String>[
            jsTest.path,
          ],
          workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason: 'touching-ruby JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test(
      'popup.css restores the horizontal reserve ONLY for .ruby-tight units '
      '(BUG-1898 without regressing BUG-1778)', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();

    // 基线不变：默认孪生体仍 out of flow（BUG-1778 的紧凑正文字距）。
    final RegExp baseReserve = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*\)\s*\.ruby-reserve\s*\{([^}]*)\}',
    );
    final RegExpMatch? baseMatch = baseReserve.firstMatch(css);
    expect(
      baseMatch,
      isNotNull,
      reason: 'popup.css must keep the scoped .ruby-reserve base rule',
    );
    expect(
      RegExp(r'position\s*:\s*absolute').hasMatch(baseMatch!.group(1)!),
      isTrue,
      reason: '默认必须保持 out of flow，否则回到 BUG-1778 的「注音撑宽正文」',
    );

    // 新不变量：存在一条把 .ruby-tight 单元的孪生体放回 in-flow 的规则。
    final RegExp tightRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*\)\s*'
      r'\.ruby-unit\.ruby-tight\s*>\s*\.ruby-reserve\s*\{([^}]*)\}',
      multiLine: true,
    );
    final RegExpMatch? tightMatch = tightRule.firstMatch(css);
    expect(
      tightMatch,
      isNotNull,
      reason: 'popup.css 必须为 .ruby-unit.ruby-tight 的 .ruby-reserve 提供规则，'
          '否则紧邻的两条读音重新撞在一起（BUG-850 / BUG-1898）',
    );
    expect(
      RegExp(r'position\s*:\s*static').hasMatch(tightMatch!.group(1)!),
      isTrue,
      reason: '.ruby-tight 单元的孪生体必须回到 inline flow 才能撑出避让宽度',
    );
  });

  test(
      'postProcessRuby marks touching units through markTouchingRubyUnits '
      'without depending on Range/:scope (BUG-1898)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    expect(
      js.contains('markTouchingRubyUnits(container)'),
      isTrue,
      reason: 'postProcessRuby 必须调用相邻判定，否则 .ruby-tight 永不出现',
    );
    expect(
      js.contains("classList.add('ruby-tight')"),
      isTrue,
      reason: '相邻单元必须被打上 .ruby-tight',
    );

    // 判定只能用假 DOM 也具备的原语：一旦回退到 Range / :scope，
    // popup_glossary_ruby_touching_units_test.js 会静默失效（判不出 → 不标记 →
    // 断言全绿的假象只会出现在「恒不标记」那侧，但真机行为已经变了）。
    final int fn = js.indexOf('function rubyUnitsAreTouching(');
    expect(
      fn,
      greaterThanOrEqualTo(0),
      reason: 'popup.js must define rubyUnitsAreTouching',
    );
    final int fnEnd = js.indexOf('\n}', fn);
    expect(fnEnd, greaterThan(fn));
    final String body = js.substring(fn, fnEnd);
    expect(
      body.contains('createRange'),
      isFalse,
      reason: '相邻判定不得依赖 Range —— 行为测试的假 DOM 不提供它，'
          '依赖了就等于这条逻辑没有任何行为级守护',
    );
    expect(body.contains(':scope'), isFalse, reason: '相邻判定不得依赖 :scope 选择器，同上');
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

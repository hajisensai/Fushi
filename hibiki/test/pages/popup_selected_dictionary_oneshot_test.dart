import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-645 / BUG-358: the popup mining dictionary selection must be one-shot.
///
/// 根因：`hibiki/assets/popup/popup.js` 的 `selectedDictionaries[idx]`（记某词条
/// 长按选了哪本词典，填 Anki `{selected-glossary}` 字段）原来只在用户长按同一词典
/// 取消时清。制卡成功 / 换词重渲染都不清，于是换词复用常驻热槽 WebView（同 entryIdx）
/// 时残留选择粘到下一张卡，静默带上次选的词典。修复对齐句子上下文镜像的一次性生命周期：
/// 制卡成功后清本词条（`resetSelectedDictionariesForEntry`），换词由宿主调
/// `resetSelectedDictionaries()` 清全部。
///
/// 这里两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `buildMinePayload`（读
///    `selectedDictionaries[idx]?.name` 进 `selectedDictionary` 字段），断言
///    制卡成功清后 / 换词 reset 后该字段为空，且多词条选择相互独立。无 node 时 skip。
/// ② 源码级——静态扫描 popup.js + 宿主，保证一次性清理的两入口与宿主调用都在位
///    （即便无 node 也能在 CI 守住回归）。
void main() {
  test(
    'popup dictionary selection is one-shot (executes buildMinePayload via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_selected_dictionary_oneshot_test.js',
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
        reason: 'popup dictionary one-shot JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js clears the dictionary selection after a successful mine', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // The reset helpers must exist (mirror of resetSentenceContextMirror).
    expect(
      js,
      contains('window.resetSelectedDictionaries = function()'),
      reason: 'word-change reset helper must exist',
    );
    expect(
      js,
      contains('window.resetSelectedDictionariesForEntry = function(idx)'),
      reason: 'per-entry mine-success reset helper must exist',
    );

    // The mine-success branch (after the real mineEntry call) must clear THIS
    // entry's selection. Assert the per-entry clear sits AFTER the mineEntry call
    // (so the mined card still carried the pick) and BEFORE the post-mine
    // anki refresh closure — i.e. inside the success path.
    final int mineCall = js.indexOf('const reply = await mineEntry(');
    expect(mineCall, greaterThanOrEqualTo(0),
        reason: 'mine-success call missing');
    final int perEntryClear =
        js.indexOf('window.resetSelectedDictionariesForEntry(idx);', mineCall);
    expect(
      perEntryClear,
      greaterThan(mineCall),
      reason:
          'mine-success branch must clear this entry selection after mineEntry',
    );
    final int refreshClosure = js.indexOf('const refreshFromAnki', mineCall);
    expect(
      perEntryClear,
      lessThan(refreshClosure),
      reason:
          'per-entry clear must be in the mine-success path before the refresh closure',
    );
  });

  test('host word-change inject zeros the dictionary selection', () {
    final String dart = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();

    expect(
      dart,
      contains('window.resetSelectedDictionaries();'),
      reason: 'host must zero the dictionary selection on word change',
    );

    // It must sit right next to the existing sentence-context mirror reset and
    // before renderPopup() (the same reused-warm-slot reason).
    final int sentenceReset =
        dart.indexOf('window.resetSentenceContextMirror();');
    final int dictReset = dart.indexOf('window.resetSelectedDictionaries();');
    final int render = dart.indexOf('window.renderPopup();', sentenceReset);
    expect(sentenceReset, greaterThanOrEqualTo(0));
    expect(dictReset, greaterThan(sentenceReset));
    expect(render, greaterThan(dictReset),
        reason:
            'dictionary reset must run before renderPopup rebuilds the DOM');
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

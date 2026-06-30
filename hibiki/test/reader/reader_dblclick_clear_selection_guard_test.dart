import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1028 / BUG-481 source guard: the reader must clear the native
/// double-click text selection (so it stops hijacking single-tap lookup), while
/// keeping the furigana whole-page double-click toggle intact.
///
/// 两个 dblclick 监听语义完全不同、极易被后人误删或混淆：
/// ① `_buildReaderSetupScript` 里新增的 **capture 阶段** dblclick → `removeAllRanges()`
///    清掉双击建立的原生框选（本 bug 的修复）。
/// ② `_buildFuriganaJs` 'toggle' 分支的 **bubble 阶段** dblclick →
///    `document.body.classList.toggle('show-all-rt')` 振假名整页切换（保留功能）。
///
/// 这个静态守卫断言两者都在 `webview.part.dart` 中存在，且修复用的是 `removeAllRanges`
/// + capture（`, true)`），不是 `preventDefault`（原生选词在 mousedown/selectstart 已
/// 发生，dblclick 只是结果，preventDefault 拦不住）。配合行为测试
/// reader_dblclick_clear_selection_behavior_test.{dart,js}（node-vm 真跑两 handler）
/// 一起防回归。
void main() {
  final File webview = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  );

  test('webview.part.dart exists', () {
    expect(webview.existsSync(), isTrue,
        reason: 'guarded source ${webview.path} must exist');
  });

  test('TODO-1028 fix: capture-phase dblclick clears native selection', () {
    final String src = webview.readAsStringSync();
    // The clear-selection dblclick listener: getSelection + removeAllRanges,
    // registered with capture (third arg true).
    expect(
      src.contains("document.addEventListener('dblclick'") &&
          src.contains('sel.removeAllRanges()'),
      isTrue,
      reason: 'TODO-1028 fix must clear the native double-click selection via '
          'removeAllRanges() in a dblclick listener',
    );
    final RegExp captureListener = RegExp(
      r"document\.addEventListener\('dblclick',\s*function\(\)\s*\{\s*"
      r'var sel = window\.getSelection && window\.getSelection\(\);\s*'
      r'if \(sel && !sel\.isCollapsed\) sel\.removeAllRanges\(\);\s*'
      r'\},\s*true\);',
    );
    expect(
      captureListener.hasMatch(src),
      isTrue,
      reason:
          'the clear-selection dblclick listener must use the CAPTURE phase '
          '(, true)) so it runs before the bubble-phase furigana toggle',
    );
    // Must NOT downgrade to preventDefault (won't undo an already-made selection).
    expect(
      src.contains("addEventListener('dblclick', function(e) {") &&
          src.contains('e.preventDefault'),
      isFalse,
      reason: 'the dblclick clear must use removeAllRanges, not preventDefault '
          '(the native selection already happened in mousedown/selectstart)',
    );
  });

  test('furigana whole-page double-click toggle is preserved', () {
    final String src = webview.readAsStringSync();
    final RegExp furiganaToggle = RegExp(
      r"document\.addEventListener\('dblclick',\s*function\(\)\s*\{\s*"
      r'var sel = window\.getSelection\(\);\s*'
      r'if \(sel && !sel\.isCollapsed\) return;\s*'
      r"document\.body\.classList\.toggle\('show-all-rt'\);\s*"
      r'\}\);',
    );
    expect(
      furiganaToggle.hasMatch(src),
      isTrue,
      reason: 'the furigana whole-page toggle dblclick handler '
          '(show-all-rt) must remain intact and must NOT be confused with the '
          'TODO-1028 clear-selection listener',
    );
  });
}

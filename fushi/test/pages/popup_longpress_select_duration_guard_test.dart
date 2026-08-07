import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-536 守卫（board-1117）：查词弹窗 WebView 在 Flutter 手势竞技场里挂了一个
/// [LongPressGestureRecognizer]（5deeb754d 加），作用是让「长按」把手势让给 WebView 的
/// 原生选词把手（长按→选区把手→复制/分享）。它原本用裸构造器
/// `LongPressGestureRecognizer()`，deadline 吃 Flutter 默认 `kLongPressTimeout`（500ms）
/// →用户反馈「popup 里长按选中文字的等待时间太长」。
///
/// 这个 recognizer 只为触发原生选区，不需要与系统长按菜单对齐 500ms，故必须传显式的
/// `duration:` 缩短 deadline。若有人改回裸构造器（重新吃 500ms 默认值），或把常量调回
/// ≥500ms，本守卫失败，防止「等待又变长」的回归。
void main() {
  final File source = File(
    'lib/src/pages/implementations/dictionary_popup_webview.dart',
  );

  test('popup native-select long-press uses an explicit sub-default duration',
      () {
    expect(source.existsSync(), isTrue,
        reason: 'popup webview source not found at ${source.path}');
    final String text = source.readAsStringSync();

    // The recognizer must pass an explicit duration — never fall back to the
    // bare LongPressGestureRecognizer() (which re-inherits kLongPressTimeout=500ms).
    expect(
      RegExp(r'LongPressGestureRecognizer\(\s*\)').hasMatch(text),
      isFalse,
      reason:
          'popup LongPressGestureRecognizer must not use the bare constructor — '
          'that re-inherits the 500ms kLongPressTimeout the user found too slow '
          '(BUG-536). Pass duration: kPopupNativeSelectLongPressDuration.',
    );
    expect(
      RegExp(r'LongPressGestureRecognizer\(\s*duration:\s*'
              r'kPopupNativeSelectLongPressDuration')
          .hasMatch(text),
      isTrue,
      reason: 'popup LongPressGestureRecognizer must be constructed with '
          'duration: kPopupNativeSelectLongPressDuration (BUG-536).',
    );
  });

  test(
      'popup native-select long-press duration is snappier than the 500ms default',
      () {
    final String text = source.readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'kPopupNativeSelectLongPressDuration\s*=\s*Duration\(milliseconds:\s*(\d+)\)',
    ).firstMatch(text);
    expect(match, isNotNull,
        reason: 'kPopupNativeSelectLongPressDuration must be a '
            'Duration(milliseconds: N) constant (BUG-536).');
    final int ms = int.parse(match!.group(1)!);
    // Below Flutter's 500ms kLongPressTimeout default (the "too slow" value),
    // yet clearly above a tap so single-tap lookups are never misread as a
    // long-press.
    expect(ms, lessThan(500),
        reason: 'must be faster than the 500ms default that felt too slow');
    expect(ms, greaterThanOrEqualTo(150),
        reason: 'must stay above a tap to avoid hijacking single-tap lookup');
  });
}

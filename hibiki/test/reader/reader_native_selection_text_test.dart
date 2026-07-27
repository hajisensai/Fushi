// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

void main() {
  group('ReaderSelectionScripts.nativeSelection (BUG-402)', () {
    test('invocation 取浏览器原生 getSelection 而非 hoshiSelection', () {
      final String js = ReaderSelectionScripts.nativeSelectionTextInvocation();
      expect(js, contains('window.getSelection'));
      expect(js.contains('hoshiSelection'), isFalse);
    });

    test('Windows WebView2 回 JSON 引号字符串 → 解码出文本', () {
      // 模拟 evaluateJavascript(JSON.stringify(...)) 返回的带引号字符串。
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult('"hello world"'),
        equals('hello world'),
      );
    });

    test('JSON 引号串含转义引号 -> 正确解码', () {
      // 输入 Dart 字面量为 5 个字符: " a \" b " -> JSON 解码出 a"b
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult(r'"a\"b"'),
        equals('a"b'),
      );
    });

    test('裸 String 直接返回（移动端可能不带引号）', () {
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult('hello'),
        equals('hello'),
      );
    });

    test('空选区（空引号字符串）→ 空串', () {
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult('""'),
        isEmpty,
      );
    });

    test('null → 空串', () {
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult(null),
        isEmpty,
      );
    });

    test('JS null（无选区，JSON.stringify(null)）→ 空串', () {
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult('null'),
        isEmpty,
      );
    });

    test('非合法 JSON 裸串 → 原样兜底返回，不抛', () {
      // 不是合法 JSON：当作平台直接回的裸选区文本兜底（不抛异常）。
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult('a"b'),
        equals('a"b'),
      );
    });

    test('非 String 类型 → 空串', () {
      expect(
        ReaderSelectionScripts.nativeSelectionTextFromResult(42),
        isEmpty,
      );
    });
  });
}

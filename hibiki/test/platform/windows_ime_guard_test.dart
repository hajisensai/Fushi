import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/platform/windows_ime_guard.dart';

/// BUG-1450：中文输入法激活时全表面快捷键失效。根因是 Flutter 的 Windows 窗口终生
/// 保留 IME context，输入法吞掉所有按键（引擎报成 physical=0/logical=0）。修法是
/// 无文本框焦点时解除关联、文本框拿焦时恢复。
///
/// 这里锁死两条不变式：
/// 1. 没有可编辑焦点 → 关（否则快捷键继续被吞）。
/// 2. 有可编辑焦点 → 开（否则用户在 app 里根本打不了中日文——比原 bug 更糟）。
void main() {
  group('imeShouldBeEnabled', () {
    test('无文本框焦点时关闭输入法接管，快捷键才能到达', () {
      expect(
        imeShouldBeEnabled(
          hasEditableFocus: false,
          focusedEditableIsReadOnly: false,
        ),
        isFalse,
      );
    });

    test('文本框持焦时必须开启，否则中日文输入全废', () {
      expect(
        imeShouldBeEnabled(
          hasEditableFocus: true,
          focusedEditableIsReadOnly: false,
        ),
        isTrue,
      );
    });

    test('只读 EditableText 持焦不等于文本输入，保持 IME 解除', () {
      expect(
        imeShouldBeEnabled(
          hasEditableFocus: true,
          focusedEditableIsReadOnly: true,
        ),
        isFalse,
      );
    });
  });

  group('WindowsImeGuard 焦点驱动', () {
    final List<bool> calls = <bool>[];

    setUp(() {
      calls.clear();
      WindowsImeGuard.debugReset();
      WindowsImeGuard.debugForceEnabled = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app.fushi/windows_ime_guard'),
        (MethodCall call) async {
          if (call.method == 'setImeEnabled') {
            calls.add(call.arguments as bool);
          }
          return null;
        },
      );
    });

    tearDown(() {
      WindowsImeGuard.debugForceEnabled = false;
      WindowsImeGuard.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app.fushi/windows_ime_guard'),
        null,
      );
    });

    testWidgets('冷启动无文本框焦点：立刻解除关联', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('no text field'))),
      );
      WindowsImeGuard.install();
      await tester.pump();

      expect(calls, <bool>[false]);
      expect(WindowsImeGuard.debugLastSent, isFalse);
    });

    testWidgets('文本框拿到焦点 → 恢复；失焦 → 再次解除', (WidgetTester tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TextField(focusNode: node),
                const Text('elsewhere'),
              ],
            ),
          ),
        ),
      );
      WindowsImeGuard.install();
      await tester.pump();
      expect(calls, <bool>[false], reason: '启动时没有编辑焦点');

      node.requestFocus();
      await tester.pump();
      expect(calls, <bool>[false, true], reason: '文本框持焦必须恢复输入法，否则打不了中文');

      node.unfocus();
      await tester.pump();
      expect(calls, <bool>[false, true, false], reason: '离开文本框应重新让快捷键可用');
    });

    testWidgets('点击 SelectableText 不会重新关联 IME，快捷键保持可用',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SelectableText('click to select')),
        ),
      );
      WindowsImeGuard.install();
      await tester.pump();
      expect(calls, <bool>[false]);

      await tester.tap(find.byType(SelectableText));
      await tester.pump();

      expect(
        calls,
        <bool>[false],
        reason: 'SelectableText 的只读 EditableText 焦点不能冒充输入焦点',
      );
      expect(WindowsImeGuard.debugLastSent, isFalse);
    });

    testWidgets('SelectableText 与真文本框来回切焦只在输入能力变化时切换',
        (WidgetTester tester) async {
      final FocusNode editableNode = FocusNode();
      addTearDown(editableNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const SelectableText('selectable'),
                TextField(focusNode: editableNode),
              ],
            ),
          ),
        ),
      );
      WindowsImeGuard.install();
      await tester.pump();

      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      expect(calls, <bool>[false]);

      editableNode.requestFocus();
      await tester.pump();
      expect(calls, <bool>[false, true]);

      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      expect(calls, <bool>[false, true, false]);
    });

    testWidgets('同一状态的重复焦点通知不重复打通道', (WidgetTester tester) async {
      final FocusNode a = FocusNode();
      final FocusNode b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Focus(focusNode: a, child: const Text('a')),
                Focus(focusNode: b, child: const Text('b')),
              ],
            ),
          ),
        ),
      );
      WindowsImeGuard.install();
      await tester.pump();

      a.requestFocus();
      await tester.pump();
      b.requestFocus();
      await tester.pump();

      expect(calls, <bool>[false], reason: '两个都不是文本框，状态没翻转就不该再发');
    });

    testWidgets('非 Windows 平台完全空转', (WidgetTester tester) async {
      WindowsImeGuard.debugReset();
      WindowsImeGuard.debugForceEnabled = false;

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('x'))),
      );
      WindowsImeGuard.install();
      await tester.pump();

      expect(calls, isEmpty);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// schema v5 → v6（用户拍板）：「关闭词典」与「退出书籍」拆成两个独立动作。
///
/// - [ShortcutAction.readerDismissDict]（Esc）只关词典弹窗，无弹窗时不消费、
///   **绝不退书**；
/// - [ShortcutAction.readerExitBook]（新增，默认 Ctrl+W）直接退书，必须走
///   maybePop → PopScope onWillPop 闸门（flush 阅读位置 / closeMedia / 关书
///   自动同步，BUG-782 同径）。
///
/// 本文件钉死三层不变式：老快照迁移播种、默认键解析、执行体源码切片。
void main() {
  const InputBinding ctrlW = InputBinding(
    key: LogicalKeyboardKey.keyW,
    modifiers: <ModifierKey>{ModifierKey.ctrl},
  );

  test('老快照 (v5，无 reader_exit_book) 加载后 readerExitBook 播种 Ctrl+W', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    // 模拟 v5 老用户快照：只有 readerDismissDict 的 Esc，没有 reader_exit_book。
    final String snapshot = jsonEncode(<String, dynamic>{
      kShortcutSchemaVersionKey: 5,
      ShortcutAction.readerDismissDict.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.escape),
        ],
      ).toJson(),
    });
    registry.loadFromJsonString(snapshot, TargetPlatform.windows);
    expect(
      registry.bindingsFor(ShortcutAction.readerExitBook).keyboardBindings,
      contains(ctrlW),
      reason: '新 action 的 key 在老快照里缺席 → 必须天然拿到 Ctrl+W 默认',
    );
    expect(
      registry.bindingsFor(ShortcutAction.readerDismissDict).keyboardBindings,
      contains(const InputBinding(key: LogicalKeyboardKey.escape)),
      reason: '迁移不得动 readerDismissDict 的 Esc',
    );
  });

  test('默认表：Esc→关词典、Ctrl+W→退书，两动作各自独立解析', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.escape,
        modifiers: <ModifierKey>{},
        scope: ShortcutScope.reader,
      ),
      ShortcutAction.readerDismissDict,
    );
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.keyW,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
        scope: ShortcutScope.reader,
      ),
      ShortcutAction.readerExitBook,
    );
  });

  group('执行体源码切片守卫（caret.part.dart，pumpWidget 阅读器过重故走静态断言）', () {
    const String path =
        'lib/src/pages/implementations/reader_hibiki/caret.part.dart';

    /// 切出某个 case 分支：从 `case ShortcutAction.<name>:` 起到下一个
    /// `case ShortcutAction.` 止。
    String caseSlice(String source, String name) {
      final String start = 'case ShortcutAction.$name:';
      final int startIdx = source.indexOf(start);
      expect(startIdx, greaterThanOrEqualTo(0), reason: '$name 的 case 分支应存在');
      final int endIdx =
          source.indexOf('case ShortcutAction.', startIdx + start.length);
      expect(endIdx, greaterThan(startIdx));
      return source.substring(startIdx, endIdx);
    }

    test('readerDismissDict 分支不得退书（无 maybePop / pop）', () {
      final String source = File(path).readAsStringSync();
      final String slice = caseSlice(source, 'readerDismissDict');
      expect(
        slice.contains('maybePop') || slice.contains('.pop('),
        isFalse,
        reason: '关词典键绝不退书——退书是 readerExitBook 的职责（用户拍板拆分）',
      );
      expect(slice.contains('clearDictionaryResult'), isTrue,
          reason: '关词典键应关词典弹窗');
      expect(slice.contains('KeyEventResult.ignored'), isTrue,
          reason: '无弹窗时不消费（ignored），不得吞键');
    });

    test('readerExitBook 分支必须走 maybePop（BUG-782 闸门），且无裸 pop', () {
      final String source = File(path).readAsStringSync();
      final String slice = caseSlice(source, 'readerExitBook');
      expect(slice.contains('maybePop('), isTrue,
          reason: '退书必须经 maybePop 触发 PopScope→onWillPop（flush/closeMedia/同步）');
      final String noComments = slice
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        RegExp(r'(?<!maybe)\.pop\(').hasMatch(noComments),
        isFalse,
        reason: '不得出现绕过 PopScope 的裸 pop()（BUG-782）',
      );
    });
  });
}

// PR#457 审查 §10-5 守卫（源码扫描层）：设置页 Lapis 区两个真缺陷不得回归。
//
// 1. `_restoreLapisBackup` 的在途标记 `_lapisBusy` 原本在 `listBackups()` 之后
//    才置位 —— 那段异步窗口里 `_lapisBusy ? null : ...` 的门还开着，连点两下
//    会开出两条恢复流程写同一个 note type。要求：置位必须先于本方法的第一个
//    `await`。
// 2. Lapis CSS 编辑器持有的 controller 必须随页面 dispose。旧弹窗曾在
//    `setLapisCustomCss` 抛错时漏掉 controller；改成独立页面后生命周期守卫移到
//    `LapisStyleEditorPage.dispose`。
//
// 这两条都是时序/生命周期，widget 测试要真跑整个 Anki 设置页（依赖 AppModel /
// 平台通道），源码扫描是本仓能落地的最强层。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉整行 `//` 注释：本守卫按「先后顺序」判定，注释里出现 `await` /
/// `dispose` 这些词会污染下标比较（守卫自己的说明文字就带这些词）。
String _stripLineComments(String source) => const LineSplitter()
    .convert(source)
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join(' ');

/// 从 [source] 里截取名为 [name] 的方法体（从签名行到与之配对的右花括号）。
///
/// **前置条件**：[source] 必须已经过 [_stripLineComments]——否则注释里的花括号
/// 会把配平算错。剩余约束：方法体内的字符串字面量若含**不配对**的花括号
/// （如 `'{'`），配平同样会错；当前被扫的两个方法没有这种字面量，真加了就得把
/// 这里升级成带字符串状态机的扫描。
String _methodBody(String source, String name) {
  final RegExp declaration = RegExp(
    r'(?:Future<void>|void)\s+' + RegExp.escape(name) + r'\s*\(',
  );
  final int start = declaration.firstMatch(source)?.start ?? -1;
  expect(start, greaterThanOrEqualTo(0), reason: '找不到方法 $name');
  final int braceStart = source.indexOf('{', start);
  int depth = 0;
  for (int i = braceStart; i < source.length; i++) {
    final String c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(braceStart, i + 1);
    }
  }
  fail('方法 $name 的括号不配对');
}

void main() {
  final File file =
      File('lib/src/pages/implementations/anki_settings_page.dart');
  final File editorFile = File('lib/src/anki/lapis_style_editor_page.dart');
  late String source;
  late String editorSource;

  setUpAll(() {
    expect(file.existsSync(), isTrue, reason: '路径变了就更新本守卫');
    expect(editorFile.existsSync(), isTrue, reason: '路径变了就更新本守卫');
    source = _stripLineComments(file.readAsStringSync());
    editorSource = _stripLineComments(editorFile.readAsStringSync());
  });

  test('_restoreLapisBackup 在第一个 await 之前就置 _lapisBusy', () {
    final String body = _methodBody(source, '_restoreLapisBackup');
    final int busyAt = body.indexOf('_lapisBusy = true');
    final int awaitAt = body.indexOf('await ');
    expect(busyAt, greaterThanOrEqualTo(0), reason: '在途标记没了？');
    expect(awaitAt, greaterThanOrEqualTo(0));
    expect(busyAt, lessThan(awaitAt),
        reason: '_lapisBusy 必须先于任何 await 置位，否则连点两下能开两条恢复流程');
    expect(body, contains('finally'),
        reason: '置位后必须在 finally 里复位，异常路径不能把按钮永久卡死');
  });

  test('_runRestoreLapisBackup 的刷新失败仍会呈现给用户（不落 finally）', () {
    // 回归守卫：把 refreshSettingsFromStore 放进 finally 会让它跑到 catch 之外，
    // 抛出即成为没人接的异步异常——页面继续显示恢复前的值，用户什么也看不到。
    // 那正是本 PR 要修的「谎报」同一类问题，不能在修它的过程中引入。
    final String body = _methodBody(source, '_runRestoreLapisBackup');
    expect(body.contains('finally'), isFalse,
        reason: 'finally 里的 await 抛出会绕过 catch，变成未捕获异步异常');
    final int refreshAt = body.indexOf('refreshSettingsFromStore');
    expect(refreshAt, greaterThanOrEqualTo(0), reason: '刷新调用没了？');
    expect(body.indexOf('catch', refreshAt), greaterThan(refreshAt),
        reason: '刷新必须被 catch 包住，失败要走 restore_failed 提示');
    expect(body, contains('anki_lapis_restore_failed'));
  });

  test('LapisStyleEditorPage 随页面 dispose 高级 CSS controller', () {
    final String body = _methodBody(editorSource, 'dispose');
    expect(body, contains('_advancedCssController'));
    expect(body, contains('removeListener(_handleAdvancedCssChanged)'));
    expect(body, contains('dispose()'),
        reason: '独立编辑页退出时必须释放 TextEditingController');
  });
}

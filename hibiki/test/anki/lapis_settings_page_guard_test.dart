// PR#457 审查 §10-5 守卫（源码扫描层）：设置页 Lapis 区两个真缺陷不得回归。
//
// 1. `_restoreLapisBackup` 的在途标记 `_lapisBusy` 原本在 `listBackups()` 之后
//    才置位 —— 那段异步窗口里 `_lapisBusy ? null : ...` 的门还开着，连点两下
//    会开出两条恢复流程写同一个 note type。要求：置位必须先于本方法的第一个
//    `await`。
// 2. `_editLapisCustomCss` 原本在 `setLapisCustomCss` 之后才 dispose
//    controller —— 保存抛错就漏掉 dispose。要求：dispose 在 `finally` 里。
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
String _methodBody(String source, String name) {
  final int start = source.indexOf('Future<void> $name(');
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
  late String source;

  setUpAll(() {
    expect(file.existsSync(), isTrue, reason: '路径变了就更新本守卫');
    source = file.readAsStringSync();
  });

  test('_restoreLapisBackup 在第一个 await 之前就置 _lapisBusy', () {
    final String body =
        _stripLineComments(_methodBody(source, '_restoreLapisBackup'));
    final int busyAt = body.indexOf('_lapisBusy = true');
    final int awaitAt = body.indexOf('await ');
    expect(busyAt, greaterThanOrEqualTo(0), reason: '在途标记没了？');
    expect(awaitAt, greaterThanOrEqualTo(0));
    expect(busyAt, lessThan(awaitAt),
        reason: '_lapisBusy 必须先于任何 await 置位，否则连点两下能开两条恢复流程');
    expect(body, contains('finally'),
        reason: '置位后必须在 finally 里复位，异常路径不能把按钮永久卡死');
  });

  test('_editLapisCustomCss 在 finally 里 dispose controller', () {
    final String body =
        _stripLineComments(_methodBody(source, '_editLapisCustomCss'));
    expect(body, contains('finally'));
    final int finallyAt = body.indexOf('finally');
    final int disposeAt = body.indexOf('controller.dispose()');
    expect(disposeAt, greaterThan(finallyAt),
        reason: 'dispose 必须在 finally 内，保存抛错时也要释放');
  });
}

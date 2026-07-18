import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-909 源码守卫：TODO-792 / 753 竖排翻页漂移取证已完成，一次性诊断探针
/// （`[792-REVEAL]` / `[792-REVEAL-RB]` / `[792-RPITCH]` / `[792-TURN]` /
/// `[753-DIAG]`，含 `_diag753` / `_diagTurn` 两个 helper 及其 init/resize/翻页
/// 调用点）已整体移除。它们曾走 console.log → onConsoleMessage → debugPrint →
/// DebugLogService，常驻按句 reveal / 手动翻页热路径，发布版不剥离。
///
/// 这些是取证完成的死代码，直接删除而非「加门控常量保留死路径」。本守卫锁死
/// 「探针标记字符串与 helper 定义/调用点不再出现」，任何一处回潮 → 转红，防止
/// 后续 merge/cherry-pick 把探针带回热路径。纯静态扫描，不需真机。
void main() {
  late String scripts;
  late String webview;

  setUpAll(() {
    scripts = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    webview = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync();
  });

  test('reader_pagination_scripts.dart 不再出现竖排取证探针标记字符串', () {
    for (final String marker in <String>[
      '792-REVEAL',
      '792-REVEAL-RB',
      '792-RPITCH',
      '792-TURN',
      '753-DIAG',
    ]) {
      expect(scripts.contains(marker), isFalse,
          reason: '取证探针标记 [$marker] 已随 BUG-909 移除，不得回潮进分页脚本');
    }
  });

  test('_diag753 / _diagTurn helper 定义与调用点全部移除', () {
    expect(scripts.contains('_diag753'), isFalse,
        reason: '_diag753 诊断 helper（含 init/resize 调用点、_diag753Seen 去重态）须整体移除');
    expect(scripts.contains('_diagTurn'), isFalse,
        reason: '_diagTurn 逐页漂移 helper（含 paginate 两分支调用点、_turnSeq 序号态）须整体移除');
  });

  test('webview.part.dart 不再引用已移除的 [792-REVEAL] 探针', () {
    // 仅探针注释引用被清理；[806-TAP] 框选坐标探针本身不在本 BUG 范围，保留。
    expect(webview.contains('792-REVEAL'), isFalse,
        reason: '[806-TAP] 注释里对已删除 [792-REVEAL] 探针的引用须一并更新');
  });
}

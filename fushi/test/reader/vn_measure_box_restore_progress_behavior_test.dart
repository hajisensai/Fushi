import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-2575 / BUG-2576：VN 量尺盒尺寸优先级 + restore 进度落屏的**行为级**覆盖。
///
/// BUG-2575：量尺 `createScreenMeasurement` 与真实屏共用 `.fushi-vn-screen`，样式表
/// 里 `width/height: 100% !important` 压过普通内联样式，BUG-1688 那次「把真实屏盒
/// 宽高搬进量尺」从没生效——量尺恒为整视口，比真屏高出整条 chrome 预留带；竖排下
/// 量尺列更长、以为装得下更多字，真屏就多出一列贴左边被裁（iOS 实机最左列切半），
/// 横排则末行被底栏吃掉。源码守卫（vn_viewport_geometry_bug1688_test）只看
/// `root.style.width = …` 这行在不在，看不出它被样式表压掉；这里让真实的
/// `createScreenMeasurement` 在 CSSStyleDeclaration 替身上跑，断言优先级是 important。
///
/// BUG-2576：宿主 `restoreProgress(>= 0.99)` 是「章末」约定值（往前翻章），分页/连续
/// shell 分流到 scrollToChapterEnd，VN 只按进度锚线性找屏，长章停在距末屏还差几屏
/// 处；fragment 解析失败也硬落第 0 屏。
///
/// 走仓库已有的 `Process.run(node, ...)` 范式（先例：pr912_vn_shim_behavior_test），
/// 把 [ReaderVisualNovelScripts.vnShellScript] 的 `window.fushiReader = {…}` 对象字面量
/// 原文丢进 node 求值，用替身补齐协作者后调真实方法。
void main() {
  test('VN 行为级：量尺盒宽高 important / restore 0.99 落末屏 / fragment 失效回退进度', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final Directory temp =
        Directory.systemTemp.createTempSync('hibiki-vn-measure-restore-js-');
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(jsonEncode(<String, String>{'shell': shell}));
    final File runner =
        File('test/reader/vn_measure_box_restore_progress_behavior_test.js');
    expect(runner.existsSync(), isTrue,
        reason: 'behavior harness ${runner.path} must exist');
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>[runner.path, payload.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason: 'VN measure/restore behavior runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });

  test('restore 入口统一走 screenIndexForRestoreProgress（不再裸调进度锚查找）', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    // restoreProgress 与 renderInitialScreen 是宿主恢复口径的两条入口，都必须吃
    // 0.99 = 章末 的约定；calculateProgress 往返（refit / 样式重锚）保持进度锚查找。
    final int restoreAt =
        shell.indexOf('restoreProgress: async function(progress) {');
    expect(restoreAt, greaterThan(-1));
    final String restoreBody =
        shell.substring(restoreAt, shell.indexOf('\n  },', restoreAt));
    expect(
        restoreBody, contains('this.screenIndexForRestoreProgress(progress)'));
    expect(
        restoreBody, isNot(contains('this.screenIndexForProgress(progress)')));
    final int initialAt = shell.indexOf('renderInitialScreen: function() {');
    expect(initialAt, greaterThan(-1));
    final String initialBody =
        shell.substring(initialAt, shell.indexOf('\n  },', initialAt));
    expect(initialBody,
        contains('this.screenIndexForRestoreProgress(this.initialProgress)'));
    expect(
        shell, contains('if (target >= 0.99) return this.screens.length - 1;'));
  });
}

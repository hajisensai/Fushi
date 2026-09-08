import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-2261：VN 视图下改字号/边距/主题等纯 CSS 外观设置不实时生效——VN shell 有
/// `window.fushiReader` 却没实现 `beginStyleReanchor` / `commitStyleReanchor`，Dart 侧
/// gate 开时把换 CSS 全托付给它，CSS 一次都没换。
///
/// 本测试把 [ReaderVisualNovelScripts.vnShellScript] 生成的 host-compat shim 原文丢进
/// node 真跑（范式同 `pr912_vn_shim_behavior_test`），断言：begin 同步换 CSS 并返回当前
/// 屏首字符偏移；commit 按新 CSS 重切屏后落到同一偏移；屏表未就绪时 CSS 仍换、锚为 -1；
/// 锚查无时退回进度比例；无参 refit 行为不变。
void main() {
  test('VN shim 行为级：样式两阶段重锚 begin/commit', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final Directory temp = Directory.systemTemp.createTempSync(
      'hibiki-bug2261-vn-js-',
    );
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(jsonEncode(<String, String>{'shell': shell}));
    final File runner = File('test/reader/vn_style_reanchor_behavior_test.js');
    expect(
      runner.existsSync(),
      isTrue,
      reason: 'behavior harness ${runner.path} must exist',
    );
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
      reason:
          'VN style reanchor behavior runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// BUG-3431：滚动（连续）模式每次杀进程重开都回退一列（竖排 912 → 874 → 837）。
///
/// 恢复目标恰是一列的列首时，Chromium 把软换行处的塌缩光标算到**上一列末尾**；
/// 连续 shell 的 `scrollToCharOffset` 拿光标矩形对齐视口首边，视口首边就成了上一列，
/// 下一次进度采样如实报上一列的列首并落库。真机 CDP 探针：恢复 1551，首边那列从
/// 1513 起、光标矩形右缘 403 = innerWidth − padding-right。
///
/// 这里在 `flutter test` 内用 Node 真执行连续 shell，喂一个「光标在上一列 / 上一行末、
/// 字形在下一列 / 下一行首」的 range，断言滚动落在字形上（竖排、横排各一例），量不到
/// 字形时仍退回光标矩形。撤掉修复，Node 断言失败、本 Dart 测试转红。没有 node 的环境
/// 自动 skip。
void main() {
  test(
    'continuous restore aligns the target glyph, not the soft-wrap caret',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/reader/continuous_restore_glyph_anchor_behavior_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final String payload = jsonEncode(<String, String>{
        'continuous': ReaderPaginationScripts.continuousShellSource(),
        'studyUnits': kStudyUnitJs,
      });
      final Directory temp = Directory.systemTemp.createTempSync(
        'fushi-continuous-glyph-anchor-',
      );
      final File payloadFile = File('${temp.path}/payload.json')
        ..writeAsStringSync(payload);
      late final ProcessResult result;
      try {
        result = await Process.run(
          nodeExe,
          <String>[jsTest.path, payloadFile.path],
          workingDirectory: Directory.current.path,
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
            'continuous glyph anchor JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

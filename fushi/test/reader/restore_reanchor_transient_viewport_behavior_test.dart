import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// BUG-2652：iOS 上先以分页开书、再在书内切到滚动模式，落点每次都被钉回章首。
///
/// 书内切模式是在**同一个 WKWebView** 里原地重载本章。连续 shell 的恢复把滚动写对了
/// （charOffset 663 → scrollX -1047），但随后几帧原生侧会让 scrollX / scrollY 瞬时读成
/// 0（iOS 模拟器探针：t=3ms 写入 -1047，+16ms 读到 0，期间没有任何 JS 写入，约 40ms 时
/// 滚动树里仍是 -1047）。恰在这个窗口里有两次重锚采样首字锚 = 章首，随后
/// `scrollToChapterStart()`：
///  1. `setChromeInsets()` 重发了已经烘焙进引擎配置的同一组 inset——没有重排要补偿，
///     却照样采样重锚；
///  2. TODO-718 的恢复完成重锚（`beginUiScaleReanchor`）现场采样视口，而不是用恢复
///     自己的锚。
/// 新开书是全新 WebView，没有这个瞬时态，所以用户「退出重进就好」。
///
/// 这里在 `flutter test` 内用 Node 真执行分页 / 连续两个 shell 对象，采样器恒答
/// 「章首」模拟未落定的视口，断言：inset 无变化时不采样、不重锚；有变化时照旧；
/// `beginRestoreReanchor` 取恢复锚（含句尾锚）不采样，无精确锚时退回采样。撤掉修复，
/// Node 断言失败、本 Dart 守卫转红。没有 node 的环境自动 skip。
void main() {
  test(
    'a re-anchor right after a restore never samples the unsettled viewport',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/reader/restore_reanchor_transient_viewport_behavior_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final String payload = jsonEncode(<String, String>{
        'paged': ReaderPaginationScripts.paginatedShellSource(),
        'continuous': ReaderPaginationScripts.continuousShellSource(),
        'studyUnits': kStudyUnitJs,
      });
      final Directory temp = Directory.systemTemp.createTempSync(
        'fushi-restore-reanchor-transient-',
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
            'restore re-anchor JS behavior test failed.\n'
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

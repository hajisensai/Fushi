import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// BUG-2744：横排听书读到插图处「图片闪一下、被跳过」（Windows）。
///
/// 恢复落点登记的「迟到图片重锚」锚只在用户手动翻页时作废；有声书跟读翻页
/// （`scrollToRange` / `scrollToTarget`）与跨插图暂停滚到插图都不作废它。跟读翻过几页后
/// 前方懒加载插图才 load，`reapplyImageLateAnchor()` 把视口拽回打开本章时的那页；开了
/// 图片暂停时，插图刚被滚到、一 load 就被拽回，暂停停在错页。
///
/// 修复后程序化揭示的目标就是新的锚。这里在 `flutter test` 内用 Node 真执行分页 / 连续
/// 两个 shell 对象，用可移动几何的假 Range / 元素模拟懒图 load 引起的位移，断言：揭示后的
/// 迟到重锚对齐到揭示目标、绝不回退到恢复锚；分页跨图暂停时占位在本页、load 后插图挪到
/// 下一页，重锚要跟过去；之后新的恢复登记仍然生效。撤掉修复，Node 断言失败、本 Dart 守卫
/// 转红。没有 node 的环境自动 skip。
void main() {
  test(
    'a programmatic reveal replaces the restore anchor that late image loads re-apply',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/reader/reader_follow_reveal_late_image_anchor_behavior_test.js',
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
        'fushi-follow-reveal-late-image-anchor-',
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
            'late image anchor JS behavior test failed.\n'
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// BUG-2748：连续模式用户滚走后，前方懒图 load 把视口拽回最近一次揭示 / 恢复的目标。
///
/// 迟到图片锚（BUG-1140 / BUG-2744）与恢复锚（BUG-2652）只由分页 `paginate` 作废；连续
/// 模式的视口靠原生滚动驱动——滚轮、触摸、拖滚动条、方向 / 翻页键、查词弹窗遮罩转发的
/// 滚动都不经过 `paginate`，锚一直活着。修复后连续 shell 在捕获阶段认领这些输入，调
/// `noteUserScroll()`（与 `paginate` 同一语义）；Dart 转发出口 `_evaluateScrollForward`
/// 先调同一个方法再滚。
///
/// 这里在 `flutter test` 内用 Node 真执行连续 / 分页 shell 对象与连续 shell 的意图监听，
/// 派发输入事件后断言两个锚都已作废、非滚动输入（点正文 / Space）不动锚、分页 shell 不受
/// 影响。撤掉修复，Node 断言失败、本 Dart 守卫转红。没有 node 的环境自动 skip。
void main() {
  test(
    'continuous-mode user scroll input retires the late-image and restore anchors',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/reader/reader_continuous_user_scroll_anchor_behavior_test.js',
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
        'fushi-continuous-user-scroll-anchor-',
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
            'continuous user-scroll anchor JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test(
    'the popup-barrier scroll forward retires the anchors before it scrolls',
    () {
      // 弹窗遮罩把滚轮 / 拖动转给正文走的是 Dart 拼的裸 scrollBy，不产生 DOM 输入事件，
      // 连续 shell 的意图监听看不见——只能在这个唯一出口显式调 noteUserScroll。
      final String source = File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync();
      final int start = source.indexOf(
        'Future<void> _evaluateScrollForward(String js) async {',
      );
      expect(start, isNonNegative, reason: '_evaluateScrollForward must exist');
      final int end = source.indexOf('\n  }\n', start);
      final String body = source.substring(start, end);
      final int note = body.indexOf('r.noteUserScroll()');
      final int forwarded = body.indexOf(r'$js');
      expect(note, isNonNegative, reason: 'forward must call noteUserScroll');
      expect(
        forwarded,
        greaterThan(note),
        reason: 'anchors are retired before the forwarded scroll runs',
      );
      expect(
        RegExp(r'_evaluateScrollForward\(').allMatches(source).length,
        3,
        reason:
            'the wheel and drag forwards both go through this one exit '
            '(1 definition + 2 call sites); a new raw forward must use it too',
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

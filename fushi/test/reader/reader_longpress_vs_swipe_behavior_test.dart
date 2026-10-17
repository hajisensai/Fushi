import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// BUG-2919：长按拖选与滑动翻页是并行识别器，长按计时器先 fire 就会让翻页让路，
/// 用户「翻个页有时都会选中」。这里用 Node 真执行生成的长按 IIFE（伪 DOM + 虚拟
/// 时钟），回放四种触摸序列：
/// * 原地按住 500ms → 必须选中（长按功能不能被改没）；
/// * 停顿 350ms 再横滑 → 必须翻页、不选中（用户报告的路径）；
/// * 40px/s 慢滑 1 秒 → 必须翻页、不选中；
/// * 120ms 轻点 → 不选中。
/// 同时用 BUG-2563 的旧参数 280ms/16px 生成一份脚本，断言后两种滑动在旧参数下
/// 确实会被抢——证明本 harness 能识别回归，不是空壳。
/// 本机 / CI 无 node 时 skip。
void main() {
  test(
    'long-press drag-select never steals a page-turn swipe (BUG-2919)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final int swipeDist = ReaderSettings.swipePageTurnDistThresholds(
        ReaderSettings.defaultSwipePageTurnSensitivity,
      ).dist;

      final Map<String, dynamic> current = await _runHarness(
        nodeExe,
        ReaderSelectionScripts.longPressDragGestureScript(),
        swipeDist,
      );
      expect(current['holdStill'], <String, bool>{
        'selected': true,
        'pageTurn': false,
      });
      expect(current['restThenSwipe'], <String, bool>{
        'selected': false,
        'pageTurn': true,
      }, reason: '翻页前停顿 350ms 不能被判成长按');
      expect(current['slowSwipe'], <String, bool>{
        'selected': false,
        'pageTurn': true,
      }, reason: '40px/s 慢滑不能被长按计时器抢走');
      expect(current['tap'], <String, bool>{
        'selected': false,
        'pageTurn': false,
      });

      final Map<String, dynamic> legacy = await _runHarness(
        nodeExe,
        ReaderSelectionScripts.longPressDragGestureScript(
          delayMs: 280,
          slop: 16,
        ),
        swipeDist,
      );
      expect(
        legacy['restThenSwipe']['selected'],
        isTrue,
        reason: 'harness 必须能复现旧参数下的抢手势，否则它守不住回归',
      );
      expect(legacy['slowSwipe']['selected'], isTrue);
    },
  );
}

Future<Map<String, dynamic>> _runHarness(
  String nodeExe,
  String script,
  int swipeDist,
) async {
  final Directory tmp = await Directory.systemTemp.createTemp('bug2919_');
  try {
    final File scriptFile = File('${tmp.path}/longpress.js');
    await scriptFile.writeAsString(script);
    final ProcessResult result = await Process.run(nodeExe, <String>[
      'test/reader/reader_longpress_vs_swipe_behavior_test.js',
      scriptFile.path,
      '$swipeDist',
    ], workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason:
          'harness failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    return jsonDecode(result.stdout.toString().trim()) as Map<String, dynamic>;
  } finally {
    await tmp.delete(recursive: true);
  }
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

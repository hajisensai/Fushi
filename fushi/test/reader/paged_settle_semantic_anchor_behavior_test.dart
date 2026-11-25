import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

import '../helpers/node_runtime.dart';

/// BUG-4808：分页恢复落点后的 16 ms settle、以及揭示落页后的下一帧重写，把**延后之前
/// 捕获的像素位置**原样写回。
///
/// 三个恢复入口（`restoreProgress` / `restoreToCharOffset` / `jumpToFragment`）落点后读出
/// 当前页位置交给 `_settleAndNotify(context, pos)`，16 ms 定时器里 `setPagePosition(context,
/// pos)`；`_alignRangeToPage` 落页后下一帧再写一次捕获的 `targetScroll`。两处都不判断这期间
/// 位置有没有被正当改写：迟到的图在窗口内 load、`reapplyImageLateAnchor()` 已按语义锚把
/// 视口挪到正确页，定时器随后把旧页写回，之后没有别的图 load 就再没人纠正，进度回传还会
/// 把错位置落库；揭示后这一帧里用户翻页同样被拽回揭示目标。
///
/// 修复后两处都按**仍登记着的语义锚**重算（锚已清 / 已换代就不写位置）。这里在
/// `flutter test` 内用 Node 真执行分页 shell 对象，定时器与动画帧由测试手动放行，用可移动
/// 几何模拟迟到图片，断言见 `.js` 文件头 A～F。撤掉修复，Node 断言失败、本 Dart 守卫转红。
/// 没有 node 的环境自动 skip。
void main() {
  test(
    'deferred settle / reveal-frame callbacks re-derive the landing from the semantic anchor',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/reader/paged_settle_semantic_anchor_behavior_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final NodeHarnessResult result =
          await runNodeHarness(nodeExe, jsTest.path, <String, String>{
            'paged': ReaderPaginationScripts.paginatedShellSource(),
            'studyUnits': kStudyUnitJs,
          });

      expect(
        result.exitCode,
        0,
        reason:
            'paged settle semantic anchor JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout,
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );
}

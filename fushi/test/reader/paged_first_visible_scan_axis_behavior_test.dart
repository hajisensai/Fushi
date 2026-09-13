import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// BUG-2492：分页首字探针兜底返章首 0 → 统计把整段前文计成已读（iOS 一页记 5172 字）。
///
/// 真机日志（`fushi_study_diag_log.txt`）：`arrive [5406,5429) next` 之后紧跟
/// `arrive [278,5450) back -5128c`，再翻一页 `+5172c`。278 恰是该章的全书累计基址，
/// 即 JS 那次返回了章内 start=0、end=5172：页尾探测正确，页首探针落在插图 `<p><img>`
/// 上走了 `firstVisibleCharOffsetByScanPaged` 兜底，而兜底抄了连续模式的轴
/// （横排 `rect.bottom<=0` / 竖排 `rect.left>=body.clientWidth`），在分页 multicol
/// 几何下前页永远不算「在首边之前」→ 恒 0。重锚路径被 `scrollToCharOffset` 的
/// `<=0 → 保当前页` 掩住，统计接入后一次翻页整段入账。
///
/// 这里在 `flutter test` 内用 Node 真执行分页 shell 对象（`paginatedShellSource()`
/// 抽出的 `window.fushiReader` 字面量 + 真 `fushiStudyUnits`），伪 DOM 按三页带状网格
/// 摆每字 rect，断言：扫描兜底沿翻页轴数出前页字数；`charOffsetOnCurrentPage` 只认
/// 本页；`getLastVisibleCharOffset(start)` 对不在本页的起点返 -1（Dart 不 arrive）；
/// 探点落元素时走几何扫描；`fushiProgressDetails` 的 atEnd 钳位绕不过 -1。撤掉
/// 修复，Node 断言失败、本 Dart 守卫转红。没有 node 的环境自动 skip。
void main() {
  test(
      'paged first-visible scan counts along the page-turn axis and off-page starts never become units',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/reader/paged_first_visible_scan_axis_behavior_test.js',
    );
    expect(jsTest.existsSync(), isTrue,
        reason: 'behavior harness ${jsTest.path} must exist');

    final String payload = jsonEncode(<String, String>{
      'paged': ReaderPaginationScripts.paginatedShellSource(),
      'studyUnits': kStudyUnitJs,
      'engine': readerFushiEngineSourceUncompacted(),
    });
    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi-paged-first-visible-axis-',
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
      reason: 'paged first-visible axis JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// 无头复现辅助（TODO-1229 / BUG-594）：把**真实**分页 / 连续横排 shell（`ReaderPaginationScripts
/// .shellScript` 的完整产物，含 `_sharedJs` 与初始 `restoreProgress(0)` 引导）写到系统 temp，
/// 供 `tool/reader_pitch_headless/*.mjs`（headless Chrome）注入真 shell 复现章首插图跳变。
///
/// CI 跑不到真 WebView，故真实渲染层的「初始落插图页后被重锚二次跳到首文本」只能靠 headless
/// Chrome + 本 dump 复现。生成后跑：
///   flutter test test/reader/reader_headless_shell_dump_test.dart   # 生成 shell 到 temp
///   node tool/reader_pitch_headless/chapter_start_reanchor_probe.mjs # 复现/验证
///
/// 产物文件（systemTemp）：fushi_shell_paginated.html / fushi_shell_continuous.html
/// （另写 fushi_shell_fwd.html / fushi_shell_bwd.html 兼容既有 matrix_probe.mjs）。
/// 本测试永远 pass——它只是把真 shell 落盘，不断言渲染行为（那由 headless probe 断言）。
void main() {
  test('dump paginated + continuous horizontal shell to systemTemp', () {
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
    final String continuous = ReaderPaginationScripts.continuousShellSource();
    final String tmp = Directory.systemTemp.path;
    File('$tmp/fushi_shell_paginated.html').writeAsStringSync(paginated);
    File('$tmp/fushi_shell_continuous.html').writeAsStringSync(continuous);
    File('$tmp/fushi_shell_fwd.html').writeAsStringSync(paginated);
    File('$tmp/fushi_shell_bwd.html').writeAsStringSync(paginated);
    // BUG-2205：shell 已改成运行时工厂（`window.__fushiShells.<mode>(C)`），裸 shell 无法
    // 自举；另写完整引擎产物（含学习单位 JS + `__fushiInstallShell`），探针按真实装配
    // 顺序 `__fushiInstallShell(C)` 安装后自动 boot initialize。
    File('$tmp/fushi_engine_paginated.html').writeAsStringSync(
      ReaderPaginationScripts.engineShell(vnMode: false, continuousMode: false),
    );
    File('$tmp/fushi_engine_continuous.html').writeAsStringSync(
      ReaderPaginationScripts.engineShell(vnMode: false, continuousMode: true),
    );
    expect(paginated.contains('window.fushiReader'), isTrue);
    expect(continuous.contains('window.fushiReader'), isTrue);
  });
}

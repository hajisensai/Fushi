@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/node_runtime.dart';

/// BUG-4102（反馈 3op205DyWN「阅读时卡住」，错误日志 200 条全是同一句）：查词弹窗
/// 词头元数据列的 ResizeObserver 回调里同步挂 / 摘 `.meta-stacked`，改了被观察的
/// `.entry-header` 自身尺寸，Chrome 每次弹窗宽度变化都抛
/// 「ResizeObserver loop completed with undelivered notifications」，经 window.onerror
/// 桥灌满错误日志。真 Chrome 里跑生产 popup.css + popup.js 的那一段
/// （`popup_header_meta_ro_harness.mjs`），拖宽 / 拖窄后不得有 ResizeObserver 报错，
/// 且叠放判据结果不变。
void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe(needsChrome: true);

  test(
    'popup header meta layout raises no ResizeObserver loop error in Chrome',
    () async {
      final String node = runtime.requireNode();
      final Process process = await Process.start(node, <String>[
        'test/dictionary/popup_header_meta_ro_harness.mjs',
      ]);
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      final Future<void> outDone = process.stdout
          .transform(utf8.decoder)
          .forEach(out.write);
      final Future<void> errDone = process.stderr
          .transform(utf8.decoder)
          .forEach(err.write);
      final int? exitCode = await process.exitCode
          .then<int?>((int code) => code)
          .timeout(
            const Duration(seconds: 80),
            onTimeout: () {
              killProcessTree(process);
              return null;
            },
          );
      await Future.wait(<Future<void>>[
        outDone,
        errDone,
      ]).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
      expect(
        exitCode,
        0,
        reason:
            '${exitCode == null ? 'node killed after 80 s\n' : ''}$out\n$err',
      );
      expect(out.toString(), contains('PASS popup header meta ResizeObserver'));
    },
    skip: runtime.skipReason,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

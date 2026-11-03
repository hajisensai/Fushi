import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' show desktopExitWatchdogTimeout;

/// 退出看门狗（main.dart `_exitWatchdogTimeout`，由退出链各步超时推出）决定「正在退出
/// 的旧进程」最长还活多久；Windows / Linux runner 等它让出单实例的上界必须更长，
/// 否则退出链拖满时 runner 先超时，把文件转交给一个马上就没的进程（Windows）或直接
/// 丢掉 argv（Linux）。两个数在不同语言里，只能由这条守卫把它们钉在一起：给退出链
/// 加一步超时让看门狗变长时，这里红，逼着同步放宽 runner 上界。
void main() {
  /// 看门狗到点后 `exit` → 进程拆除 → 内核释放互斥量 / D-Bus 名的余量。
  const Duration teardownSlack = Duration(seconds: 2);

  int runnerWaitMs(String rel) {
    final String src = File(rel).readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'constexpr\s+\w+\s+kPreviousInstanceWaitMs\s*=\s*(\d+)\s*;',
    ).firstMatch(src);
    expect(m, isNotNull, reason: '$rel 必须用具名常量 kPreviousInstanceWaitMs');
    return int.parse(m!.group(1)!);
  }

  test('看门狗由退出链预算推出且长于旧的 6s 拍脑袋值', () {
    expect(desktopExitWatchdogTimeout, greaterThan(const Duration(seconds: 6)));
  });

  for (final String rel in <String>[
    'windows/runner/main.cpp',
    'linux/runner/main.cc',
  ]) {
    test('$rel 等旧实例的上界 ≥ 退出看门狗 + 拆除余量', () {
      final int waitMs = runnerWaitMs(rel);
      expect(
        waitMs,
        greaterThanOrEqualTo(
          (desktopExitWatchdogTimeout + teardownSlack).inMilliseconds,
        ),
        reason:
            '退出看门狗 ${desktopExitWatchdogTimeout.inMilliseconds}ms，'
            'runner 只等 ${waitMs}ms',
      );
    });
  }

  test('Windows runner 的长等待一律走 kPreviousInstanceWaitMs，不留裸字面量', () {
    final String src = File('windows/runner/main.cpp').readAsStringSync();
    final Iterable<RegExpMatch> literalWaits = RegExp(
      r'single_instance_mutex\.Wait\((\d+)\)',
    ).allMatches(src);
    for (final RegExpMatch m in literalWaits) {
      // 只允许分片探测用的短等待。
      expect(
        int.parse(m.group(1)!),
        lessThanOrEqualTo(1000),
        reason: '长等待必须用 kPreviousInstanceWaitMs：${m.group(0)}',
      );
    }
    expect(
      'single_instance_mutex.Wait(kPreviousInstanceWaitMs)'
          .allMatches(src)
          .length,
      2,
      reason: '重启标志分支与「窗口不可见 ⇔ 正在退出」分支',
    );
    expect(src, contains('waited < kPreviousInstanceWaitMs'));
  });
}

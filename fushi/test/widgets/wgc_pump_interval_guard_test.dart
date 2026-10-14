import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3352 guard: the WGC timer pump must tick every system timer tick.
///
/// `DispatcherQueueTimer` 按系统计时器一格（默认 15.625ms）向上取整触发。
/// 间隔写成 16.67ms（「60Hz」）时实测平均 31.3ms 才 Tick 一次，所有 Windows
/// WebView（查词弹窗、阅读器）的画面被压到 ~32 帧。间隔必须明显短于一格
/// （≤ 10ms）才每格都触发；也不能短到在高精度计时下空转（≥ 4ms）。
String _read(List<String> candidates, String name) {
  final File? file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

void main() {
  test('BUG-3352: WGC pump interval fires on every default timer tick', () {
    final String src = maskComments(
      _read(<String>[
        'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      ], 'texture_bridge.cc'),
    );

    final RegExpMatch? match = RegExp(
      r'kPumpInterval100ns\s*=\s*(\d+)\s*;',
    ).firstMatch(src);
    expect(match, isNotNull, reason: 'kPumpInterval100ns must be a literal');
    final int interval100ns = int.parse(match!.group(1)!);

    expect(
      interval100ns,
      lessThanOrEqualTo(100000),
      reason:
          'an interval near/above one 15.625ms system tick rounds up to '
          'two ticks (~32 fps WebView frames)',
    );
    expect(
      interval100ns,
      greaterThanOrEqualTo(40000),
      reason:
          'shorter intervals only spin the UI thread under '
          'timeBeginPeriod(1)',
    );
    expect(
      src.contains('interval.Duration = kPumpInterval100ns'),
      isTrue,
      reason: 'the pump timer must use kPumpInterval100ns',
    );
  });
}

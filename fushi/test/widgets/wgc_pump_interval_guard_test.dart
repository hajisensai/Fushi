import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4114 guard（取代 BUG-3352 的定时器间隔守卫）：WGC 取帧节拍不能挂在
/// UI 线程定时器上。
///
/// 旧实现用 `DispatcherQueueTimer` 在平台线程上每格取一次帧：系统计时器按
/// 15.625ms 一格向上取整（BUG-3352，最好也只有 ~64 Hz），而平台线程与 Dart UI
/// 线程合并，Dart 一忙 tick 就整格推迟，帧池单缓冲时这一帧直接丢掉。现在每个
/// 帧池一条取帧线程，首选合成器时钟（与 DWM 帧对齐），退回路径是按 DWM 刷新
/// 间隔重装的高精度可等待定时器；帧池至少两个缓冲。
String _read(List<String> candidates, String name) {
  final File? file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

void main() {
  test('BUG-4114: WGC frame worker is paced by the compositor clock', () {
    final String src = maskComments(
      _read(<String>[
        'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      ], 'texture_bridge.cc'),
    );

    expect(
      src.contains('DispatcherQueueTimer') || src.contains('CreateTimer('),
      isFalse,
      reason: 'frame pacing must not depend on a UI-thread timer',
    );
    expect(
      src.contains('"DCompositionWaitForCompositorClock"'),
      isTrue,
      reason: 'the worker waits on the compositor clock when available',
    );
    expect(
      src.contains('CREATE_WAITABLE_TIMER_HIGH_RESOLUTION') &&
          src.contains('DwmGetCompositionTimingInfo'),
      isTrue,
      reason:
          'the fallback is a high-resolution timer at the DWM refresh period, '
          'not the 15.625ms-quantised default timer',
    );

    final RegExpMatch? buffers = RegExp(
      r'const int kNumBuffers\s*=\s*(\d+)\s*;',
    ).firstMatch(src);
    expect(buffers, isNotNull, reason: 'kNumBuffers must be a literal');
    expect(
      int.parse(buffers!.group(1)!),
      greaterThanOrEqualTo(2),
      reason:
          'a single-buffer pool gives DWM nowhere to write while a frame is '
          'being copied, so every late pull drops a frame',
    );

    final RegExpMatch? timeout = RegExp(
      r'kCompositorClockTimeoutMs\s*=\s*(\d+)\s*;',
    ).firstMatch(src);
    expect(timeout, isNotNull);
    final int timeoutMs = int.parse(timeout!.group(1)!);
    expect(
      timeoutMs,
      inInclusiveRange(16, 1000),
      reason:
          'the compositor wait must time out so an idle desktop still '
          're-checks the stop signal, without spinning',
    );
  });

  test('BUG-4114: capture session lifts the WGC ~60 Hz delivery throttle', () {
    // 144 Hz 屏实测：不设 MinUpdateInterval 时 WGC 交帧恒为 20.83 ms（每 3 个
    // 刷新周期一帧，48 帧/秒），设 1 ms 后 130～144 帧/秒。必须在 StartCapture
    // 之前设，且接口 IID 与系统 Windows.Graphics.winmd 一致。
    final String src = maskComments(
      _read(<String>[
        'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      ], 'texture_bridge.cc'),
    );
    expect(src, contains('67c0ea62-1f85-5061-925a-239be0ac09cb'));
    final int put = src.indexOf('put_MinUpdateInterval(interval)');
    final int start = src.indexOf('capture_session->StartCapture()');
    expect(put, isNonNegative, reason: 'MinUpdateInterval must be set');
    expect(start, isNonNegative);
    expect(put, lessThan(start), reason: 'set before StartCapture');
    expect(src, contains('interval.Duration = 10000;'));
  });
}

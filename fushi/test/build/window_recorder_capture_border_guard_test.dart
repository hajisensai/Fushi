// BUG-2733 源码守卫：galgame 全屏时游戏窗口四周常驻一圈黄线。
//
// 黄线是 Windows.Graphics.Capture 给被捕获窗口画的系统高亮框。滚动录制
// （window_recorder.cpp）在整局 hook 会话里常驻，与制卡媒体设置无关；而
// `IsBorderRequired` 只在 Windows build 20348+ 的 IGraphicsCaptureSession3 上存在，
// 旧版本（Windows 10 22H2 = 19045）上应用**关不掉**这个框。以前录制静默吞掉去框失败、
// 照常开会话，于是 Win10 用户整局都看着一圈黄线。
// C++ 无法在 Dart 测试里执行，故在源码层锁死结构：
//   ① 去框收口到 wgc_interop.h 的 SuppressCaptureBorder，Session3 缺失要可区分；
//   ② 录制去框失败必须拒绝开会话，且检查在 StartCapture 之前；
//   ③ runner 里不得再有绕过 helper、吞掉 HRESULT 的裸 put_IsBorderRequired；
//   ④ 单帧截图去框失败要进 diagnostics（可在用户日志里证实是否是这类系统）；
//   ⑤ 录制起不来时制卡要有退路（视频片段 → 动图 / 静图）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String interop = File(
    'windows/runner/wgc_interop.h',
  ).readAsStringSync();
  final String recorder = File(
    'windows/runner/window_recorder.cpp',
  ).readAsStringSync();
  final String capture = File(
    'windows/runner/window_capture.cpp',
  ).readAsStringSync();
  final String coordinator = File(
    'lib/src/mining/gal_hook_mining_coordinator.dart',
  ).readAsStringSync();

  test('① SuppressCaptureBorder 收口去框并区分 Session3 缺失', () {
    expect(
      interop.contains('inline HRESULT SuppressCaptureBorder('),
      isTrue,
      reason: '去框必须是具名、返回 HRESULT 的共用入口',
    );
    expect(
      interop.contains('return E_NOINTERFACE;'),
      isTrue,
      reason: 'Session3 缺失（黄框关不掉）必须能与 put 失败区分开',
    );
    expect(
      interop.contains('return session3->put_IsBorderRequired(false);'),
      isTrue,
      reason: 'put 的 HRESULT 必须原样交给调用方，不得吞掉',
    );
  });

  test('② 滚动录制去框失败就不开会话，且在 StartCapture 之前判', () {
    const String gate =
        'if (FAILED(SuppressCaptureBorder(g_state.session.Get()))) {';
    final int gateAt = recorder.indexOf(gate);
    expect(gateAt, isNonNegative, reason: '录制必须检查去框结果');
    final int startAt = recorder.indexOf('g_state.session->StartCapture()');
    expect(startAt, isNonNegative);
    expect(gateAt < startAt, isTrue, reason: 'StartCapture 之后再判，黄框已经画上了');
    final String afterGate = recorder.substring(gateAt, gateAt + 200);
    expect(
      afterGate.contains('return "capture border cannot be suppressed'),
      isTrue,
      reason: '去框失败要走 SetupCapture 的出错返回（拆会话 + Start 返回 false）',
    );
  });

  test('③ runner 里只有 helper 直接调用 put_IsBorderRequired', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'windows/runner',
    ).listSync(recursive: true)) {
      if (entity is! File) continue;
      final String path = entity.path.replaceAll('\\', '/');
      if (!path.endsWith('.cpp') && !path.endsWith('.h')) continue;
      if (path.endsWith('/wgc_interop.h')) continue;
      if (entity.readAsStringSync().contains('->put_IsBorderRequired(')) {
        offenders.add(path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '裸 put 会再次吞掉「黄框没去掉」的事实，一律走 SuppressCaptureBorder',
    );
  });

  test('④ 单帧截图把去框失败写进 diagnostics', () {
    expect(capture.contains('SuppressCaptureBorder(session.Get())'), isTrue);
    expect(
      capture.contains('"IGraphicsCaptureSession3 unavailable (needs Windows '),
      isTrue,
      reason: 'Session3 缺失要留下可证的日志，而不是静默',
    );
  });

  test('⑤ 录制起不来时视频片段卡退回动图 / 静图阶梯', () {
    expect(
      coordinator.contains('// 片段没做出来（录制未启动 / 帧不足 / ffmpeg 失败）：退回既有动图 → 静图阶梯。'),
      isTrue,
      reason: '拒绝录制的代价只能是视频片段降级，不能让制卡失败',
    );
  });
}

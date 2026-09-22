import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';
import 'package:fushi/src/diagnostics/video_frame_timing_probe.dart';

/// [VideoFrameTimingProbe] 的门控与生命周期契约。
///
/// 这个探针挂的是 [SchedulerBinding.addTimingsCallback]——**每一帧**都会回调。诊断
/// 关着时它必须连注册都不做（注册了就等于给每帧加一次回调开销），开着时必须能干净
/// 地摘下来（漏摘 = 退出视频页后仍逐帧记账，探针自己变成卡顿源）。汇总行的算法在
/// `video_diag_stats_test.dart` 里单独测，这里只管接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => VideoDiagLog.instance.resetForTesting());
  tearDown(() => VideoDiagLog.instance.resetForTesting());

  test('诊断关闭时 start 不注册回调', () {
    final VideoFrameTimingProbe probe = VideoFrameTimingProbe();
    probe.start();
    expect(probe.isRunning, isFalse);
    // stop 在没跑起来时也必须安全（页面 dispose 无条件调）。
    probe.stop();
    expect(probe.isRunning, isFalse);
  });

  test('诊断开启时 start/stop 生效且幂等', () {
    VideoDiagLog.instance.enableForTesting();
    final VideoFrameTimingProbe probe = VideoFrameTimingProbe(label: 'unit');
    probe.start();
    expect(probe.isRunning, isTrue);
    probe.start(); // 重复调用不得叠加第二个回调/定时器。
    expect(probe.isRunning, isTrue);
    probe.stop();
    expect(probe.isRunning, isFalse);
    probe.stop();
    expect(probe.isRunning, isFalse);
  });

  test('起停各留一条带标签的痕迹（能在流水里划出观测区间）', () {
    VideoDiagLog.instance.enableForTesting();
    final VideoFrameTimingProbe probe = VideoFrameTimingProbe(label: 'unit');
    probe.start();
    probe.stop();
    final List<String> lines = VideoDiagLog.instance.lines;
    expect(
      lines.any((String l) => l.contains('probe start label=unit')),
      isTrue,
    );
    expect(
      lines.any((String l) => l.contains('probe stop label=unit')),
      isTrue,
    );
  });

  test('frame 类别被过滤串压到 v 以下时同样不注册', () {
    // 用户把 `frame=no` 写进过滤串＝明确不要帧采样，那就连回调都不该挂。
    VideoDiagLog.instance.enableForTesting(msgLevel: 'all=v,frame=no');
    final VideoFrameTimingProbe probe = VideoFrameTimingProbe();
    probe.start();
    expect(probe.isRunning, isFalse);
  });
}

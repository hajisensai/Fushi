// BUG-5038 / video-36e：「换集保持全屏」原先就绪后逐帧重试、最多 30 帧——每帧空转，
// 而 controls 首建慢于 30 帧时直接放弃、全屏丢了。改成事件驱动的一次性闸门：就绪开闸，
// controls context 赋值 / 失败态渲染各触发一次尝试，同帧合并。
//
// 这里用手动帧泵驱动闸门，钉住：
// - 开闸后 context 迟迟不来时**不排任何后续帧**（不轮询）；
// - context 在第 40 帧才来仍然进全屏（旧实现第 31 帧放弃）；
// - 同帧多次通知只尝试一次；开闸前的通知无效；关闸后一切 no-op。
import 'package:fushi/src/media/video/video_initial_fullscreen_gate.dart';
import 'package:test/test.dart';

/// 模拟 `addPostFrameCallback`：排进的回调在下一次 [pumpFrame] 时一并执行。
class _FramePump {
  final List<void Function()> _pending = <void Function()>[];
  int scheduled = 0;

  void schedule(void Function() callback) {
    scheduled++;
    _pending.add(callback);
  }

  bool get hasPending => _pending.isNotEmpty;

  void pumpFrame() {
    final List<void Function()> run = List<void Function()>.of(_pending);
    _pending.clear();
    for (final void Function() callback in run) {
      callback();
    }
  }
}

void main() {
  late _FramePump frames;
  late bool controlsReady;
  late bool failed;
  late int attempts;
  late int entered;
  late int abandoned;
  late VideoInitialFullscreenGate gate;

  setUp(() {
    frames = _FramePump();
    controlsReady = false;
    failed = false;
    attempts = 0;
    entered = 0;
    abandoned = 0;
    gate = VideoInitialFullscreenGate(
      schedulePostFrame: frames.schedule,
      attempt: () {
        attempts++;
        if (failed) {
          abandoned++;
          return VideoInitialFullscreenStep.settled;
        }
        if (!controlsReady) return VideoInitialFullscreenStep.waiting;
        entered++;
        return VideoInitialFullscreenStep.settled;
      },
    );
  });

  test('controls 晚于 30 帧才建仍进全屏，且等待期间不逐帧轮询', () {
    gate.arm();
    expect(frames.scheduled, 1);
    frames.pumpFrame();
    expect(attempts, 1);
    expect(gate.isSettled, isFalse);
    // 40 帧过去，context 一直没来：一个帧回调都不该再排。
    for (int i = 0; i < 40; i++) {
      frames.pumpFrame();
    }
    expect(frames.hasPending, isFalse);
    expect(frames.scheduled, 1, reason: '等待期间不得逐帧排回调');
    expect(attempts, 1);
    // 第 41 帧 controls 建出来、赋值点通知闸门。
    controlsReady = true;
    gate.notify();
    frames.pumpFrame();
    expect(entered, 1, reason: '旧实现第 31 帧就放弃了，这里必须仍进全屏');
    expect(gate.isSettled, isTrue);
  });

  test('同帧多次通知只尝试一次；进过之后再通知是 no-op', () {
    gate.arm();
    controlsReady = true;
    gate.notify();
    gate.notify();
    gate.notify();
    expect(frames.scheduled, 1);
    frames.pumpFrame();
    expect(entered, 1);
    gate.notify();
    gate.arm();
    expect(frames.hasPending, isFalse);
    expect(attempts, 1);
  });

  test('开闸前的通知无效（加载中 controls 不会进全屏）', () {
    controlsReady = true;
    gate.notify();
    expect(frames.hasPending, isFalse);
    expect(attempts, 0);
    gate.arm();
    frames.pumpFrame();
    expect(entered, 1);
  });

  test('开闸后进了失败态：失败渲染事件触发放弃，只放弃一次', () {
    gate.arm();
    frames.pumpFrame();
    failed = true;
    gate.notify();
    gate.notify();
    frames.pumpFrame();
    expect(abandoned, 1);
    expect(entered, 0);
    expect(gate.isSettled, isTrue);
    gate.notify();
    expect(frames.hasPending, isFalse);
  });

  test('settle 后（不需要 / 所有权已移交）开闸与通知都不尝试，排队中的回调也作废', () {
    gate.arm();
    gate.settle();
    controlsReady = true;
    frames.pumpFrame();
    gate.arm();
    gate.notify();
    frames.pumpFrame();
    expect(attempts, 0);
  });
}

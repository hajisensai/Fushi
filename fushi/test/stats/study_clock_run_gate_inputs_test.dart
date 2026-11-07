import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';
import 'package:fushi/src/stats/study_clock_run_gate.dart';

/// 计时门 2026-11-07 新增的输入：失焦（视频面仍在播照计）、计时开始方式、首次开播
/// 自动起表、手动暂停旗的监听口。
void main() {
  // PR #3020 审查：桌面查词窗三端都不抢焦点，主窗报失焦就是切到了别的 app——不存在
  // 「焦点在本 app 查词窗」这种失焦，门也不再有这路输入。
  test('门：失焦且没在播放 → 停表、appForeground 为假；回前台一次落定续表', () {
    final List<bool> applied = <bool>[];
    final StudyClockRunGate gate = StudyClockRunGate(apply: applied.add);
    addTearDown(gate.dispose);
    gate.setUnfocused(true);
    expect(gate.mayRun, isFalse, reason: '真失焦且没在播放');
    expect(gate.appForeground, isFalse);
    expect(applied, <bool>[false]);
    gate.setLifecycleStopped(true);
    gate.setFocusedForeground();
    expect(gate.mayRun, isTrue);
    expect(gate.appForeground, isTrue);
    expect(applied.last, isTrue);
    expect(applied, <bool>[false, false, true], reason: '回前台两旗一起清，只落定一次');
  });

  group('开始方式（与小说同一偏好）', () {
    test('onOpen：照常起表', () {
      final StudyClockRunGate gate = StudyClockRunGate(apply: (_) {});
      addTearDown(gate.dispose);
      gate.applyStartMode(ReaderStudyClockStartMode.onOpen);
      expect(gate.manualPause, isFalse);
      expect(gate.awaitingFirstPlay, isFalse);
      expect(gate.mayRun, isTrue);
    });

    test('manual：打开即暂停，开播不自动起表', () {
      final StudyClockRunGate gate = StudyClockRunGate(apply: (_) {});
      addTearDown(gate.dispose);
      gate.applyStartMode(ReaderStudyClockStartMode.manual);
      expect(gate.mayRun, isFalse);
      gate.setPlaying(true);
      expect(gate.manualPause, isTrue);
      expect(gate.mayRun, isFalse);
    });

    test('onPageTurn：视频解释为首次开播自动起表，监听口随之通知', () {
      final List<bool> applied = <bool>[];
      final StudyClockRunGate gate = StudyClockRunGate(apply: applied.add);
      addTearDown(gate.dispose);
      int notified = 0;
      gate.manualPauseListenable.addListener(() => notified++);
      gate.applyStartMode(ReaderStudyClockStartMode.onPageTurn);
      expect(gate.manualPause, isTrue);
      expect(gate.awaitingFirstPlay, isTrue);
      expect(gate.mayRun, isFalse);
      gate.setPlaying(true);
      expect(gate.manualPause, isFalse);
      expect(gate.awaitingFirstPlay, isFalse);
      expect(gate.mayRun, isTrue);
      expect(applied.last, isTrue);
      expect(notified, 2, reason: '打开置暂停一次 + 首播起表一次');
    });

    test('onPageTurn：开播前用户亲手停 / 续即结束等待，之后开播不替他起表', () {
      final StudyClockRunGate gate = StudyClockRunGate(apply: (_) {});
      addTearDown(gate.dispose);
      gate.applyStartMode(ReaderStudyClockStartMode.onPageTurn);
      gate.toggleManualPause(); // 继续
      gate.toggleManualPause(); // 又暂停
      expect(gate.awaitingFirstPlay, isFalse);
      gate.setPlaying(true);
      expect(gate.manualPause, isTrue);
      expect(gate.mayRun, isFalse);
    });
  });

  test('applyStudyClockRun：无时钟跳过', () {
    expect(applyStudyClockRun(null, true), isFalse);
  });
}

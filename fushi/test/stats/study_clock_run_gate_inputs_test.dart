import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';
import 'package:fushi/src/stats/study_clock_run_gate.dart';

/// 计时门 2026-11-07 新增的输入：本 app 查词窗持有焦点不算失焦、计时开始方式、
/// 首次开播自动起表、手动暂停旗的监听口。
void main() {
  test('判据：焦点在本 app 的查词窗里不算失焦（暂停查词也算时间）', () {
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        unfocused: true,
        focusInOwnWindow: true,
      ),
      isTrue,
    );
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        unfocused: true,
        focusInOwnWindow: true,
        manualPause: true,
      ),
      isFalse,
      reason: '手动暂停仍一票否决',
    );
  });

  test('门：失焦 + 查词窗持焦 → 可跑且 appForeground；查词窗关了 sync 重判', () {
    bool lookupHasFocus = true;
    final List<bool> applied = <bool>[];
    final StudyClockRunGate gate = StudyClockRunGate(
      apply: applied.add,
      focusHeldByOwnWindow: () => lookupHasFocus,
    );
    addTearDown(gate.dispose);
    gate.setUnfocused(true);
    expect(gate.mayRun, isTrue);
    expect(gate.appForeground, isTrue);
    lookupHasFocus = false;
    gate.sync();
    expect(gate.mayRun, isFalse, reason: '真失焦且没在播放');
    expect(gate.appForeground, isFalse);
    expect(applied.last, isFalse);
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

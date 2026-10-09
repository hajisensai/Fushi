import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show studyClockMayRun;
import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';

/// 阅读计时开始方式（手动 / 打开即开始 / 翻页后开始，2026-10-05）的纯逻辑契约。
/// 页面接线见 `test/pages/reader_study_clock_start_mode_wiring_guard_static_test.dart`。
void main() {
  /// 打开书后的时钟可跑判据：只看开始方式门的暂停旗，其余输入取「前台、无面板」。
  bool mayRunInForeground(ReaderStudyClockStartGate gate) => studyClockMayRun(
        manualPause: gate.manualPause,
        lifecycleStopped: false,
        modalDepth: 0,
        audiobookPlaying: false,
      );

  group('偏好值', () {
    test('默认是打开即开始（缺失 / 未知值都回落默认）', () {
      expect(
          kDefaultReaderStudyClockStartMode, ReaderStudyClockStartMode.onOpen);
      expect(ReaderStudyClockStartMode.parse(null),
          ReaderStudyClockStartMode.onOpen);
      expect(ReaderStudyClockStartMode.parse('garbage'),
          ReaderStudyClockStartMode.onOpen);
    });

    test('持久化值往返', () {
      for (final ReaderStudyClockStartMode mode
          in ReaderStudyClockStartMode.values) {
        expect(ReaderStudyClockStartMode.parse(mode.storageValue), mode);
      }
      expect(
        ReaderStudyClockStartMode.values
            .map((ReaderStudyClockStartMode m) => m.storageValue),
        <String>['manual', 'on_open', 'on_page_turn'],
      );
      expect(
          kReaderStudyClockStartModePrefKey, 'stats_reading_clock_start_mode');
    });
  });

  group('打开书时的计时状态', () {
    test('打开即开始：直接在跑', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onOpen);
      expect(gate.manualPause, isFalse);
      expect(gate.awaitingFirstTurn, isFalse);
      expect(mayRunInForeground(gate), isTrue);
    });

    test('手动：暂停，且不等翻页', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.manual);
      expect(gate.manualPause, isTrue);
      expect(gate.awaitingFirstTurn, isFalse);
      expect(mayRunInForeground(gate), isFalse);
    });

    test('翻页后开始：暂停，等首次翻页', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onPageTurn);
      expect(gate.manualPause, isTrue);
      expect(gate.awaitingFirstTurn, isTrue);
      expect(mayRunInForeground(gate), isFalse);
    });
  });

  group('翻页后开始', () {
    test('首次向前翻页起表，之后不再重复触发', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onPageTurn);
      // 打开落定：没有上一单元，不触发。
      expect(gate.noteUnitArrival(previous: null, start: 1000, end: 1400),
          isFalse);
      expect(gate.manualPause, isTrue);
      // 翻到下一页：起点 = 上一页终点。
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1400, end: 1800),
          isTrue);
      expect(gate.manualPause, isFalse);
      expect(gate.awaitingFirstTurn, isFalse);
      expect(mayRunInForeground(gate), isTrue);
      expect(
          gate.noteUnitArrival(previous: (1400, 1800), start: 1800, end: 2200),
          isFalse,
          reason: '只触发一次');
    });

    test('仅打开 / 重排漂移 / 回翻 / 跳转后首落定都不起表', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onPageTurn);
      // 同单元重复采样。
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1000, end: 1400),
          isFalse);
      // 重排 / 宽变：视口首字小幅漂移。
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1012, end: 1450),
          isFalse);
      // 回翻。
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 600, end: 1000),
          isFalse);
      // 跳转（目录 / 进度条）先 leave 清掉当前单元 → previous 为 null。
      expect(gate.noteUnitArrival(previous: null, start: 9000, end: 9400),
          isFalse);
      expect(gate.manualPause, isTrue);
      expect(gate.awaitingFirstTurn, isTrue);
    });

    test('连续滚动：滚过半屏才算推进，滚一两行不算', () {
      expect(
        readerStudyClockTurnAdvanced(
            previous: (1000, 1400), start: 1040, end: 1440),
        isFalse,
      );
      expect(
        readerStudyClockTurnAdvanced(
            previous: (1000, 1400), start: 1200, end: 1600),
        isTrue,
      );
    });

    test('有声书开始出声同样起表；暂停态不触发', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onPageTurn);
      expect(gate.noteAudiobookPlaying(false), isFalse);
      expect(gate.manualPause, isTrue);
      expect(gate.noteAudiobookPlaying(true), isTrue);
      expect(gate.manualPause, isFalse);
    });

    test('用户先手动停 / 续过就不再自动起表', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onPageTurn);
      expect(gate.toggleManualPause(), isFalse, reason: '按 P = 继续');
      expect(gate.toggleManualPause(), isTrue, reason: '再按 P = 暂停');
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1400, end: 1800),
          isFalse,
          reason: '用户亲手暂停了，翻页不能替他续表');
      expect(gate.manualPause, isTrue);
    });
  });

  group('手动', () {
    test('翻页 / 有声书播放都不起表，按 P（toggle）才开始', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.manual);
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1400, end: 1800),
          isFalse);
      expect(gate.noteAudiobookPlaying(true), isFalse);
      expect(mayRunInForeground(gate), isFalse);
      expect(
        studyClockMayRun(
          manualPause: gate.manualPause,
          lifecycleStopped: true,
          modalDepth: 0,
          audiobookPlaying: true,
        ),
        isFalse,
        reason: '手动暂停旗照旧一票否决，后台听书也不计',
      );
      expect(gate.toggleManualPause(), isFalse);
      expect(mayRunInForeground(gate), isTrue);
    });
  });

  group('打开即开始', () {
    test('手动暂停 / 继续照常可用，翻页不会替用户续表', () {
      final ReaderStudyClockStartGate gate =
          ReaderStudyClockStartGate(ReaderStudyClockStartMode.onOpen);
      expect(gate.toggleManualPause(), isTrue);
      expect(
          gate.noteUnitArrival(previous: (1000, 1400), start: 1400, end: 1800),
          isFalse);
      expect(gate.manualPause, isTrue);
      expect(gate.toggleManualPause(), isFalse);
      expect(mayRunInForeground(gate), isTrue);
    });
  });
}

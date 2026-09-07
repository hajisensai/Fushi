import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// 2026-09 阅读统计审计（BUG-2207 / 2170 / 2171 / 2172 / 2173 / 2174 / 2175 /
/// 2179 / 2184）的源码形态守卫。（BUG-2206 的令牌桶清零门随标量水位一起拆除——
/// 字数统计改走 `ReadUnitLedger`，接线守卫见
/// `test/reader/reader_read_ledger_wiring_guard_static_test.dart`。）判据本身是纯函数（见
/// `test/reader/reader_study_clock_policy_test.dart`、`study_clock_test.dart`），这里
/// 钉的是**页面接线**：判据必须被用在正确的位置、旧的裸 start/stop / 无门轮询 /
/// 无条件清零形态不得回归。
void main() {
  final String corpus = maskComments(readReaderPageSource());
  final String studyClock = maskComments(
    File(
      '../packages/fushi_audio/lib/src/audiobook/study_clock.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n'),
  );
  final String pdf = maskComments(
    File(
      'lib/src/pages/implementations/reader_pdf_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n'),
  );

  group('BUG-2209：所有 start / stop 决策只经统一判据 studyClockMayRun', () {
    test('_ensureStudyClock 按 _studyClockMayRun 起表，不再只看手动暂停旗', () {
      final String body = _functionSource(
        corpus,
        '  StudyClock _ensureStudyClock() {',
        '\n  }\n',
      );
      expect(body, contains('if (_studyClockMayRun) clock.start();'));
      expect(
        body,
        isNot(contains('_studyClockManualPause')),
        reason: '旧形态只看手动暂停旗 → 后台听书跟随每次翻章都把已停表的时钟重新起表',
      );
    });

    test('生命周期 paused/inactive 置旗停表、resumed 清旗后经判据续表', () {
      final String body = _functionSource(
        corpus,
        '  void didChangeAppLifecycleState(AppLifecycleState state) {',
        '\n  }\n',
      );
      expect(body, contains('_studyClockLifecycleStopped = true;'));
      expect(body, contains('_studyClockLifecycleStopped = false;'));
      expect(
        '_syncStudyClockRunState();'.allMatches(body),
        hasLength(2),
        reason: '两个分支都经 _syncStudyClockRunState 对齐运行态',
      );
      expect(body, isNot(contains('_studyClock?.start()')));
      expect(body, isNot(contains('_studyClock?.stop()')));
    });

    test('手动暂停开关只翻旗再 sync，不直接 start/stop', () {
      final String body = _functionSource(
        corpus,
        '  void _toggleStudyClockManualPause() {',
        '\n  }\n',
      );
      expect(body, contains('_syncStudyClockRunState();'));
      expect(body, isNot(contains('.start()')));
      expect(body, isNot(contains('.stop()')));
    });

    test('_syncStudyClockRunState：可跑 start、不可跑 stop', () {
      final String body = _functionSource(
        corpus,
        '  void _syncStudyClockRunState() {',
        '\n  }\n',
      );
      expect(body, contains('_studyClockMayRun'));
      expect(body, contains('clock.start();'));
      expect(body, contains('unawaited(clock.stop());'));
    });
  });

  group('BUG-2208：面板 / 弹层 / 全页路由压住正文期间停表', () {
    test('_withStudyClockPaused 计数进出并 sync（finally 保证减计数）', () {
      final String body = _functionSource(
        corpus,
        '  Future<T> _withStudyClockPaused<T>(Future<T> Function() body) async {',
        '\n  }\n',
      );
      expect(body, contains('_studyClockModalDepth++;'));
      expect(body, contains('finally'));
      expect(body, contains('_studyClockModalDepth--;'));
      expect(
        '_syncStudyClockRunState();'.allMatches(body),
        hasLength(2),
        reason: '进入停表、退出按判据续表',
      );
    });

    const List<String> entries = <String>[
      '  Future<void> _showAppearanceSheet({String? initialSubPage}) async {',
      '  void _openReadingStatistics() {',
      '  Future<void> _openAlignmentImportDialog({',
      '  Future<void> _openAudioImportDialog() async {',
      '  Future<void> _openSrtBookReimport() async {',
      '  void _openImageViewer(String imgUrl) {',
      '  void _openGallery() {',
      '  Future<void> _transcribeFromAudiobookPanel() async {',
      '  void _showLyricsModeHintIfNeeded() {',
    ];
    for (final String entry in entries) {
      test('入口经 _withStudyClockPaused：${entry.trim()}', () {
        final String body = _functionSource(corpus, entry, '\n  }\n');
        expect(
          body,
          contains('_withStudyClockPaused('),
          reason: '外观 / 导航 / 搜索 / 统计 / 导入 / 看图 / 画廊都不是阅读，压住期间必须停表',
        );
      });
    }

    test('查词浮窗 / Anki 制卡（mining.part）不停表——那是阅读的一部分', () {
      final String mining = maskComments(
        File(
          'lib/src/pages/implementations/reader_fushi/mining.part.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      expect(mining, isNot(contains('_withStudyClockPaused(')));
    });
  });

  group('BUG-2207：恢复在飞期间 10s 轮询不采样', () {
    test('_refreshProgress 首条门含 _restoreInFlight', () {
      final String body = _functionSource(
        corpus,
        '  Future<void> _refreshProgress() async {',
        '\n  }\n',
      );
      const String gate =
          'if (_controller == null || _lyricsMode || _restoreInFlight) return;';
      final int gateIdx = body.indexOf(gate);
      expect(gateIdx, isNonNegative, reason: '重载在飞时瞬态 atEnd 会把本章剩余计入');
      expect(
        gateIdx,
        lessThan(body.indexOf('evaluateJavascript')),
        reason: '门必须在采样之前',
      );
    });
  });

  group('BUG-2212：听书播放态每次 cue 推进喂空闲门', () {
    test('_onCueChanged 在歌词模式分支之前按 isPlaying touch', () {
      final String body = _functionSource(
        corpus,
        '  void _onCueChanged() {',
        '\n  }\n',
      );
      const String touch = 'if (controller.isPlaying) _studyClock?.touch();';
      final int touchIdx = body.indexOf(touch);
      expect(touchIdx, isNonNegative, reason: '歌词模式没有滚动回传，听一小时只计 10 分钟');
      expect(touchIdx, lessThan(body.indexOf('if (_lyricsMode) {')));
    });
  });

  group('BUG-2213：空闲门分钟数不在建时钟时快照', () {
    test('_ensureStudyClock 每次刷新 idleTimeout，构造期不传', () {
      final String body = _functionSource(
        corpus,
        '  StudyClock _ensureStudyClock() {',
        '\n  }\n',
      );
      expect(
        body,
        contains('clock.idleTimeout = appModel.readingIdleTimeout;'),
      );
      expect(body, isNot(contains('idleTimeout: appModel.readingIdleTimeout')));
    });

    test('外观面板关闭时也刷一次', () {
      final String body = _functionSource(
        corpus,
        '  Future<void> _showAppearanceSheet({String? initialSubPage}) async {',
        '\n  }\n',
      );
      expect(
        body,
        contains('_studyClock?.idleTimeout = appModel.readingIdleTimeout;'),
      );
    });
  });

  group('BUG-2210 / BUG-2211 / BUG-2217：StudyClock 内容账与起表形态', () {
    test('addChars / addPages 停表即丢、记账前先结算待定窗口', () {
      for (final String start in <String>[
        '  void addChars(int chars) {',
        '  void addPages(int pages) {',
      ]) {
        final String body = _functionSource(studyClock, start, '\n  }\n');
        expect(body, contains('!isRunning) return;'), reason: start);
        expect(body, contains('_settleBeforeContentAccount();'), reason: start);
      }
    });

    test('start 无条件重锚空闲基准', () {
      final String body = _functionSource(
        studyClock,
        '  void start() {',
        '\n  }\n',
      );
      expect(body, contains('_lastTouch = now;'));
      expect(body, isNot(contains('_lastTouch ??= now;')));
    });
  });

  group('BUG-2222：PDF 翻页记页数（2026-09-06 起走 ReadUnitLedger 翻走即计）', () {
    test('_onPageChanged 把页号单元交给账本，onCredit 按首次覆盖长度 addPages', () {
      final String body = _functionSource(
        pdf,
        '  void _onPageChanged(int? pageNumber) {',
        '\n  }\n',
      );
      expect(body, contains('_studyClock?.touch();'));
      expect(body, contains('_readLedger.arrive(pageIndex, pageIndex + 1);'));
      expect(pdf, contains('addPages(readUnitsLength('));
      expect(
        pdf,
        contains('retractPages(readUnitsLength('),
        reason: '回翻撤回（onRetract）必须对称接到 retractPages',
      );
      // 标量水位形态已废：跳 N 页只计跳走前那页，不再计 N 页。
      expect(pdf, isNot(contains('pdfPagesNewlyReached')));
      expect(pdf, isNot(contains('_sessionMaxPageIndex')));
    });

    test('dispose / onSourcePagePop 在 flush 前 leave()，结算停在的最后一页', () {
      final String dispose = _functionSource(
        pdf,
        '  void dispose() {',
        '\n  }\n',
      );
      expect(
        dispose.indexOf('_readLedger.leave();'),
        allOf(
          greaterThanOrEqualTo(0),
          lessThan(dispose.indexOf('unawaited(_flushPosition());')),
        ),
      );
      final String pop = _functionSource(
        pdf,
        '  Future<void> onSourcePagePop() async {',
        '\n  }\n',
      );
      expect(
        pop.indexOf('_readLedger.leave();'),
        allOf(
          greaterThanOrEqualTo(0),
          lessThan(pop.indexOf('await _flushPosition();')),
        ),
      );
    });
  });
}

/// 从 [start] 标记切到其后的第一个 [end] 标记（与
/// `reader_stats_pure_duration_guard_static_test.dart` 同范式）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

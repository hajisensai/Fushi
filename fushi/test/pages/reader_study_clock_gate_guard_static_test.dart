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

  group('BUG-2558：后台听书期间照常计时', () {
    final String session = maskComments(
      File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );

    test('_studyClockMayRun 现读控制器播放态，不读镜像字段', () {
      final String body = _functionSource(
        corpus,
        '  bool get _studyClockMayRun =>',
        ';\n',
      );
      expect(
        body,
        contains('audiobookPlaying: _audiobookController?.isPlaying ?? false'),
        reason: '判据读镜像字段就会在媒体中心暂停后多计到下一次事件',
      );
      expect(
        body,
        isNot(contains('audiobookPlaying: _audiobookPlayingForStudyClock')),
      );
    });

    test('_onCueChanged 在播放态翻转时 sync 运行态（暂停后不会再有 cue）', () {
      final String body = _functionSource(
        corpus,
        '  void _onCueChanged() {',
        '\n  }\n',
      );
      expect(
        body,
        contains('_noteAudiobookPlayingForStudyClock(controller.isPlaying);'),
        reason: '不 sync 的话后台暂停后时钟一直空转到下一次前台事件',
      );
    });

    test('_noteAudiobookPlayingForStudyClock 只在翻转时 sync', () {
      final String body = _functionSource(
        corpus,
        '  void _noteAudiobookPlayingForStudyClock(bool playing) {',
        '\n  }\n',
      );
      expect(
        body,
        contains('if (playing == _audiobookPlayingForStudyClock) return;'),
      );
      expect(body, contains('_syncStudyClockRunState();'));
      expect(body, isNot(contains('.start()')));
      expect(body, isNot(contains('.stop()')));
    });

    test('会话侧后台时钟与 reader 那只互斥（判据含 hasReaderAttached）', () {
      final String body = _functionSource(
        session,
        '  bool get _studyClockMayRun =>',
        ';\n',
      );
      expect(
        body,
        contains('!hasReaderAttached'),
        reason: '两只时钟同时跑 = 同一段时间记两遍',
      );
      expect(
        body,
        contains('_controller?.isPlaying ?? false'),
        reason: '「会话还活着」不是「在学习」——判据要的是真在出声',
      );
    });

    test('判据三个输入的每一次翻转都接到了 sync', () {
      for (final String marker in <String>[
        // 播放态：控制器 notify（含 just_audio playingStream）
        '  void _onControllerChanged() {',
        // reader 在场：两个方向都要
        '  void attachReader(ReaderAudiobookView reader) {',
        '  void detachReader(ReaderAudiobookView reader) {',
      ]) {
        final String body = _functionSource(session, marker, '\n  }\n');
        expect(
          body,
          contains('_syncStudyClockRunState();'),
          reason: '漏一个翻转点就是漏计 / 多计一整段：$marker',
        );
      }
    });

    test('停会话在清空 _book 之前结算时钟，dispose 走零 IO 的 detach', () {
      final String stop = _functionSource(
        session,
        '  Future<void> _stopInternal() async {',
        '\n  }\n',
      );
      final int retireIdx = stop.indexOf('_retireStudyClock();');
      expect(retireIdx, isNonNegative);
      expect(
        retireIdx,
        lessThan(stop.indexOf('_book = null;')),
        reason: '_book 清空后判据恒 false，但那时已经没人持有这只时钟了',
      );

      final String dispose = _functionSource(
        session,
        '  void dispose() {',
        '\n  }\n',
      );
      expect(
        dispose,
        contains('_studyClock?.detach();'),
        reason: 'dispose 是同步的：在这里 stop() 就是无人 await 的事务，'
            '会与随后的 db.close() 互等（与阅读器 / PDF 的 dispose 同律）',
      );
      expect(dispose, isNot(contains('_studyClock?.stop()')));
    });

    test('后台听书时钟的统计身份与阅读器同源（不用 SRT 的 uid）', () {
      final String body = _functionSource(
        session,
        '  StudyClock? _ensureStudyClock() {',
        '\n  }\n',
      );
      expect(body, contains('mediaKey: book.studyMediaKey,'));
      expect(
        body,
        isNot(contains('mediaKey: book.bookKey')),
        reason: 'SRT 书源的 bookKey 是 srt_books.uid，'
            '记岔了同一本书在统计中心会裂成两条',
      );
      expect(body, contains('mediaKind: kActivityMediaBook,'));
    });

    test('launcher 两条分支都显式填统计身份 = 调用方传进来的 key', () {
      final String launcher = maskComments(
        File(
          'lib/src/media/audiobook/audiobook_session_launcher.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      expect(
        'statsMediaKey:'.allMatches(launcher),
        hasLength(2),
        reason: 'EPUB 与 SRT 两条分支各一处；漏一条就是那条路的统计记到别的身份上',
      );
      expect(launcher, contains('statsMediaKey: bookKey,'));
      expect(launcher, contains('statsMediaKey: statsMediaKey,'));
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
      '  Future<void> _openStatisticsCenter() async {',
      '  Future<void> _openAlignmentImportDialog(',
      '  Future<void> _openAudioImportDialog() async {',
      '  Future<void> _openSrtBookReimport() async {',
      '  void _openImageViewer(String imgUrl, {File? resolvedFile}) {',
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
          reason: '外观 / 导航 / 搜索 / 统计中心 / 导入 / 看图 / 画廊都不是阅读，'
              '压住期间必须停表',
        );
      });
    }

    test('书内统计侧栏（_openReadingStatistics）有意不停表——侧栏不遮正文', () {
      // 2026-09-13 chrome 重做：统计从 640px 居中对话框改成右侧侧栏，正文照常可读，
      // 侧栏里就是一块实时走的秒表 + 暂停键（_toggleStudyClockManualPause）。停表
      // 会让那块秒表永远不动。「打开完整记录」那条全页路由仍在上面的停表清单里。
      final String body = _functionSource(
        corpus,
        '  void _openReadingStatistics() {',
        '\n  }\n',
      );
      expect(body, contains('_presentSideSheet('));
      expect(body, isNot(contains('_withStudyClockPaused(')));
      expect(body, contains('onTogglePause: _toggleStudyClockManualPause,'));
    });

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

    test('关书三条路只停表 / 落盘，不结算站着的页（BUG-2264）', () {
      final String dispose = _functionSource(
        pdf,
        '  void dispose() {',
        '\n  }\n',
      );
      expect(
        dispose,
        contains('_studyClock?.detach();'),
        reason: 'dispose 是同步的：停表必须走 detach（零 IO，攒下的写交给 '
            'ExitFlushRegistry.defer）；在 dispose 里直接落库 = 无人 await 的事务，'
            '与随后的 db.close() 互等',
      );
      expect(
        dispose.contains('_readLedger'),
        isFalse,
        reason: 'BUG-2264：关书不是翻走，dispose 不许把 leave 交给 detach 结算落地页',
      );
      for (final String forbidden in <String>[
        'unawaited(_flushPosition());',
        '_studyClock?.dispose();',
      ]) {
        expect(
          dispose.contains(forbidden),
          isFalse,
          reason: 'dispose 不得发起无人 await 的 DB 写：$forbidden',
        );
      }
      expect(
        dispose,
        contains('ExitFlushRegistry.instance.defer(_flushPosition);'),
      );
      // 进程退出登记 _flushForExit（只落盘）：桌面点 X 不触发 dispose。
      expect(pdf, contains('ExitFlushRegistry.instance.register(_flushForExit);'));
      final String forExit = _functionSource(
        pdf,
        '  Future<void> _flushForExit() async {',
        '\n  }\n',
      );
      expect(forExit, contains('await _flushPosition();'));
      expect(
        forExit.contains('_readLedger'),
        isFalse,
        reason: '退出 / 退后台不是翻走（BUG-2264）；旧 settle 已删',
      );
      final String pop = _functionSource(
        pdf,
        '  Future<void> onSourcePagePop() async {',
        '\n  }\n',
      );
      expect(pop, contains('await _flushPosition();'));
      expect(
        pop.contains('_readLedger'),
        isFalse,
        reason: '关书那页此刻不结算（开关一次涨一次的根因就是这里的 leave）',
      );
      expect(
        '_readLedger.leave('.allMatches(pdf),
        isEmpty,
        reason: 'PDF 没有跳转入口：翻页 / 跳页都经 arrive 切单元，全文件零 leave',
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

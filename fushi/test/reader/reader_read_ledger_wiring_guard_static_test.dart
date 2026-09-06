import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// EPUB 阅读器 `ReadUnitLedger`（翻走即计 + 会话覆盖并集，2026-09-06 裁定）的接线守卫。
/// 账本语义本身由 `test/stats/read_unit_ledger_test.dart` 与
/// `reader_read_ledger_boundaries_test.dart` 锁定，这里钉的是**页面把账本接在了正确的
/// 位置、且只在那些位置**：
///
///  * `_refreshProgress`：每次采样把当前可见区间 `[start, end)`（经 `absoluteCharOffsetOf`
///    换成全书绝对偏移，起 / 止都 >= 0 且 end > start）交给 `arrive`——这是**唯一**的
///    记字入口；
///  * `_onRestoreComplete`：不播种，只在 `restoreIsInPlace` 时 `rebaseOnNextArrive`；
///  * `_failNavigation`（含内容就绪兜底超时）：`discard`；
///  * `_recomputeCharCountsInBackground` 落定：`reset`；
///  * 显式跳句 `_handleExplicitCueJump`：`leave`；
///  * dispose / `onSourcePagePop` / 进程退出 flush：`leave` 在 `_flushReadingStats` 之前；
///  * 听书 reveal 落定后补刷一次 `_refreshProgress`（B-3 窗吃掉 scroll 回传）；
///  * 进度条拖动 / 搜索跳转不再对账本做任何动作（旧标量水位在此播种）。
void main() {
  final String corpus = readReaderPageSource();
  final String masked = maskComments(corpus);

  group('arrive：_refreshProgress 是唯一记字入口', () {
    final String body = methodBody(
      corpus,
      'Future<void> _refreshProgress() async',
    );

    test('起 / 止都经 absoluteCharOffsetOf 换算，止点取 snapshot.charOffsetEnd', () {
      expect(containsCodeLine(body, 'absoluteCharOffsetOf('), isTrue);
      expect(
        containsCodeLine(body, 'charOffset: snapshot.charOffsetEnd,'),
        isTrue,
        reason: '单元终点必须来自四段协议的第四段（当前可见区间终点）',
      );
      expect(containsCodeLine(body, 'charOffset: charOffset,'), isTrue);
    });

    test('arrive 受「起止都有效且 end > start」门控', () {
      final int gate = body.indexOf(
        'if (unitStart >= 0 && unitEnd > unitStart) {',
      );
      final int arrive = body.indexOf(
        '_readLedger.arrive(unitStart, unitEnd);',
      );
      expect(gate, isNonNegative, reason: 'JS 拿不到起 / 止点时不 arrive（宁可不计）');
      expect(arrive, greaterThan(gate));
    });

    test('采样时记下实时锚 _readLedgerLiveAnchor（给原位恢复判据）', () {
      final int anchor = body.indexOf(
        '_readLedgerLiveAnchor = (_currentChapter, charOffset);',
      );
      expect(anchor, isNonNegative);
      expect(
        anchor,
        lessThan(body.indexOf('_readLedger.arrive(')),
        reason: '锚与 arrive 描述同一次采样',
      );
    });

    test('分数口径的 _absoluteCharPosition 只留给进度 UI，不再进统计', () {
      expect(containsCodeLine(body, '_absoluteCharPosition(progress)'), isTrue);
      expect(containsIdentifier(body, 'addChars'), isFalse);
    });

    test('全语料只有 _refreshProgress 调 _readLedger.arrive(', () {
      expect('_readLedger.arrive('.allMatches(masked), hasLength(1));
    });
  });

  group('账本构造：结算直接记进 StudyClock 当前段', () {
    test('onCredit → _ensureStudyClock().addChars(readUnitsLength(fresh))', () {
      expect(
        containsCodeLine(
          corpus,
          'late final ReadUnitLedger _readLedger = ReadUnitLedger(',
        ),
        isTrue,
      );
      expect(
        containsCodeLine(
          corpus,
          '_ensureStudyClock().addChars(readUnitsLength(fresh)),',
        ),
        isTrue,
        reason: '字数与时长同一段（v92），停表期间由 StudyClock.addChars 丢弃',
      );
    });
  });

  group('rebase：恢复完成不播种，只在原位恢复时换坐标', () {
    final String body = methodBody(corpus, 'void _onRestoreComplete()');

    test('restoreIsInPlace 门控 rebaseOnNextArrive', () {
      final int gate = body.indexOf('if (restoreIsInPlace(');
      final int rebase = body.indexOf('_readLedger.rebaseOnNextArrive();');
      expect(gate, isNonNegative);
      expect(rebase, greaterThan(gate));
      expect(
        containsCodeLine(body, 'restoredCharOffset: _initialCharOffset,'),
        isTrue,
        reason: '恢复锚必须是真实恢复锚（BUG-1107 断点 B 的同源要求）',
      );
    });

    test('判据的「上一次实时进度」来自 _readLedgerLiveAnchor，不是被导航镜像的 _lastProgress*', () {
      expect(containsCodeLine(body, 'lastChapter: liveAnchor?.\$1,'), isTrue);
      expect(
        containsCodeLine(body, 'lastCharOffset: liveAnchor?.\$2,'),
        isTrue,
      );
      expect(
        containsIdentifier(body, '_lastProgressCharOffset'),
        isFalse,
        reason:
            '_navigateToChapter / _reloadWithCurrentSettings 把 _lastProgressCharOffset '
            '镜像成 _initialCharOffset，拿它比对恒等 → 收藏句跨章跳转被误判成原位',
      );
    });

    test('恢复完成不结算、不丢弃、不清并集', () {
      for (final String verb in <String>[
        '_readLedger.arrive(',
        '_readLedger.leave(',
        '_readLedger.discard(',
        '_readLedger.reset(',
      ]) {
        expect(containsCodeLine(body, verb), isFalse, reason: verb);
      }
    });

    test('全语料只有 _onRestoreComplete 调 rebaseOnNextArrive', () {
      expect(
        '_readLedger.rebaseOnNextArrive('.allMatches(masked),
        hasLength(1),
      );
    });
  });

  group('discard：导航中止 / 内容就绪兜底超时', () {
    test('_failNavigation 丢弃当前单元', () {
      final String body = methodBody(corpus, 'void _failNavigation()');
      expect(containsCodeLine(body, '_readLedger.discard();'), isTrue);
    });

    test('内容就绪兜底超时经 _failNavigation（同一份收尾）', () {
      final String body = methodBody(
        corpus,
        'void _startContentReadyTimeout()',
      );
      expect(containsCodeLine(body, '_failNavigation();'), isTrue);
    });

    test('全语料只有 _failNavigation 调 discard', () {
      expect('_readLedger.discard('.allMatches(masked), hasLength(1));
    });
  });

  group('reset：章字数后台补算落定（坐标系整体变更）', () {
    test('_recomputeCharCountsInBackground 落定后 reset', () {
      final String body = methodBody(
        corpus,
        'void _recomputeCharCountsInBackground()',
      );
      final int adopt = body.indexOf('_applyCharCounts(counts);');
      final int reset = body.indexOf('_readLedger.reset();');
      expect(adopt, isNonNegative);
      expect(reset, greaterThan(adopt), reason: '先换口径再清账本');
    });

    test('全语料只有补算落定调 reset', () {
      expect('_readLedger.reset('.allMatches(masked), hasLength(1));
    });
  });

  group('leave：显式跳句 + 关书三条路', () {
    test('_handleExplicitCueJump 体内只 leave', () {
      final String body = methodBody(
        corpus,
        'void _handleExplicitCueJump(AudioCue cue)',
      );
      expect(containsCodeLine(body, '_readLedger.leave();'), isTrue);
      expect(
        containsIdentifier(masked, '_absoluteCharPositionForCue'),
        isFalse,
        reason: 'cue 绝对位置只服务旧水位播种，随之删除',
      );
    });

    test('dispose：leave 在 _failNavigation（discard）与 _flushReadingStats 之前', () {
      final String body = methodBody(corpus, 'void dispose()');
      final int leave = body.indexOf('_readLedger.leave();');
      final int fail = body.indexOf('_failNavigation();');
      final int flush = body.indexOf('_flushReadingStats();');
      expect(leave, isNonNegative);
      expect(
        leave,
        lessThan(fail),
        reason: '_failNavigation 会 discard，关书那页必须先结算',
      );
      expect(leave, lessThan(flush));
      expect(
        containsCodeLine(body, '_revealProgressRefreshTimer?.cancel();'),
        isTrue,
      );
    });

    test('onSourcePagePop：leave 在 await _flushReadingStats 之前', () {
      final String body = methodBody(
        corpus,
        'Future<void> onSourcePagePop() async',
      );
      final int leave = body.indexOf('_readLedger.leave();');
      final int flush = body.indexOf('await _flushReadingStats();');
      expect(leave, isNonNegative);
      expect(leave, lessThan(flush));
    });

    test('进程退出 flush：leave 在 await _flushReadingStats 之前', () {
      final String body = methodBody(
        corpus,
        'Future<void> _flushAllForProcessExit() async',
      );
      final int leave = body.indexOf('_readLedger.leave();');
      final int flush = body.indexOf('await _flushReadingStats();');
      expect(leave, isNonNegative);
      expect(leave, lessThan(flush));
    });

    test('_flushReadingStats 体保持只委托 flushNow（不碰账本）', () {
      final String body = methodBody(
        corpus,
        'Future<void> _flushReadingStats() async',
      );
      expect(containsIdentifier(body, '_readLedger'), isFalse);
      expect(containsCodeLine(body, 'await _studyClock?.flushNow();'), isTrue);
    });

    test('leave 恰在跳句 + dispose + onSourcePagePop + 进程退出四处', () {
      expect('_readLedger.leave('.allMatches(masked), hasLength(4));
    });
  });

  group('跳转不对账本做动作（旧标量水位在此播种）', () {
    test('_jumpToGlobalCharOffset 无账本动作', () {
      final String body = methodBody(
        corpus,
        'Future<void> _jumpToGlobalCharOffset(int globalOffset) async',
      );
      expect(containsIdentifier(body, '_readLedger'), isFalse);
      expect(containsIdentifier(body, '_sessionMaxAbsoluteChars'), isFalse);
    });

    test('onSearchJump 无账本动作', () {
      final int start = masked.indexOf(
        'onSearchJump: (BookSearchResult result, String query) async {',
      );
      expect(start, isNonNegative);
      final int end = masked.indexOf('switch (action) {', start);
      expect(end, greaterThan(start));
      final String body = masked.substring(start, end);
      expect(containsIdentifier(body, '_readLedger'), isFalse);
      expect(containsIdentifier(body, '_sessionMaxAbsoluteChars'), isFalse);
    });
  });

  group('听书 reveal 落定后补刷进度', () {
    test('_onCueChanged 在 highlight 之后按 reveal 排补刷', () {
      final String body = methodBody(corpus, 'void _onCueChanged()');
      final int stamp = body.indexOf('_reanchorClearedAt = DateTime.now();');
      final int highlight = body.indexOf('AudiobookBridge.highlight(', stamp);
      final int schedule = body.indexOf(
        'if (reveal) _scheduleRevealProgressRefresh();',
      );
      expect(stamp, isNonNegative);
      expect(highlight, greaterThan(stamp));
      expect(schedule, greaterThan(highlight));
    });

    test('补刷排在 B-3 窗（kReaderReanchorSettleMs）关闭之后，单 Timer 复位', () {
      final String body = methodBody(
        corpus,
        'void _scheduleRevealProgressRefresh()',
      );
      expect(
        containsCodeLine(body, '_revealProgressRefreshTimer?.cancel();'),
        isTrue,
      );
      expect(
        containsCodeLine(
          body,
          'const Duration(milliseconds: kReaderReanchorSettleMs),',
        ),
        isTrue,
        reason: '与 readerScrollWithinReanchorSettle 同一个窗常量，不再散落 250 字面量',
      );
      expect(containsCodeLine(body, 'unawaited(_refreshProgress());'), isTrue);
      expect(containsCodeLine(body, 'if (!mounted) return;'), isTrue);
    });
  });

  group('四段协议解析', () {
    test('ReaderStableProgressDetails 带 charOffsetEnd，第四段缺省 -1', () {
      expect(containsCodeLine(corpus, '  int charOffsetEnd,'), isTrue);
      expect(
        containsCodeLine(corpus, 'final int charOffsetEnd = parts.length >= 4'),
        isTrue,
      );
    });
  });
}

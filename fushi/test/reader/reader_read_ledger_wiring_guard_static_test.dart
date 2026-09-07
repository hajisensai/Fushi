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
///  * 离开当前单元只有一种动作 `leave`，且在**离开那一刻**：`_beginNavigation`（所有
///    导航的必经点）与同章跳转入口（进度条 `restoreProgress` / 收藏句 `restoreToCharOffset`
///    / 脚注内链 `jumpToFragment`）；`_onRestoreComplete` 不碰账本（BUG-2225 / 2189：
///    旧的 `restoreIsInPlace → rebaseOnNextArrive` 把同章跳转恒判原位、跳走前那页不结算）；
///  * `_failNavigation`（含内容就绪兜底超时）：`discard`；
///  * `_recomputeCharCountsInBackground` 落定：`reset`；
///  * 显式跳句 `_handleExplicitCueJump`：`leave`；
///  * dispose / `onSourcePagePop` / 进程退出 flush：`leave` 在 `_flushReadingStats` 之前；
///  * 听书 reveal 落定后与 B-3 窗内丢弃 scroll 回传后各补刷一次 `_refreshProgress`
///    （同一个 Timer；BUG-2227：窗内丢掉的可能是用户真实落点，只等 10s 轮询会让关书
///    结算旧页）；
///  * 跳转不播种（旧标量水位在此播种），跨章的离开结算由 `_beginNavigation` 统一做。
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
      expect(
        containsCodeLine(
          corpus,
          '_ensureStudyClock().retractChars(readUnitsLength(retracted)),',
        ),
        isTrue,
        reason: '回翻撤回对称接到 retractChars（会话级夹 0 由 StudyClock 保证）',
      );
    });
  });

  group('leave：离开当前单元只在离开那一刻（BUG-2225 / BUG-2226）', () {
    test('_beginNavigation 先 leave 再置恢复在飞（所有导航的必经点）', () {
      final String body = methodBody(corpus, 'void _beginNavigation(');
      final int leave = body.indexOf('_readLedger.leave();');
      final int inFlight = body.indexOf('_restoreInFlight = true;');
      expect(leave, isNonNegative, reason: '跳走前那页在离开那一刻结算');
      expect(leave, lessThan(inFlight));
      expect(
        leave,
        lessThan(body.indexOf('_preciseLocateQueue.clear();')),
        reason: '在 loadUrl 之前：装载失败 / 兜底超时 discard 时当前单元已空（BUG-2226）',
      );
    });

    test('_onRestoreComplete 不碰账本（不播种、不 rebase、不结算）', () {
      final String body = methodBody(corpus, 'void _onRestoreComplete()');
      expect(
        containsIdentifier(body, '_readLedger'),
        isFalse,
        reason:
            'BUG-2225：旧 restoreIsInPlace 拿「恢复锚 vs 上次采样」比对，同章跳转不经 '
            '_beginNavigation、恢复锚就是上次采样 → 恒判原位 → 跳走前那页被 rebase 掉',
      );
    });

    test('同章进度条跳转（restoreProgress）在 JS 之前 leave', () {
      final String body = methodBody(
        corpus,
        'Future<void> _jumpToGlobalCharOffset(int globalOffset) async',
      );
      final int navigate = body.indexOf('_navigateToChapterAndWait(');
      final int leave = body.indexOf('_readLedger.leave();');
      final int js = body.indexOf('restoreProgress(');
      expect(navigate, isNonNegative);
      expect(
        leave,
        greaterThan(navigate),
        reason: '只在同章分支（跨章由 _beginNavigation）',
      );
      expect(js, greaterThan(leave));
      expect(containsIdentifier(body, '_sessionMaxAbsoluteChars'), isFalse);
    });

    test('同章收藏跳转（restoreToCharOffset）在 JS 之前 leave', () {
      final String body = methodBody(
        corpus,
        'Future<void> _jumpToFavoriteSentence(FavoriteSentence fav) async',
      );
      final int navigate = body.indexOf('_navigateToChapterAndWait(');
      final int leave = body.indexOf('_readLedger.leave();');
      final int js = body.indexOf('.restoreToCharOffset(');
      expect(navigate, isNonNegative);
      expect(leave, greaterThan(navigate));
      expect(js, greaterThan(leave));
    });

    test('同章脚注内链（jumpToFragment）在 JS 之前 leave', () {
      final String body = methodBody(
        corpus,
        'Future<void> _jumpToFragmentInPlace(String fragment) async',
      );
      final int leave = body.indexOf('_readLedger.leave();');
      final int js = body.indexOf('jumpToFragment(');
      expect(leave, isNonNegative);
      expect(js, greaterThan(leave));
    });

    test('原位恢复判据与实时锚已删（EPUB 不再用 rebaseOnNextArrive）', () {
      for (final String stale in <String>[
        'restoreIsInPlace',
        '_readLedgerLiveAnchor',
        '_readLedger.rebaseOnNextArrive(',
      ]) {
        expect(containsIdentifier(masked, stale), isFalse, reason: stale);
      }
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

    test(
      'leave 恰八处：跳句 + dispose + onSourcePagePop + 进程退出 + _beginNavigation + 三个同章跳转入口',
      () {
        expect('_readLedger.leave('.allMatches(masked), hasLength(8));
      },
    );
  });

  group('搜索跳转不对账本做动作（只滚动、不 notifyRestoreComplete，落点首个 arrive 结算旧页）', () {
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
        'if (reveal) _scheduleReanchorSettleProgressRefresh();',
      );
      expect(stamp, isNonNegative);
      expect(highlight, greaterThan(stamp));
      expect(schedule, greaterThan(highlight));
    });

    test('补刷排在 B-3 窗（kReaderReanchorSettleMs）关闭之后，单 Timer 复位', () {
      final String body = methodBody(
        corpus,
        'void _scheduleReanchorSettleProgressRefresh()',
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

    test('B-3 窗内丢弃 scroll 回传时也排同一个补刷（BUG-2227）', () {
      final String body = methodBody(corpus, 'void _handleReaderScroll()');
      final int gate = body.indexOf('if (readerScrollWithinReanchorSettle(');
      final int schedule = body.indexOf(
        '_scheduleReanchorSettleProgressRefresh();',
        gate,
      );
      final int ret = body.indexOf('return;', gate);
      expect(gate, isNonNegative);
      expect(schedule, greaterThan(gate));
      expect(
        ret,
        greaterThan(schedule),
        reason: '丢弃不变，但窗关后必须补刷一次，落点页不能只靠 10s 轮询',
      );
      expect(
        '_scheduleReanchorSettleProgressRefresh('.allMatches(masked),
        hasLength(3),
        reason: '定义 + 听书 reveal + B-3 丢弃，共用一个单 Timer',
      );
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

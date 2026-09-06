import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// 漫画阅读统计的接线守卫（源码语料层，同 `manga_routing_guard_test.dart` 纪律——
/// MangaFushiPage 过重无法在纯 widget test 拉起完整链路）。
///
/// 2026-09-06 裁定（`docs/plans/2026-09-06-read-unit-ledger.md`）：三域「读过」判据
/// 统一为 `ReadUnitLedger`——**翻走即计 + 会话覆盖并集**。漫画因此**推翻** BUG-1761
/// 的到达停留裁定：没有 1.5s 停留门、没有会话 `Set` 去重、没有存档预置。守卫钉：
///
/// 1. **唯一账本**：位置落定只经 `_noteVisiblePages()`（`touch()` + `arrive`），
///    `_readLedger.arrive(` 只出现在这一处；四个位置变化入口（本地开书 / 在线开章 /
///    `_recordProgress` / spread↔webtoon 切换）都走它。
/// 2. **离开结算**：dispose 与 `onSourcePagePop` 在 flush / 时钟 dispose 之前
///    `_readLedger.leave()`；换章（同 State 内页号坐标系重用）`leave()` + `reset()`。
/// 3. **停留门 / Set / 预置形态不得回潮**：`_sessionCountedPages` / `_pageDwellTimer` /
///    `_kPageDwellThreshold` / `kArrivalDwellMs` / `_seedCountedPagesFromRestore` 一律
///    不许出现（`kArrivalDwellMs` 的唯一消费者是视频 cue 停留门）。
/// 4. **单一时钟**（BUG-1052 同款，v92 形态）：字数 / 页数在 `_creditPages` 里经
///    `_studyClock?.addChars(added.chars)` / `addPages(added.pages)` 记进当前段；页面
///    不持会话累计器、不整段过 `isContinuousReadingGap`。
void main() {
  final String raw = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  // 负向断言先掩掉注释：源码注释里刻意保留旧字段名作历史说明，不能让它把
  // 「字段已删除」的断言判假（等长掩码，下标与原文对齐）。
  final String src = maskComments(raw);

  test('唯一账本：arrive 只经 _noteVisiblePages，四个位置变化入口都走它', () {
    expect(
      src.contains('late final ReadUnitLedger _readLedger = ReadUnitLedger('),
      isTrue,
      reason: '账本必须是页面 State 字段（会话并集只活在一次打开里）',
    );
    expect(
      src.contains('onCredit: _creditPages'),
      isTrue,
      reason: '结算回调必须接到 _creditPages',
    );
    expect(
      src.contains('onRetract: _retractPages'),
      isTrue,
      reason: '回翻撤回必须接到 _retractPages（同一换算，扣出时钟）',
    );
    expect(src, contains('_studyClock?.retractChars(removed.chars);'));
    expect(src, contains('_studyClock?.retractPages(removed.pages);'));
    expect(
      '_readLedger.arrive('.allMatches(src).length,
      1,
      reason:
          'arrive 只许出现在 _noteVisiblePages 里（touch + arrive 一体），'
          '其它任何直接 arrive 都会绕过空闲门',
    );
    final String note = _functionSource(
      src,
      '  void _noteVisiblePages() {',
      '\n  }\n',
    );
    expect(note, contains('_studyClock?.touch();'));
    expect(note, contains('_readLedger.arrive(start, end);'));
    // 本地开书 / 在线开章 / _recordProgress / spread↔webtoon 切换。
    expect(
      '_noteVisiblePages();'.allMatches(src).length,
      4,
      reason: '四个位置变化入口都必须把当前单元交给账本，少一处就是那条路上的页永远不计',
    );
  });

  test('离开结算：dispose / onSourcePagePop 在 flush 前 leave()，换章 leave + reset', () {
    final String dispose = _functionSource(
      src,
      '  void dispose() {',
      '\n  }\n',
    );
    final int leaveAt = dispose.indexOf('_readLedger.leave();');
    final int flushAt = dispose.indexOf('unawaited(_flushPosition());');
    final int clockAt = dispose.indexOf('_studyClock?.dispose();');
    expect(leaveAt, greaterThanOrEqualTo(0), reason: 'dispose 必须 leave()');
    expect(leaveAt, lessThan(flushAt), reason: 'leave 必须早于最后一次 flush');
    expect(leaveAt, lessThan(clockAt), reason: 'leave 必须早于时钟 dispose，否则最后一页丢');

    final String pop = _functionSource(
      src,
      '  Future<void> onSourcePagePop() async {',
      '\n  }\n',
    );
    expect(
      pop.indexOf('_readLedger.leave();'),
      allOf(
        greaterThanOrEqualTo(0),
        lessThan(pop.indexOf('await _flushPosition();')),
      ),
      reason: '正常退出路径同样先结算最后一个单元再落盘',
    );
    expect(
      '_readLedger.leave();'.allMatches(src).length,
      2,
      reason: '生命周期 paused 不 leave（停表期间 addPages 会被丢弃，且恢复后当前页要继续算）',
    );
    // 换章：同一 State 内页号坐标系重用，先结算旧章末页再清并集。
    final String online = _functionSource(
      src,
      '  Future<void> _loadOnlineChapter(',
      '\n  }\n',
    );
    expect(online, contains('_readLedger\n      ..leave()\n      ..reset();'));
  });

  test('停留门 / 会话 Set / 存档预置形态不得回潮', () {
    for (final String gone in <String>[
      '_sessionCountedPages',
      '_pageDwellTimer',
      '_pageDwellKey',
      '_kPageDwellThreshold',
      'kArrivalDwellMs',
      '_armPageDwellCount',
      '_countVisiblePages',
      '_seedCountedPagesFromRestore',
      'mangaAccumulateReadingStats',
    ]) {
      expect(
        src.contains(gone),
        isFalse,
        reason: '$gone：2026-09-06 裁定翻走即计 + 并集去重，停留门 / Set / 预置已废',
      );
    }
  });

  test('单一时钟：字数/页数在 _creditPages 记进 StudyClock 的段，页面不持会话累计器', () {
    expect(
      src.contains('_ensureStudyClock('),
      isTrue,
      reason: '页面必须经 _ensureStudyClock 建并启动唯一时钟',
    );
    final String credit = _functionSource(
      src,
      '  void _creditPages(List<(int, int)> fresh) {',
      '\n  }\n',
    );
    expect(
      credit.contains('mangaStatsForPages('),
      isTrue,
      reason: '字数必须来自 OCR 文本换算，不能凭页数现编',
    );
    expect(
      credit.contains('_studyClock?.addChars(added.chars)'),
      isTrue,
      reason: 'OCR 字数必须记进时钟当前段（与时长同一 uid 同一行）',
    );
    expect(
      credit.contains('_studyClock?.addPages(added.pages)'),
      isTrue,
      reason: '翻走入账的页数必须记进时钟当前段',
    );
    expect(
      src.contains('await _studyClock?.flushNow()'),
      isTrue,
      reason: 'flush 只能是结算时钟当前窗口并落库，没有第二本账可结',
    );
    // 会话累计器 / 整段墙钟基准的回潮形态。
    expect(
      src.contains('_sessionReadingMs'),
      isFalse,
      reason: '会话时长累计器已废：与小时桶分账正是 BUG-1052 的形状',
    );
    expect(
      src.contains('_sessionCharsRead'),
      isFalse,
      reason: '会话字数累计器已废：字数直接进段',
    );
    expect(
      src.contains('_sessionPagesRead'),
      isFalse,
      reason: '会话页数累计器已废：页数直接进段',
    );
    expect(
      src.contains('DateTime _sessionStartTime'),
      isFalse,
      reason: '整段墙钟基准已废：>120s 的正常会话会被整段判非连续丢弃时长',
    );
    expect(
      src.contains('isContinuousReadingGap('),
      isFalse,
      reason: 'gap 守卫只在时钟内逐 tick 生效，页面侧不得整段调用',
    );
  });

  test('最后一段 flush 不许把已入账的页数/字数丢掉', () {
    // v92 前这里是 `if (elapsedMs < 1000 && _sessionCharsRead <= 0 &&
    // _sessionPagesRead <= 0)`——时长阈值与内容账分门。现在没有任何早退路径：
    // _flushReadingStats 只结算时钟（时长 / 字数 / 页数同一段、绝对值写回），
    // dispose 前最后一段哪怕 <1s，刚 leave() 入账的页也随段落库。
    final String body = _functionSource(
      src,
      'Future<void> _flushReadingStats() async {',
      '\n  }\n',
    );
    expect(body.contains('await _studyClock?.flushNow();'), isTrue);
    expect(
      body.contains('return'),
      isFalse,
      reason:
          '任何早退都会让 dispose 前最后一段的页数/字数蒸发'
          '（之后没有下一次 flush 了）',
    );
  });
}

/// 从 [start] 标记切到其后的第一个 [end] 标记。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

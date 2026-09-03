import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-1761：漫画阅读统计的三条接线守卫（源码语料层，同
/// `manga_routing_guard_test.dart` 纪律——MangaFushiPage 过重无法在纯 widget test
/// 拉起完整链路）。
///
/// 1. **停留门**：页面成为当前页并停留 ≥ 阈值才入账。「到达即计」会把快速翻过/
///    扫过的页全部记成已读——来回翻一圈就是整卷虚增（用户实测 170 页的卷记成
///    400 页的一半根因）。
/// 2. **续读预置**：去重集合只活在一次 State 里，重开这卷是空集；恢复存档时必须
///    把恢复位置之前的页预置为已计，否则每次重开都把已读区重算一遍（另一半根因）。
/// 3. **单一时钟**（BUG-1052 同款，v92 形态）：时长 / 字数 / 页数全部记进
///    `StudyClock` 的当前段（断档守卫在时钟内逐 tick 生效）。页面侧不得再持有
///    `_sessionReadingMs` 这类会话累计器、不得拿整段墙钟过一次
///    `isContinuousReadingGap`（>120s 的正常会话会被整段判非连续丢弃）。
///
/// v92 前的形态（`onDelta: (int deltaMs) => _sessionReadingMs += deltaMs` /
/// `_readingTimeTracker?.sampleNow()` / `if (elapsedMs < 1000 && _sessionCharsRead
/// <= 0 && _sessionPagesRead <= 0)`）随 `ReadingTimeTracker` 一起删除；对应断言改成
/// 新形态（见第 3、4 条用例），语义不变：时长与内容账同一时钟、最后一段不丢。
void main() {
  final String raw = File('lib/src/media/manga/reader/manga_fushi_page.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  // 负向断言先掩掉注释：源码注释里刻意保留旧字段名作历史说明，不能让它把
  // 「字段已删除」的断言判假（等长掩码，下标与原文对齐）。
  final String src = maskComments(raw);

  test('停留门：入账只经 _armPageDwellCount 的定时器，不许到达即计', () {
    expect(src.contains('void _armPageDwellCount()'), isTrue,
        reason: '停留门入口必须存在');
    expect(src.contains('_kPageDwellThreshold'), isTrue, reason: '停留阈值必须是具名常量');
    // _countVisiblePages 的调用点只许有一个：停留定时器到期回调。
    // （声明 `void _countVisiblePages()` 与 doc 注释里的引用不带 `();`，
    //  调用点字面量是 `_countVisiblePages();`。）
    expect('_countVisiblePages();'.allMatches(src).length, 1,
        reason: '除停留定时器外的任何直接调用都是「到达即计」回潮：'
            '快速翻过/扫过的页会被记成已读');
    // 三个「位置变化」入口全部走停留门，而不是直接入账。
    expect('_armPageDwellCount();'.allMatches(src).length, 3,
        reason: '开书摆位（本地/在线）与 _recordProgress 三处都必须经停留门');
    // webtoon 页内滚动不得重置同页计时（否则慢速连续滚读永远攒不满停留门）。
    expect(src.contains('if (_pageDwellTimer != null && key == _pageDwellKey)'),
        isTrue,
        reason: '同一页重复 arm 必须早退，只有换页才重新计时');
  });

  test('续读预置：恢复存档时把恢复位置之前的页预置为已计', () {
    expect(src.contains('void _seedCountedPagesFromRestore(int restoredPage)'),
        isTrue);
    // 本地卷与在线章两条恢复路径都要预置（都以 saved != null 为门）。
    expect(
        '_seedCountedPagesFromRestore(restoredPage);'.allMatches(src).length, 2,
        reason: '本地/在线两条恢复路径都必须预置，少一条就是重开重复计页');
  });

  test('单一时钟：时长/字数/页数都记进 StudyClock 的段，页面不持会话累计器', () {
    expect(src.contains('_ensureStudyClock('), isTrue,
        reason: '页面必须经 _ensureStudyClock 建并启动唯一时钟');
    expect(src.contains('_studyClock?.addChars(added.chars)'), isTrue,
        reason: 'OCR 字数必须记进时钟当前段（与时长同一 uid 同一行）');
    expect(src.contains('_studyClock?.addPages(added.pages)'), isTrue,
        reason: '停留入账的页数必须记进时钟当前段');
    expect(src.contains('await _studyClock?.flushNow()'), isTrue,
        reason: 'flush 只能是结算时钟当前窗口并落库，没有第二本账可结');
    // 会话累计器 / 整段墙钟基准的回潮形态。
    expect(src.contains('_sessionReadingMs'), isFalse,
        reason: '会话时长累计器已废：与小时桶分账正是 BUG-1052 的形状');
    expect(src.contains('_sessionCharsRead'), isFalse,
        reason: '会话字数累计器已废：字数直接进段');
    expect(src.contains('_sessionPagesRead'), isFalse,
        reason: '会话页数累计器已废：页数直接进段');
    expect(src.contains('DateTime _sessionStartTime'), isFalse,
        reason: '整段墙钟基准已废：>120s 的正常会话会被整段判非连续丢弃时长');
    expect(src.contains('isContinuousReadingGap('), isFalse,
        reason: 'gap 守卫只在时钟内逐 tick 生效，页面侧不得整段调用');
  });

  test('最后一段 flush 不许把已入账的页数/字数丢掉', () {
    // v92 前这里是 `if (elapsedMs < 1000 && _sessionCharsRead <= 0 &&
    // _sessionPagesRead <= 0)`——时长阈值与内容账分门。现在没有任何早退路径：
    // _flushReadingStats 只结算时钟（时长 / 字数 / 页数同一段、绝对值写回），
    // dispose 前最后一段哪怕 <1s，已停留入账的页也随段落库。
    final int start = src.indexOf('Future<void> _flushReadingStats() async {');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('await _studyClock?.flushNow();'), isTrue);
    expect(body.contains('return'), isFalse,
        reason: '任何早退都会让 dispose 前最后一段的页数/字数蒸发'
            '（之后没有下一次 flush 了）');
  });
}

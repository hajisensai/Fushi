import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1761：漫画阅读统计的三条接线守卫（源码语料层，同
/// `manga_routing_guard_test.dart` 纪律——MangaFushiPage 过重无法在纯 widget test
/// 拉起完整链路）。
///
/// 1. **停留门**：页面成为当前页并停留 ≥ 阈值才入账。「到达即计」会把快速翻过/
///    扫过的页全部记成已读——来回翻一圈就是整卷虚增（用户实测 170 页的卷记成
///    400 页的一半根因）。
/// 2. **续读预置**：去重集合只活在一次 State 里，重开这卷是空集；恢复存档时必须
///    把恢复位置之前的页预置为已计，否则每次重开都把已读区重算一遍（另一半根因）。
/// 3. **时长逐 tick 记账**（BUG-1052 同款）：整段墙钟交给 isContinuousReadingGap
///    判一次，会把任何 >120s 的正常会话整段判成非连续窗口丢弃；时长必须走
///    ReadingTimeTracker 的 onDelta 逐 tick 累计。
void main() {
  final String src = File('lib/src/media/manga/reader/manga_fushi_page.dart')
      .readAsStringSync();

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

  test('时长走 tracker 逐 tick 记账，不许整段墙钟过 gap 守卫', () {
    expect(
        src.contains('onDelta: (int deltaMs) => _sessionReadingMs += deltaMs'),
        isTrue,
        reason: '会话时长必须与小时桶共用 tracker 的同一个守卫时钟');
    expect(src.contains('_readingTimeTracker?.sampleNow();'), isTrue,
        reason: 'flush 前必须结算未满一个 tick 的窗口，否则每次落库漏最多 60s');
    // 整段墙钟基准的回潮形态：现场重新出现 `DateTime _sessionStartTime` 字段或
    // 拿 isContinuousReadingGap 判整段。
    expect(src.contains('DateTime _sessionStartTime'), isFalse,
        reason: '整段墙钟基准已废：>120s 的正常会话会被整段判非连续丢弃时长');
    expect(src.contains('isContinuousReadingGap('), isFalse,
        reason: 'gap 守卫只在 tracker 内逐 tick 生效，页面侧不得整段调用');
  });

  test('最后一段 flush 不许把已入账的页数/字数丢掉', () {
    expect(
        src.contains(
            'if (elapsedMs < 1000 && _sessionCharsRead <= 0 && _sessionPagesRead <= 0)'),
        isTrue,
        reason: '时长阈值与内容账不同门：dispose 前最后一段哪怕 <1s，'
            '已停留入账的页也必须落库（之后没有下一次 flush 了）');
  });
}

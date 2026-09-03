import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1762 接线守卫（源码语料层）：EPUB 字数统计的「到达即计」治理不得回潮。
///
/// 1. `_refreshProgress` 的字数推进必须走带速度封顶的
///    `accumulateSessionCharsCapped`——裸 `accumulateSessionChars` 只有 high-water
///    去重，按住翻页键扫过的每一页都在到达瞬间全额入账。
/// 2. 速度封顶是**令牌桶**：额度按流逝时间累积、跨次结转、有容量上限。按「距上次
///    水位推进的时间 × 速率」收费等于按上报节奏收费——连续模式一次甩动被 50ms 节流
///    拆成 5~8 次推进，第一次吃光额度、后面几次各自只隔几十毫秒，正常阅读被砍掉八成。
/// 3. 章内跳转必须先抬水位（不计数）：进度条拖动（`_jumpToGlobalCharOffset`
///    同章分支此前完全裸奔）与文本搜索跳转（跨章旧行为只播到章首）落点后的首个
///    `_refreshProgress` 不得把「旧位置 → 落点」的前缀计成新读字数。
void main() {
  final String navSrc =
      File('lib/src/pages/implementations/reader_fushi/navigation.part.dart')
          .readAsStringSync();
  final String chromeSrc =
      File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
          .readAsStringSync();

  test('字数推进走速度封顶版，裸 accumulateSessionChars 不得回潮', () {
    expect(navSrc.contains('accumulateSessionCharsCapped('), isTrue,
        reason: '_refreshProgress 必须走带封顶的推进');
    expect(navSrc.contains('accumulateSessionChars('), isFalse,
        reason: '裸版只挡重复计入、不挡首次快速掠过——到达即计回潮');
  });

  test('速度封顶按令牌桶结算：额度跨次结转、桶有容量上限', () {
    expect(navSrc.contains('creditMilliChars: _readChargeCreditMilliChars'),
        isTrue,
        reason: '额度必须从上一次结转进来，否则每次上报都从零开始 = 按上报节奏收费');
    expect(
        navSrc.contains('_readChargeCreditMilliChars = delta.creditMilliChars'),
        isTrue,
        reason: '花剩的额度必须写回，否则余量被丢弃、碎片化上报被惩罚');
    expect(
        navSrc
            .contains('maxCreditMilliChars: gapCapMs * kMaxReadCharsPerSecond'),
        isTrue,
        reason: '桶容量必须按 kMaxReadingGap 折算：挂机不攒无限额度');
    // 旧语义（只在水位推进时重锚计时基准）不得回潮：它让后续碎片各自只隔几十毫秒。
    expect(
        navSrc.contains('if (delta.highWaterMark > _sessionMaxAbsoluteChars)'),
        isFalse,
        reason: '计时基准必须每次采样都推进，额度才是连续累积的');
  });

  test('进度条拖动先抬水位（不计数）再跳', () {
    const String head =
        'Future<void> _jumpToGlobalCharOffset(int globalOffset)';
    final int start = navSrc.indexOf(head);
    expect(start, isNot(-1), reason: '跳转入口不在了，先确认它没被改名');
    final String body = navSrc.substring(start, navSrc.indexOf('\n  }', start));
    final int seed = body.indexOf('sessionWatermarkAfterRestore(');
    final int resolve = body.indexOf('resolveChapterProgressForGlobalOffset(');
    expect(seed, isNot(-1), reason: '同章分支落点前必须播种水位，否则整段前缀被误计');
    expect(resolve, isNot(-1));
    expect(seed < resolve, isTrue, reason: '播种必须在解析/跳转之前');
  });

  test('文本搜索跳转按命中位置抬水位（不是章首）', () {
    const String head = 'onSearchJump: (BookSearchResult result, String query)';
    final int start = chromeSrc.indexOf(head);
    expect(start, isNot(-1), reason: '搜索跳转入口不在了，先确认它没被改名');
    final String body = chromeSrc.substring(
        start, chromeSrc.indexOf('onDeleteFavorite:', start));
    expect(body.contains('sessionWatermarkAfterRestore('), isTrue);
    expect(body.contains('computeCharWatermark('), isTrue,
        reason: '必须用命中 charOffset 推绝对水位——只播章首时章首到命中处仍被误计');
    expect(body.contains('charOffset: result.charOffset'), isTrue);
  });
}

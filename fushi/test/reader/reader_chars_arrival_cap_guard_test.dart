import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1762 接线守卫（源码语料层）：EPUB 字数统计的「到达即计」治理不得回潮。
///
/// 1. `_refreshProgress` 的字数推进必须走带速度封顶的
///    `accumulateSessionCharsCapped`——裸 `accumulateSessionChars` 只有 high-water
///    去重，按住翻页键扫过的每一页都在到达瞬间全额入账。
/// 2. 速度封顶的时间窗只在**水位真的推进**时重锚——原地采样（delta 0 的 10s
///    轮询）重锚会把长停留页的时间窗压到轮询间隔，正常整页都计不满。
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

  test('时间窗只在水位推进时重锚', () {
    expect(
        navSrc.contains('if (delta.highWaterMark > _sessionMaxAbsoluteChars)'),
        isTrue,
        reason: '原地采样重锚会把长停留页的时间窗压到轮询间隔');
    expect(navSrc.contains('kMaxReadingGap.inMilliseconds'), isTrue,
        reason: '时间窗必须按 kMaxReadingGap 封顶：挂机不攒计数额度');
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

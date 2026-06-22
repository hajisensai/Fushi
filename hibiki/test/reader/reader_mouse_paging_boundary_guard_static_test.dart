import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// 源码守卫（headless WebView 不可用，锁注入 JS 行为）：
/// - BUG-368：分页模式鼠标在正文上横向拖动必须像触摸横滑一样翻页（pointermove 里把
///   native-text-start 的明确横向拖动转换成 onSwipe 翻页），否则桌面鼠标分页「翻不了页」。
/// - BUG-369：滚动模式滚轮跨章必须 arm-then-fire 二次确认，杜绝向上滚动惯性/缓动擦边
///   时「还没到章首就切上一章」。
void main() {
  late String source;
  late String setupScript;

  setUpAll(() {
    // TODO-589 batch8: setup 脚本(pointermove/wheel 边界)已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    source = readReaderPageSource();
    setupScript = _between(
      source,
      r'var hoshiContinuousMode = $continuousMode;',
      'window.hoshiProgressDetails = function()',
    );
  });

  group('BUG-368 paged mouse drag over text converts to page swipe', () {
    test('pointermove native-text branch resolves a paged page direction', () {
      final String pointerMove = _listenerBlock(setupScript, 'pointermove');
      // 转换发生在 native-text-start 分支内，且仅分页模式（!hoshiContinuousMode）。
      final int nativeBranch =
          pointerMove.indexOf('if (_hoshiReaderMouseNativeTextStart)');
      expect(nativeBranch, isNonNegative);
      final String branch = pointerMove.substring(nativeBranch);
      expect(branch, contains('!hoshiContinuousMode'),
          reason: '正文拖动转翻页只在分页模式，连续模式仍是拖动滚动');
      expect(branch, contains('_hoshiReaderMouseDragResolvePageDirection'),
          reason: '复用与触摸横滑同款方向判据，达阈值才转翻页');
      expect(branch, contains('_hoshiReaderMouseDragClaimed = true'),
          reason:
              '转换后接管为拖动翻页，pointerup 经 _finishHoshiReaderMouseDrag 回传 onSwipe');
      expect(branch, contains('_hoshiReaderMouseNativeTextStart = false'),
          reason: '转翻页后必须退出原生选词态');
      expect(branch, contains('_hoshiReaderClearMouseSelection()'),
          reason: '转翻页前清掉已起的原生选区');
      // 短拖/竖向拖（resolve 返 null）仍回退原生选词——保留划词查词。
      expect(branch, contains('if (totalDistSq > 36) hasStart = false;'),
          reason: '非翻页手势仍交还原生选区，划词查词不受影响');
    });

    test('pointermove still does not emit onSwipe directly (sent on pointerup)',
        () {
      final String pointerMove = _listenerBlock(setupScript, 'pointermove');
      expect(pointerMove, isNot(contains("callHandler('onSwipe'")),
          reason:
              '方向在 move 决定，onSwipe 仍只从 pointerup/_finishHoshiReaderMouseDrag 发一次');
    });
  });

  group('BUG-369 scroll-mode wheel boundary arm-then-fire confirmation', () {
    test('wheel listener no longer crosses on the first boundary tick', () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      expect(wheel, contains('_wheelBoundaryArmed'),
          reason: '滚轮跨章必须经 arm-then-fire 武装态，禁止真滚不动后一次就跨章');
      // 同方向二次确认才 callHandler；首次到边界只武装。
      expect(wheel, contains('_wheelBoundaryArmed === wheelDir'),
          reason: '只有同方向二次到边界才跨章');
      expect(wheel, contains('_wheelBoundaryArmed = wheelDir'),
          reason: '首次到边界仅武装本方向');
      expect(wheel, contains('_wheelBoundaryArmed = null'),
          reason: '真的滚动了（moved）必须解除武装');
      // 跨章回传仍走 onBoundarySwipe，且在二次确认分支内。
      final int confirmBranch =
          wheel.indexOf('_wheelBoundaryArmed === wheelDir');
      final int handlerCall =
          wheel.indexOf("callHandler('onBoundarySwipe'", confirmBranch);
      final int armBranch = wheel.indexOf('_wheelBoundaryArmed = wheelDir');
      expect(handlerCall, isNonNegative);
      expect(handlerCall, greaterThan(confirmBranch),
          reason: 'onBoundarySwipe 必须在「同方向二次确认」分支内回传');
      expect(handlerCall, lessThan(armBranch), reason: '首次武装分支（不跨章）必须排在确认分支之后');
    });

    test('wheel boundary uses real try-scroll (scrollBy + moved) (TODO-656)',
        () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      // TODO-656：跨章判据改为「真试滚」——真的 scrollBy 一步、读实际位移 moved。滚动了不
      // 跨章，真滚不动才跨章。彻底弃用 scrollTop<=2 / 相邻拍 / clamp 推算（横排误翻/竖排滚不动）。
      expect(wheel, contains('var moved = Math.abs(after - before) > 1'),
          reason: '滚轮跨章须靠真试滚的实际位移判边界');
      expect(wheel, contains('window.scrollBy'),
          reason: '横排/竖排都真的 window.scrollBy 一步再读位移（已验证原语）');
      expect(wheel, isNot(contains('atStart = root.scrollTop <= 2')),
          reason: '不得再用瞬时 scrollTop<=2 几何');
      expect(wheel, isNot(contains('_wheelLastScrollPos')),
          reason: '不得再用相邻拍位置推算（时序坏 → 横排中部误翻）');
    });
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _listenerBlock(String source, String eventName) {
  final String marker = "addEventListener('$eventName'";
  final int startIndex = source.indexOf(marker);
  expect(startIndex, isNonNegative, reason: 'missing listener: $eventName');
  final int endIndex = source.indexOf('}, {passive:', startIndex);
  expect(endIndex, isNonNegative,
      reason: 'listener must end with a passive option: $eventName');
  return source.substring(startIndex, endIndex);
}

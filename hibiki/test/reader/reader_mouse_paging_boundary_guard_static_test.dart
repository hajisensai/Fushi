import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（headless WebView 不可用，锁注入 JS 行为）：
/// - BUG-368：分页模式鼠标在正文上横向拖动必须像触摸横滑一样翻页（pointermove 里把
///   native-text-start 的明确横向拖动转换成 onSwipe 翻页），否则桌面鼠标分页「翻不了页」。
/// - BUG-369：滚动模式滚轮跨章必须 arm-then-fire 二次确认，杜绝向上滚动惯性/缓动擦边
///   时「还没到章首就切上一章」。
void main() {
  late String source;
  late String setupScript;

  setUpAll(() {
    source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
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
          reason: '滚轮跨章必须经 arm-then-fire 武装态，禁止单次瞬时 atStart 直接跨章');
      // 同方向二次确认才 callHandler；首次到边界只武装。
      expect(wheel, contains('_wheelBoundaryArmed === boundaryDir'),
          reason: '只有同方向二次到边界才跨章');
      expect(wheel, contains('_wheelBoundaryArmed = boundaryDir'),
          reason: '首次到边界仅武装本方向');
      expect(wheel, contains('_wheelBoundaryArmed = null'),
          reason: '未到边界 / 跨章后必须解除武装');
      // 跨章回传仍走 onBoundarySwipe，且在二次确认分支内。
      final int confirmBranch =
          wheel.indexOf('_wheelBoundaryArmed === boundaryDir');
      final int handlerCall =
          wheel.indexOf("callHandler('onBoundarySwipe'", confirmBranch);
      final int armBranch = wheel.indexOf('_wheelBoundaryArmed = boundaryDir');
      expect(handlerCall, isNonNegative);
      expect(handlerCall, greaterThan(confirmBranch),
          reason: 'onBoundarySwipe 必须在「同方向二次确认」分支内回传');
      expect(handlerCall, lessThan(armBranch), reason: '首次武装分支（不跨章）必须排在确认分支之后');
    });

    test('wheel arming uses the same atStart/atEnd geometry, unchanged', () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      // 边界几何判定本身不变（atStart/atEnd），只是改成确认后才跨章。
      expect(wheel, contains('atStart = root.scrollTop <= 2'));
      expect(
          wheel,
          contains(
              'atEnd = root.scrollTop + window.innerHeight >= root.scrollHeight - 2'));
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

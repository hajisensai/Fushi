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

  // TODO-737 守卫（4 必补点 #2：删 _wheelTimer 不变红=盲区，这里显式断言）。
  // 行为变更声明：分页滚轮方向从此脱钩 invertSwipeDirection——该开关只管触摸滑动 /
  // 鼠标拖动（onSwipe 路径），不再管滚轮。滚轮翻页改走新 handler onWheelPaginate，
  // 节流闸门统一到 Dart 侧 _paginate / onBoundarySwipe 的 _lastPaginateTime 时间戳。
  group(
      'TODO-737 wheel input unify: direction decoupled + single throttle gate',
      () {
    test('JS wheel block no longer self-throttles via _wheelTimer', () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      // 只锁「代码形态」（赋值/读取），不锁注释文本——注释里解释「不再自持 _wheelTimer」
      // 是允许的；真正回归是 setTimeout 节流代码复活。
      expect(wheel, isNot(contains('_wheelTimer = setTimeout')),
          reason: 'TODO-737：JS _wheelTimer setTimeout 节流双处已删，'
              '节流统一到 Dart 侧时间戳闸门；删 _wheelTimer 不变红是盲区，这里显式锁住不复活');
      expect(wheel, isNot(contains('if (_wheelTimer)')),
          reason: 'TODO-737：JS _wheelTimer 读取门控已删，不得复活');
      expect(wheel, isNot(contains('var _wheelTimer')),
          reason: 'TODO-737：JS _wheelTimer 声明已删，不得复活');
    });

    test('paged wheel emits onWheelPaginate (not onSwipe)', () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      expect(wheel, contains("callHandler('onWheelPaginate'"),
          reason: '分页滚轮翻页改走 onWheelPaginate（产语义意图 forward/backward）');
      expect(wheel, isNot(contains("callHandler('onSwipe'")),
          reason: 'wheel 块不得再回传 onSwipe（onSwipe 专属触摸/鼠标拖动）');
      // 方向归一：deltaY>0=forward（对齐连续滚轮 delta>0=前进），消除旧裸符号
      // deltaY<0=forward 与连续相反的方向矛盾。
      expect(wheel, contains('var forward = (e.deltaY > 0 || e.deltaX > 0)'),
          reason: 'TODO-737：分页滚轮方向归一为 deltaY>0=forward，对齐连续滚轮');
      expect(wheel, isNot(contains('e.deltaY < 0 || e.deltaX > 0')),
          reason: '旧的 deltaY<0=forward 裸符号（方向矛盾根因）必须移除');
    });

    test('arm-then-fire 二次确认仍完整（删 _wheelTimer 不回归 BUG-369）', () {
      final String wheel = _listenerBlock(setupScript, 'wheel');
      // arm 才是防 BUG-369 擦边误跨章的防线（与节流无关），删 _wheelTimer 后必须保留。
      expect(wheel, contains('_wheelBoundaryArmed === wheelDir'),
          reason: 'arm-then-fire 同方向二次确认逻辑保留');
      expect(wheel, contains('_wheelBoundaryArmed = wheelDir'),
          reason: '首次到边界仅武装本方向');
      // onBoundarySwipe 仍在二次确认分支内回传（紧跟 arm 命中后清武装）。
      final int confirm = wheel.indexOf('_wheelBoundaryArmed === wheelDir');
      final int call = wheel.indexOf("callHandler('onBoundarySwipe'", confirm);
      expect(call, greaterThan(confirm),
          reason: 'onBoundarySwipe 必须在二次确认分支内回传');
    });

    test('onWheelPaginate Dart handler 不读 invertSwipeDirection，传 throttleMs',
        () {
      // 行为变更：onWheelPaginate handler 直送 _paginate，**不读 invertSwipeDirection**
      // （脱钩根因），并传 wheelPageTurnInterval 作 throttleMs。Dart handler 在合并语料
      // 的 webview.part.dart 段，setupScript 切片不含它，故读整源 [source]。
      final int start = source.indexOf("handlerName: 'onWheelPaginate'");
      expect(start, isNonNegative, reason: 'onWheelPaginate Dart handler 必须存在');
      final int end = source.indexOf('addJavaScriptHandler', start + 1);
      final String body =
          end > start ? source.substring(start, end) : source.substring(start);
      expect(body, isNot(contains('invertSwipeDirection')),
          reason: 'TODO-737：滚轮翻页 handler 不得读 invertSwipeDirection（只归触摸/拖动管）');
      expect(body, contains('throttleMs:'),
          reason: '滚轮翻页经 _paginate 入口节流闸门（throttleMs: wheelPageTurnInterval）');
      expect(body, contains('wheelPageTurnInterval'),
          reason: '滚轮 throttleMs 源是 wheelPageTurnInterval');
    });

    test(
        'throttle gate lives at _paginate entry + onBoundarySwipe (split, 防自吞)',
        () {
      final String src = source;
      // _paginate 入口闸门（分页/键盘/手柄/音量键共用）。
      expect(src, contains('int throttleMs = 0'),
          reason: '_paginate 增加 throttleMs 入口闸门参数');
      expect(src, contains('_lastPaginateTime'),
          reason: '节流时间戳真相源 _lastPaginateTime 必须存在');
      // 闸门不放 _handlePageTurnLimit 本体（否则分页跨章经 _paginate 盖戳后自吞）。
      final int hpStart =
          src.indexOf('void _handlePageTurnLimit(String direction)');
      expect(hpStart, isNonNegative);
      final int hpEnd = src.indexOf('Future<void> _refreshProgress', hpStart);
      expect(hpEnd, greaterThan(hpStart),
          reason: '_handlePageTurnLimit 体到下一方法 _refreshProgress 为止');
      final String hpBody = src.substring(hpStart, hpEnd);
      expect(hpBody, isNot(contains('_lastPaginateTime')),
          reason: '4 必补点 #1：节流闸门不得放 _handlePageTurnLimit 本体（会自吞分页章末跨章）');
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

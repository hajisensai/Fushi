import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 源码守卫（headless WebView 不可用，锁注入 JS 行为）：
/// - BUG-368：分页模式鼠标在正文上横向拖动必须像触摸横滑一样翻页（pointermove 里把
///   native-text-start 的明确横向拖动转换成 onSwipe 翻页），否则桌面鼠标分页「翻不了页」。
/// - BUG-369：滚动模式滚轮跨章必须 arm-then-fire 二次确认，杜绝向上滚动惯性/缓动擦边
///   时「还没到章首就切上一章」。
///
/// TODO-2616 假绿收口。本文件此前每一个窗口都是**裸 `substring`**——`_between` 直接在
/// 原文上 `indexOf`、listener 用 `'}, {passive:'` 这个字面量当结束标记、Dart handler 用
/// `substring(start, end)`——窗口里注释原样留着，于是**所有** `contains` 断言都能被
/// 「把实现删光、只在注释里留下同一串字面量」骗绿。它今天没假绿纯属**措辞巧合**：生产
/// 注释写的是 `canTurnPage=false`，与断言要找的 `canTurnPage: !_paginationInFlight` 不
/// 同形；改一句注释措辞守卫就变永真。（`_wheelBoundaryArmed` 那条更近——注释里就写着
/// 这个裸符号，删掉实现只留注释即可骗过它。）
///
/// 现在三条纪律：
/// - **语料先词法掩码**：[maskCommentsAndScriptLines] 把 Dart 注释与三引号串里的 JS
///   注释一起换成**等长空白**，长度/换行与原文逐字节一致，下标照样能切片；
/// - **窗口边界由结构给出**：[methodBody] 花括号配对、[enclosingCallOf] 圆括号配对，
///   不再依赖 `'}, {passive:'` 这类「碰巧第一个出现」的字面量结束标记；
/// - **断言走 [containsCodeLine]**：注释里的同名文本一律不算数。
void main() {
  /// 已词法掩码的「主壳 + 全部 part」合并语料（注释位置留等长空白）。
  late String source;

  /// 注入 JS 的 setup 段窗口（同样落在掩码语料上）。
  late String setupScript;

  setUpAll(() {
    // TODO-589 batch8: setup 脚本(pointermove/wheel 边界)已搬到
    // reader_fushi/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    source = maskCommentsAndScriptLines(readReaderPageSource());
    // setup 段不是任何一个函数体，没有结构边界可用，只能靠两条**真代码**语句夹出来；
    // 但因为语料已掩码，这两个标记不可能锚到注释里的同名文本上。
    setupScript = _between(
      source,
      r'var fushiContinuousMode = C.continuousMode;',
      'window.fushiProgressDetails = function()',
    );
  });

  group('BUG-368 paged mouse drag over text converts to page swipe', () {
    test('pointermove native-text branch resolves a paged page direction', () {
      final String pointerMove = _listenerBody(setupScript, 'pointermove');
      // 转换发生在 native-text-start 分支内，且仅分页模式（!fushiContinuousMode）。
      // 窗口取该 `if` 的**块本体**（花括号配对）：旧写法 `substring(nativeBranch)` 一路
      // 吃到 listener 末尾，把 if 之后的通用拖动分支也算进窗口——那里有同名的
      // `_fushiReaderMouseDragClaimed = true` / `_fushiReaderClearMouseSelection()`，
      // 足以在 native-text 分支被删空时顶包骗绿。
      final String branch = methodBody(
        pointerMove,
        'if (_fushiReaderMouseNativeTextStart)',
        lexicon: SourceLexicon.js,
      );
      expect(containsCodeLine(branch, '!fushiContinuousMode'), isTrue,
          reason: '正文拖动转翻页只在分页模式，连续模式仍是拖动滚动');
      expect(
          containsCodeLine(branch, '_fushiReaderMouseDragResolvePageDirection'),
          isTrue,
          reason: '复用与触摸横滑同款方向判据，达阈值才转翻页');
      expect(containsCodeLine(branch, '_fushiReaderMouseDragClaimed = true'),
          isTrue,
          reason:
              '转换后接管为拖动翻页，pointerup 经 _finishFushiReaderMouseDrag 回传 onSwipe');
      expect(
          containsCodeLine(branch, '_fushiReaderMouseNativeTextStart = false'),
          isTrue,
          reason: '转翻页后必须退出原生选词态');
      expect(
          containsCodeLine(branch, '_fushiReaderClearMouseSelection()'), isTrue,
          reason: '转翻页前清掉已起的原生选区');
      // 短拖/竖向拖（resolve 返 null）仍回退原生选词——保留划词查词。
      expect(
          containsCodeLine(branch, 'if (totalDistSq > 36) hasStart = false;'),
          isTrue,
          reason: '非翻页手势仍交还原生选区，划词查词不受影响');
    });

    test('pointermove still does not emit onSwipe directly (sent on pointerup)',
        () {
      final String pointerMove = _listenerBody(setupScript, 'pointermove');
      expect(containsCodeLine(pointerMove, "callHandler('onSwipe'"), isFalse,
          reason:
              '方向在 move 决定，onSwipe 仍只从 pointerup/_finishFushiReaderMouseDrag 发一次');
    });
  });

  group('BUG-369 scroll-mode wheel boundary arm-then-fire confirmation', () {
    test('wheel listener no longer crosses on the first boundary tick', () {
      final String wheel = _listenerBody(setupScript, 'wheel');
      expect(containsCodeLine(wheel, '_wheelBoundaryArmed'), isTrue,
          reason: '滚轮跨章必须经 arm-then-fire 武装态，禁止真滚不动后一次就跨章');
      // 同方向二次确认才 callHandler；首次到边界只武装。
      expect(
          containsCodeLine(wheel, '_wheelBoundaryArmed === wheelDir'), isTrue,
          reason: '只有同方向二次到边界才跨章');
      expect(containsCodeLine(wheel, '_wheelBoundaryArmed = wheelDir'), isTrue,
          reason: '首次到边界仅武装本方向');
      expect(containsCodeLine(wheel, '_wheelBoundaryArmed = null'), isTrue,
          reason: '真的滚动了（moved）必须解除武装');
      // 跨章回传仍走 onBoundarySwipe，且在二次确认分支内。下标跑在**掩码**窗口上，
      // 注释里出现同名符号不会把先后顺序算歪。
      final int confirmBranch =
          wheel.indexOf('_wheelBoundaryArmed === wheelDir');
      expect(confirmBranch, isNonNegative);
      final int handlerCall =
          wheel.indexOf("callHandler('onBoundarySwipe'", confirmBranch);
      final int armBranch = wheel.indexOf('_wheelBoundaryArmed = wheelDir');
      expect(handlerCall, isNonNegative);
      expect(armBranch, isNonNegative);
      expect(handlerCall, greaterThan(confirmBranch),
          reason: 'onBoundarySwipe 必须在「同方向二次确认」分支内回传');
      expect(handlerCall, lessThan(armBranch), reason: '首次武装分支（不跨章）必须排在确认分支之后');
    });

    test('wheel boundary uses real try-scroll (scrollBy + moved) (TODO-656)',
        () {
      final String wheel = _listenerBody(setupScript, 'wheel');
      // TODO-656：跨章判据改为「真试滚」——真的 scrollBy 一步、读实际位移 moved。滚动了不
      // 跨章，真滚不动才跨章。彻底弃用 scrollTop<=2 / 相邻拍 / clamp 推算（横排误翻/竖排滚不动）。
      expect(
          containsCodeLine(wheel, 'var moved = Math.abs(after - before) > 1'),
          isTrue,
          reason: '滚轮跨章须靠真试滚的实际位移判边界');
      expect(containsCodeLine(wheel, 'window.scrollBy'), isTrue,
          reason: '横排/竖排都真的 window.scrollBy 一步再读位移（已验证原语）');
      expect(containsCodeLine(wheel, 'atStart = root.scrollTop <= 2'), isFalse,
          reason: '不得再用瞬时 scrollTop<=2 几何');
      expect(containsCodeLine(wheel, '_wheelLastScrollPos'), isFalse,
          reason: '不得再用相邻拍位置推算（时序坏 → 横排中部误翻）');
      // 连续分支自己的主轴归一（wheelDelta 取绝对值更大的轴）。分页侧同款判据在
      // _handlePagedWheelTick 里单独守（见下方 TODO-737 组），两处不得再互相顶包。
      expect(
          containsCodeLine(wheel, 'Math.abs(e.deltaY) >= Math.abs(e.deltaX)'),
          isTrue,
          reason: '连续模式 wheelDelta 也按绝对值更大的主轴取，斜向触控板不误判方向');
    });
  });

  // TODO-737 / BUG-1342 守卫：Dart 入口仍是唯一 rate-limit；横向触控板 burst
  // 由跨 document 的 Dart State 聚合，普通纵向鼠标滚轮维持既有 rate-limit 语义。
  // 行为变更声明：分页滚轮方向从此脱钩 invertSwipeDirection——该开关只管触摸滑动 /
  // 鼠标拖动（onSwipe 路径），不再管滚轮。滚轮翻页改走新 handler onWheelPaginate，
  // 节流闸门统一到 Dart 侧 _paginate / onBoundarySwipe 的 _lastPaginateTime 时间戳。
  group(
      'TODO-737 wheel input unify: direction decoupled + single throttle gate',
      () {
    test('JS wheel block reports dominant axis but owns no gesture state', () {
      final String wheel = _listenerBody(setupScript, 'wheel');
      // 只锁「代码形态」（赋值/读取），不锁注释文本——注释里解释「不再自持 _wheelTimer」
      // 是允许的（生产注释真的这么写）；真正回归是 setTimeout 节流代码复活。窗口已掩码 +
      // containsCodeLine 双保险，注释怎么写都不会把这三条禁止型断言误判成红。
      expect(containsCodeLine(wheel, '_wheelTimer = setTimeout'), isFalse,
          reason: 'TODO-737：JS _wheelTimer setTimeout 节流双处已删，'
              '节流统一到 Dart 侧时间戳闸门；删 _wheelTimer 不变红是盲区，这里显式锁住不复活');
      expect(containsCodeLine(wheel, 'if (_wheelTimer)'), isFalse,
          reason: 'TODO-737：JS _wheelTimer 读取门控已删，不得复活');
      expect(containsCodeLine(wheel, 'var _wheelTimer'), isFalse,
          reason: 'TODO-737：JS _wheelTimer 声明已删，不得复活');
      expect(containsCodeLine(wheel, '_handlePagedWheelTick(e)'), isTrue,
          reason: '分页 wheel tick 必须回传方向与主轴给跨章节 Dart 闸门');
      expect(containsCodeLine(setupScript, '_pagedWheelGestureSettleTimer'),
          isFalse,
          reason: 'JS document 切章即销毁，不得持有手势 session');
      expect(
          containsCodeLine(setupScript, '_pagedWheelGestureActive'), isFalse);
    });

    test('paged wheel emits onWheelPaginate (not onSwipe)', () {
      final String wheel = _listenerBody(setupScript, 'wheel');
      // 假绿修复（PR#670 复核）：分页主轴/方向判据必须锚进 _handlePagedWheelTick
      // **方法体内部**。旧写法对整份 setupScript 取 contains，命中的是**连续模式分支**
      // 里同名的 `Math.abs(e.deltaY) >= Math.abs(e.deltaX)`（基底就存在，与本守卫要守的
      // 分页侧无关）；把分页侧改回旧裸符号判据时 21 条 wheel 守卫全绿 = 零覆盖。
      final String tick = methodBody(
        setupScript,
        'function _handlePagedWheelTick(e)',
        lexicon: SourceLexicon.js,
      );
      expect(containsCodeLine(tick, "callHandler('onWheelPaginate'"), isTrue,
          reason: '分页滚轮翻页改走 onWheelPaginate（产语义意图 forward/backward）');
      expect(containsCodeLine(tick, "horizontal ? 'horizontal' : 'vertical'"),
          isTrue,
          reason: '主轴须一并回传，Dart 侧才能只对横向触控板 burst 开跨章节手势闸门');
      // 主轴判据：按绝对值更大的轴取 delta，斜向 tick 不得被次轴符号带偏。
      expect(containsCodeLine(tick, 'Math.abs(e.deltaX) > Math.abs(e.deltaY)'),
          isTrue,
          reason: '分页滚轮必须按绝对值更大的主轴判横/纵，不能任一轴为正就前进');
      expect(
          containsCodeLine(
              tick, 'var delta = horizontal ? e.deltaX : e.deltaY'),
          isTrue,
          reason: 'delta 必须取自主轴本身，而不是固定读 deltaY');
      // 方向归一：主轴 delta>0=forward（对齐连续滚轮 delta>0=前进），消除旧裸符号
      // deltaY<0=forward 与连续相反的方向矛盾。
      expect(
          containsCodeLine(tick, "delta > 0 ? 'forward' : 'backward'"), isTrue,
          reason: '方向只由主轴 delta 的符号决定');
      expect(containsCodeLine(tick, 'e.deltaY > 0 || e.deltaX > 0'), isFalse,
          reason: '旧的「任一轴为正就前进」裸符号判据（BUG-1342 根因）必须移除');
      expect(containsCodeLine(tick, 'e.deltaY < 0 || e.deltaX > 0'), isFalse,
          reason: '旧的 deltaY<0=forward 裸符号（方向矛盾根因）必须移除');
      expect(containsCodeLine(wheel, "callHandler('onSwipe'"), isFalse,
          reason: 'wheel 块不得再回传 onSwipe（onSwipe 专属触摸/鼠标拖动）');
    });

    test('arm-then-fire 二次确认仍完整（删 _wheelTimer 不回归 BUG-369）', () {
      final String wheel = _listenerBody(setupScript, 'wheel');
      // arm 才是防 BUG-369 擦边误跨章的防线（与节流无关），删 _wheelTimer 后必须保留。
      expect(
          containsCodeLine(wheel, '_wheelBoundaryArmed === wheelDir'), isTrue,
          reason: 'arm-then-fire 同方向二次确认逻辑保留');
      expect(containsCodeLine(wheel, '_wheelBoundaryArmed = wheelDir'), isTrue,
          reason: '首次到边界仅武装本方向');
      // onBoundarySwipe 仍在二次确认分支内回传（紧跟 arm 命中后清武装）。
      final int confirm = wheel.indexOf('_wheelBoundaryArmed === wheelDir');
      expect(confirm, isNonNegative);
      final int call = wheel.indexOf("callHandler('onBoundarySwipe'", confirm);
      expect(call, greaterThan(confirm),
          reason: 'onBoundarySwipe 必须在二次确认分支内回传');
    });

    test('onWheelPaginate Dart handler 不读 invertSwipeDirection，传 throttleMs',
        () {
      // 行为变更：onWheelPaginate handler 直送 _paginate，**不读 invertSwipeDirection**
      // （脱钩根因），并传 wheelPageTurnInterval 作 throttleMs。Dart handler 在合并语料
      // 的 webview.part.dart 段，setupScript 切片不含它，故读整源 [source]。
      //
      // 窗口由 `controller.addJavaScriptHandler(...)` 的**圆括号配对**给出。旧写法是
      // `substring(handlerName 处, 下一个 addJavaScriptHandler 处)`：既依赖「下一个
      // handler 恰好存在」，又把两个 handler 之间的注释块一并读进窗口——那正是
      // `canTurnPage: ...` 这条断言差一点被注释顶包的地方。
      final EnclosingCall handler =
          enclosingCallOf(source, "handlerName: 'onWheelPaginate'");
      expect(handler.name, endsWith('addJavaScriptHandler'),
          reason: 'onWheelPaginate 必须仍以 addJavaScriptHandler 的具名实参注册');
      final String body = handler.text;
      expect(containsCodeLine(body, 'invertSwipeDirection'), isFalse,
          reason: 'TODO-737：滚轮翻页 handler 不得读 invertSwipeDirection（只归触摸/拖动管）');
      expect(containsCodeLine(body, 'throttleMs:'), isTrue,
          reason: '滚轮翻页经 _paginate 入口节流闸门（throttleMs: wheelPageTurnInterval）');
      expect(containsCodeLine(body, 'wheelPageTurnInterval'), isTrue,
          reason: '滚轮 throttleMs 源是 wheelPageTurnInterval');
      expect(containsCodeLine(body, "axis == 'horizontal'"), isTrue,
          reason: '只有横向触控板手势进入跨章节 burst 闸门');
      expect(
          containsCodeLine(
              body, '_pagedWheelGestureGate.shouldStartNewGesture'),
          isTrue,
          reason: '手势 session 必须属于 reader State，切章后仍在');
      // BUG-1380：token 只能在这一 tick 真能落地翻页时消费。handler 必须把
      // _paginationInFlight 交给闸门，否则换章加载期的首个 tick 白吃 token，
      // 整段惯性的后续 tick 全在闸门早退 → 用户这一次滑动零反馈。
      //
      // 这条正是 TODO-2616 的样本：紧邻的生产注释写着「canTurnPage=false 时闸门只查询
      // 不认领」，与本 needle 只差一个字符形态；窗口不掩码时，把实参删掉、注释改成
      // `canTurnPage: !_paginationInFlight` 的措辞即可永久骗绿。
      expect(
          containsCodeLine(body, 'canTurnPage: !_paginationInFlight'), isTrue,
          reason: 'BUG-1380：闸门必须知道这一 tick 能否翻页，才决定是否消费手势 token');
    });

    test(
        'throttle gate lives at _paginate entry + onBoundarySwipe (split, 防自吞)',
        () {
      // _paginate 入口闸门（分页/键盘/手柄/音量键共用）。旧写法对**整份 9000 行语料**取
      // contains，全语料任何一处（含注释）出现同名符号都能顶包；改成方法体窗口后，断言
      // 说的才真是「闸门在 _paginate 入口」。
      final String paginate = methodBody(source, 'Future<void> _paginate(');
      expect(containsCodeLine(paginate, 'int throttleMs = 0'), isTrue,
          reason: '_paginate 增加 throttleMs 入口闸门参数');
      expect(containsCodeLine(paginate, '_lastPaginateTime'), isTrue,
          reason: '节流时间戳真相源 _lastPaginateTime 必须落在 _paginate 入口');
      // 闸门不放 _handlePageTurnLimit 本体（否则分页跨章经 _paginate 盖戳后自吞）。
      // 体的右边界由花括号配对给出，不再靠「下一个方法叫 _refreshProgress」这个假设。
      final String hpBody =
          methodBody(source, 'void _handlePageTurnLimit(String direction');
      expect(containsCodeLine(hpBody, '_lastPaginateTime'), isFalse,
          reason: '4 必补点 #1：节流闸门不得放 _handlePageTurnLimit 本体（会自吞分页章末跨章）');
    });
  });
}

/// 在**已掩码**的 [source] 上夹出 `[start, end)` 之间的窗口。
///
/// 只用于 setup 段这种「不是任何函数体、没有结构边界」的区间；有函数体/调用可锚的一律
/// 用 [methodBody] / [enclosingCallOf]。两个标记必须是真代码语句——语料已掩码，注释里
/// 的同名文本不会被锚上。
String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

/// `document.addEventListener('<event>', function(e) { ... })` 的**回调体**窗口。
///
/// 旧实现用 `'}, {passive:'` 当结束标记：那是「碰巧第一个出现的字面量」，回调里一旦出现
/// 同形文本或 listener 改成 `{passive:true}` 之外的写法就整段漂掉。这里改用花括号配对，
/// 窗口由结构决定，与长度、嵌套、options 写法无关。
String _listenerBody(String script, String eventName) => methodBody(
      script,
      "'$eventName', function",
      lexicon: SourceLexicon.js,
    );

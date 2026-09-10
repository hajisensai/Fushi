import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// BUG-2424：换章加载期的翻页输入必须**排队**而不是丢弃。
///
/// 取代 `chapter_turn_cooldown_test.dart` / `chapter_turn_cooldown_ready_restamp_test.dart`
/// （TODO-1229 / BUG-568 / BUG-1829 那套时间窗的守卫）。那套机制想区分「同一次拨轮的
/// 残余惯性」与「用户新拨了一下」，用的代理量却是「距上次**跨章**多久」，而且 v3 把窗口
/// 锚点重 stamp 到**新章 content-ready** 那一刻——惯性时长是手离开滚轮起算的固定物理量，
/// 和章节加载多久没有因果关系，锚在加载完成上的后果是「加载越慢、罚用户等得越久」：
/// 实测滚轮跨章后下一次跨章最早要等 `T_load + 450ms`，且这段时间到达的输入被静默丢弃。
/// 用户报的「来回跨章强制等待、按了没反应要再按一次」就是它。
///
/// 真正的不变式不是「两次跨章之间必须隔多久」，而是**一次输入最多产生一次跨章**——
/// 现在由 [ReaderPageTurnQueue] 的 1:1 消费直接保证。本文件同时把旧守卫护住的行为
/// 不变式（不饥饿、单页章能连续前进、一次输入不跳两章）用新语义重新钉住。
void main() {
  group('ReaderPageTurnQueue 纯语义', () {
    test('空队列消费返回 null', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      expect(queue.isEmpty, isTrue);
      expect(queue.consume(), isNull);
    });

    test('一次输入 = 一次重放（1:1，绝不放大成两次跨章）', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      queue.push(ReaderNavigationDirection.forward);
      expect(queue.consume(), ReaderNavigationDirection.forward);
      expect(queue.consume(), isNull,
          reason: '一次 push 只能换来一次 consume —— 这就是「跳两章」不可能再发生的原因');
    });

    test('N 次输入 = N 次重放（用户一口气拨多格就跨多章，不吞输入）', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      for (int i = 0; i < 5; i++) {
        queue.push(ReaderNavigationDirection.forward);
      }
      int replayed = 0;
      while (queue.consume() != null) {
        replayed++;
      }
      expect(replayed, 5, reason: '换章加载期拨的每一格滚轮都必须留下，旧实现在这里全部丢弃');
    });

    test('反向输入相互抵消（翻过头往回拨，不先把积压翻完再倒回来）', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      queue.push(ReaderNavigationDirection.forward);
      queue.push(ReaderNavigationDirection.forward);
      queue.push(ReaderNavigationDirection.backward);
      expect(queue.pending, 1);
      expect(queue.consume(), ReaderNavigationDirection.forward);
      expect(queue.isEmpty, isTrue);
    });

    test('抵消可以穿过 0 变号（净意图是后退）', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      queue.push(ReaderNavigationDirection.forward);
      queue.push(ReaderNavigationDirection.backward);
      queue.push(ReaderNavigationDirection.backward);
      expect(queue.pending, -1);
      expect(queue.consume(), ReaderNavigationDirection.backward);
      expect(queue.isEmpty, isTrue);
    });

    test('积压有上限，一次误触的惯性流不会换来失控连翻', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      for (int i = 0; i < 200; i++) {
        queue.push(ReaderNavigationDirection.forward);
      }
      expect(queue.pending, ReaderPageTurnQueue.kMaxPending);
      // 上下界对称：反向同样饱和。
      for (int i = 0; i < 400; i++) {
        queue.push(ReaderNavigationDirection.backward);
      }
      expect(queue.pending, -ReaderPageTurnQueue.kMaxPending);
    });

    test('clear 丢弃全部积压（用户显式换了目的地）', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      queue.push(ReaderNavigationDirection.forward);
      queue.push(ReaderNavigationDirection.forward);
      queue.clear();
      expect(queue.isEmpty, isTrue);
      expect(queue.consume(), isNull);
    });
  });

  group('旧守卫的行为不变式，用新语义重新钉住', () {
    // BUG-1829 的原始症状：真实滚轮每 30~100ms 一个事件，冷却窗被被拦的输入自我续期，
    // 用户拨得越快越不动；单页章（封面/插图/目录/版权页，页内没有可滚的量，每一次滚轮
    // 都必须走跨章判定）直接成为滚轮死区——实测 100ms 间隔连发 5 次：零跨章。
    //
    // 队列化之后「输入密度」这个维度整个消失了：每一格滚轮要么当场执行，要么进队列
    // 等重放，没有任何一条路径会把它扔掉，所以不存在「拨得越快越不动」。
    test('高密度连续输入不饥饿：5 格滚轮 = 5 次翻页意图', () {
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      // 模拟换章加载期（_paginationInFlight 为真）里 100ms 间隔到达的 5 个 tick。
      for (int i = 0; i < 5; i++) {
        queue.push(ReaderNavigationDirection.forward);
      }
      int turns = 0;
      while (queue.consume() != null) {
        turns++;
      }
      expect(turns, 5, reason: 'BUG-1829 的饥饿在队列语义下不可能出现：输入密度不再是任何判据的维度');
    });

    test('单页章场景：每次输入都走跨章判定时仍能逐次前进', () {
      // 单页章 = 每一次滚轮都落到「章内翻不动 → 跨章」。队列里 3 个意图应换来 3 次
      // 跨章，一次不多（不跳章）一次不少（不死区）。
      final ReaderPageTurnQueue queue = ReaderPageTurnQueue();
      for (int i = 0; i < 3; i++) {
        queue.push(ReaderNavigationDirection.forward);
      }
      final List<ReaderNavigationDirection> replayed =
          <ReaderNavigationDirection>[];
      ReaderNavigationDirection? next;
      while ((next = queue.consume()) != null) {
        replayed.add(next!);
      }
      expect(replayed, <ReaderNavigationDirection>[
        ReaderNavigationDirection.forward,
        ReaderNavigationDirection.forward,
        ReaderNavigationDirection.forward,
      ]);
    });
  });

  group('源码守卫：队列接线到位', () {
    // 注意读的是**剥掉注释**的语料。守卫要钉的是「代码里没有这些接线」，不是
    // 「注释里不准提这些名字」——本次改动的说明注释本身就要讲清删掉了什么，
    // 裸扫原文会被自己的解释文字判红（而且那种红没法靠改代码消除）。
    // 用共享词法掩码，别手写 startsWith('//')（见 helpers/banned_comment_strip.dart）。
    late String source;
    setUpAll(() {
      source = maskComments(readReaderPageSource());
    });

    // 切片的两个锚都必须是**代码**：语料已剥注释（注释被等长掩成空白），拿
    // `// ── Image Viewer` 这类注释横幅当 end marker 会直接找不到。
    String paginateBody() => _slice(
          source,
          '  Future<void> _paginate(',
          '  File? _readerImageFileForUrl(',
        );

    String boundarySwipeHandler() => _slice(
          source,
          "handlerName: 'onBoundarySwipe'",
          "handlerName: 'onImageDetected'",
        );

    test('_paginate 的在飞路径必须排队，不得再退回丢弃', () {
      final String paginate = paginateBody();
      final int inFlightIdx = paginate.indexOf('if (_paginationInFlight) {');
      expect(inFlightIdx, isNonNegative);
      final String branch = paginate.substring(
        inFlightIdx,
        paginate.indexOf('}', inFlightIdx),
      );
      expect(branch, contains('_pageTurnQueue.push(direction);'),
          reason: '换章加载期到达的输入必须入队；直接 return 就是 BUG-2424 的原状');
    });

    test('onBoundarySwipe 的在飞路径必须排队，不得再退回丢弃', () {
      final String handler = boundarySwipeHandler();
      final int inFlightIdx = handler.indexOf('if (_paginationInFlight) {');
      expect(inFlightIdx, isNonNegative);
      expect(handler, contains('_pageTurnQueue.push('),
          reason: '跨章通道在飞时同样必须入队');
    });

    test('跨章冷却窗那一整套不得复活', () {
      for (final String symbol in <String>[
        '_chapterTurnCoolingDown(',
        '_noteChapterTurn(',
        '_noteChapterTurnSettledIfPending(',
        '_markInertiaChapterTurnPending(',
        '_lastChapterTurnAt',
        '_kChapterTurnCooldown ',
        '_inertiaChapterTurnPending',
      ]) {
        expect(source.contains(symbol), isFalse,
            reason: '「距上次跨章多久」是错误的判据维度，且锚在加载完成上会让等待随加载'
                '时长膨胀（BUG-2424）。要拦的不变式是「一次输入最多一次跨章」，'
                '由 ReaderPageTurnQueue 的 1:1 消费保证；符号 $symbol 不得回归');
      }
    });

    test('onBoundarySwipe 不再对跨章叠 _lastPaginateTime 节流窗', () {
      final String handler = boundarySwipeHandler();
      expect(handler.contains('_lastPaginateTime'), isFalse,
          reason: '用户要求一口气连续跨多章、不必停手；wheelPageTurnInterval 限的是'
              '章内翻页速率，跨章由加载节奏天然限流');
    });

    test('触摸板惯性仍由跨文档 gate 聚合（JS 侧手势窗随换文档归零，拦不住）', () {
      final String handler = boundarySwipeHandler();
      expect(handler, contains("pointerKind == 'trackpad'"));
      expect(handler, contains('_pagedWheelGestureGate.shouldStartNewGesture('),
          reason: '跨章会 loadUrl 换文档，JS 的 _continuousWheelLastTickAt 随之归零，'
              '新章第一个残余惯性 tick 会被 JS 误判成新手势 → 二次跨章。'
              '必须由活在 reader State、跨文档持续存在的 gate 兜住');
    });

    test('鼠标滚轮不被手势 gate 聚合（一格一次跨章）', () {
      final String handler = boundarySwipeHandler();
      final int gateIdx = handler.indexOf('_pagedWheelGestureGate');
      expect(gateIdx, isNonNegative);
      final int kindIdx = handler.indexOf("pointerKind == 'trackpad'");
      expect(kindIdx, isNonNegative);
      expect(kindIdx, lessThan(gateIdx),
          reason: 'gate 必须被 trackpad 判据门控；无条件套在鼠标上就回到了'
              '「拨一格没反应」的老问题');
    });

    test('每个 content-ready 完成点都重放积压意图', () {
      // 三个完成点：onRestoreComplete 的延后收尾 / spreadReady / 8s 兜底超时。
      // 漏掉任何一个，那条路径上的积压意图就会一直压到下一次真实导航才突然连翻。
      expect(
        '_replayPendingPageTurn()'.allMatches(source).length,
        greaterThanOrEqualTo(3),
        reason: 'onRestoreComplete / spreadReady / content-ready 兜底超时都要重放',
      );
    });

    test('重放发生在收尾之后，且受代际守卫保护', () {
      final int settleIdx = source.indexOf('final int settleGeneration =');
      expect(settleIdx, isNonNegative);
      final int replayIdx =
          // 钉「调用出现在收尾之后」这条不变式，不钉调用的写法：包在
          // unawaited(...) 里时带分号的形态就不存在了（钉写法 = 加个包装就假红）。
          source.indexOf('_replayPendingPageTurn()', settleIdx);
      expect(replayIdx, isNonNegative);
      final int prefetchIdx =
          source.indexOf('_prefetchAdjacentChapterImages(', settleIdx);
      expect(prefetchIdx, isNonNegative);
      expect(prefetchIdx, lessThan(replayIdx),
          reason: '重放必须排在收尾块最后：遮罩先撤、新章可见、fushiReader 已就绪，'
              '页边界判定才是在真实状态上做的（原始「跳两章」正是在飞时 '
              'evaluateJavascript 返 null 被 _didScroll 误读成边界）');
    });

    test('重放必须消费到「队空」或「又进入在飞」，不能只消费一个', () {
      final String replay = _slice(
        source,
        'Future<void> _replayPendingPageTurn() async {',
        'Future<void> _paginate(',
      );
      expect(replay, contains('while ('),
          reason: '重放只消费一个意图是错的：若那一次只是**章内翻页**'
              '（新章还有下一页），就不会再有 content-ready 把我们叫醒，'
              '剩下的意图会一直压到下一次跨章才突然连翻');
      expect(replay, contains('!_paginationInFlight'),
          reason: '循环必须在重新进入在飞（重放导致跨章）时退出，'
              '剩余意图交给那次导航的 content-ready 继续消费');
      expect(replay, contains('await _paginate(next);'),
          reason: '必须 await：不等就无法得知这一次到底是章内翻页还是跨章');
      expect(replay, contains('_replayingPageTurns'),
          reason: '重入闸必须在：await 期间可能被另一个 content-ready '
              '完成点再次调用，两个循环同时消费同一队列会让意图乱序落到不同章上');
    });

    test('非翻页导航作废积压意图，翻页导航保留', () {
      expect(source, contains('if (!_navigationFromPageTurn) {'));
      expect(source, contains('_pageTurnQueue.clear();'));
      expect(source, contains('_navigationFromPageTurn = true;'),
          reason: '_handlePageTurnLimit 必须置位，否则翻页跨章会把排队中的意图清掉'
              '——那等于又把用户的输入丢了');
    });
  });
}

String _slice(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

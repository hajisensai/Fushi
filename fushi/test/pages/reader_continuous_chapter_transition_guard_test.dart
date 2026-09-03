import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// BUG-2015：真实 WebView 截图需要平台视图，headless widget test 无法执行。
/// 本守卫锁住最强可落地的编排：先截旧视口并预解码，再发起跨章；加载遮罩使用该帧，
/// 新章 ready 后淡出。输入语义另由 continuous_wheel_boundary_confirm_test 覆盖。
void main() {
  late String source;

  setUpAll(() {
    source = maskCommentsAndScriptLines(readReaderPageSource());
  });

  test('跨章快照在导航开始前准备，失败只降级而不阻塞导航', () {
    final String prepare = methodBody(
      source,
      'Future<bool> _prepareContinuousChapterTransition()',
    );
    expect(containsCodeLine(prepare, 'controller.takeScreenshot()'), isTrue);
    expect(
      containsCodeLine(prepare, 'const Duration(milliseconds: 450)'),
      isTrue,
    );
    expect(
      containsCodeLine(prepare, 'await precacheImage(snapshot, context)'),
      isTrue,
    );
    expect(
      containsCodeLine(prepare, '_chapterTransitionSnapshot = snapshot'),
      isTrue,
    );

    final int handler = source.indexOf("handlerName: 'onBoundarySwipe'");
    final int nextHandler = source.indexOf(
      'controller.addJavaScriptHandler(',
      handler + 1,
    );
    expect(handler, isNonNegative);
    expect(nextHandler, greaterThan(handler));
    final String body = source.substring(handler, nextHandler);
    final int snapshot = body.indexOf(
      'await _prepareContinuousChapterTransition()',
    );
    final int navigate = body.indexOf("_handlePageTurnLimit('");
    expect(snapshot, isNonNegative);
    expect(
      navigate,
      greaterThan(snapshot),
      reason: '必须先拿到旧视口帧，再替换 WebView document',
    );
  });

  test('导航没真的开始时快照必须当场丢弃', () {
    // 快照的唯一消费者是 _beginNavigation 之后的加载期。拿到快照却没进导航的路径
    // （分页在飞 / 目标章不存在 / _handlePageTurnLimit 内部守卫吃掉）如果不丢弃，
    // 这帧旧视口会挂到下一次 _readerContentReady 归 false（换字号、歌词模式），
    // 变成整屏淡出的旧章画面。
    final int handler = source.indexOf("handlerName: 'onBoundarySwipe'");
    final int nextHandler = source.indexOf(
      'controller.addJavaScriptHandler(',
      handler + 1,
    );
    expect(handler, isNonNegative);
    expect(nextHandler, greaterThan(handler));
    final String body = source.substring(handler, nextHandler);
    final int navigate = body.indexOf("_handlePageTurnLimit('");
    expect(navigate, isNonNegative);
    const String discard = '_discardIdleChapterTransitionSnapshot()';
    expect(body.indexOf(discard), isNonNegative,
        reason: '早退路径（分页在飞 / 无目标章）必须丢弃已拿到的快照');
    expect(body.indexOf(discard), lessThan(navigate),
        reason: '早退丢弃要排在跨章调用之前');
    expect(body.lastIndexOf(discard), greaterThan(navigate),
        reason: '跨章被 _handlePageTurnLimit 内部守卫吃掉时同样要丢弃');

    // 丢弃器本身必须只在「导航没开始」时动手——否则会把正在用的那帧删掉，
    // 加载期又退回纯黑屏。
    final String discardBody = methodBody(
      source,
      'void _discardIdleChapterTransitionSnapshot()',
    );
    expect(containsCodeLine(discardBody, 'if (!_readerContentReady) return;'),
        isTrue,
        reason: '_readerContentReady==false 说明导航已开始，那帧还在用，不能丢');
  });

  test('加载遮罩优先显示旧帧，目标章 ready 后淡出并释放缓存', () {
    final String overlay = methodBody(
      source,
      'Widget _buildChapterTransitionOverlay(Color backgroundColor)',
    );
    expect(containsCodeLine(overlay, 'AnimatedOpacity('), isTrue);
    expect(
      containsCodeLine(overlay, 'opacity: _readerContentReady ? 0 : 1'),
      isTrue,
    );
    expect(containsCodeLine(overlay, 'gaplessPlayback: true'), isTrue);
    expect(containsCodeLine(overlay, 'unawaited(snapshot.evict())'), isTrue);
    expect(
      source.contains("ValueKey<String>('fushi_chapter_transition_snapshot')"),
      isTrue,
    );
  });
}

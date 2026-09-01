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

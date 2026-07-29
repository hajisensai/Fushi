import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String readerPage = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();
  final String navigationPart = File(
    'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
  ).readAsStringSync();
  final String audiobookPart = File(
    'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
  ).readAsStringSync();

  String bodyBetween(String source, String start, String end) {
    final int startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: '找不到方法起点：$start');
    final int endIndex = source.indexOf(end, startIndex + start.length);
    expect(endIndex, greaterThan(startIndex), reason: '找不到方法终点：$end');
    return source.substring(startIndex, endIndex);
  }

  test('_rebuild 在统一 setState 转发边界拒绝已销毁 State', () {
    final String body = bodyBetween(
      readerPage,
      'void _rebuild(VoidCallback fn) {',
      'DictionaryPopupWebViewState? get _caretTopPopupState',
    );
    final int mountedGuard = body.indexOf('if (!mounted) return;');
    final int setStateCall = body.indexOf('setState(fn);');

    expect(mountedGuard, isNonNegative);
    expect(
      setStateCall,
      greaterThan(mountedGuard),
      reason: 'mounted 必须在 setState 之前复检，晚到的 part 回调不得触发已销毁 State',
    );
  });

  test('_navigateToChapter 在任何状态变更前拒绝已销毁 reader', () {
    final String body = bodyBetween(
      navigationPart,
      'Future<void> _navigateToChapter(',
      'Future<bool> _navigateToChapterAndWait(',
    );
    final int mountedGuard = body.indexOf('if (!mounted ||');
    final int beginNavigation = body.indexOf('_beginNavigation(');

    expect(mountedGuard, isNonNegative);
    expect(
      beginNavigation,
      greaterThan(mountedGuard),
      reason: '所有导航入口都必须先验证 State 仍 mounted，再初始化导航代际并重绘',
    );
  });

  test('有声书跨图片章 await 返回后复检生命周期并释放 transition', () {
    final String body = bodyBetween(
      audiobookPart,
      'Future<void> _handleCueCrossChapter(',
      'Future<void> _pauseThroughImageOnlyChapters(',
    );
    final int pauseAwait =
        body.indexOf('await _pauseThroughImageOnlyChapters(newSection);');
    final int mountedGuard =
        body.indexOf('if (!mounted || _controller == null)', pauseAwait);
    final int cancelTransition = body.indexOf(
      '_audiobookController?.cancelChapterTransition();',
      mountedGuard,
    );
    final int finalNavigation = body.indexOf(
      'await _navigateToChapter(newSection',
      pauseAwait,
    );

    expect(pauseAwait, isNonNegative);
    expect(mountedGuard, greaterThan(pauseAwait));
    expect(
      cancelTransition,
      greaterThan(mountedGuard),
      reason: 'dispose 竞态终止导航时必须释放图片序列持住的跨章 transition',
    );
    expect(
      finalNavigation,
      greaterThan(cancelTransition),
      reason: '最终跨章导航只能发生在 await 后的生命周期复检与清理分支之后',
    );
  });
}

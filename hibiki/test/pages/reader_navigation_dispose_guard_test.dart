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

  /// TODO-2337：断言**早退语义**而不是「字面量按顺序都在」。
  ///
  /// 旧版三个断言只用 `indexOf` 检查四个字面量存在且有序——把守卫体里的
  /// `return;` 单独删掉（保留 if 体与 `cancelChapterTransition()`，即 dispose 后
  /// 照样往下走进 `_navigateToChapter`，正是原缺陷的完整复现）时守卫仍然全绿。
  /// 这里改成花括号配对切出守卫块本体，断言块内确实早退、且被守卫的动作**不在**
  /// 块内继续发生。
  String guardBlockBody(String body, String guardHead) {
    final int headIndex = body.indexOf(guardHead);
    expect(headIndex, isNonNegative, reason: '找不到生命周期守卫：$guardHead');
    final int open = body.indexOf('{', headIndex + guardHead.length - 1);
    expect(open, isNonNegative, reason: '守卫必须是带花括号的块：$guardHead');
    int depth = 0;
    for (int i = open; i < body.length; i++) {
      final String ch = body[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return body.substring(open + 1, i);
      }
    }
    fail('守卫块花括号未闭合：$guardHead');
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

    // TODO-2337：守卫必须真的早退，而不是只把条件写出来。
    final String guardBody = guardBlockBody(body, 'if (!mounted ||');
    expect(
      guardBody.contains('return;'),
      isTrue,
      reason: '已销毁 State 命中守卫后必须 return，否则照样跑到 _beginNavigation/setState',
    );
    expect(
      guardBody.contains('_beginNavigation('),
      isFalse,
      reason: '守卫块内不得继续初始化导航代际',
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

    // TODO-2337：这才是缺陷本身——dispose 后必须**早退**，而不是清完 transition
    // 继续往下走进 _navigateToChapter/setState。只删守卫块里的 `return;`（旧版
    // 守卫对此全绿）在这里必须转红。
    final String guardBody = guardBlockBody(
      body.substring(pauseAwait),
      'if (!mounted || _controller == null)',
    );
    expect(
      guardBody.contains('return;'),
      isTrue,
      reason: 'dispose 后不得继续执行——守卫块必须 return，否则仍会进入 _navigateToChapter',
    );
    expect(
      guardBody.contains('_navigateToChapter('),
      isFalse,
      reason: '守卫块内不得再发起导航',
    );
  });
}

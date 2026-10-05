import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-2959：移动端划词后翻页，选择高亮与两端手柄留在新页面上。
///
/// 根因：**翻页路径从来没有清过选区**。`reader_pagination_scripts.dart` 里只有两处
/// `window.fushiSelection.clearSelection()`，且都挂在**有声书句子音频**的收口上
/// （`applySentenceAudioCues` / `resetSentenceAudioCues`），与翻页无关；两个 shell 的
/// `paginate()` 原来只做 `clearImageLateAnchor()`（放弃迟到图片重锚），不碰选区 —— 于是
/// 翻页后旧页面的 highlight / wrapper / 两端手柄 / 原生 range 全部留在屏幕上。
///
/// 输入意图不清选区；真实连续滚动保护拖选，显式分页 / DOM 替换强制结束拖选。
/// 行为回归见 reader_selection_viewport_behavior_test.{dart,js}，此处只守卫接线。
void main() {
  test('shell 区分强制失效与滚动，完整清理仍委托 selection', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('_clearSelectionOnViewportChange: function');
    expect(start, greaterThan(0), reason: '换视口收口必须存在');
    final String body = js.substring(
      start,
      js.indexOf('reapplyImageLateAnchor: function', start),
    );
    expect(body, contains('window.fushiSelection'));
    expect(body, contains('s.clearSelectionOnViewportChange();'));
    expect(body, contains('function(force)'));
    expect(
      body,
      contains("if (force && s && typeof s.clearSelection === 'function')"),
    );
    expect(body, contains('s.clearSelection();'));
    expect(body, isNot(contains('s.dragAnchor')));
    expect(body, isNot(contains('s.activeHandle')));
  });

  test('capture 输入意图只清恢复锚，不清选区', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('noteUserScroll: function');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('_clearSelectionOnViewportChange: function', start),
    );
    expect(
      body,
      isNot(contains('this._clearSelectionOnViewportChange(')),
      reason: '输入可能被手柄 target 阻止，或被边界 clamp，不能冒充位移',
    );
  });

  test('分页所有程序化落点共用 setPagePosition，实际位移后强制清理', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('setPagePosition: function');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('registerSnapScroll: function', start),
    );
    expect(body, contains('var before = this.getPagePosition(context);'));
    expect(body, contains('if (this.getPagePosition(context) !== before)'));
    expect(
      body,
      contains('this._clearSelectionOnViewportChange(true);'),
      reason: '程序化翻页也必须结束旧拖选，不能被 dragAnchor / activeHandle 挡住',
    );
    expect(
      body.indexOf('this.assignPagePosition(context, clamped);'),
      lessThan(body.indexOf('if (this.getPagePosition(context) !== before)')),
      reason: '比较实际落点，不把同位置 settle 或 clamp 当作换页',
    );
  });

  test('分页 paginate 的两个方向在 limit 后才进入统一落点收口', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('paginate: function(direction)');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('getFirstVisibleCharOffset: function', start),
    );
    expect('this.setPagePosition('.allMatches(body).length, 2);
    for (final String target in <String>['targetForward', 'targetBack']) {
      final int call = body.indexOf('this.setPagePosition(context, $target);');
      final int limit = body.lastIndexOf('return "limit";', call);
      expect(call, greaterThan(0));
      expect(limit, greaterThan(0));
      expect(call - limit, lessThan(80));
    }
    expect(
      body,
      isNot(contains('this._clearSelectionOnViewportChange(')),
      reason: 'setPagePosition 已清理，不应重复通知或清掉新选区',
    );
  });

  test('连续 shell 的 paginate：只在真的滚动了才清选区', () {
    final String js = ReaderPaginationScripts.continuousShellSource();
    final int start = js.indexOf('paginate: function(direction)');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('getFirstVisibleCharOffset: function', start),
    );
    expect(
      body,
      contains('if (moved) this._clearSelectionOnViewportChange(true);'),
      reason: '没滚动（moved=false）不该丢选区',
    );
  });

  test('原生连续 scroll 仍走拖选保护，不能强制清理', () {
    final String js = ReaderPaginationScripts.continuousShellSource();
    final int start = js.indexOf('_onContinuousViewportScroll: function');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('_writeContinuousScroll: function', start),
    );
    expect(body, contains('position !== previous'));
    expect(body, contains('this._clearSelectionOnViewportChange();'));
    expect(body, isNot(contains('this._clearSelectionOnViewportChange(true)')));
  });

  test('VN 所有 renderScreen 在替换旧节点前完整清理，不复用滚动保护', () {
    final String js = ReaderVisualNovelScripts.vnShellScript();
    final int start = js.indexOf('renderScreen: function');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('centerScreenInk: function', start),
    );
    final int clear = body.indexOf('selection.clearSelection();');
    expect(clear, greaterThan(0));
    expect(body, isNot(contains('clearSelectionOnViewportChange')));
    expect(clear, lessThan(body.indexOf('this.screen.replaceChildren();')));
    expect(clear, lessThan(body.indexOf('this.screen.removeChild(')));
    expect(body.indexOf('if (!this.screens.length) return;'), lessThan(clear));
  });

  test('翻页清除与有声书 cue 清除是两件事（本 bug 长期存在的根因）', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    // 这两处只服务句子音频：有 cue 才发生，翻页不经过它们。留着这条断言是为了防止
    // 以后有人看到它们就以为「翻页已经清过选区了」而把新收口拆掉。
    for (final String fn in <String>[
      'applySentenceAudioCues: function',
      'resetSentenceAudioCues: function',
    ]) {
      final int start = js.indexOf(fn);
      expect(start, greaterThan(0), reason: '$fn 应存在');
      expect(
        js.substring(start, start + 400),
        contains('clearSelection'),
        reason: '$fn 的清除是有声书路径专用，不是翻页清除',
      );
    }
  });
}

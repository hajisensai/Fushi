import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-2952：移动端划词后翻页，选择高亮与两端手柄留在新页面上。
///
/// 根因：**翻页路径从来没有清过选区**。`reader_pagination_scripts.dart` 里只有两处
/// `window.fushiSelection.clearSelection()`，且都挂在**有声书句子音频**的收口上
/// （`applySentenceAudioCues` / `resetSentenceAudioCues`），与翻页无关；两个 shell 的
/// `paginate()` 原来只做 `clearImageLateAnchor()`（放弃迟到图片重锚），不碰选区 —— 于是
/// 翻页后旧页面的 highlight / wrapper / 两端手柄 / 原生 range 全部留在屏幕上。
///
/// 修法：换视口统一收口 `_clearSelectionOnViewportChange()`，用户滚动（`noteUserScroll`）
/// 与两个 shell 的 `paginate` 都走它；**拖选中途不打断**（`dragAnchor` 还在 = 手指没松）。
/// 这里钉住的就是这些接线：清除点被删掉、或挪到 `"limit"` 早退路径上（页面没换却丢选区），
/// CI 就红。
void main() {
  test('换视口的收口：必须清选区，且拖选中途不打断', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('_clearSelectionOnViewportChange: function');
    expect(start, greaterThan(0), reason: '换视口收口必须存在');
    final String body = js.substring(
      start,
      js.indexOf('reapplyImageLateAnchor: function', start),
    );
    expect(body, contains('window.fushiSelection'));
    expect(body, contains('clearSelection'));
    expect(body, contains('s.dragAnchor'), reason: '拖选中途（手指没松）不得被翻页/滚动打断');
  });

  test('用户滚动（noteUserScroll）走同一个收口', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('noteUserScroll: function');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('_clearSelectionOnViewportChange: function', start),
    );
    expect(
      body,
      contains('this._clearSelectionOnViewportChange();'),
      reason: '连续模式的滚轮 / 触摸原生滚动 / 拖滚动条换的也是视口，选区必须跟着清',
    );
  });

  test('分页 shell 的 paginate：两个方向都在真正翻页之后清选区', () {
    final String js = ReaderPaginationScripts.paginatedShellSource();
    final int start = js.indexOf('paginate: function(direction)');
    expect(start, greaterThan(0));
    final String body = js.substring(
      start,
      js.indexOf('getFirstVisibleCharOffset: function', start),
    );
    expect(
      'this._clearSelectionOnViewportChange();'.allMatches(body).length,
      2,
      reason: 'forward / backward 两个方向各清一次',
    );
    // 每次清除都必须紧跟在 `setPagePosition` 之后：`"limit"` 早退（页面没换）不清 ——
    // 否则用户在末页点一下翻页就会莫名丢掉选区。
    int idx = 0;
    int checked = 0;
    while (true) {
      final int call = body.indexOf(
        'this._clearSelectionOnViewportChange();',
        idx,
      );
      if (call < 0) break;
      final int setPos = body.lastIndexOf('this.setPagePosition(', call);
      expect(setPos, greaterThan(0), reason: '清选区必须排在 setPagePosition 之后');
      expect(
        call - setPos,
        lessThan(200),
        reason: '两者必须在同一个翻页分支内（不能挪到 limit 早退路径上）',
      );
      idx = call + 1;
      checked++;
    }
    expect(checked, 2);
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
      contains('if (moved) this._clearSelectionOnViewportChange();'),
      reason: '没滚动（moved=false）不该丢选区',
    );
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

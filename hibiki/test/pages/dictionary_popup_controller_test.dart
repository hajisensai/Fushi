import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';

/// Unit tests for the shared [DictionaryPopupController] — the single set of
/// stack primitives across the reader / audiobook / video / home tab /
/// standalone window (unification plan
/// docs/specs/2026-06-07-dictionary-popup-unification-plan.md). Pure logic, no
/// WebView rendering. The controller only owns the stack mechanism; whether a
/// search-target is visible while searching is the host's choice (`visible`).
void main() {
  test('seedWarmSlot 放一个隐藏的常驻热槽（幂等、低内存跳过）', () {
    final c = DictionaryPopupController(lowMemory: false);
    c.seedWarmSlot();
    c.seedWarmSlot();
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
    expect(c.hasVisiblePopup, false);

    final lm = DictionaryPopupController(lowMemory: true)..seedWarmSlot();
    expect(lm.entries, isEmpty);
  });

  test('beginTop 复用热槽（视频：搜索期即可见）', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final e = c.beginTop(
      term: 'あ',
      rect: const Rect.fromLTWH(1, 2, 3, 4),
      reuseWarmSlot: true,
      replaceStack: false,
      visible: true,
    );
    expect(c.entries.length, 1);
    expect(identical(e, c.entries.first), true);
    expect(e.visible, true);
    expect(e.isSearching, true);
    expect(e.searchTerm, 'あ');
  });

  test('beginTop 书内：搜索期隐藏，就绪 fillResult + show 才显示', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final e = c.beginTop(
      term: 'あ',
      rect: Rect.zero,
      reuseWarmSlot: true,
      replaceStack: false,
      visible: false,
    );
    expect(e.visible, false, reason: '搜索期隐藏（书内另画占位）');
    c.fillResult(e, result: null, allLoaded: true);
    expect(e.visible, false, reason: 'fillResult 不改 visible（支持延迟显示）');
    expect(e.isSearching, false);
    c.show(e);
    expect(e.visible, true);
    expect(c.hasVisiblePopup, true);
  });

  test('beginTop replaceStack 无热槽时清栈压新条', () {
    final c = DictionaryPopupController(lowMemory: true);
    c.beginTop(
      term: 'x',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    c.beginTop(
      term: 'y',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    expect(c.entries.length, 1);
    expect(c.entries.first.searchTerm, 'y');
  });

  test('pushChild 先裁深层再压新嵌套层', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.pushChild(term: 'b', rect: Rect.zero, parentIndex: 0, visible: true);
    expect(c.entries.length, 2);
    // 从第 0 层再次下钻：第 1 层及之上被裁掉，压入新的。
    c.pushChild(term: 'c', rect: Rect.zero, parentIndex: 0, visible: true);
    expect(c.entries.length, 2);
    expect(c.entries.last.searchTerm, 'c');
  });

  test('lastVisibleIndex 忽略隐藏热槽', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    expect(c.lastVisibleIndex, -1);
    final e = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: false);
    expect(c.lastVisibleIndex, -1, reason: '隐藏不算');
    c.show(e);
    expect(c.lastVisibleIndex, 0);
  });

  test('dismissAt(0) 隐藏并保留热槽；低内存清空', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final e = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(e, result: null, allLoaded: true);
    c.dismissAt(0);
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);

    final lm = DictionaryPopupController(lowMemory: true);
    lm.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true);
    lm.dismissAt(0);
    expect(lm.entries, isEmpty);
  });

  test('dismissAt(非0) 只裁该层及之上', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final e = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(e, result: null, allLoaded: true);
    c.pushChild(term: 'b', rect: Rect.zero, parentIndex: 0, visible: true);
    expect(c.entries.length, 2);
    c.dismissAt(1);
    expect(c.entries.length, 1);
    expect(c.entries.first.visible, true);
  });

  test('pruneToWarmSlot 保留隐藏热槽丢弃其余', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final e = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(e, result: null, allLoaded: true);
    c.pushChild(term: 'b', rect: Rect.zero, parentIndex: 0, visible: true);
    c.pruneToWarmSlot();
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
  });
}

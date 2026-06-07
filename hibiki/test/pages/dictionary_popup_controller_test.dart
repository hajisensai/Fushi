import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';

/// Unit tests for the shared [DictionaryPopupController] — the single source of
/// truth for the dictionary popup stack across the reader / audiobook / video /
/// home tab / standalone window (unification plan
/// docs/specs/2026-06-07-dictionary-popup-unification-plan.md). Pure logic, no
/// WebView rendering.
void main() {
  test('seedWarmSlot 放一个隐藏的常驻热槽', () {
    final c = DictionaryPopupController(lowMemory: false);
    c.seedWarmSlot();
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
    expect(c.hasVisiblePopup, false);
  });

  test('seedWarmSlot 幂等：重复调用不重复 seed', () {
    final c = DictionaryPopupController(lowMemory: false);
    c.seedWarmSlot();
    c.seedWarmSlot();
    expect(c.entries.length, 1);
  });

  test('lowMemory 不 seed 热槽', () {
    final c = DictionaryPopupController(lowMemory: true);
    c.seedWarmSlot();
    expect(c.entries, isEmpty);
  });

  test('reveal 把结果填进热槽并设可见（搜索→就绪才显示）', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginSearch(const Rect.fromLTWH(1, 2, 3, 4), 'あ');
    expect(c.entries.first.visible, false, reason: '搜索期热槽仍隐藏');
    expect(c.isSearching, true);
    expect(c.pendingRect, const Rect.fromLTWH(1, 2, 3, 4));

    c.revealResult(result: null, allLoaded: true);
    expect(c.isSearching, false);
    expect(c.pendingRect, isNull);
    expect(c.entries.first.visible, true);
    expect(c.hasVisiblePopup, true);
  });

  test('无热槽时 reveal 也能落到一个条目（首页/独立窗冷开场景）', () {
    final c = DictionaryPopupController(lowMemory: true); // 不 seed
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);
    expect(c.entries.length, 1);
    expect(c.entries.first.visible, true);
  });

  test('dismiss(0) 隐藏并保留热槽（非清空）', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);

    c.dismissAt(0);
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
    expect(c.hasVisiblePopup, false);
  });

  test('lowMemory 下 dismiss(0) 清空（不保留热槽）', () {
    final c = DictionaryPopupController(lowMemory: true);
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);
    c.dismissAt(0);
    expect(c.entries, isEmpty);
  });

  test('dismiss(非0) 只裁掉该层及其之上，保留下层', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);
    c.pushChild(const Rect.fromLTWH(5, 5, 1, 1), 'い');
    c.revealResult(result: null, allLoaded: true);
    expect(c.entries.length, 2);

    c.dismissAt(1);
    expect(c.entries.length, 1);
    expect(c.entries.first.visible, true);
  });

  test('notifyListeners 在状态变化时触发', () {
    final c = DictionaryPopupController(lowMemory: false);
    int n = 0;
    c.addListener(() => n++);
    c.seedWarmSlot();
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);
    c.dismissAt(0);
    expect(n, greaterThanOrEqualTo(4));
  });
}

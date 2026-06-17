// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
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

  test('TODO-485: child back keeps parent; top close keeps existing semantics',
      () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final parent = c.beginTop(
        term: 'parent',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(parent, result: null, allLoaded: true);
    c.pushChild(
        term: 'child',
        rect: const Rect.fromLTWH(1, 1, 1, 1),
        parentIndex: 0,
        visible: true);

    c.dismissAt(1);
    expect(c.entries, hasLength(1),
        reason: 'closing a child layer must return to the parent layer');
    expect(c.entries.single.searchTerm, 'parent');
    expect(c.entries.single.visible, isTrue);

    c.dismissAt(0);
    expect(c.entries, hasLength(1),
        reason:
            'top close still preserves the hidden warm slot in normal mode');
    expect(c.entries.single.isWarmSlot, isTrue);
    expect(c.entries.single.visible, isFalse);
  });

  // ── TODO-058：嵌套（第二个）冷层挂起到渲染完成才显示，消除白屏一瞬 ──────────
  test('markPendingReveal 挂起：fillResult 后先不显示，等 revealRendered', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final a = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(a, result: null, allLoaded: true);
    // 嵌套层：append 一条新建 WebView 的冷层。
    final child =
        c.pushChild(term: 'b', rect: Rect.zero, parentIndex: 0, visible: false);
    c.fillResult(child, result: null, allLoaded: true);
    c.markPendingReveal(child);
    expect(child.visible, isFalse, reason: '冷层结果就绪也先不显示（避免白屏一瞬）');
    expect(child.revealOnRender, isTrue, reason: '挂起等渲染信号');
    expect(c.lastVisibleIndex, 0, reason: '顶层可见仍是父层');

    // WebView 渲染完成信号到达 → 翻可见、清标记。
    final bool revealed = c.revealRendered(child);
    expect(revealed, isTrue);
    expect(child.visible, isTrue);
    expect(child.revealOnRender, isFalse);
    expect(c.lastVisibleIndex, 1);
  });

  test('revealRendered 仅对挂起层生效：非挂起层（热槽再渲染/load-more）不动', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    final a = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    c.fillResult(a, result: null, allLoaded: true);
    // a 立即可见（热槽复用），未挂起 → revealRendered 应是 no-op 返回 false。
    expect(a.revealOnRender, isFalse);
    expect(c.revealRendered(a), isFalse);
    expect(a.visible, isTrue);
  });

  test('show 清掉挂起标记（幂等收口）', () {
    final c = DictionaryPopupController(lowMemory: true);
    final e = c.beginTop(
        term: 'x',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: false);
    c.markPendingReveal(e);
    expect(e.revealOnRender, isTrue);
    c.show(e);
    expect(e.visible, isTrue);
    expect(e.revealOnRender, isFalse, reason: 'show 直显也清挂起标记');
  });

  test('复用热槽 / 隐藏热槽都清挂起标记，避免陈旧 revealOnRender 残留', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    // 让热槽带上一个陈旧挂起标记，再复用。
    c.entries.first.revealOnRender = true;
    final e = c.beginTop(
        term: 'a',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true);
    expect(e.revealOnRender, isFalse, reason: 'beginTop 复用热槽清陈旧挂起');

    // dismissAt(0) 隐藏热槽也清挂起。
    e.revealOnRender = true;
    c.dismissAt(0);
    expect(c.entries.first.isWarmSlot, isTrue);
    expect(c.entries.first.revealOnRender, isFalse);

    // pruneToWarmSlot 隐藏热槽也清挂起。
    c.entries.first.revealOnRender = true;
    c.pruneToWarmSlot();
    expect(c.entries.first.revealOnRender, isFalse);
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

  // ── TODO-058 fail-safe：popupRendered 永不发时的超时兜底 + Timer 取消/防泄漏 ──
  test('超时兜底：挂起层未收到 popupRendered，到时强制翻可见', () {
    fakeAsync((FakeAsync async) {
      final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      final a = c.beginTop(
          term: 'a',
          rect: Rect.zero,
          reuseWarmSlot: true,
          replaceStack: false,
          visible: true);
      c.fillResult(a, result: null, allLoaded: true);
      final child = c.pushChild(
          term: 'b', rect: Rect.zero, parentIndex: 0, visible: false);
      c.fillResult(child, result: null, allLoaded: true);

      bool forced = false;
      c.markPendingReveal(child, onForcedReveal: () => forced = true);
      expect(child.visible, isFalse, reason: '挂起期不可见');
      expect(child.revealOnRender, isTrue);

      // 略短于超时：还没翻可见（验证不是立刻显示）。
      async.elapse(DictionaryPopupController.kRevealFailsafeTimeout -
          const Duration(milliseconds: 1));
      expect(child.visible, isFalse, reason: '超时前不显示，不破坏「就绪才显示」正常路径');

      // 跨过超时：强制翻可见 + 回调 + 清挂起标记。
      async.elapse(const Duration(milliseconds: 2));
      expect(child.visible, isTrue, reason: 'popupRendered 永不发也最终显示，不卡死');
      expect(child.revealOnRender, isFalse);
      expect(forced, isTrue, reason: '强制翻可见后回调宿主重建');
      expect(c.lastVisibleIndex, 1);
    });
  });

  test('revealRendered 先于超时到达：取消 Timer，不再强制翻（无重复/无泄漏）', () {
    fakeAsync((FakeAsync async) {
      final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      final a = c.beginTop(
          term: 'a',
          rect: Rect.zero,
          reuseWarmSlot: true,
          replaceStack: false,
          visible: true);
      c.fillResult(a, result: null, allLoaded: true);
      final child = c.pushChild(
          term: 'b', rect: Rect.zero, parentIndex: 0, visible: false);
      c.fillResult(child, result: null, allLoaded: true);

      bool forced = false;
      c.markPendingReveal(child, onForcedReveal: () => forced = true);
      // 渲染信号在超时前到达 → 正常翻可见并取消 Timer。
      expect(c.revealRendered(child), isTrue);
      expect(child.visible, isTrue);

      // 跨过超时：onForcedReveal 不应再被调用（Timer 已取消）。
      async.elapse(DictionaryPopupController.kRevealFailsafeTimeout +
          const Duration(milliseconds: 10));
      expect(forced, isFalse, reason: 'Timer 已被 revealRendered 取消，不重复强制');
      expect(async.pendingTimers, isEmpty, reason: '无残留 Timer 泄漏');
    });
  });

  test('show/dismiss/裁剪/dispose 取消挂起 Timer（防泄漏）', () {
    fakeAsync((FakeAsync async) {
      // show 取消。
      final c1 = DictionaryPopupController(lowMemory: true);
      final e1 = c1.beginTop(
          term: 'x',
          rect: Rect.zero,
          reuseWarmSlot: false,
          replaceStack: true,
          visible: false);
      c1.markPendingReveal(e1);
      c1.show(e1);
      expect(async.pendingTimers, isEmpty, reason: 'show 取消 Timer');

      // dismissAt 取消。
      final c2 = DictionaryPopupController(lowMemory: true);
      final e2 = c2.beginTop(
          term: 'y',
          rect: Rect.zero,
          reuseWarmSlot: false,
          replaceStack: true,
          visible: false);
      c2.markPendingReveal(e2);
      c2.dismissAt(0);
      expect(async.pendingTimers, isEmpty, reason: 'dismissAt 取消 Timer');

      // truncateTo 取消被裁子层。
      final c3 = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      final a3 = c3.beginTop(
          term: 'a',
          rect: Rect.zero,
          reuseWarmSlot: true,
          replaceStack: false,
          visible: true);
      c3.fillResult(a3, result: null, allLoaded: true);
      final child3 = c3.pushChild(
          term: 'b', rect: Rect.zero, parentIndex: 0, visible: false);
      c3.markPendingReveal(child3);
      c3.truncateTo(1);
      expect(async.pendingTimers, isEmpty, reason: 'truncateTo 取消被裁层 Timer');

      // dispose 取消全部。
      final c4 = DictionaryPopupController(lowMemory: true);
      final e4 = c4.beginTop(
          term: 'z',
          rect: Rect.zero,
          reuseWarmSlot: false,
          replaceStack: true,
          visible: false);
      c4.markPendingReveal(e4);
      c4.dispose();
      expect(async.pendingTimers, isEmpty, reason: 'dispose 取消全部 Timer');
    });
  });
}

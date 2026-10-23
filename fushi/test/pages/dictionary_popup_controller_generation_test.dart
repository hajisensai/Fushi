import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 2026-10-20 查词提速批次里 controller 层的三条新契约（纯逻辑）：
///   - 查词会话代次：热槽复用 / 复位 / 原地换页都不换 entry 身份，代次是唯一能分辨
///     「这还是不是发起查询时那一次」的依据（过期结果不覆盖新词）；
///   - [DictionaryPopupController.setAutoFitHeight]：变了才 notify（P1-D 局部重建）；
///   - 挂起中的热槽（P1-C 起热槽命中也先挂起等渲染）接受重锚。
void main() {
  DictionaryPopupEntry topLookup(DictionaryPopupController c, String term) =>
      c.beginTop(
        term: term,
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: false,
      );

  group('lookupGeneration / isCurrentLookup', () {
    test('热槽复用换词：同一个 entry，旧代次失效', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      )..seedWarmSlot();
      final DictionaryPopupEntry first = topLookup(c, '旧');
      final int oldGeneration = first.lookupGeneration;
      expect(c.isCurrentLookup(first, oldGeneration), isTrue);

      final DictionaryPopupEntry second = topLookup(c, '新');
      expect(second, same(first), reason: '热槽复用不换 entry 身份');
      expect(
        c.entries.contains(first),
        isTrue,
        reason: '只核 entries.contains 判不出换词——这正是要代次的原因',
      );
      expect(c.isCurrentLookup(first, oldGeneration), isFalse);
      expect(c.isCurrentLookup(second, second.lookupGeneration), isTrue);
    });

    test('关栈复位热槽（dismissAt(0) / pruneToWarmSlot）也作废在途查询', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      )..seedWarmSlot();
      final DictionaryPopupEntry e = topLookup(c, '一');
      int generation = e.lookupGeneration;
      c.dismissAt(0);
      expect(c.entries.single, same(e));
      expect(c.isCurrentLookup(e, generation), isFalse);

      topLookup(c, '二');
      generation = e.lookupGeneration;
      c.pruneToWarmSlot();
      expect(c.isCurrentLookup(e, generation), isFalse);
    });

    test('原地跳转 / 后退换页作废本层在途的旧词查询（如 load-more）', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      );
      final DictionaryPopupEntry e = topLookup(c, '一');
      c.fillResult(
        e,
        result: DictionarySearchResult(searchTerm: '一'),
        allLoaded: true,
      );
      final int beforeJump = e.lookupGeneration;
      expect(
        c.navigateInPlace(
          e,
          term: '二',
          result: DictionarySearchResult(searchTerm: '二'),
          allLoaded: true,
          scrollTop: 0,
        ),
        isTrue,
      );
      expect(c.isCurrentLookup(e, beforeJump), isFalse);
      final int beforeBack = e.lookupGeneration;
      expect(c.goBack(e, scrollTop: 0), isTrue);
      expect(c.isCurrentLookup(e, beforeBack), isFalse);
    });

    test('离栈的 entry 恒不是当前查询', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      );
      final DictionaryPopupEntry e = topLookup(c, '一');
      final int generation = e.lookupGeneration;
      c.clear();
      expect(c.isCurrentLookup(e, generation), isFalse);
    });
  });

  group('setAutoFitHeight', () {
    test('变化才写入并 notify；不足 1 逻辑像素 / 已离栈都是 no-op', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      );
      final DictionaryPopupEntry e = topLookup(c, '一');
      int notified = 0;
      c.addListener(() => notified++);

      expect(c.setAutoFitHeight(e, 240), isTrue);
      expect(e.autoFitHeight, 240);
      expect(notified, 1);

      expect(c.setAutoFitHeight(e, 240.4), isFalse);
      expect(e.autoFitHeight, 240);
      expect(notified, 1);

      c.clear();
      notified = 0;
      expect(c.setAutoFitHeight(e, 300), isFalse);
      expect(notified, 0);
    });
  });

  group('reanchorEntry on a pending warm slot (P1-C)', () {
    test('被查词认领、挂起等渲染的热槽接受重锚；未认领的隐身热槽仍不动', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
      )..seedWarmSlot();
      final DictionaryPopupEntry idle = c.entries.single;
      const Rect refined = Rect.fromLTWH(10, 10, 40, 20);
      c.reanchorEntry(idle, refined);
      expect(idle.selectionRect, Rect.zero, reason: '没被认领的热槽不动');

      final DictionaryPopupEntry e = topLookup(c, '一');
      c.markPendingReveal(e);
      c.reanchorEntry(e, refined);
      expect(e.selectionRect, refined, reason: '挂起期回来的高亮 bbox 必须落地，翻出时一次到位');
      c.dispose();
    });
  });

  test('停驻上限为 2（P2-G：第三层嵌套不再每次冷建）', () {
    expect(DictionaryPopupController.kMaxParkedRealms, 2);
  });
}

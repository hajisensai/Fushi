import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';

/// TODO-607 P0-2/②（关口语义验证）：查词面包屑落在 DictionaryPopupController 的
/// **栈层进出**（同步代码），经注入回调 onLookupStackDepthChanged 上报当前**可见**
/// 栈深度 + 栈顶词。嵌套查词（pushChild）使深度 >=2，关栈使深度回落——崩溃面包屑
/// 据此记「崩时第几层」。本测试验注入回调在各栈操作上正确触发，覆盖嵌套查词路径。
void main() {
  late List<({int depth, String? term})> events;
  late DictionaryPopupController c;

  setUp(() {
    events = <({int depth, String? term})>[];
    c = DictionaryPopupController(
      lowMemory: false,
      onLookupStackDepthChanged: (int depth, String? topTerm) =>
          events.add((depth: depth, term: topTerm)),
    );
  });

  test('顶层查词 → 可见深度 1', () {
    c.beginTop(
      term: '一',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    expect(events.last.depth, 1);
    expect(events.last.term, '一');
  });

  test('嵌套查词 pushChild → 可见深度 >=2（崩溃面包屑记的层数）', () {
    c.beginTop(
      term: '親',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    c.pushChild(term: '子', rect: Rect.zero, parentIndex: 0, visible: true);
    expect(events.last.depth, 2, reason: '嵌套一层 = 可见深度 2');
    expect(events.last.term, '子', reason: '栈顶是最新的嵌套查词');

    c.pushChild(term: '孫', rect: Rect.zero, parentIndex: 1, visible: true);
    expect(events.last.depth, 3);
    expect(events.last.term, '孫');
  });

  test('关栈（dismissAt）→ 深度回落', () {
    c.beginTop(
      term: 'a',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    c.pushChild(term: 'b', rect: Rect.zero, parentIndex: 0, visible: true);
    expect(events.last.depth, 2);
    c.dismissAt(1); // 关掉嵌套层，保留顶层
    expect(events.last.depth, 1);
    expect(events.last.term, 'a');
  });

  test('清空栈（clear）→ 深度 0（面包屑应被清，崩溃与查词无关）', () {
    c.beginTop(
      term: 'x',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: true,
      visible: true,
    );
    c.clear();
    expect(events.last.depth, 0);
  });

  test('隐藏热槽不计入可见深度（深度 0 → 清面包屑）', () {
    c.seedWarmSlot();
    // 热槽 visible=false，可见深度仍为 0。
    expect(events.last.depth, 0);
  });

  test('不注入回调时栈操作不抛（纯逻辑测试不受影响）', () {
    final DictionaryPopupController plain =
        DictionaryPopupController(lowMemory: false);
    expect(
      () => plain.beginTop(
        term: 't',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
      ),
      returnsNormally,
    );
  });
}

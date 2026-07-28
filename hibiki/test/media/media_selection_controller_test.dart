import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/selection/media_selection_controller.dart';

/// 库页多选状态机：区间选、扫选、锚点失效、分区隔离。
///
/// 这些规则以前分散在书架 / 视频库两页的 setState 里，谁都测不到；抽成纯 Dart
/// 类后在这里一次性钉死，两页共用同一份行为。
void main() {
  late MediaSelectionController controller;

  /// 一个典型库页：3 个合集行 + 5 张散卡。
  void seedVisible() {
    controller.setVisibleOrder(
      loose: const <String>['a', 'b', 'c', 'd', 'e'],
      collections: const <int>[10, 20, 30],
    );
  }

  setUp(() {
    controller = MediaSelectionController();
    seedVisible();
  });

  group('模式与入口', () {
    test('初始不在多选态，toggleMode 开关并清空', () {
      expect(controller.active, isFalse);
      controller.toggleMode();
      expect(controller.active, isTrue);
      controller.toggle(const SelectionSlot.loose('a'));
      expect(controller.looseKeys, <String>{'a'});
      controller.toggleMode();
      expect(controller.active, isFalse);
      expect(controller.isEmpty, isTrue);
    });

    test('enterWith 从非多选态进入并选中该项', () {
      controller.enterWith(const SelectionSlot.loose('c'));
      expect(controller.active, isTrue);
      expect(controller.looseKeys, <String>{'c'});
    });

    test('已在多选态时 enterWith 退化为切换，不清空既有选中集', () {
      controller.enterWith(const SelectionSlot.loose('a'));
      controller.toggle(const SelectionSlot.loose('b'));
      // 长按已选中的 b：只取消 b，a 必须留着（曾经的踩坑：重进多选把全清了）。
      controller.enterWith(const SelectionSlot.loose('b'));
      expect(controller.looseKeys, <String>{'a'});
      expect(controller.active, isTrue);
    });

    test('exit 关闭并清空；clearSelection 只清空、留在多选态', () {
      controller.enterWith(const SelectionSlot.loose('a'));
      controller.clearSelection();
      expect(controller.active, isTrue);
      expect(controller.isEmpty, isTrue);
      controller.toggle(const SelectionSlot.loose('a'));
      controller.exit();
      expect(controller.active, isFalse);
      expect(controller.isEmpty, isTrue);
    });
  });

  group('Shift 区间选', () {
    test('锚点到目标的可见区间整段并入（正向）', () {
      controller.toggle(const SelectionSlot.loose('b'));
      controller.extendTo(const SelectionSlot.loose('d'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
    });

    test('反向 Shift 点击同样成立', () {
      controller.toggle(const SelectionSlot.loose('d'));
      controller.extendTo(const SelectionSlot.loose('b'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
    });

    test('区间只增不减，锚点不动，可反复调整末端', () {
      controller.toggle(const SelectionSlot.loose('b'));
      controller.extendTo(const SelectionSlot.loose('d'));
      controller.extendTo(const SelectionSlot.loose('e'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd', 'e'});
      expect(controller.anchor, const SelectionSlot.loose('b'));
    });

    test('无锚点时退化为普通切换', () {
      controller.extendTo(const SelectionSlot.loose('c'));
      expect(controller.looseKeys, <String>{'c'});
    });

    test('合集区自己的区间选', () {
      controller.toggle(const SelectionSlot.collection(10));
      controller.extendTo(const SelectionSlot.collection(30));
      expect(controller.collectionIds, <int>{10, 20, 30});
      expect(controller.looseKeys, isEmpty);
    });

    test('跨分区退化为普通切换并重设锚点，不牵连另一区', () {
      controller.toggle(const SelectionSlot.collection(10));
      controller.extendTo(const SelectionSlot.loose('d'));
      expect(controller.collectionIds, <int>{10});
      expect(controller.looseKeys, <String>{'d'});
      // 锚点已挪到散卡区，接着 Shift 点击在散卡区内正常成段。
      controller.extendTo(const SelectionSlot.loose('b'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
    });

    test('目标已不在可见顺序里时退化为普通切换', () {
      controller.toggle(const SelectionSlot.loose('b'));
      controller.extendTo(const SelectionSlot.loose('zzz'));
      expect(controller.looseKeys, <String>{'b', 'zzz'});
    });
  });

  group('锚点随可见顺序失效', () {
    test('排序/筛选变化后 Shift 点击退化为切换，不会选中一片没看见的条目', () {
      controller.toggle(const SelectionSlot.loose('b'));
      // 用户改了排序：可见顺序整个换了。
      controller.setVisibleOrder(
        loose: const <String>['e', 'd', 'c', 'b', 'a'],
        collections: const <int>[10, 20, 30],
      );
      controller.extendTo(const SelectionSlot.loose('a'));
      expect(controller.looseKeys, <String>{'b', 'a'});
    });

    test('同内容的新列表（每帧重建）不算变化，锚点保留', () {
      controller.toggle(const SelectionSlot.loose('b'));
      controller.setVisibleOrder(
        loose: <String>['a', 'b', 'c', 'd', 'e'],
        collections: <int>[10, 20, 30],
      );
      controller.extendTo(const SelectionSlot.loose('d'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
    });
  });

  group('长按扫选', () {
    test('从起点刷到目标，等价于区间选', () {
      controller.beginRangeDrag(const SelectionSlot.loose('b'));
      controller.updateRangeDrag(const SelectionSlot.loose('d'));
      controller.endRangeDrag();
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
      expect(controller.isRangeDragging, isFalse);
    });

    test('手指往回滑取消刚刷上的一段（基线语义，不是只增不减）', () {
      controller.beginRangeDrag(const SelectionSlot.loose('b'));
      controller.updateRangeDrag(const SelectionSlot.loose('e'));
      expect(controller.looseKeys, <String>{'b', 'c', 'd', 'e'});
      controller.updateRangeDrag(const SelectionSlot.loose('c'));
      expect(controller.looseKeys, <String>{'b', 'c'});
    });

    test('扫选叠加在已有选中集之上，不抹掉先前的选择', () {
      controller.toggle(const SelectionSlot.loose('a'));
      controller.beginRangeDrag(const SelectionSlot.loose('c'));
      controller.updateRangeDrag(const SelectionSlot.loose('d'));
      expect(controller.looseKeys, <String>{'a', 'c', 'd'});
      // 回滑到起点：a 是基线的一部分，必须留着。
      controller.updateRangeDrag(const SelectionSlot.loose('c'));
      expect(controller.looseKeys, <String>{'a', 'c'});
    });

    test('起点已选中时扫选不把它取消（并入语义）', () {
      controller.toggle(const SelectionSlot.loose('c'));
      controller.beginRangeDrag(const SelectionSlot.loose('c'));
      expect(controller.looseKeys, <String>{'c'});
    });

    test('滑到另一分区时保持上一帧结果，不抖动', () {
      controller.beginRangeDrag(const SelectionSlot.loose('b'));
      controller.updateRangeDrag(const SelectionSlot.loose('d'));
      controller.updateRangeDrag(const SelectionSlot.collection(20));
      expect(controller.looseKeys, <String>{'b', 'c', 'd'});
      expect(controller.collectionIds, isEmpty);
    });

    test('未开始扫选时的 update 是 no-op', () {
      controller.updateRangeDrag(const SelectionSlot.loose('d'));
      expect(controller.isEmpty, isTrue);
    });
  });

  group('全选 / 反选', () {
    test('全选只并入调用方给的候选（各页资格规则留在页里）', () {
      controller.selectAll(
        loose: const <String>['a', 'c'],
        collections: const <int>[10],
      );
      expect(controller.looseKeys, <String>{'a', 'c'});
      expect(controller.collectionIds, <int>{10});
    });

    test('反选在候选集内取补集并清锚点', () {
      controller.toggle(const SelectionSlot.loose('b'));
      controller.invert(
        loose: const <String>['a', 'b', 'c'],
        collections: const <int>[10, 20],
      );
      expect(controller.looseKeys, <String>{'a', 'c'});
      expect(controller.collectionIds, <int>{10, 20});
      expect(controller.anchor, isNull);
    });
  });

  group('SelectionSlot 值语义', () {
    test('同值相等、可作 Set 键；两分区互不相等', () {
      expect(const SelectionSlot.loose('a'), const SelectionSlot.loose('a'));
      expect(const SelectionSlot.collection(1),
          isNot(const SelectionSlot.loose('1')));
      // 逐个 add 而非 set 字面量：字面量里的重复元素会被
      // `equal_elements_in_set` 判为 warning（CI 视 warning 为致命），而 `.toSet()`
      // 又撞 `prefer_collection_literals`。这里的重复正是被测行为。
      final Set<SelectionSlot> set = <SelectionSlot>{};
      set.add(const SelectionSlot.loose('a'));
      set.add(const SelectionSlot.loose('a'));
      set.add(const SelectionSlot.collection(1));
      expect(set, hasLength(2));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/controls/control_layout.dart';

/// 泛型布局模型的契约测试：用一套与视频无关的最小枚举（3 可见槽 + hidden、5 个
/// 按钮）钉住不变式。视频宿主的行为由 `test/media/video/video_control_layout_test.dart`
/// 端到端覆盖；这里保证阅读器等第二个宿主接进来时拿到的是同一份语义。
enum _Slot implements ControlSlotSpec {
  left('left'),
  center('center'),
  right('right'),
  hidden('hidden');

  const _Slot(this.storageValue);

  @override
  final String storageValue;
}

enum _Item implements ControlItemSpec<_Slot> {
  /// 必需项：不可移除，落空回 center。
  play('play', pinnedRequired: true),

  /// 触屏必需项：只在 UI 门上禁移除，模型层照常可移除。
  settings('settings', pinnedOnTouch: true),

  /// 单实例项：只能在 left / right。
  title('title', isSingleInstance: true),
  speed('speed'),
  bookmark('bookmark');

  const _Item(
    this.storageValue, {
    this.pinnedRequired = false,
    this.pinnedOnTouch = false,
    this.isSingleInstance = false,
  });

  @override
  final String storageValue;
  @override
  final bool pinnedRequired;
  @override
  final bool pinnedOnTouch;
  @override
  final bool isSingleInstance;

  @override
  _Slot get recoverySlot => _Slot.center;

  @override
  bool canMoveToSlot(_Slot target, {bool isTouchControls = false}) {
    if (this == _Item.title) {
      return target == _Slot.left ||
          target == _Slot.right ||
          target == _Slot.hidden;
    }
    if (pinnedRequired && target == _Slot.hidden) return false;
    if (isTouchControls && pinnedOnTouch && target == _Slot.hidden) {
      return false;
    }
    return true;
  }
}

typedef _Layout = ControlLayout<_Slot, _Item>;

const ControlLayoutScheme<_Slot, _Item> _scheme =
    ControlLayoutScheme<_Slot, _Item>(
  slots: _Slot.values,
  hiddenSlot: _Slot.hidden,
  items: _Item.values,
);

const Map<_Item, _Slot> _defaultAssignments = <_Item, _Slot>{
  _Item.title: _Slot.left,
  _Item.play: _Slot.center,
  _Item.speed: _Slot.right,
  _Item.settings: _Slot.right,
  _Item.bookmark: _Slot.right,
};

_Layout _defaults() => _Layout.fromAssignments(
      _scheme,
      _defaultAssignments,
      explicitOrder: const <_Slot, List<_Item>>{
        _Slot.right: <_Item>[_Item.bookmark, _Item.speed, _Item.settings],
      },
    );

void main() {
  group('construction + invariants', () {
    test('fromAssignments honours explicitOrder and backfills the rest', () {
      final _Layout layout = _defaults();
      expect(layout.itemsIn(_Slot.left), <_Item>[_Item.title]);
      expect(layout.itemsIn(_Slot.center), <_Item>[_Item.play]);
      expect(
        layout.itemsIn(_Slot.right),
        <_Item>[_Item.bookmark, _Item.speed, _Item.settings],
      );
      expect(layout.hiddenItems, isEmpty);
      expect(layout.removedItems, isEmpty);
    });

    test('unassigned removable items land in removed; required ones recover',
        () {
      final _Layout layout = _Layout.fromAssignments(
        _scheme,
        const <_Item, _Slot>{_Item.speed: _Slot.left},
      );
      expect(layout.itemsIn(_Slot.left), <_Item>[_Item.speed]);
      // play 是必需项：没有 assignment 也不能落 removed，回到 recoverySlot。
      expect(layout.itemsIn(_Slot.center), <_Item>[_Item.play]);
      expect(layout.isOnPlayer(_Item.play), isTrue);
      expect(
        layout.removedItems,
        <_Item>[_Item.settings, _Item.title, _Item.bookmark],
      );
      expect(layout.slotsOf(_Item.settings), <_Slot>[_Slot.hidden]);
    });

    test('canMoveToSlot is enforced on construction (title only left/right)',
        () {
      final _Layout layout = _Layout.fromAssignments(
        _scheme,
        const <_Item, _Slot>{_Item.title: _Slot.center},
      );
      expect(layout.itemsIn(_Slot.center), isNot(contains(_Item.title)));
      expect(layout.removedItems, contains(_Item.title));
    });

    test('fromSlots keeps one item in several slots but dedupes within a slot',
        () {
      final _Layout layout = _Layout.fromSlots(
        _scheme,
        const <_Slot, List<_Item>>{
          _Slot.left: <_Item>[_Item.speed, _Item.speed],
          _Slot.right: <_Item>[_Item.speed],
        },
        assignments: _defaultAssignments,
      );
      // 槽内重复的 speed 只留一份；title 按 assignments 回填到 left 末尾。
      expect(layout.itemsIn(_Slot.left), <_Item>[_Item.speed, _Item.title]);
      expect(layout.slotsOf(_Item.speed), <_Slot>[_Slot.left, _Slot.right]);
      // 其它按钮按 assignments 回填。
      expect(layout.itemsIn(_Slot.center), <_Item>[_Item.play]);
      expect(layout.itemsIn(_Slot.right), contains(_Item.settings));
    });

    test('fromSlots respects removedItems, except for required keys', () {
      final _Layout layout = _Layout.fromSlots(
        _scheme,
        const <_Slot, List<_Item>>{
          _Slot.left: <_Item>[_Item.speed]
        },
        assignments: _defaultAssignments,
        removedItems: <_Item>{_Item.settings, _Item.play},
      );
      expect(layout.isOnPlayer(_Item.settings), isFalse);
      expect(layout.removedItems, contains(_Item.settings));
      expect(layout.isOnPlayer(_Item.play), isTrue);
      expect(layout.removedItems, isNot(contains(_Item.play)));
    });

    test('pinnedOnTouch never leaks into the persisted model', () {
      final _Layout layout = _defaults().moveItem(_Item.settings, _Slot.hidden);
      expect(layout.isOnPlayer(_Item.settings), isFalse);
      expect(_Item.settings.canMoveToSlot(_Slot.hidden), isTrue);
      expect(
        _Item.settings.canMoveToSlot(_Slot.hidden, isTouchControls: true),
        isFalse,
      );
    });
  });

  group('write operations', () {
    test('moveItem collapses all copies into the target at index', () {
      final _Layout layout = _defaults()
          .addItemToSlot(_Item.speed, _Slot.left)
          .moveItem(_Item.speed, _Slot.center, index: 0);
      expect(layout.slotsOf(_Item.speed), <_Slot>[_Slot.center]);
      expect(layout.itemsIn(_Slot.center), <_Item>[_Item.speed, _Item.play]);
    });

    test('moveItem into hidden removes; required item is rejected', () {
      final _Layout base = _defaults();
      final _Layout removed = base.moveItem(_Item.bookmark, _Slot.hidden);
      expect(removed.removedItems, <_Item>[_Item.bookmark]);
      expect(
          removed.itemsIn(_Slot.right), <_Item>[_Item.speed, _Item.settings]);
      expect(identical(base.moveItem(_Item.play, _Slot.hidden), base), isTrue);
    });

    test('addItemToSlot copies, is idempotent, moves single-instance items',
        () {
      final _Layout once = _defaults().addItemToSlot(_Item.speed, _Slot.left);
      expect(once.slotsOf(_Item.speed), <_Slot>[_Slot.left, _Slot.right]);
      final _Layout twice = once.addItemToSlot(_Item.speed, _Slot.left);
      expect(identical(twice, once), isTrue);
      final _Layout title = once.addItemToSlot(_Item.title, _Slot.right);
      expect(title.slotsOf(_Item.title), <_Slot>[_Slot.right]);
    });

    test('moveDraggedItem from palette adds a copy at targetIndex', () {
      final _Layout layout = _defaults().moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.speed,
          sourceSlot: null,
        ),
        _Slot.left,
        targetIndex: 0,
      );
      expect(layout.itemsIn(_Slot.left), <_Item>[_Item.speed, _Item.title]);
      expect(layout.itemsIn(_Slot.right), contains(_Item.speed));
    });

    test('moveDraggedItem same-slot reorder is index aware', () {
      // right = [bookmark, speed, settings]; 把 bookmark(0) 拖到 settings 后面(3)。
      final _Layout layout = _defaults().moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.bookmark,
          sourceSlot: _Slot.right,
          sourceIndex: 0,
        ),
        _Slot.right,
        targetIndex: 3,
      );
      expect(
        layout.itemsIn(_Slot.right),
        <_Item>[_Item.speed, _Item.settings, _Item.bookmark],
      );
    });

    test('moveDraggedItem to hidden drops only that copy', () {
      final _Layout two = _defaults().addItemToSlot(_Item.speed, _Slot.left);
      expect(two.itemsIn(_Slot.left), <_Item>[_Item.title, _Item.speed]);
      final _Layout one = two.moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.speed,
          sourceSlot: _Slot.left,
          sourceIndex: 1,
        ),
        _Slot.hidden,
      );
      expect(one.slotsOf(_Item.speed), <_Slot>[_Slot.right]);
      expect(one.removedItems, isNot(contains(_Item.speed)));
      final _Layout none = one.moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.speed,
          sourceSlot: _Slot.right,
          sourceIndex: 1,
        ),
        _Slot.hidden,
      );
      expect(none.removedItems, contains(_Item.speed));
    });

    test('moveDraggedItem with a stale sourceIndex is a no-op', () {
      final _Layout base = _defaults();
      final _Layout same = base.moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.speed,
          sourceSlot: _Slot.right,
          sourceIndex: 0, // 0 号其实是 bookmark
        ),
        _Slot.left,
      );
      expect(identical(same, base), isTrue);
    });

    test('removeItemFromSlot refuses the last copy of a required key', () {
      final _Layout base = _defaults();
      expect(
        identical(base.removeItemFromSlot(_Item.play, _Slot.center), base),
        isTrue,
      );
      final _Layout extra = base.addItemToSlot(_Item.play, _Slot.left);
      final _Layout back = extra.removeItemFromSlot(_Item.play, _Slot.left);
      expect(back, base);
      final _Layout gone = base.removeItemFromSlot(_Item.speed, _Slot.right);
      expect(gone.removedItems, <_Item>[_Item.speed]);
    });
  });

  group('postNormalize hook', () {
    test('runs after backfill and before the final removed cleanup', () {
      final ControlLayoutScheme<_Slot, _Item> pinned =
          ControlLayoutScheme<_Slot, _Item>(
        slots: _Slot.values,
        hiddenSlot: _Slot.hidden,
        items: _Item.values,
        postNormalize: (Map<_Slot, List<_Item>> slots, Set<_Item> removed) {
          // 宿主特判：bookmark 永远钉在 left 的最前面，且不可移除。
          for (final _Slot slot in _Slot.values) {
            slots[slot]!.remove(_Item.bookmark);
          }
          slots[_Slot.left]!.insert(0, _Item.bookmark);
        },
      );
      final _Layout layout = _Layout.fromAssignments(
        pinned,
        const <_Item, _Slot>{_Item.speed: _Slot.right},
      ).moveItem(_Item.bookmark, _Slot.hidden);
      expect(layout.itemsIn(_Slot.left), <_Item>[_Item.bookmark]);
      // 钩子把它放回可见槽，最终清理必须把它从 removed 里剔掉。
      expect(layout.removedItems, isNot(contains(_Item.bookmark)));
    });
  });

  group('codec', () {
    test('encodeSlots omits hidden by default and round-trips via decodeSlots',
        () {
      final _Layout layout = _defaults()
          .addItemToSlot(_Item.speed, _Slot.left)
          .moveItem(_Item.bookmark, _Slot.hidden);
      final Map<String, List<String>> slots = layout.encodeSlots();
      expect(slots.keys, <String>['left', 'center', 'right']);
      expect(slots['left'], <String>['title', 'speed']);
      expect(layout.encodeRemoved(), <String>['bookmark']);
      expect(layout.encodeSlots(includeHidden: true)['hidden'], isEmpty);

      final _Layout? decoded = _Layout.decodeSlots<_Slot, _Item>(
        _scheme,
        slots,
        removedRaw: layout.encodeRemoved(),
        fallbackAssignments: _defaultAssignments,
      );
      expect(decoded, layout);
      expect(decoded.hashCode, layout.hashCode);
    });

    test('decodeSlots treats hidden-slot entries as removed (v2 semantics)',
        () {
      final _Layout? decoded = _Layout.decodeSlots<_Slot, _Item>(
        _scheme,
        <String, dynamic>{
          'left': <String>['title'],
          'hidden': <String>['speed', 'play', 'unknown'],
        },
        fallbackAssignments: _defaultAssignments,
      );
      expect(decoded, isNotNull);
      expect(decoded!.removedItems, <_Item>[_Item.speed]);
      // play 必需：hidden 里列了也回到播放器。
      expect(decoded.itemsIn(_Slot.center), <_Item>[_Item.play]);
      // 没提到的按钮按 fallback 回填。
      expect(decoded.itemsIn(_Slot.right),
          <_Item>[_Item.settings, _Item.bookmark]);
    });

    test('decodeSlots skips unknown / disallowed entries, null when empty', () {
      expect(
        _Layout.decodeSlots<_Slot, _Item>(_scheme, <String, dynamic>{
          'nowhere': <String>['speed'],
          'center': <Object>['title', 42, 'ghost'],
        }),
        isNull,
      );
      expect(
        _Layout.decodeSlots<_Slot, _Item>(_scheme, <String, dynamic>{}),
        isNull,
      );
      expect(
        _Layout.decodeSlots<_Slot, _Item>(
          _scheme,
          <String, dynamic>{},
          removedRaw: <String>['speed'],
        ),
        isNotNull,
      );
    });
  });

  group('equality', () {
    test('value semantics over slot order and removed set', () {
      expect(_defaults(), _defaults());
      expect(_defaults().hashCode, _defaults().hashCode);
      final _Layout reordered = _defaults().moveDraggedItem(
        const ControlDragData<_Slot, _Item>(
          item: _Item.bookmark,
          sourceSlot: _Slot.right,
          sourceIndex: 0,
        ),
        _Slot.right,
        targetIndex: 3,
      );
      expect(reordered, isNot(_defaults()));
    });
  });
}

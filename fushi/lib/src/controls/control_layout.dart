/// 媒体页「控制按钮布局」的泛型模型：槽位（slot）× 按钮（item）的有序放置 +
/// 显式「已移除」集。纯 Dart，无 Flutter 依赖。
///
/// 视频页的 `VideoControlLayout` 是它的第一个宿主；阅读器工具栏复用同一份不变式
/// 与写操作，只提供自己的槽位枚举 / 按钮枚举 / 默认布局 / 域特判。
///
/// 不变式（由归一化构造与 pinned 守卫维护）：
///   - 每个按钮在同一个可见槽内最多出现一次（跨槽允许多份副本）；
///   - 按钮不在任何可见槽 ⇔ 它在 [ControlLayout.removedItems]（除必需项）；
///   - 老 / 残缺载荷可按 fallback assignment 回填缺失按钮；
///   - [ControlItemSpec.pinnedRequired] 的按钮不可移除，落空时回到
///     [ControlItemSpec.recoverySlot]。
library;

/// 槽位契约：持久化名。`isOnPlayer` 不放这里——由 [ControlLayoutScheme.hiddenSlot]
/// 决定，避免每个槽位枚举各写一遍「除 hidden 之外都可见」。
abstract interface class ControlSlotSpec {
  String get storageValue;
}

/// 按钮契约。宿主枚举实现它即可放进 [ControlLayout]。
abstract interface class ControlItemSpec<S> {
  String get storageValue;

  /// 必需项：任何平台都不能移入 hidden。
  bool get pinnedRequired;

  /// 触屏专属必需项：只在 UI 门（`isTouchControls: true`）上禁止移入 hidden，
  /// 持久化模型永远按 `false` 判，保证一份布局跨平台解码一致。
  bool get pinnedOnTouch;

  /// 单实例项：从调色板拖入按「移动」而不是「复制」处理。
  bool get isSingleInstance;

  /// 必需项被错误移除后回落的槽位。
  S get recoverySlot;

  bool canMoveToSlot(S target, {bool isTouchControls = false});
}

/// 归一化后置钩子：宿主的域特判（例如视频的 volume 只能在底栏、title 只能在顶栏）。
/// 在去重 + 回填之后、最终 removed 清理之前调用，直接原地改 [slots] / [removed]。
typedef ControlLayoutPostNormalize<S, I> = void Function(
    Map<S, List<I>> slots, Set<I> removed);

/// 一个宿主的槽位全集 / 按钮全集 / hidden 槽位 / 后置钩子。[slots] 与 [items] 的
/// 顺序就是所有遍历、编码与 [ControlLayout.removedItems] 的顺序。
class ControlLayoutScheme<S extends ControlSlotSpec,
    I extends ControlItemSpec<S>> {
  const ControlLayoutScheme({
    required this.slots,
    required this.hiddenSlot,
    required this.items,
    this.postNormalize,
  });

  final List<S> slots;
  final S hiddenSlot;
  final List<I> items;
  final ControlLayoutPostNormalize<S, I>? postNormalize;

  bool isOnPlayer(S slot) => slot != hiddenSlot;

  /// 持久化模型允许把该按钮从播放器上拿掉（跨平台、无触屏门）。
  bool canBeRemoved(I item) => item.canMoveToSlot(hiddenSlot);

  S? parseSlot(String value) {
    for (final S slot in slots) {
      if (slot.storageValue == value) return slot;
    }
    return null;
  }

  I? parseItem(String value) {
    for (final I item in items) {
      if (item.storageValue == value) return item;
    }
    return null;
  }

  Map<S, List<I>> emptySlotMap() => <S, List<I>>{
        for (final S slot in slots) slot: <I>[],
      };
}

/// 拖拽载荷：被拖的按钮 + 来源槽位（null = 来自「全部按钮」调色板，即新增）+
/// 来源槽内下标（同槽重排 / 多副本精确删除用）。
class ControlDragData<S, I> {
  const ControlDragData({
    required this.item,
    required this.sourceSlot,
    this.sourceIndex,
  });

  final I item;
  final S? sourceSlot;
  final int? sourceIndex;
}

class _NormalizedControlLayoutData<S, I> {
  const _NormalizedControlLayoutData({
    required this.slots,
    required this.removed,
  });

  final Map<S, List<I>> slots;
  final Set<I> removed;
}

/// 逐槽有序的按钮布局（不可变；每个写操作返回新实例）。
class ControlLayout<S extends ControlSlotSpec, I extends ControlItemSpec<S>> {
  ControlLayout._(this.scheme, this._slots, Set<I> removed)
      : _removed = Set<I>.unmodifiable(removed);

  /// 从「按钮 → 槽位」平铺表构建；[explicitOrder] 决定槽内顺序（保留用户拖拽顺序）。
  factory ControlLayout.fromAssignments(
    ControlLayoutScheme<S, I> scheme,
    Map<I, S> assignments, {
    Map<S, List<I>>? explicitOrder,
  }) {
    final Map<S, List<I>> slots = scheme.emptySlotMap();
    final Set<I> removed = <I>{};

    if (explicitOrder != null) {
      final Set<I> placed = <I>{};
      for (final S slot in scheme.slots) {
        for (final I item in explicitOrder[slot] ?? const <Never>[]) {
          if (placed.add(item)) {
            _placeRawItem(scheme, slots, removed, item, slot);
          }
        }
      }
      for (final I item in scheme.items) {
        if (placed.contains(item)) continue;
        final S slot = assignments[item] ?? scheme.hiddenSlot;
        _placeRawItem(scheme, slots, removed, item, slot);
      }
    } else {
      for (final I item in scheme.items) {
        final S slot = assignments[item] ?? scheme.hiddenSlot;
        _placeRawItem(scheme, slots, removed, item, slot);
      }
    }

    return _fromRaw(
      scheme,
      slots,
      removedItems: removed,
      fallbackAssignments: assignments,
    );
  }

  /// 直接从「槽位 → 有序按钮」构建，**不跨槽去重**（同一按钮可在多个槽）。不在任何
  /// 可见槽的按钮按 [assignments] 回填，除非它在 [removedItems]；pinned 守卫照常。
  factory ControlLayout.fromSlots(
    ControlLayoutScheme<S, I> scheme,
    Map<S, List<I>> slotItems, {
    Map<I, S>? assignments,
    Set<I>? removedItems,
  }) {
    final Map<S, List<I>> slots = scheme.emptySlotMap();
    final Set<I> removed = <I>{...?removedItems};
    final Set<I> seen = <I>{};
    for (final S slot in scheme.slots) {
      for (final I item in slotItems[slot] ?? const <Never>[]) {
        // 只在槽内去重；跨槽的同一按钮允许。
        if (slots[slot]!.contains(item)) continue;
        final bool placed = _placeRawItem(scheme, slots, removed, item, slot);
        if (placed) seen.add(item);
      }
    }
    for (final I item in scheme.items) {
      if (seen.contains(item)) continue;
      if (removed.contains(item) && scheme.canBeRemoved(item)) continue;
      final S slot = assignments?[item] ?? scheme.hiddenSlot;
      _placeRawItem(scheme, slots, removed, item, slot);
    }
    return _fromRaw(
      scheme,
      slots,
      removedItems: removed,
      fallbackAssignments: assignments,
    );
  }

  /// 解码持久化的「槽位名 → 按钮名列表」表。hidden 槽键下列出的按钮一律视作
  /// 已移除（这是 v2 → v3 迁移语义，也是唯一合理的通用解释：hidden 不是渲染面）。
  /// 一个可见按钮都没有且 removed 为空 ⇒ 返回 null，由宿主决定兜底布局。
  static ControlLayout<S, I>?
      decodeSlots<S extends ControlSlotSpec, I extends ControlItemSpec<S>>(
    ControlLayoutScheme<S, I> scheme,
    Map<String, dynamic> slotsRaw, {
    Object? removedRaw,
    Map<I, S>? fallbackAssignments,
  }) {
    final Map<S, List<I>> explicitOrder = <S, List<I>>{};
    final Set<I> removed = <I>{};
    if (removedRaw is List) {
      for (final Object? rawItem in removedRaw) {
        if (rawItem is! String) continue;
        final I? item = scheme.parseItem(rawItem);
        if (item != null && scheme.canBeRemoved(item)) {
          removed.add(item);
        }
      }
    }
    int visibleItemCount = 0;
    for (final MapEntry<String, dynamic> entry in slotsRaw.entries) {
      final S? slot = scheme.parseSlot(entry.key);
      final Object? listRaw = entry.value;
      if (slot == null || listRaw is! List) continue;
      if (slot == scheme.hiddenSlot) {
        for (final Object? rawItem in listRaw) {
          if (rawItem is! String) continue;
          final I? item = scheme.parseItem(rawItem);
          if (item != null && scheme.canBeRemoved(item)) removed.add(item);
        }
        continue;
      }
      final List<I> items = <I>[];
      for (final Object? rawItem in listRaw) {
        if (rawItem is! String) continue;
        final I? item = scheme.parseItem(rawItem);
        if (item == null) continue;
        if (!item.canMoveToSlot(slot)) continue;
        items.add(item);
      }
      visibleItemCount += items.length;
      explicitOrder[slot] = items;
    }
    if (visibleItemCount == 0 && removed.isEmpty) return null;
    return ControlLayout<S, I>.fromSlots(
      scheme,
      explicitOrder,
      assignments: fallbackAssignments,
      removedItems: removed,
    );
  }

  static bool
      _placeRawItem<S extends ControlSlotSpec, I extends ControlItemSpec<S>>(
    ControlLayoutScheme<S, I> scheme,
    Map<S, List<I>> slots,
    Set<I> removed,
    I item,
    S slot,
  ) {
    if (slot == scheme.hiddenSlot) {
      if (scheme.canBeRemoved(item)) {
        removed.add(item);
      }
      return false;
    }
    if (!item.canMoveToSlot(slot)) return false;
    slots[slot]!.add(item);
    removed.remove(item);
    return true;
  }

  static ControlLayout<S, I>
      _fromRaw<S extends ControlSlotSpec, I extends ControlItemSpec<S>>(
    ControlLayoutScheme<S, I> scheme,
    Map<S, List<I>> slots, {
    Set<I> removedItems = const <Never>{},
    Map<I, S>? fallbackAssignments,
  }) {
    final _NormalizedControlLayoutData<S, I> data = _normalize(
      scheme,
      slots,
      removedItems: removedItems,
      fallbackAssignments: fallbackAssignments,
    );
    return ControlLayout<S, I>._(scheme, data.slots, data.removed);
  }

  final ControlLayoutScheme<S, I> scheme;
  final Map<S, List<I>> _slots;
  final Set<I> _removed;

  /// 槽内有序按钮（不可变副本）。
  List<I> itemsIn(S slot) =>
      List<I>.unmodifiable(_slots[slot] ?? const <Never>[]);

  /// 按钮所在的第一个槽位；不在任何可见槽 ⇒ hidden。
  S slotOf(I item) {
    for (final S slot in scheme.slots) {
      if (_slots[slot]!.contains(item)) return slot;
    }
    return scheme.hiddenSlot;
  }

  bool isOnPlayer(I item) => scheme.isOnPlayer(slotOf(item));

  /// 显式移除的按钮，按 [ControlLayoutScheme.items] 顺序。
  List<I> get removedItems => <I>[
        for (final I item in scheme.items)
          if (_removed.contains(item)) item,
      ];

  /// hidden 槽渲染面（归一化后恒空；保留给直接查槽的旧调用方）。
  List<I> get hiddenItems => itemsIn(scheme.hiddenSlot);

  /// 按钮所在的全部槽位（按 [ControlLayoutScheme.slots] 顺序）；一个都没有时，
  /// 已移除 ⇒ `[hidden]`，否则空表。
  List<S> slotsOf(I item) {
    final List<S> hits = <S>[
      for (final S slot in scheme.slots)
        if (_slots[slot]!.contains(item)) slot,
    ];
    if (hits.isNotEmpty) return hits;
    return _removed.contains(item) ? <S>[scheme.hiddenSlot] : <S>[];
  }

  Map<S, List<I>> _copySlots() => <S, List<I>>{
        for (final S slot in scheme.slots) slot: List<I>.from(_slots[slot]!),
      };

  bool _stillVisible(Map<S, List<I>> slots, I item) => scheme.slots.any(
        (S s) => scheme.isOnPlayer(s) && slots[s]!.contains(item),
      );

  /// 把 [item] 的所有副本收拢成一份放进 [target] 的 [index]（核心拖拽写操作）。
  /// 必需项移入 hidden 被拒（返回 this）。
  ControlLayout<S, I> moveItem(I item, S target, {int? index}) {
    if (!item.canMoveToSlot(target)) return this;
    final Map<S, List<I>> next = _copySlots();
    for (final S slot in scheme.slots) {
      next[slot]!.removeWhere((I i) => i == item);
    }
    final Set<I> removed = <I>{..._removed};
    if (target == scheme.hiddenSlot) {
      removed.add(item);
      return _fromRaw(scheme, next, removedItems: removed);
    }
    removed.remove(item);
    final List<I> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(scheme, next, removedItems: removed);
  }

  /// 往 [target] 加一份 [item] 副本，**不**动其它槽里的副本；同槽幂等。
  ControlLayout<S, I> addItemToSlot(I item, S target, {int? index}) {
    if (!item.canMoveToSlot(target)) return this;
    if (item.isSingleInstance || target == scheme.hiddenSlot) {
      return moveItem(item, target, index: index);
    }
    if (_slots[target]!.contains(item)) return this;
    final Map<S, List<I>> next = _copySlots();
    final Set<I> removed = <I>{..._removed}..remove(item);
    final List<I> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(scheme, next, removedItems: removed);
  }

  /// 把 [payload] 代表的那一份精确副本移进 [target]。
  ///
  /// 调色板拖拽（sourceSlot == null）= 新增副本；已放置 chip 的拖拽只删来源槽的
  /// [ControlDragData.sourceIndex] 那一份，别处副本保留；同槽拖拽 = 带下标的重排。
  ControlLayout<S, I> moveDraggedItem(
    ControlDragData<S, I> payload,
    S target, {
    int? targetIndex,
  }) {
    final I item = payload.item;
    if (payload.sourceSlot == null) {
      return addItemToSlot(item, target, index: targetIndex);
    }
    if (!item.canMoveToSlot(target)) return this;
    if (item.isSingleInstance) {
      return moveItem(item, target, index: targetIndex);
    }

    final S source = payload.sourceSlot!;
    final Map<S, List<I>> next = _copySlots();
    final List<I> sourceList = next[source]!;
    final int sourceIndex = payload.sourceIndex ??
        sourceList.indexWhere((I candidate) => candidate == item);
    if (sourceIndex < 0 ||
        sourceIndex >= sourceList.length ||
        sourceList[sourceIndex] != item) {
      return this;
    }

    final Set<I> removed = <I>{..._removed};
    if (target == scheme.hiddenSlot) {
      sourceList.removeAt(sourceIndex);
      if (!_stillVisible(next, item)) removed.add(item);
      return _fromRaw(scheme, next, removedItems: removed);
    }
    removed.remove(item);
    final List<I> targetList = next[target]!;
    if (source != target && targetList.contains(item)) return this;

    sourceList.removeAt(sourceIndex);
    int insertAt = targetIndex ?? targetList.length;
    if (source == target && targetIndex != null && sourceIndex < targetIndex) {
      insertAt -= 1;
    }
    insertAt = insertAt.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(scheme, next, removedItems: removed);
  }

  /// 删掉 [slot] 里那一份 [item]；若是最后一份可见副本则记为已移除；必需项的最后
  /// 一份不可删（返回 this）。
  ControlLayout<S, I> removeItemFromSlot(I item, S slot) {
    if (!_slots[slot]!.contains(item)) return this;
    final Map<S, List<I>> next = _copySlots();
    next[slot]!.removeWhere((I i) => i == item);
    final Set<I> removed = <I>{..._removed};
    if (!_stillVisible(next, item)) {
      if (!scheme.canBeRemoved(item)) return this;
      removed.add(item);
    }
    return _fromRaw(scheme, next, removedItems: removed);
  }

  /// 「槽位名 → 按钮名列表」编码骨架；默认不含 hidden 槽（它不是渲染面）。
  Map<String, List<String>> encodeSlots({bool includeHidden = false}) =>
      <String, List<String>>{
        for (final S slot in scheme.slots)
          if (includeHidden || slot != scheme.hiddenSlot)
            slot.storageValue: <String>[
              for (final I item in _slots[slot]!) item.storageValue,
            ],
      };

  /// 已移除按钮名，按 [ControlLayoutScheme.items] 顺序。
  List<String> encodeRemoved() => <String>[
        for (final I item in removedItems) item.storageValue,
      ];

  /// 归一化不变式维护者：
  ///   1. 同一可见槽内按钮至多一次；
  ///   2. 按钮缺席播放器 ⇔ 显式移除；
  ///   3. 老 / 残缺载荷按 [fallbackAssignments] 回填；
  ///   4. 必需项不可移除；
  ///   5. 宿主后置钩子跑在最终 removed 清理之前。
  static _NormalizedControlLayoutData<S, I>
      _normalize<S extends ControlSlotSpec, I extends ControlItemSpec<S>>(
    ControlLayoutScheme<S, I> scheme,
    Map<S, List<I>> rawSlots, {
    Set<I> removedItems = const <Never>{},
    Map<I, S>? fallbackAssignments,
  }) {
    final Map<S, List<I>> slots = scheme.emptySlotMap();
    final Set<I> removed = <I>{
      for (final I item in removedItems)
        if (scheme.canBeRemoved(item)) item,
    };
    for (final S slot in scheme.slots) {
      for (final I item in rawSlots[slot] ?? const <Never>[]) {
        _placeRawItem(scheme, slots, removed, item, slot);
      }
    }
    for (final S slot in scheme.slots) {
      final Set<I> seen = <I>{};
      slots[slot]!.removeWhere((I item) => !seen.add(item));
    }

    final Set<I> visible = <I>{
      for (final S slot in scheme.slots)
        if (scheme.isOnPlayer(slot)) ...slots[slot]!,
    };
    removed.removeWhere(
      (I item) => visible.contains(item) || !scheme.canBeRemoved(item),
    );

    for (final I item in scheme.items) {
      if (visible.contains(item)) continue;
      if (removed.contains(item)) continue;
      final S? fallback = fallbackAssignments?[item];
      if (fallback != null) {
        final bool placed = _placeRawItem(
          scheme,
          slots,
          removed,
          item,
          fallback,
        );
        if (placed) {
          visible.add(item);
          continue;
        }
        if (removed.contains(item)) continue;
      }
      if (scheme.canBeRemoved(item)) {
        removed.add(item);
      } else {
        _placeRawItem(scheme, slots, removed, item, item.recoverySlot);
        visible.add(item);
      }
    }
    scheme.postNormalize?.call(slots, removed);
    removed.removeWhere(
      (I item) =>
          !scheme.canBeRemoved(item) ||
          scheme.slots.any(
            (S slot) => scheme.isOnPlayer(slot) && slots[slot]!.contains(item),
          ),
    );
    slots[scheme.hiddenSlot]!.clear();
    return _NormalizedControlLayoutData<S, I>(slots: slots, removed: removed);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ControlLayout<S, I>) return false;
    for (final S slot in scheme.slots) {
      final List<I> a = _slots[slot]!;
      final List<I> b = other._slots[slot]!;
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    if (_removed.length != other._removed.length) return false;
    return _removed.containsAll(other._removed);
  }

  @override
  int get hashCode {
    return Object.hashAll(<Object>[
      for (final S slot in scheme.slots) ...<Object>[slot, ..._slots[slot]!],
      'removed',
      for (final I item in scheme.items)
        if (_removed.contains(item)) item,
    ]);
  }
}

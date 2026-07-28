/// 库页多选的共享状态机（书架 / 视频库共用一份）。
///
/// 抽出来的理由：书架（`reader_hibiki_history_page.dart`）与视频库
/// （`home_video_page.dart`）此前各自维护形状完全相同的三件套——散卡选中集
/// `Set<String>`、合集整选集 `Set<int>`、模式位 `bool`——外加各自一份
/// toggle / 全选 / 反选。补 Shift 区间选与长按扫选时若继续各写一遍，两页行为
/// 必然漂开（历史上「本地视频卡漏 onSecondaryTap」BUG-758 就是这么来的）。
///
/// 本类**只管选择语义**，不碰 UI、不碰 setState：调用方在 `setState` 里调它，
/// 读它的 [looseKeys] / [collectionIds] 渲染。故可纯 Dart 单测。
///
/// ## 锚点（anchor）
///
/// Shift 区间选与长按扫选都需要一个「上次点击处」。锚点由 [toggle] /
/// [enterWith] / [beginRangeDrag] 设定，并在**可见顺序变化时清空**
/// （[setVisibleOrder]）——排序、搜索、筛选一变，旧锚点指向的位置对用户已无
/// 意义，此时 Shift 点击退化成普通切换，而不是选中一片他根本没看见的条目。
///
/// ## 分区
///
/// 库页把合集行与散卡分两区渲染，两区各有自己的可见顺序。区间选**不跨区**：
/// 锚点与目标不同区时退化为普通切换（并重设锚点）。这比「跨区时按某种拼接顺序
/// 选一片」可预测得多。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 多选的一格身份：要么是一张散卡（[looseKey]），要么是一个整合集
/// （[collectionId]）。
///
/// 刻意不复用 `MediaRef`：合集不是媒体条目（没有 `MediaKind` / `entryKey`），
/// 而两区必须能放进同一个「锚点」变量里才能表达「跨区退化」这条规则。
@immutable
class SelectionSlot {
  /// 散卡：书架是 `mediaIdentifier` / `srt_` 前缀键，视频库是 `bookUid`。
  const SelectionSlot.loose(String key)
      : looseKey = key,
        collectionId = null;

  /// 整合集：`MediaCollections.id`。
  const SelectionSlot.collection(int id)
      : collectionId = id,
        looseKey = null;

  final String? looseKey;
  final int? collectionId;

  bool get isCollection => collectionId != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionSlot &&
          other.looseKey == looseKey &&
          other.collectionId == collectionId;

  @override
  int get hashCode => Object.hash(looseKey, collectionId);

  @override
  String toString() => isCollection
      ? 'SelectionSlot.collection($collectionId)'
      : 'SelectionSlot.loose($looseKey)';
}

/// 一次卡片点击要按哪种语义处理。由按键修饰符决定（见 `selection_gestures.dart`）。
enum SelectionTapKind {
  /// 普通点击：切换该格，并把它设为新锚点。
  toggle,

  /// Shift + 点击：把锚点到该格的可见区间并入选中集，锚点不动。
  extend,
}

/// 库页多选状态机。见库文档。
class MediaSelectionController {
  bool _active = false;
  final Set<String> _looseKeys = <String>{};
  final Set<int> _collectionIds = <int>{};

  SelectionSlot? _anchor;

  List<String> _visibleLoose = const <String>[];
  List<int> _visibleCollections = const <int>[];

  /// 长按扫选期间的基线选中集（拖动只在基线上叠加区间，故手指往回滑能取消刚
  /// 刷上的那一段，而不是只增不减）。null = 当前没在扫选。
  Set<String>? _dragBaseLoose;
  Set<int>? _dragBaseCollections;

  /// 多选态是否开启。
  bool get active => _active;

  /// 已选散卡键（只读视图）。
  Set<String> get looseKeys => UnmodifiableSetView<String>(_looseKeys);

  /// 已选合集 id（只读视图）。
  Set<int> get collectionIds => UnmodifiableSetView<int>(_collectionIds);

  /// 当前锚点（无则 null）。仅供测试与调试断言。
  @visibleForTesting
  SelectionSlot? get anchor => _anchor;

  /// 是否正在长按扫选。
  bool get isRangeDragging => _dragBaseLoose != null;

  /// 选中总数（散卡 + 合集）。
  int get length => _looseKeys.length + _collectionIds.length;

  bool get isEmpty => length == 0;

  bool get isNotEmpty => length != 0;

  bool isSelected(SelectionSlot slot) => slot.isCollection
      ? _collectionIds.contains(slot.collectionId)
      : _looseKeys.contains(slot.looseKey);

  /// 每帧写入当前**可见顺序**（排序 / 搜索 / 筛选之后的实际渲染顺序）。
  ///
  /// 顺序一变就清锚点——见库文档「锚点」。内容相同（每帧新建但等值的列表）
  /// 视为未变，不会误清。
  void setVisibleOrder({
    required List<String> loose,
    required List<int> collections,
  }) {
    if (listEquals(_visibleLoose, loose) &&
        listEquals(_visibleCollections, collections)) {
      return;
    }
    _visibleLoose = List<String>.unmodifiable(loose);
    _visibleCollections = List<int>.unmodifiable(collections);
    _anchor = null;
  }

  /// 切换多选态（工具栏的选择按钮）。开与关都清空选中集，与两页原行为一致。
  void toggleMode() {
    _active = !_active;
    _resetSelection();
  }

  /// 退出多选态并清空。
  void exit() {
    _active = false;
    _resetSelection();
  }

  /// 从非多选态直接进入多选并选中 [slot]（触屏长按 / 桌面 Ctrl+点击）。
  ///
  /// 已在多选态时等价于 [toggle]——避免「长按已选中的卡」把整个选中集清掉。
  void enterWith(SelectionSlot slot) {
    if (_active) {
      toggle(slot);
      return;
    }
    _active = true;
    _resetSelection();
    _addSlot(slot);
    _anchor = slot;
  }

  /// 普通点击：切换该格，并把它设为新锚点。
  void toggle(SelectionSlot slot) {
    if (!_removeSlot(slot)) _addSlot(slot);
    _anchor = slot;
  }

  /// Shift + 点击：把锚点到 [slot] 的可见区间并入选中集（只增不减），锚点不动。
  ///
  /// 无锚点 / 跨分区 / 锚点或目标已不在可见顺序里 → 退化为 [toggle]。
  void extendTo(SelectionSlot slot) {
    final List<SelectionSlot>? range = _rangeFromAnchor(slot);
    if (range == null) {
      toggle(slot);
      return;
    }
    for (final SelectionSlot each in range) {
      _addSlot(each);
    }
  }

  /// 按 [kind] 分派 [toggle] / [extendTo]。
  void applyTap(SelectionSlot slot, SelectionTapKind kind) {
    switch (kind) {
      case SelectionTapKind.toggle:
        toggle(slot);
      case SelectionTapKind.extend:
        extendTo(slot);
    }
  }

  /// 长按扫选开始：记基线、设锚点、选中起点。
  ///
  /// 起点采用「并入」而非「切换」语义：扫选是刷一片进来，起点若已选中不该被
  /// 这一下抹掉。
  void beginRangeDrag(SelectionSlot slot) {
    _dragBaseLoose = Set<String>.of(_looseKeys);
    _dragBaseCollections = Set<int>.of(_collectionIds);
    _anchor = slot;
    _addSlot(slot);
  }

  /// 长按扫选移动：选中集 = 基线 ∪ [锚点, slot] 区间。
  ///
  /// 未在扫选中、或 [slot] 与锚点跨区 / 不可见时忽略（保持上一帧结果，手指滑到
  /// 空白处不会把已刷的一段抖没）。
  void updateRangeDrag(SelectionSlot slot) {
    final Set<String>? baseLoose = _dragBaseLoose;
    final Set<int>? baseCollections = _dragBaseCollections;
    if (baseLoose == null || baseCollections == null) return;
    final List<SelectionSlot>? range = _rangeFromAnchor(slot);
    if (range == null) return;
    _looseKeys
      ..clear()
      ..addAll(baseLoose);
    _collectionIds
      ..clear()
      ..addAll(baseCollections);
    for (final SelectionSlot each in range) {
      _addSlot(each);
    }
  }

  /// 长按扫选结束：丢弃基线，锚点保留（用户接着 Shift 点击可继续延展）。
  void endRangeDrag() {
    _dragBaseLoose = null;
    _dragBaseCollections = null;
  }

  /// 全选：把调用方给出的候选（各页自有资格规则，如视频库跳过已折进合集的成员）
  /// 全部并入。
  void selectAll({
    required Iterable<String> loose,
    required Iterable<int> collections,
  }) {
    _looseKeys.addAll(loose);
    _collectionIds.addAll(collections);
  }

  /// 反选：在候选集内取补集。锚点失效（选中集与最后一次点击已无关系）。
  void invert({
    required Iterable<String> loose,
    required Iterable<int> collections,
  }) {
    final Set<String> invertedLoose = loose.toSet().difference(_looseKeys);
    final Set<int> invertedCollections =
        collections.toSet().difference(_collectionIds);
    _looseKeys
      ..clear()
      ..addAll(invertedLoose);
    _collectionIds
      ..clear()
      ..addAll(invertedCollections);
    _anchor = null;
  }

  /// 清空选中集但**留在**多选态（批量操作落库后调用）。
  void clearSelection() => _resetSelection();

  /// 锚点 → [slot] 的可见区间。不可用时返回 null（调用方退化处理）。
  List<SelectionSlot>? _rangeFromAnchor(SelectionSlot slot) {
    final SelectionSlot? anchor = _anchor;
    if (anchor == null) return null;
    // 跨分区不连续：合集区与散卡区各有自己的顺序，拼起来选一片没有可预测语义。
    if (anchor.isCollection != slot.isCollection) return null;
    if (slot.isCollection) {
      final int from = _visibleCollections.indexOf(anchor.collectionId!);
      final int to = _visibleCollections.indexOf(slot.collectionId!);
      if (from < 0 || to < 0) return null;
      return <SelectionSlot>[
        for (int i = math.min(from, to); i <= math.max(from, to); i++)
          SelectionSlot.collection(_visibleCollections[i]),
      ];
    }
    final int from = _visibleLoose.indexOf(anchor.looseKey!);
    final int to = _visibleLoose.indexOf(slot.looseKey!);
    if (from < 0 || to < 0) return null;
    return <SelectionSlot>[
      for (int i = math.min(from, to); i <= math.max(from, to); i++)
        SelectionSlot.loose(_visibleLoose[i]),
    ];
  }

  void _addSlot(SelectionSlot slot) {
    if (slot.isCollection) {
      _collectionIds.add(slot.collectionId!);
    } else {
      _looseKeys.add(slot.looseKey!);
    }
  }

  /// 移除并返回「原本在不在集合里」。
  bool _removeSlot(SelectionSlot slot) => slot.isCollection
      ? _collectionIds.remove(slot.collectionId)
      : _looseKeys.remove(slot.looseKey);

  void _resetSelection() {
    _looseKeys.clear();
    _collectionIds.clear();
    _anchor = null;
    _dragBaseLoose = null;
    _dragBaseCollections = null;
  }
}

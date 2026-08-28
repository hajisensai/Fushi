/// 库页多选的共享状态机（书架 / 视频库共用一份）。
///
/// 抽出来的理由：书架（`reader_fushi_history_page.dart`）与视频库
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
///
/// ## 可见性约束（选中集对外只暴露看得见的那部分）
///
/// 内部选中集**无损**保留用户点过的每一格，但 [looseKeys] / [collectionIds] /
/// [length] / [isSelected] 一律只暴露**当前可见**（[setVisibleOrder] 登记）的
/// 那部分。于是「已选 N」永远等于用户屏幕上勾着的卡片数，批量操作也只作用于
/// 他看得见的条目。
///
/// 为什么不在筛选变化时把不可见项**清掉**：那要求每次 [setVisibleOrder] 都是
/// 权威的「这一帧真的只有这些」，而两个消费页的调用契约并不一致（视频库在空态
/// 提前 return、不调用；书架页每帧无条件调用）。数据重载途中闪一帧空列表就会
/// 永久吃掉用户的选中。改成视图约束后根本不需要判断「什么时候该清」——不可见
/// 期间选中项只是不参与计数与操作，筛选切回来它们原样还在，用户没取消过的东西
/// 就不会被系统悄悄取消。
///
/// [retainExisting] 仍作用于内部集：那管的是「条目真的没了」，与「暂时看不见」
/// 是两回事。
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

  /// [_visibleLoose] / [_visibleCollections] 的 Set 视图。
  Set<String> _visibleLooseSet = const <String>{};
  Set<int> _visibleCollectionSet = const <int>{};

  /// [looseKeys] / [collectionIds] 的缓存。
  ///
  /// 这两个 getter 是**每卡渲染都要问一次**的热路径：两个库页判断勾选态用的是
  /// `looseKeys.contains(key)`（不是 [isSelected]），而「全部视频」的列表布局还会
  /// 一次性急切构建全部行。若每次取值都现算交集，全选之后就是 O(n²)——5000 条
  /// 库每帧两千五百万次集合插入。选中集或可见集一变就置空，下次取值重算一次。
  Set<String>? _looseKeysView;
  Set<int>? _collectionIdsView;

  /// 选中集或可见集变了：两个派生视图作废。**任何**改动 [_looseKeys] /
  /// [_collectionIds] / [_visibleLooseSet] / [_visibleCollectionSet] 的地方都必须
  /// 调它，否则读到的是陈旧交集（守卫见
  /// `media_selection_controller_test.dart` 的「派生视图缓存」）。
  void _invalidateViews() {
    _looseKeysView = null;
    _collectionIdsView = null;
  }

  /// 长按扫选期间的基线选中集（拖动只在基线上叠加区间，故手指往回滑能取消刚
  /// 刷上的那一段，而不是只增不减）。null = 当前没在扫选。
  Set<String>? _dragBaseLoose;
  Set<int>? _dragBaseCollections;

  /// 多选态是否开启。
  bool get active => _active;

  /// 已选散卡键（只读视图，**只含当前可见的**——见库文档「可见性约束」）。
  Set<String> get looseKeys => _looseKeysView ??= UnmodifiableSetView<String>(
        <String>{
          for (final String key in _looseKeys)
            if (_visibleLooseSet.contains(key)) key,
        },
      );

  /// 已选合集 id（只读视图，**只含当前可见的**）。
  Set<int> get collectionIds => _collectionIdsView ??= UnmodifiableSetView<int>(
        <int>{
          for (final int id in _collectionIds)
            if (_visibleCollectionSet.contains(id)) id,
        },
      );

  /// 内部选中集（含当前不可见的）。仅供测试比对派生视图是否陈旧。
  @visibleForTesting
  Set<String> get retainedLooseKeys => UnmodifiableSetView<String>(_looseKeys);

  /// 内部合集选中集（含当前不可见的）。仅供测试。
  @visibleForTesting
  Set<int> get retainedCollectionIds =>
      UnmodifiableSetView<int>(_collectionIds);

  /// 当前锚点（无则 null）。仅供测试与调试断言。
  @visibleForTesting
  SelectionSlot? get anchor => _anchor;

  /// 是否正在长按扫选。
  bool get isRangeDragging => _dragBaseLoose != null;

  /// 选中总数（散卡 + 合集），**只数可见的**——底栏「已选 N」必须等于用户屏幕上
  /// 勾着的卡片数。
  int get length => looseKeys.length + collectionIds.length;

  bool get isEmpty => length == 0;

  bool get isNotEmpty => length != 0;

  /// 内部选中总数（含当前不可见的）。仅供测试断言「不可见项确实无损保留」。
  @visibleForTesting
  int get retainedLength => _looseKeys.length + _collectionIds.length;

  /// 勾过、但当前被筛选/搜索挡住看不见的格数。
  ///
  /// 批量操作只作用于可见的那部分（见库文档「可见性约束」），这个差值就是**这次
  /// 不会被处理的条数**。确认框必须把它说出来：否则用户勾了 5 个、切个筛选只剩
  /// 3 个可见，点删除只删 3 个，剩下 2 个既没被删也没被告知，退出多选态时还一起
  /// 丢掉——他会以为 5 个都删了。
  int get hiddenSelectedCount => retainedLength - length;

  bool isSelected(SelectionSlot slot) => slot.isCollection
      ? _collectionIds.contains(slot.collectionId) &&
          _visibleCollectionSet.contains(slot.collectionId)
      : _looseKeys.contains(slot.looseKey) &&
          _visibleLooseSet.contains(slot.looseKey);

  /// 当前可见的散卡键（[setVisibleOrder] 最近一次登记的那份）。
  ///
  /// 这是「屏幕上真的有哪些散卡」的唯一真相源：区间选、扫选、全选 / 反选的候选
  /// 都该取它，而不是各自再推一遍资格判据——两处推导迟早漂开。
  List<String> get visibleLooseKeys => _visibleLoose;

  /// 每帧写入当前**可见顺序**（排序 / 搜索 / 筛选之后的实际渲染顺序）。
  ///
  /// 顺序一变就清锚点——见库文档「锚点」。内容相同（每帧新建但等值的列表）
  /// 视为未变，不会误清。
  ///
  /// 返回**这次是否真的变了**。调用方据此补一帧：可见顺序是 build 期算出来的
  /// （筛选 / 排序的结果），而底栏计数这类消费者在同一帧更早的位置就读过选中集，
  /// 会比可见序滞后一帧，且没有后续 setState 把这一帧补上。
  bool setVisibleOrder({
    required List<String> loose,
    required List<int> collections,
  }) {
    if (listEquals(_visibleLoose, loose) &&
        listEquals(_visibleCollections, collections)) {
      return false;
    }
    _visibleLoose = List<String>.unmodifiable(loose);
    _visibleCollections = List<int>.unmodifiable(collections);
    _visibleLooseSet = loose.toSet();
    _visibleCollectionSet = collections.toSet();
    _invalidateViews();
    _anchor = null;
    return true;
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
    _invalidateViews();
    for (final SelectionSlot each in range) {
      _addSlot(each);
    }
  }

  /// 长按扫选结束：丢弃基线，锚点保留（用户接着 Shift 点击可继续延展）。
  void endRangeDrag() {
    _dragBaseLoose = null;
    _dragBaseCollections = null;
  }

  /// 全选：把调用方给出的候选（= 当前可见的那些格）全部并入。
  void selectAll({
    required Iterable<String> loose,
    required Iterable<int> collections,
  }) {
    _looseKeys.addAll(loose);
    _collectionIds.addAll(collections);
    _invalidateViews();
  }

  /// 反选：**在候选集内**取补集。锚点失效（选中集与最后一次点击已无关系）。
  ///
  /// 只翻候选集内的格：候选集之外（当前不可见）的选中项原样保留。此前这里
  /// `clear()` 后重填，在候选集恒等于「全部可选项」的旧设计下看不出问题，但那会
  /// 把用户在别的筛选档位下选中、此刻只是看不见的条目一并抹掉——与库文档
  /// 「可见性约束」里「没取消过的东西不会被系统悄悄取消」直接冲突。
  void invert({
    required Iterable<String> loose,
    required Iterable<int> collections,
  }) {
    final Set<String> looseCandidates = loose.toSet();
    final Set<int> collectionCandidates = collections.toSet();
    final Set<String> invertedLoose = looseCandidates.difference(_looseKeys);
    final Set<int> invertedCollections =
        collectionCandidates.difference(_collectionIds);
    _looseKeys
      ..removeAll(looseCandidates)
      ..addAll(invertedLoose);
    _collectionIds
      ..removeAll(collectionCandidates)
      ..addAll(invertedCollections);
    _invalidateViews();
    _anchor = null;
  }

  /// 清空选中集但**留在**多选态（批量操作落库后调用）。
  void clearSelection() => _resetSelection();

  /// 把选中集收敛到**当前真实存在**的条目上，返回被剔掉的个数。
  ///
  /// 为什么必须有这一步：选中集只按用户点击增删，从不随库变化剪枝。多选态可以
  /// 存活很久（切 tab、进详情页再回来都保留），期间下拉同步 / 互联对端下架 /
  /// 另一处删除都可能让某个 key 对应的行消失。此时选中集里留着的就是**幽灵键**，
  /// 后果不是「少做一件事」而是三种糟得多的结局：
  ///
  /// - 批量打标签：`bookTags` 对 `bookKey` 有外键，插幽灵键抛
  ///   `SqliteException`，而弹窗的确定按钮把落库 await 在自己的 loading 态里，
  ///   异常一抛 loading 永不落地 → **弹窗卡死**，用户只能杀进程。
  /// - 批量组合：`addToCollection` 同样撞外键，且它挂在 `void` 回调后面无人
  ///   catch，用户看到的是「点了没反应」，会以为合集建好了。
  /// - 计数虚高：底部「已选 N 项」和确认框里的 N 都把幽灵键算进去，用户是**照着
  ///   一个虚数在做删除决定**。
  ///
  /// [loose] / [collections] 传当前真实存在的全集（不是「可见」全集——被搜索或
  /// 标签筛掉的条目仍然存在，用户先勾后筛是合法用法，不该被悄悄剔掉）。
  ///
  /// 剔除后锚点失效：它可能正指着被剔掉的那一格。
  ///
  /// 返回的是**用户看得见的**那部分里被剔掉了多少（[length] 口径）：这个数字直接
  /// 进「已跳过 M 项 / 共 N 项」提示，而提示要跟他屏幕上的东西对得上。当前不可见
  /// 的幽灵键同样被剔干净，只是不计入 M。锚点则按内部集判——它可能正指着一个不
  /// 可见但已被剔掉的格。
  int retainExisting({
    required Set<String> loose,
    required Set<int> collections,
  }) {
    final int before = length;
    final int retainedBefore = retainedLength;
    _looseKeys.retainWhere(loose.contains);
    _collectionIds.retainWhere(collections.contains);
    _invalidateViews();
    if (retainedLength != retainedBefore) _anchor = null;
    return before - length;
  }

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
    _invalidateViews();
  }

  /// 移除并返回「原本在不在集合里」。
  bool _removeSlot(SelectionSlot slot) {
    final bool removed = slot.isCollection
        ? _collectionIds.remove(slot.collectionId)
        : _looseKeys.remove(slot.looseKey);
    if (removed) _invalidateViews();
    return removed;
  }

  void _resetSelection() {
    _looseKeys.clear();
    _collectionIds.clear();
    _invalidateViews();
    _anchor = null;
    _dragBaseLoose = null;
    _dragBaseCollections = null;
  }
}

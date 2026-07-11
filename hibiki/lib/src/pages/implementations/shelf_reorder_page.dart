import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 UI v2 Phase E：整理排序页（用户拍板砍掉重做）。
///
/// 旧页的分组/合并/移出全挂在 v38 迁移后已死的 Series 模型上——合集成员显示成无框
/// 散卡、拖并会重复建组、合集整体位置永远写不进 [MediaCollections].sortOrder。重做后
/// 唯一分组真相源 = MediaCollections/MediaCollectionItems（与主网格 `groupByCollections`
/// 同源）；折叠系列卡模式 / 成员子页框模式（零消费者的死复杂度）一并删除。
/// 拖拽原语复用共享 [HibikiReorderableGrid]，不重写。

/// 一个可重排条目的最小身份：稳定键 + 媒体类型（持久化到 ShelfEntries 用）+ 渲染载荷。
/// 调用方（书架 / 视频库）把当前可见条目各构造一个传进来。
class ShelfReorderItem {
  const ShelfReorderItem({
    required this.mediaType,
    required this.entryKey,
    required this.card,
    this.groupId,
    this.groupFrame,
  });

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey/srtUid/videoBookUid。
  final String entryKey;

  /// 卡片渲染 widget（复用书架 / 视频库既有卡片构造，不重写渲染）。**未套分组框**——
  /// 合集成员的同色分组框由本页据 [groupFrame] 在渲染时叠加，不预先烘进本字段。这样
  /// 「移出合集」只需清掉 [groupFrame]（[copyAsLoose]）即可就地变回无框散卡。
  final Widget card;

  /// 本条目当前归属的合集 id（展示折叠归属 = 最小 collectionId，与主网格一致）。
  /// null = 散条目。拖合并语义（建新合集 / 并入目标合集 / 跨合集移动）依赖它判定。
  final int? groupId;

  /// 合集成员的分组框渲染参数。非空 = 本条目是某合集的内联展开成员，本页把 [card]
  /// 套进同色 [SeriesReorderFrame]；null = 散条目，无框渲染。
  final GroupFrameData? groupFrame;

  /// 复制本条目，仅覆盖 [groupId]（合并后本地即时刷新 UI 用，避免整页重查）。
  ShelfReorderItem copyWithGroupId(int? newGroupId) => ShelfReorderItem(
        mediaType: mediaType,
        entryKey: entryKey,
        card: card,
        groupId: newGroupId,
        groupFrame: groupFrame,
      );

  /// 把本条目降级为**散条目**：清掉合集归属与分组框，[card] 原样保留。于是本页就地把
  /// 它渲染成无框散卡、继续留在整理列表里——「移出合集」后条目不凭空消失（归属已在
  /// 调用方 onRemove 里写库移除）。
  ShelfReorderItem copyAsLoose() => ShelfReorderItem(
        mediaType: mediaType,
        entryKey: entryKey,
        card: card,
        groupId: null,
        groupFrame: null,
      );
}

/// 合集成员分组框（[SeriesReorderFrame] 视觉复用）的渲染参数。由调用方构造（颜色按
/// collectionId 稳定分配、首成员叠合集名 header），本页据此套框。数据与渲染分离，让
/// 「移出合集」只清 [ShelfReorderItem.groupFrame] 就能就地把成员变回无框散卡。
class GroupFrameData {
  const GroupFrameData({
    required this.color,
    required this.showHeader,
    required this.groupName,
    required this.memberCount,
  });

  /// 本合集分组框颜色（同合集所有成员同色；由调用方按 collectionId 稳定分配）。
  final Color color;

  /// 是否本合集内联展开后的首个成员（仅首个成员叠合集名 header）。
  final bool showHeader;

  /// 合集名（header 文本）。
  final String groupName;

  /// 合集成员总数（header 角标）。
  final int memberCount;
}

/// 退出重排时的批量持久化回调：把最终顺序（下标 = 新 sortOrder）交给调用方落盘。
typedef ShelfReorderPersist = Future<void> Function(
    List<ShelfReorderItem> orderedItems);

/// 拖合并回调：把被拖条目 [dragged] 合并进目标条目 [target]。调用方据二者当前
/// [ShelfReorderItem.groupId] 决定建新合集 / 并入目标合集 / 跨合集移动，执行真实
/// DB 写并返回「合并后应归属的合集 id」。返回 null 表示本次合并未生效。
typedef ShelfReorderMerge = Future<int?> Function(
    ShelfReorderItem dragged, ShelfReorderItem target);

/// 点 overlay 移出按钮对某成员条目执行移出的结果。
class ShelfRemoveResult {
  const ShelfRemoveResult({required this.removed, required this.groupEmptied});

  /// 是否真的移出了（用户确认并写库）；false = 取消 / 未变。
  final bool removed;

  /// 移出后合集是否已空（[HibikiDatabase.removeFromCollection] 会自动删空合集）。
  final bool groupEmptied;
}

/// 移出某成员条目回调。由调用方弹确认框 + 执行真实 DB 移出
/// （removeFromCollection，空合集自动清理），返回 [ShelfRemoveResult]。
/// null（默认）= 不启用移出。
typedef ShelfReorderRemove = Future<ShelfRemoveResult> Function(
    ShelfReorderItem item);

/// TODO-616 B2 独立重排页：「整理排序」入口 push 进来，在独立有界覆盖层里用
/// [HibikiReorderableGrid] 二维拖拽重排，退出时把最终顺序批量回写 ShelfEntries +
/// MediaCollections.sortOrder。
///
/// 与批量选择模态互斥由调用方保证（进重排前先 `_exitSelectionMode`）。
class ShelfReorderPage extends StatefulWidget {
  const ShelfReorderPage({
    required this.title,
    required this.initialItems,
    required this.onPersist,
    required this.cellExtent,
    this.childAspectRatio,
    this.mainAxisExtent,
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 12,
    this.feedbackBorderRadius,
    this.onMerge,
    this.onRemove,
    this.overlayCornerBottomInset = 0,
    super.key,
  });

  final String title;
  final List<ShelfReorderItem> initialItems;
  final ShelfReorderPersist onPersist;
  final double cellExtent;
  final double? childAspectRatio;
  final double? mainAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final BorderRadius? feedbackBorderRadius;

  /// 拖合并回调。null（默认）= 不启用拖合并 = 纯重排（不向网格传
  /// canMergeInto/onMergeIntoTarget）。非空时启用「拖到目标卡中心 → 合并成合集」。
  final ShelfReorderMerge? onMerge;

  /// 焦点/点击移出按钮触发的移出回调。null（默认）= 不启用移出。
  final ShelfReorderRemove? onRemove;

  /// overlayActionBuilder（「移出合集」按钮）在整格里额外抬高的底部内距：书卡底部有
  /// [kShelfTitleFooterHeight] 高的标题 footer，调用方传其高度把按钮抬到封面区不压
  /// 书名；无 footer 页传 0（默认）。按钮放封面右下角，避开右上角类型徽章与左上角
  /// 合集名 header。
  final double overlayCornerBottomInset;

  @override
  State<ShelfReorderPage> createState() => _ShelfReorderPageState();
}

class _ShelfReorderPageState extends State<ShelfReorderPage> {
  /// 当前顺序（拖拽实时改）。下标即新 sortOrder。
  late List<ShelfReorderItem> _items;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _items = List<ShelfReorderItem>.of(widget.initialItems);
  }

  void _onReorder(int from, int to) {
    setState(() {
      final ShelfReorderItem moved = _items.removeAt(from);
      _items.insert(to, moved);
      _dirty = true;
    });
  }

  /// 「被拖条目 [from] 能否合并进目标条目 [target]」判据。仅 [ShelfReorderPage.onMerge]
  /// 非空时才作为回调传入网格。规则：
  /// - 拖到自己 → false。
  /// - 目标属某合集：被拖条目并入该合集（散条目加入 / 其它合集成员移动过来）；
  ///   已同合集 → false（无变化）。
  /// - 目标是散条目：被拖条目也是散条目 → true（两散条目建新合集）；被拖条目已属
  ///   某合集 → false（把成员拖到散卡上语义含糊，保守拒绝，绝不破坏现有重排）。
  bool _canMergeInto(int from, int target) {
    if (from < 0 ||
        target < 0 ||
        from >= _items.length ||
        target >= _items.length) {
      return false;
    }
    if (from == target) return false;
    final ShelfReorderItem dragged = _items[from];
    final ShelfReorderItem dst = _items[target];
    final int? targetGroup = dst.groupId;
    if (targetGroup != null) {
      return dragged.groupId != targetGroup;
    }
    return dragged.groupId == null;
  }

  /// 「把被拖条目 [from] 合并进目标条目 [target]」执行。落点已由网格校验过中心命中
  /// 半径且 [_canMergeInto] 放行；这里委托 [ShelfReorderPage.onMerge] 做真实 DB 写
  /// （建新合集 / 并入目标合集 / 跨合集移动），成功后本地把两条目的 groupId 即时更新
  /// 并标脏，弹提示（分组框视觉待退出重载后按新归属重建）。
  Future<void> _onMergeIntoTarget(int from, int target) async {
    final ShelfReorderMerge? onMerge = widget.onMerge;
    if (onMerge == null) return;
    if (from < 0 ||
        target < 0 ||
        from >= _items.length ||
        target >= _items.length ||
        from == target) {
      return;
    }
    final ShelfReorderItem dragged = _items[from];
    final ShelfReorderItem dst = _items[target];
    final int? mergedGroupId = await onMerge(dragged, dst);
    if (!mounted || mergedGroupId == null) return;
    // 被拖卡就地继承目标卡的分组框（色/合集名；不再整页残留旧合集框）。目标是
    // 散卡（新建合集）时两者都暂无框，退出重载后按新归属重建完整视觉。
    final GroupFrameData? targetFrame = dst.groupFrame;
    final GroupFrameData? inheritedFrame = targetFrame == null
        ? null
        : GroupFrameData(
            color: targetFrame.color,
            showHeader: false,
            groupName: targetFrame.groupName,
            memberCount: targetFrame.memberCount,
          );
    setState(() {
      // 用稳定身份重定位下标（await 期间列表理论上不变，但稳妥起见按 key 重查）。
      for (int i = 0; i < _items.length; i++) {
        final ShelfReorderItem it = _items[i];
        if (it.mediaType == dragged.mediaType &&
            it.entryKey == dragged.entryKey) {
          _items[i] = ShelfReorderItem(
            mediaType: it.mediaType,
            entryKey: it.entryKey,
            card: it.card,
            groupId: mergedGroupId,
            groupFrame: inheritedFrame,
          );
        } else if (it.mediaType == dst.mediaType &&
            it.entryKey == dst.entryKey) {
          _items[i] = it.copyWithGroupId(mergedGroupId);
        }
      }
      _dirty = true;
    });
    if (mounted) HibikiToast.show(msg: t.collection_merged_hint);
  }

  /// 把某成员条目移出合集——点 overlay 移出按钮触发。委托 [ShelfReorderPage.onRemove]
  /// 弹确认 + 真实 DB 写；确认移出后条目**不消失**——就地降级为散条目（[copyAsLoose]
  /// 清掉分组框；归属已在 onRemove 里写库移除）继续留在整理列表里。
  Future<void> _onRemoveOutside(int index) async {
    final ShelfReorderRemove? onRemove = widget.onRemove;
    if (onRemove == null || index < 0 || index >= _items.length) return;
    final ShelfReorderItem item = _items[index];
    final ShelfRemoveResult result = await onRemove(item);
    if (!mounted || !result.removed) return;
    setState(() => _items[index] = _items[index].copyAsLoose());
  }

  /// 每格右上角焦点驱动移出按钮。用 [HibikiIconButton]（自动注册焦点目标，Tab 可达 +
  /// Enter 触发），点击/确认走同一 [_onRemoveOutside] 移出流程。
  Widget _buildRemoveOverlay(int index) {
    // 「移出合集」按钮放封面**右下角**——避开右上角书籍类型徽章与左上角合集名 header。
    // [overlayCornerBottomInset] 把它从整格底部抬到封面区，别压住书卡底部的标题 footer。
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          end: 4,
          bottom: widget.overlayCornerBottomInset + 4,
        ),
        child: Material(
          color: Colors.transparent,
          child: HibikiIconButton(
            tooltip: t.collection_remove_member,
            icon: Icons.remove_circle_outline,
            onTap: () => _onRemoveOutside(index),
          ),
        ),
      ),
    );
  }

  /// 渲染一个重排条目：合集成员（[ShelfReorderItem.groupFrame] 非空）套同色
  /// [SeriesReorderFrame] 分组框，其余（散条目）直接用原卡。框在此处按数据叠加，故
  /// 「移出合集」清掉 groupFrame 后同一条目就地变回无框散卡（不整条丢弃）。
  Widget _buildItemCard(ShelfReorderItem item) {
    final GroupFrameData? frame = item.groupFrame;
    if (frame == null) return item.card;
    return SeriesReorderFrame(
      color: frame.color,
      showHeader: frame.showHeader,
      seriesName: frame.groupName,
      memberCount: frame.memberCount,
      child: item.card,
    );
  }

  Widget _buildGrid() {
    return HibikiReorderableGrid(
      itemCount: _items.length,
      cellExtent: widget.cellExtent,
      childAspectRatio: widget.childAspectRatio,
      mainAxisExtent: widget.mainAxisExtent,
      crossAxisSpacing: widget.crossAxisSpacing,
      mainAxisSpacing: widget.mainAxisSpacing,
      padding: const EdgeInsets.all(12),
      feedbackBorderRadius: widget.feedbackBorderRadius,
      keyForIndex: (int i) => ValueKey<String>(
          'reorder_${_items[i].mediaType}_${_items[i].entryKey}'),
      itemBuilder: (BuildContext context, int i) => _buildItemCard(_items[i]),
      onReorder: _onReorder,
      // 仅当调用方提供 onMerge 时才启用拖合并手势；否则两回调为 null，网格走纯重排。
      canMergeInto: widget.onMerge == null ? null : _canMergeInto,
      onMergeIntoTarget: widget.onMerge == null ? null : _onMergeIntoTarget,
      // 焦点/点击移出按钮：只挂在**合集成员格**（groupId 非空）上，散卡格不挂
      // （散卡没有「移出合集」语义）。
      overlayActionBuilder: widget.onRemove == null
          ? null
          : (BuildContext ctx, int i) =>
              _items[i].groupId != null ? _buildRemoveOverlay(i) : null,
    );
  }

  /// 正在执行退出收口（落盘 -> 真正 pop）。置位后 [PopScope.canPop] 翻成 true，
  /// 使我们手动发起的 pop 直接放行，不再被本 PopScope 二次拦截。
  bool _finishing = false;

  /// 退出页面：脏了才落盘（避免无改动空写），落盘后真正弹回。
  ///
  /// 根因（TODO-947）：旧实现 `canPop:false` 恒定 + `_finish()` 永远走
  /// `maybePop()`——而 `maybePop` 又触发本页 `PopScope.onPopInvokedWithResult`
  /// (`didPop==false`) -> 再调 `_finish()` -> 再 `maybePop()`，形成无限递归，页面
  /// 永远退不出。这里改为：进入收口先置 `_finishing=true` 让 `canPop` 翻 true，
  /// 落盘后用 `Navigator.pop()` 真正出栈。
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    if (_dirty) {
      await widget.onPersist(_items);
      if (mounted) HibikiToast.show(msg: t.shelf_sort_saved);
    }
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    // 翻开 canPop 闸门，让下面这次 pop 不再被本 PopScope 拦回。
    setState(() {});
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 收口期（_finishing）放行真正的 pop；其余时候拦下裸返回，先落盘再退出。
      canPop: _finishing,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _finish();
      },
      child: Scaffold(
        // TODO-1228：不放确认 ✓ 动作——本页语义是「自动保存」：拖合并/移出是即时 DB
        // 写，重排顺序由上面的 PopScope 在任何退出路径统一经 [_finish] 落盘。
        // leading 用共享 [HibikiIconButton]（自动注册焦点目标）而非隐式 BackButton。
        appBar: AppBar(
          leading: HibikiIconButton(
            tooltip: t.back,
            icon: Icons.arrow_back,
            onTap: _finish,
          ),
          title: Text(widget.title),
        ),
        body: SafeArea(child: _buildGrid()),
      ),
    );
  }
}

/// 整理页落盘拆分（合集**内联展开成员**模式）：每个条目都是一条真实 [ShelfEntries]
/// 行（散条目 + 合集成员一视同仁），下标 → [ShelfEntries].sortOrder；每个合集额外把
/// [MediaCollections].sortOrder 设为该合集**首个成员的下标**（首次出现即最小下标）。
/// 这样回主区经 `groupByCollections` 混排后，合集行落在其首成员位置、成员按 sortOrder
/// 升序重新聚拢。纯函数，widget/DB-free，供单测直接断言落盘契约。
({
  List<({String mediaType, String entryKey, int sortOrder})> entryOrders,
  List<({int groupId, int sortOrder})> groupOrders,
}) unfoldedShelfReorderOrders(List<ShelfReorderItem> ordered) {
  final List<({String mediaType, String entryKey, int sortOrder})> entryOrders =
      <({String mediaType, String entryKey, int sortOrder})>[];
  // groupId → 该合集首个成员的下标（首次出现即最小，因按序遍历）。
  final Map<int, int> groupFirstIndex = <int, int>{};
  for (int i = 0; i < ordered.length; i++) {
    final ShelfReorderItem it = ordered[i];
    entryOrders
        .add((mediaType: it.mediaType, entryKey: it.entryKey, sortOrder: i));
    final int? gid = it.groupId;
    if (gid != null) {
      groupFirstIndex.putIfAbsent(gid, () => i);
    }
  }
  final List<({int groupId, int sortOrder})> groupOrders =
      <({int groupId, int sortOrder})>[
    for (final MapEntry<int, int> e in groupFirstIndex.entries)
      (groupId: e.key, sortOrder: e.value),
  ];
  return (entryOrders: entryOrders, groupOrders: groupOrders);
}

/// 整理页最终顺序 → 每个合集的组内成员有序清单（按出现序），喂
/// [HibikiDatabase.reorderCollectionItems] 把 MediaCollectionItems.sortIndex 与
/// 库页行序（ShelfEntries.sortOrder）写穿同源——否则整理后库页顺序与播放器剧集
/// 面板/连播、合集详情页（按 sortIndex 取）分叉。纯函数，供两页共用与单测。
Map<int, List<({String mediaType, String entryKey})>> collectionMemberOrders(
  List<ShelfReorderItem> ordered,
) {
  final Map<int, List<({String mediaType, String entryKey})>> out =
      <int, List<({String mediaType, String entryKey})>>{};
  for (final ShelfReorderItem it in ordered) {
    final int? gid = it.groupId;
    if (gid == null) continue;
    (out[gid] ??= <({String mediaType, String entryKey})>[])
        .add((mediaType: it.mediaType, entryKey: it.entryKey));
  }
  return out;
}

/// 拖拽合并的共享 DB 执行（书架 / 视频库两页共用）：
/// - 目标已属某合集 → 并入该合集；
/// - 目标是散条目 → 建新合集（[defaultName]），目标与被拖条目双双加入；
/// - 被拖条目原属**其它**合集 → 移动语义：先从旧合集移除（空合集由
///   [HibikiDatabase.removeFromCollection] 自动清理）再加入。
/// [HibikiDatabase.addToCollection] 幂等（INSERT OR IGNORE），目标已在合集内不重复。
/// 返回合并后归属的合集 id。
Future<int> mergeReorderItemsIntoCollection({
  required HibikiDatabase database,
  required String defaultName,
  required ShelfReorderItem dragged,
  required ShelfReorderItem target,
}) async {
  final int collectionId =
      target.groupId ?? await database.createMediaCollection(defaultName);
  final int? draggedOld = dragged.groupId;
  if (draggedOld != null && draggedOld != collectionId) {
    await database.removeFromCollection(
        draggedOld, dragged.mediaType, dragged.entryKey);
  }
  await database.addToCollection(
      collectionId, target.mediaType, target.entryKey);
  await database.addToCollection(
      collectionId, dragged.mediaType, dragged.entryKey);
  return collectionId;
}

/// 移出合集的共享 DB 执行（确认框由调用方弹）：removeFromCollection（空合集自动删），
/// 返回该合集是否因此被清空删除。
Future<bool> removeReorderItemFromCollection({
  required HibikiDatabase database,
  required int collectionId,
  required ShelfReorderItem item,
}) async {
  await database.removeFromCollection(
      collectionId, item.mediaType, item.entryKey);
  return await database.getMediaCollectionById(collectionId) == null;
}

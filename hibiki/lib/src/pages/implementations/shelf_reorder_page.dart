import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

/// 一个可重排条目的最小身份：稳定键 + 媒体类型（持久化到 ShelfEntries 用）+ 渲染载荷。
/// 调用方（书架 / 视频库）把当前可见的本地 + 远端条目各构造一个传进来。
class ShelfReorderItem {
  const ShelfReorderItem({
    required this.mediaType,
    required this.entryKey,
    required this.card,
    this.seriesId,
    this.seriesCardId,
  });

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey/srtUid/videoBookUid；远端 = downloadId/video.id。
  final String entryKey;

  /// 卡片渲染 widget（复用书架 / 视频库既有卡片构造，不重写渲染）。
  final Widget card;

  /// 本条目当前归属的系列 id（TODO-947-② PR2）。null = 散书（不属任何系列）。
  /// 调用方从已加载的 ShelfEntries 归属映射填入；拖合并语义（建新系列 / 并入已有
  /// 系列）依赖它判定。不传 [ShelfReorderPage.onMerge] 时本字段被忽略（纯重排不读它）。
  final int? seriesId;

  /// 折叠后系列卡标识（TODO-947 方案A）。非空 = 本条目**本身就是一张折叠系列卡**
  /// （渲染的是 [SeriesShelfCard]，entryKey = 'series_<id>' 的合成键，不对应任何真书
  /// 条目）；null = 普通散书 / 系列成员条目。持久化时据此分流：系列卡下标回写
  /// [SeriesRow.sortOrder]，散书条目下标回写 [ShelfEntries.sortOrder]。点进（tap）
  /// 也据此判定「进入系列成员视图」（散书 tap 不进入）。
  final int? seriesCardId;

  /// 复制本条目，仅覆盖 [seriesId]（合并后本地即时刷新 UI 用，避免整页重查）。
  /// [seriesCardId] 原样保留（散书合并不会把散书变成折叠卡，语义不变）。
  ShelfReorderItem copyWithSeriesId(int? newSeriesId) => ShelfReorderItem(
        mediaType: mediaType,
        entryKey: entryKey,
        card: card,
        seriesId: newSeriesId,
        seriesCardId: seriesCardId,
      );
}

/// 退出重排时的批量持久化回调：把最终顺序（下标 = 新 sortOrder）交给调用方落盘。
typedef ShelfReorderPersist = Future<void> Function(
    List<ShelfReorderItem> orderedItems);

/// 拖合并回调（TODO-947-② PR2）：把被拖条目 [dragged] 合并进目标条目 [target]。
/// 调用方据二者当前 seriesId 决定建新系列还是并入已有系列，执行真实 DB 写并返回
/// 「[dragged]、[target] 合并后应归属的系列 id」（建新 = 新建系列 id；并入 = 目标已
/// 有系列 id）。返回 null 表示本次合并未生效（不写 DB / 不刷新）。
typedef ShelfReorderMerge = Future<int?> Function(
    ShelfReorderItem dragged, ShelfReorderItem target);

/// 点进一张折叠系列卡的回调（TODO-947 方案A ③④⑤）：把该系列 [seriesId] 交给调用方，
/// 由调用方推入成员视图（拖出成员 = setSeriesForEntry(null)、成员重排）。await 返回后
/// 本页用 [ShelfReorderRebuild] 重取折叠条目刷新（成员可能已被拖出/重排）。
typedef ShelfReorderEnterSeries = Future<void> Function(int seriesId);

/// 进入系列成员视图返回后重取折叠条目（TODO-947 方案A）：成员被拖出会让系列成员数变化
/// （甚至系列清空后消失），本页据此重建 [ShelfReorderPage.initialItems] 的当前快照，
/// 避免显示过期折叠卡。null（默认，如系列成员子页自身）= 不重取。
typedef ShelfReorderRebuild = Future<List<ShelfReorderItem>> Function();

/// TODO-616 B2 独立重排页：长按 / 「编辑排序」入口 push 进来，在独立有界覆盖层里用
/// [HibikiReorderablegrid] 二维拖拽重排，退出时把最终顺序批量回写 ShelfEntries。
///
/// 与书架批量选择模态互斥由调用方保证（进重排前先 `_exitSelectionMode`）。本页是独立
/// route，普通模式长按上下文菜单不受影响。
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
    this.onEnterSeries,
    this.rebuildItems,
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

  /// 拖合并回调（TODO-947-② PR2）。null（默认）= 不启用拖合并 = 纯重排（不向网格传
  /// canMergeInto/onMergeIntoTarget，行为与历史逐像素一致）。非空时启用「拖到目标卡
  /// 中心 → 合并成合集」手势。
  final ShelfReorderMerge? onMerge;

  /// 点进折叠系列卡的回调（TODO-947 方案A ③）。null（默认，如系列成员子页）= 折叠卡
  /// 点击无效（本页无系列卡，也不需要「进入」）。非空时点一张系列卡（[ShelfReorderItem
  /// .seriesCardId] 非空）触发它进入成员视图。
  final ShelfReorderEnterSeries? onEnterSeries;

  /// 进入成员视图返回后重取折叠条目（TODO-947 方案A）。null = 不重取（保持当前 _items）。
  final ShelfReorderRebuild? rebuildItems;

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

  /// 「被拖条目 [from] 能否合并进目标条目 [target]」判据（TODO-947-② PR2，保守 Phase1）。
  /// 仅 [ShelfReorderPage.onMerge] 非空时才作为回调传入网格。规则：
  /// - 拖到自己 → false。
  /// - 目标已属某系列：被拖条目并入该系列；若被拖条目已在同一系列 → false（无变化）。
  /// - 目标是散书（无系列）：
  ///   - 被拖条目也是散书 → true（两散书建新系列）。
  ///   - 被拖条目已属某系列 → false（本期不做「把系列成员拖到散书上」这类复杂语义，
  ///     绝不破坏现有重排）。
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
    final int? targetSeries = dst.seriesId;
    if (targetSeries != null) {
      // 并入目标已有系列；已同系列则不重复合并。
      return dragged.seriesId != targetSeries;
    }
    // 目标是散书：仅当被拖条目也是散书时建新系列。
    return dragged.seriesId == null;
  }

  /// 「把被拖条目 [from] 合并进目标条目 [target]」执行（TODO-947-② PR2）。落点已由
  /// 网格校验过中心命中半径且 [_canMergeInto] 放行；这里委托 [ShelfReorderPage.onMerge]
  /// 做真实 DB 写（建新系列 / 并入已有系列），成功（返回非空系列 id）后本地把两条目的
  /// seriesId 即时更新并标脏，弹提示。
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
    final int? mergedSeriesId = await onMerge(dragged, dst);
    if (!mounted || mergedSeriesId == null) return;
    setState(() {
      // 用稳定身份重定位下标（await 期间列表理论上不变，但稳妥起见按 key 重查）。
      for (int i = 0; i < _items.length; i++) {
        final ShelfReorderItem it = _items[i];
        if ((it.mediaType == dragged.mediaType &&
                it.entryKey == dragged.entryKey) ||
            (it.mediaType == dst.mediaType && it.entryKey == dst.entryKey)) {
          _items[i] = it.copyWithSeriesId(mergedSeriesId);
        }
      }
      _dirty = true;
    });
    if (mounted) HibikiToast.show(msg: t.series_merged_hint);
  }

  /// TODO-947 方案A ③：点一张折叠系列卡（[ShelfReorderItem.seriesCardId] 非空）进入
  /// 成员视图。散书 / 系列成员卡（seriesCardId==null）点击一律无效（R2：排序态点书不
  /// 开书），未提供 [ShelfReorderPage.onEnterSeries] 时同样无效。返回后若提供
  /// [ShelfReorderPage.rebuildItems] 则重取折叠条目刷新（成员可能已被拖出 / 系列已清空）。
  Future<void> _onActivate(int index) async {
    if (index < 0 || index >= _items.length) return;
    final int? seriesCardId = _items[index].seriesCardId;
    final ShelfReorderEnterSeries? onEnter = widget.onEnterSeries;
    if (seriesCardId == null || onEnter == null) return;
    await onEnter(seriesCardId);
    if (!mounted) return;
    final ShelfReorderRebuild? rebuild = widget.rebuildItems;
    if (rebuild == null) return;
    final List<ShelfReorderItem> fresh = await rebuild();
    if (!mounted) return;
    setState(() {
      _items = fresh;
      // 拖出成员改的是 seriesId 归属（各自 setSeriesForEntry），未触碰 sortOrder，故
      // 折叠层顺序本身没被本页改动——不置 _dirty，退出时不做无谓 sortOrder 回写。
    });
  }

  /// 正在执行退出收口（落盘 -> 真正 pop）。置位后 [PopScope.canPop] 翻成 true，
  /// 使我们手动发起的 pop 直接放行，不再被本 PopScope 二次拦截。
  bool _finishing = false;

  /// 退出页面：脏了才落盘（避免无改动空写），落盘后真正弹回。
  ///
  /// 根因（TODO-947）：旧实现 `canPop:false` 恒定 + `_finish()` 永远走
  /// `maybePop()`——而 `maybePop` 又触发本页 `PopScope.onPopInvokedWithResult`
  /// (`didPop==false`) -> 再调 `_finish()` -> 再 `maybePop()`，形成无限递归，页面
  /// 永远退不出（用户报「左上角退出未响应」）。这里改为：进入收口先置
  /// `_finishing=true` 让 `canPop` 翻 true，落盘后用 `Navigator.pop()` 真正出栈
  /// （此时 PopScope 放行，didPop==true 直接 return，不再递归）。
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
        appBar: AppBar(
          title: Text(widget.title),
          actions: <Widget>[
            HibikiIconButton(
              tooltip: t.shelf_done,
              icon: Icons.check,
              onTap: _finish,
            ),
          ],
        ),
        body: SafeArea(
          child: HibikiReorderableGrid(
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
            itemBuilder: (BuildContext context, int i) => _items[i].card,
            onReorder: _onReorder,
            // 仅当调用方提供 onMerge 时才启用拖合并手势；否则两回调为 null，网格走
            // 纯重排（与历史逐像素一致，绝不破坏现有行为）。
            canMergeInto: widget.onMerge == null ? null : _canMergeInto,
            onMergeIntoTarget:
                widget.onMerge == null ? null : _onMergeIntoTarget,
            // 仅当调用方提供 onEnterSeries 时才识别 tap（进折叠系列卡成员视图）；否则
            // null = 网格不装 tap 识别器 = 纯拖拽（与历史一致，散书页/成员子页不受影响）。
            onActivate: widget.onEnterSeries == null ? null : _onActivate,
          ),
        ),
      ),
    );
  }
}

/// TODO-947 方案A：把折叠重排页给回的有序条目按下标拆成两套持久化目标——散书条目
/// （[ShelfReorderItem.seriesCardId] == null）→ ShelfEntries.sortOrder 三元组；折叠系列卡
/// （seriesCardId != null）→ (系列 id, 下标) 对回写 Series.sortOrder。两者共用同一折叠
/// 下标 i，保证回主网格经 groupAndSortShelfEntries 混排后顺序与折叠视图一致。纯函数，
/// widget/DB-free，供单测直接断言拆分正确（散书落 ShelfEntries、系列卡落 Series）。
({
  List<({String mediaType, String entryKey, int sortOrder})> entryOrders,
  List<({int seriesId, int sortOrder})> seriesOrders,
}) splitShelfReorderOrders(List<ShelfReorderItem> ordered) {
  final List<({String mediaType, String entryKey, int sortOrder})> entryOrders =
      <({String mediaType, String entryKey, int sortOrder})>[];
  final List<({int seriesId, int sortOrder})> seriesOrders =
      <({int seriesId, int sortOrder})>[];
  for (int i = 0; i < ordered.length; i++) {
    final ShelfReorderItem it = ordered[i];
    final int? seriesCardId = it.seriesCardId;
    if (seriesCardId != null) {
      seriesOrders.add((seriesId: seriesCardId, sortOrder: i));
    } else {
      entryOrders
          .add((mediaType: it.mediaType, entryKey: it.entryKey, sortOrder: i));
    }
  }
  return (entryOrders: entryOrders, seriesOrders: seriesOrders);
}

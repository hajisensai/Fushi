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

  /// 复制本条目，仅覆盖 [seriesId]（合并后本地即时刷新 UI 用，避免整页重查）。
  ShelfReorderItem copyWithSeriesId(int? newSeriesId) => ShelfReorderItem(
        mediaType: mediaType,
        entryKey: entryKey,
        card: card,
        seriesId: newSeriesId,
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
          ),
        ),
      ),
    );
  }
}

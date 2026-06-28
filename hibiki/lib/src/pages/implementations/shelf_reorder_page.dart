import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

/// 一个可重排条目的最小身份：稳定键 + 媒体类型（持久化到 ShelfEntries 用）+ 渲染载荷。
/// 调用方（书架 / 视频库）把当前可见的本地 + 远端条目各构造一个传进来。
class ShelfReorderItem {
  const ShelfReorderItem({
    required this.mediaType,
    required this.entryKey,
    required this.card,
  });

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey/srtUid/videoBookUid；远端 = downloadId/video.id。
  final String entryKey;

  /// 卡片渲染 widget（复用书架 / 视频库既有卡片构造，不重写渲染）。
  final Widget card;
}

/// 退出重排时的批量持久化回调：把最终顺序（下标 = 新 sortOrder）交给调用方落盘。
typedef ShelfReorderPersist = Future<void> Function(
    List<ShelfReorderItem> orderedItems);

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

  /// 退出页面：脏了才落盘（避免无改动空写），落盘后弹回。
  Future<void> _finish() async {
    if (_dirty) {
      await widget.onPersist(_items);
      if (mounted) HibikiToast.show(msg: t.shelf_sort_saved);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 拦截裸返回：先把顺序落盘再真正退出（didPop 时已无 context 可用，故走
      // canPop:false + 手动 maybePop 收口持久化）。
      canPop: false,
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
          ),
        ),
      ),
    );
  }
}

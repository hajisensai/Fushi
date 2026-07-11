import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/series_detail_page.dart'
    show showSeriesNameDialog;
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：网格式合集详情页（书架用；书籍合集是无序手动分组，与 playlist 的
/// 有序剧集列表 [MediaCollectionDetailPage] 区分）。渲染成员卡网格（[memberCardBuilder]
/// 由调用方按 mediaType/entryKey 提供），支持重命名 / 删除合集（删只解链、绝不删条目）+
/// 逐个「移出合集」（移空后合集自删）。
class MediaCollectionGridDetailPage extends StatefulWidget {
  const MediaCollectionGridDetailPage({
    required this.database,
    required this.collection,
    required this.memberCardBuilder,
    required this.onChanged,
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 按成员 (mediaType, entryKey) 渲染卡片；返回 null = 该成员当前不可见（孤儿/被过滤），
  /// 详情页跳过它。
  final Widget? Function(String mediaType, String entryKey) memberCardBuilder;

  /// 改名 / 删除 / 移出成员后刷新书架。
  final VoidCallback onChanged;

  @override
  State<MediaCollectionGridDetailPage> createState() =>
      _MediaCollectionGridDetailPageState();
}

class _MediaCollectionGridDetailPageState
    extends State<MediaCollectionGridDetailPage> {
  late String _name;
  List<MediaCollectionItemRow> _rows = const <MediaCollectionItemRow>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _name = widget.collection.name;
    _reload();
  }

  Future<void> _reload() async {
    final List<MediaCollectionItemRow> rows =
        await widget.database.getCollectionItems(widget.collection.id);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _rename() async {
    final String? newName = await showSeriesNameDialog(
      context: context,
      title: t.rename_collection,
      initialName: _name,
    );
    if (newName == null || newName == _name) return;
    await widget.database.renameMediaCollection(widget.collection.id, newName);
    if (!mounted) return;
    setState(() => _name = newName);
    widget.onChanged();
  }

  Future<void> _delete() async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.delete_collection),
        content: Text(t.delete_collection_confirm),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.delete_collection),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.database.deleteMediaCollection(widget.collection.id);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  Future<void> _removeMember(MediaCollectionItemRow row) async {
    await widget.database.removeFromCollection(
        widget.collection.id, row.mediaType, row.entryKey);
    if (!mounted) return;
    widget.onChanged();
    // 移空后 removeFromCollection 已自删合集 → 退回上层。
    final List<MediaCollectionItemRow> remaining =
        await widget.database.getCollectionItems(widget.collection.id);
    if (!mounted) return;
    if (remaining.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final List<({MediaCollectionItemRow row, Widget card})> members =
        <({MediaCollectionItemRow row, Widget card})>[
      for (final MediaCollectionItemRow r in _rows)
        if (widget.memberCardBuilder(r.mediaType, r.entryKey)
            case final Widget card)
          (row: r, card: card),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: <Widget>[
          IconButton(
            tooltip: t.rename_collection,
            icon: const Icon(Icons.drive_file_rename_outline),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: t.delete_collection,
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : members.isEmpty
                ? Center(child: Text(t.collection_empty))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 160 / 260,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: members.length,
                    itemBuilder: (BuildContext context, int i) {
                      final ({MediaCollectionItemRow row, Widget card}) m =
                          members[i];
                      return Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          m.card,
                          PositionedDirectional(
                            top: 2,
                            end: 2,
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                tooltip: t.remove_from_series,
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => _removeMember(m.row),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：网格式合集详情页（书架用；成员按 sortIndex 有序渲染，与 playlist
/// 的剧集列表 [MediaCollectionDetailPage] 同一顺序真相源）。渲染成员卡网格
/// （[memberCardBuilder] 由调用方按 mediaType/entryKey 提供），支持重命名 / 删除合集
/// （删只解链、绝不删条目）+ 逐个「移出合集」（移空后合集自删）+ AppBar 一键排序
/// （按名称/导入时间写穿 sortIndex；v1 不做网格拖拽，用户拍板）。
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

  /// 一键整理（排序交互重设计层次 B2；书合集 v1 不做网格拖拽，用户拍板——卷序 =
  /// 名称 natural 序几乎恒正确）：按名称 / 导入时间（旧→新）重排全表并落盘
  /// sortIndex（`reorderCollectionItems`），库页合集行同源立即同序。标题/导入
  /// 时间从 epub/srt 两表现查（成员行只有身份键）。
  Future<void> _applyOneKeySort({required bool byTitle}) async {
    final List<EpubBookRow> epubs = await widget.database.getAllEpubBooks();
    final List<SrtBookRow> srts = await widget.database.getAllSrtBooks();
    final Map<String, ({String title, int importedAt})> meta =
        <String, ({String title, int importedAt})>{
      for (final EpubBookRow r in epubs)
        'epub|${r.bookKey}': (title: r.title, importedAt: r.importedAt),
      for (final SrtBookRow r in srts)
        'srt|${r.uid}': (title: r.title, importedAt: r.importedAt),
    };
    ({String title, int importedAt}) metaOf(MediaCollectionItemRow r) =>
        meta['${r.mediaType}|${r.entryKey}'] ??
        (title: r.entryKey, importedAt: 0);
    final List<MediaCollectionItemRow> next =
        List<MediaCollectionItemRow>.of(_rows)
          ..sort((MediaCollectionItemRow a, MediaCollectionItemRow b) {
            final ({String title, int importedAt}) ma = metaOf(a);
            final ({String title, int importedAt}) mb = metaOf(b);
            if (byTitle) {
              final int c = naturalCompare(ma.title, mb.title);
              return c != 0 ? c : ma.importedAt.compareTo(mb.importedAt);
            }
            final int c = ma.importedAt.compareTo(mb.importedAt);
            return c != 0 ? c : naturalCompare(ma.title, mb.title);
          });
    if (!mounted) return;
    setState(() => _rows = next);
    await widget.database.reorderCollectionItems(
      widget.collection.id,
      <({String mediaType, String entryKey})>[
        for (final MediaCollectionItemRow r in next)
          (mediaType: r.mediaType, entryKey: r.entryKey),
      ],
    );
    widget.onChanged();
  }

  /// AppBar「排序」菜单：按名称（natural，卷1<卷2<卷10）/ 按导入时间一键重排。
  Widget _buildSortMenu() {
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.sort_by_alpha, size: 20),
          onPressed: () => _applyOneKeySort(byTitle: true),
          child: Text(t.collection_sort_by_title),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.history, size: 20),
          onPressed: () => _applyOneKeySort(byTitle: false),
          child: Text(t.collection_sort_by_imported),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          IconButton(
        tooltip: t.sort_by,
        icon: const Icon(Icons.sort),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _rename() async {
    final String? newName = await showCollectionNameDialog(
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
          _buildSortMenu(),
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

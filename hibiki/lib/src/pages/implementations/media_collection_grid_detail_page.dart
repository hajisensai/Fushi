import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
import 'package:hibiki/src/utils/components/hibiki_reorderable_grid.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：网格式合集详情页（书架用；成员按 sortIndex 有序渲染，与 playlist
/// 的剧集列表 [MediaCollectionDetailPage] 同一顺序真相源）。渲染成员卡网格
/// （[memberCardBuilder] 由调用方按 mediaType/entryKey 提供），支持重命名 / 删除合集
/// （删只解链、绝不删条目）+ AppBar 一键排序（按名称/导入时间写穿 sortIndex）+
/// **网格拖拽精修**（[HibikiReorderableGrid]，消缩放 2D 拖排，落盘 sortIndex 与库页
/// 合集行同源）。「移出合集」/「打开」走卡片**长按 / 右键**上下文菜单（不再是每卡右上角
/// 浮动按钮），移空后合集自删。
class MediaCollectionGridDetailPage extends StatefulWidget {
  const MediaCollectionGridDetailPage({
    required this.database,
    required this.collection,
    required this.memberCardBuilder,
    required this.onChanged,
    this.onOpenMember,
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 按成员 (mediaType, entryKey) 渲染卡片；返回 null = 该成员当前不可见（孤儿/被过滤），
  /// 详情页跳过它。
  final Widget? Function(String mediaType, String entryKey) memberCardBuilder;

  /// 打开某成员（点卡片 / 菜单「打开」）。null = 不提供打开（仅菜单移出）。卡片自身的
  /// 手势被 [IgnorePointer] 屏蔽（避免其内部 long-press 与网格触摸拖拽争用），故「打开」
  /// 统一经此回调，由调用方按 (mediaType, entryKey) 找到条目并打开。
  final void Function(String mediaType, String entryKey)? onOpenMember;

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

  /// 当前**可见**成员行（memberCardBuilder 返回非空的子集，与 [_rows] 同序）。build
  /// 时刷新；拖拽 onReorder 的 from/to 是这份列表的下标，用它把可见序回写进 [_rows]
  /// 全表（孤儿行追加到末尾），再一次落盘 sortIndex。
  List<MediaCollectionItemRow> _visibleRows = const <MediaCollectionItemRow>[];
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

  /// 一键整理（排序交互重设计层次 B2；覆盖 95% 场景，配合网格拖拽精修）：按名称 /
  /// 导入时间（旧→新）重排全表并落盘 sortIndex（`reorderCollectionItems`），库页合集行
  /// 同源立即同序。标题/导入时间从 epub/srt 两表现查（成员行只有身份键）。
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

  /// 网格拖拽落序：from/to 是**可见**成员下标（[_visibleRows]）。先在可见序上应用
  /// removeAt/insert，再把可见序回写进 [_rows] 全表（孤儿行——当前不可见——追加到末尾，
  /// 保持落盘为一次全表 sortIndex 回写、不与孤儿旧序交错），最后 `reorderCollectionItems`
  /// 一次落盘。库页合集行 / 播放器换集读同一 `getCollectionItems`，落盘即同序。
  Future<void> _onReorder(int from, int to) async {
    if (from == to) return;
    final List<MediaCollectionItemRow> visible =
        List<MediaCollectionItemRow>.of(_visibleRows);
    if (from < 0 || from >= visible.length || to < 0 || to >= visible.length) {
      return;
    }
    final MediaCollectionItemRow moved = visible.removeAt(from);
    visible.insert(to, moved);
    final Set<String> visibleKeys = <String>{
      for (final MediaCollectionItemRow r in visible)
        '${r.mediaType}|${r.entryKey}',
    };
    final List<MediaCollectionItemRow> orphans = <MediaCollectionItemRow>[
      for (final MediaCollectionItemRow r in _rows)
        if (!visibleKeys.contains('${r.mediaType}|${r.entryKey}')) r,
    ];
    final List<MediaCollectionItemRow> next = <MediaCollectionItemRow>[
      ...visible,
      ...orphans,
    ];
    setState(() {
      _rows = next;
      _visibleRows = visible;
    });
    await widget.database.reorderCollectionItems(
      widget.collection.id,
      <({String mediaType, String entryKey})>[
        for (final MediaCollectionItemRow r in next)
          (mediaType: r.mediaType, entryKey: r.entryKey),
      ],
    );
    widget.onChanged();
  }

  /// 长按（原地松手）/ 右键上下文菜单：移出合集 + 可选打开。照仓库既有卡片长按菜单
  /// 范式（书卡 onLongPress/onSecondaryTap 弹条目动作）。
  Future<void> _showMemberMenu(
      MediaCollectionItemRow row, Offset globalPosition) async {
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    );
    final _MemberMenuAction? action = await showMenu<_MemberMenuAction>(
      context: context,
      position: position,
      items: <PopupMenuEntry<_MemberMenuAction>>[
        if (widget.onOpenMember != null)
          PopupMenuItem<_MemberMenuAction>(
            value: _MemberMenuAction.open,
            child: Row(
              children: <Widget>[
                const Icon(Icons.open_in_new, size: 20),
                const SizedBox(width: 12),
                Text(t.collection_open),
              ],
            ),
          ),
        PopupMenuItem<_MemberMenuAction>(
          value: _MemberMenuAction.remove,
          child: Row(
            children: <Widget>[
              const Icon(Icons.remove_circle_outline, size: 20),
              const SizedBox(width: 12),
              Text(t.collection_remove_member),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MemberMenuAction.open:
        widget.onOpenMember?.call(row.mediaType, row.entryKey);
      case _MemberMenuAction.remove:
        await _removeMember(row);
    }
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
    _visibleRows = <MediaCollectionItemRow>[
      for (final ({MediaCollectionItemRow row, Widget card}) m in members)
        m.row,
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
                : _buildMemberGrid(members),
      ),
    );
  }

  /// 成员网格：消缩放 2D 拖排（[HibikiReorderableGrid]）。列数按可用宽度换算
  /// （每卡 ≤180 宽，与旧 [SliverGridDelegateWithMaxCrossAxisExtent] 一致）。卡片包在
  /// [IgnorePointer] 里——其内部 InkWell 的 long-press 会与网格触摸长按拖拽争用手势
  /// 竞技场（LongPress 在 500ms 抢先夺胜 → 触摸永远拖不动），故屏蔽卡片自身手势，由
  /// 网格统一接管：轻点→打开、按下/长按拖→重排、长按松手/右键→上下文菜单。
  Widget _buildMemberGrid(
      List<({MediaCollectionItemRow row, Widget card})> members) {
    const double spacing = 12;
    const double maxCardWidth = 180;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth - 24; // 两侧各 12 padding
        final int cols = available <= 0
            ? 1
            : ((available + spacing) / (maxCardWidth + spacing))
                .ceil()
                .clamp(1, 1 << 30);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: HibikiReorderableGrid(
            itemCount: members.length,
            crossAxisCount: cols,
            childAspectRatio: 160 / 260,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            feedbackBorderRadius: HibikiBorderRadius.card,
            keyForIndex: (int i) => ValueKey<String>(
                '${members[i].row.mediaType}|${members[i].row.entryKey}'),
            onReorder: _onReorder,
            onActivateItem: widget.onOpenMember == null
                ? null
                : (int i) => widget.onOpenMember!(
                    members[i].row.mediaType, members[i].row.entryKey),
            onContextMenu: (int i, Offset globalPosition) =>
                _showMemberMenu(members[i].row, globalPosition),
            itemBuilder: (BuildContext context, int i) =>
                IgnorePointer(child: members[i].card),
          ),
        );
      },
    );
  }
}

/// 成员卡上下文菜单动作。
enum _MemberMenuAction { open, remove }

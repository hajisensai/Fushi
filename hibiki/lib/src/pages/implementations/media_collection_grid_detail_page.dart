import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/collection_shelf_row.dart'
    show unifiedShelfCardLayout;
import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart'
    show GalgameCustomData;
import 'package:hibiki/src/pages/implementations/collection_detail_shared.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show kShelfBookCardAspectRatio;
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
    this.onDeleteMembersMedia,
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 按成员 (mediaType, entryKey) 渲染卡片；返回 null = 该成员当前不可见（孤儿/被过滤），
  /// 详情页跳过它。
  ///
  /// [onRemoveFromCollection]（详情页在此处注入 `() => _removeMember(row)`）供调用方把
  /// 「移出合集」接进该成员卡的**长按/右键对话框**（[MediaItemDialogPage] 的 extraActions）。
  /// 触摸/鼠标经网格接管走上下文菜单移出，但键盘/手柄用户是聚焦长按 A 弹卡片自身的
  /// [MediaItemDialogPage]（不经网格指针路径），若不注入就没有移出项——故给可聚焦对话框
  /// 补一条「移出合集」DialogAction，键盘/手柄用户不失能。
  final Widget? Function(
    String mediaType,
    String entryKey, {
    VoidCallback? onRemoveFromCollection,
  }) memberCardBuilder;

  /// 打开某成员（点卡片 / 菜单「打开」）。null = 不提供打开（仅菜单移出）。卡片自身的
  /// 手势被 [IgnorePointer] 屏蔽（避免其内部 long-press 与网格触摸拖拽争用），故「打开」
  /// 统一经此回调，由调用方按 (mediaType, entryKey) 找到条目并打开。
  final void Function(String mediaType, String entryKey)? onOpenMember;

  /// 改名 / 删除 / 移出成员后刷新书架。
  final VoidCallback onChanged;

  /// 「删除合集」时可选连同成员本体一起删（默认不删，保持只解链语义）。调用方
  /// （持 AppModel + [ReaderHibikiSource] / [VideoBookRepository]）注入：按每个成员
  /// (mediaType, entryKey) 删底层书/有声书/视频本体 + 磁盘副本，并释放空间。
  /// null = 详情页不提供该选项（确认框不显示复选框），退回纯解链删除。
  final Future<void> Function(List<MediaCollectionItemRow> members)?
      onDeleteMembersMedia;

  @override
  State<MediaCollectionGridDetailPage> createState() =>
      _MediaCollectionGridDetailPageState();
}

class _MediaCollectionGridDetailPageState
    extends State<MediaCollectionGridDetailPage>
    with CollectionDetailShared<MediaCollectionGridDetailPage> {
  late String _name;
  List<MediaCollectionItemRow> _rows = const <MediaCollectionItemRow>[];

  @override
  HibikiDatabase get detailDatabase => widget.database;
  @override
  MediaCollectionRow get detailCollection => widget.collection;
  @override
  String get detailName => _name;
  @override
  set detailName(String value) => _name = value;
  @override
  VoidCallback get detailOnChanged => widget.onChanged;

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
  /// 同源立即同序。标题/导入时间从 epub/srt/galgames 三表现查（成员行只有身份键）。
  Future<void> _applyOneKeySort({required bool byTitle}) async {
    final List<EpubBookRow> epubs = await widget.database.getAllEpubBooks();
    final List<SrtBookRow> srts = await widget.database.getAllSrtBooks();
    // game 成员（游戏库页打开本详情页）：标题取用户覆盖名（customDataJson.name）
    // 优先，回落本地默认名；导入时间 = addedAt。查不到的类型仍走下面的
    // (entryKey, 0) 兜底，不 throw。
    final List<GalgameRow> games = await widget.database.getAllGalgames();
    final Map<String, ({String title, int importedAt})> meta =
        <String, ({String title, int importedAt})>{
      for (final EpubBookRow r in epubs)
        MediaKind.epub.compositeKey(r.bookKey): (
          title: r.title,
          importedAt: r.importedAt
        ),
      for (final SrtBookRow r in srts)
        MediaKind.srt.compositeKey(r.uid): (
          title: r.title,
          importedAt: r.importedAt
        ),
      for (final GalgameRow r in games)
        MediaKind.game.compositeKey(r.id): (
          title: GalgameCustomData.decode(r.customDataJson).name ?? r.name,
          importedAt: r.addedAt,
        ),
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
  /// 菜单外壳共享 [buildDetailSortMenu]。
  Widget _buildSortMenu() {
    return buildDetailSortMenu(
      onSortByTitle: () => _applyOneKeySort(byTitle: true),
      onSortByImported: () => _applyOneKeySort(byTitle: false),
    );
  }

  Future<void> _delete() async {
    // 仅当调用方注入了删本体回调、且合集当前有成员时，才给用户「连同书一起删」
    // 勾选行；否则退回纯解链删除（老行为，零变化）。确认框统一走 PR-0 的
    // [HibikiDestructiveConfirmDialog]（经 [confirmDetailCollectionDelete]）。
    final bool canDeleteMembers =
        widget.onDeleteMembersMedia != null && _rows.isNotEmpty;
    final HibikiDestructiveConfirmResult? result =
        await confirmDetailCollectionDelete(
      checkboxLabel: canDeleteMembers ? t.delete_collection_also_books : null,
    );
    if (result == null || !mounted) return;
    // 先删成员本体（书/有声书/视频 DB 行 + 磁盘副本），再解散容器。删书不动合集引用
    // 行，故随后的 deleteMediaCollection 负责清掉残留引用 + 写合集级墓碑。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget
          .onDeleteMembersMedia!(List<MediaCollectionItemRow>.of(_rows));
    }
    await widget.database.deleteMediaCollection(widget.collection.id);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  Future<void> _removeMember(MediaCollectionItemRow row) async {
    // 按成员行值移出（行值可能是对端未知种类）→ raw 版，保证移得掉。
    await widget.database.removeFromCollectionRaw(
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
  /// removeAt/insert，再**保序合并**回 [_rows] 全表：遍历原 _rows，可见槽按新可见序
  /// 依次填入、孤儿行（当前不可见——被书架标签筛选掉的成员）留在原下标。绝不把隐藏
  /// 成员挤到表尾——否则筛选态下一次拖拽就把全部隐藏成员从原位挤到末尾落盘。最后
  /// `reorderCollectionItems` 一次落盘。库页合集行 / 播放器换集读同一 `getCollectionItems`，
  /// 落盘即同序。
  Future<void> _onReorder(int from, int to) async {
    if (from == to) return;
    final List<MediaCollectionItemRow> visible =
        List<MediaCollectionItemRow>.of(_visibleRows);
    if (from < 0 || from >= visible.length || to < 0 || to >= visible.length) {
      return;
    }
    final MediaCollectionItemRow moved = visible.removeAt(from);
    visible.insert(to, moved);
    // 保序合并：可见槽（key 命中 visibleKeys）按 visible 的新顺序依次消费，孤儿行按
    // 其在原 _rows 中的下标原地保留。visible 的成员集合与拖前一致（只是被置换顺序），
    // 故可见槽数 == visible.length，vi 恰好消费完，不会越界。
    final Set<String> visibleKeys = <String>{
      for (final MediaCollectionItemRow r in visible)
        '${r.mediaType}|${r.entryKey}',
    };
    int vi = 0;
    final List<MediaCollectionItemRow> next = <MediaCollectionItemRow>[
      for (final MediaCollectionItemRow r in _rows)
        if (visibleKeys.contains('${r.mediaType}|${r.entryKey}'))
          visible[vi++]
        else
          r,
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
    // BUG-781（与 BUG-129/261/381 同族）：[globalPosition] 是网格右键 / 触摸长按
    // 回调报的真实视口坐标；而 showMenu 的 RelativeRect 落在根 Navigator 的
    // Overlay 坐标系，该 Overlay 位于全局 [HibikiAppUiScale]（FittedBox 整体缩放）
    // 的缩放画布内。直接把真实视口坐标当 Overlay 本地坐标喂进去，界面大小≠100%
    // 时菜单会偏离点击点 factor≈scale（scale=0.5 时约偏半个点击坐标、数百像素）。
    // 用 Overlay 的 RenderBox.globalToLocal 沿真实渲染变换链换算——中间的 FittedBox
    // 缩放被 render transform 自动吸收，对任意 scale 自洽无残差；scale=1 时变换为
    // 单位阵，逐像素等价（零行为变化，向后兼容）。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(anchor, anchor),
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

  /// [availableWidth] 是这条 AppBar 实际拿到的约束宽（由 [LayoutBuilder] 下发）。
  AppBar _buildAppBar(double availableWidth) => AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        // BUG-1184：同合集详情页——窄屏把次要动作收进溢出菜单，给合集名让出宽度。
        actions: narrowAwareAppBarActions(
          availableWidth: availableWidth,
          alwaysVisible: <Widget>[_buildSortMenu()],
          collapsible: <HibikiAppBarAction>[
            HibikiAppBarAction(
              icon: Icons.drive_file_rename_outline,
              label: t.rename_collection,
              onPressed: renameDetailCollection,
            ),
            HibikiAppBarAction(
              icon: Icons.sell_outlined,
              label: t.tag_label,
              onPressed: editDetailCollectionTags,
            ),
            HibikiAppBarAction(
              icon: Icons.delete_outline,
              label: t.delete_collection,
              onPressed: _delete,
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final List<({MediaCollectionItemRow row, Widget card})> members =
        <({MediaCollectionItemRow row, Widget card})>[
      for (final MediaCollectionItemRow r in _rows)
        if (widget.memberCardBuilder(
          r.mediaType,
          r.entryKey,
          onRemoveFromCollection: () => _removeMember(r),
        )
            case final Widget card)
          (row: r, card: card),
    ];
    _visibleRows = <MediaCollectionItemRow>[
      for (final ({MediaCollectionItemRow row, Widget card}) m in members)
        m.row,
    ];
    return Scaffold(
      // BUG-1186：折叠判据取这条 AppBar 的局部约束宽，不是整窗宽（同合集详情页）。
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              _buildAppBar(constraints.maxWidth),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? Center(child: adaptiveIndicator(context: context))
            : members.isEmpty
                ? HibikiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.collection_empty,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      buildDetailTagChips(),
                      Expanded(child: _buildMemberGrid(members)),
                    ],
                  ),
      ),
    );
  }

  /// 成员网格：消缩放 2D 拖排（[HibikiReorderableGrid]）。卡尺寸对齐书架散卡口径
  /// （[readerShelfGridExtentForLayout] 断点 → [unifiedShelfCardLayout] 列数、
  /// [kShelfBookCardAspectRatio] 槽比）——旧实现自带 180+ceil+硬编码 160/260，
  /// 同一本书在书架与详情页两个网格里尺寸口径不一致（巡检 PR-3）。卡片包在
  /// [IgnorePointer] 里——其内部 InkWell 的 long-press 会与网格触摸长按拖拽争用手势
  /// 竞技场（LongPress 在 500ms 抢先夺胜 → 触摸永远拖不动），故屏蔽卡片自身手势，由
  /// 网格统一接管：轻点→打开、按下/长按拖→重排、长按松手/右键→上下文菜单；
  /// 指针悬停反馈由外层 [_HoverableMemberCard] 补回（IgnorePointer 灭掉了 InkWell
  /// 自身 hover，桌面上成员卡曾读作死内容）。
  Widget _buildMemberGrid(
      List<({MediaCollectionItemRow row, Widget card})> members) {
    const double spacing = 12;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth - 24; // 两侧各 12 padding
        final double targetWidth = readerShelfGridExtentForLayout(
          mediaWidth: MediaQuery.sizeOf(context).width,
          contentWidth: available,
        );
        final ({int columns, double cardWidth}) layout = unifiedShelfCardLayout(
          availableWidth: available > 0 ? available : targetWidth,
          targetWidth: targetWidth,
          spacing: spacing,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: HibikiReorderableGrid(
            itemCount: members.length,
            crossAxisCount: layout.columns,
            childAspectRatio: kShelfBookCardAspectRatio,
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
                _HoverableMemberCard(child: members[i].card),
          ),
        );
      },
    );
  }
}

/// 成员卡的指针悬停反馈壳：卡片本体仍被 [IgnorePointer] 屏蔽（长按拖拽手势竞技场
/// 决策不变），悬停高亮由本壳的 [MouseRegion]（默认 opaque，自身参与命中测试）
/// 提供——桌面指针划过成员卡有可交互反馈，触摸/手柄路径零变化。
class _HoverableMemberCard extends StatefulWidget {
  const _HoverableMemberCard({required this.child});

  final Widget child;

  @override
  State<_HoverableMemberCard> createState() => _HoverableMemberCardState();
}

class _HoverableMemberCardState extends State<_HoverableMemberCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(child: widget.child),
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  // eink 半透明 hover 罩合成抖动灰 → 改描边反馈。
                  decoration: eink
                      ? BoxDecoration(
                          border: Border.all(color: tokens.surfaces.outline),
                          borderRadius: tokens.radii.cardRadius,
                        )
                      : BoxDecoration(
                          color:
                              tokens.surfaces.onSurface.withValues(alpha: 0.08),
                          borderRadius: tokens.radii.cardRadius,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 成员卡上下文菜单动作。
enum _MemberMenuAction { open, remove }

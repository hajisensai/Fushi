import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/media/tags/tag_drop.dart' show reorderTagsSafely;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/utils.dart';

/// MD3 底部让给悬浮新建按钮的高度：常规 FAB 56dp + Scaffold 的 FAB 外边距
/// （上下各一份 [kFloatingActionButtonMargin]），末行才不被悬浮按钮压住。
/// FAB 几何是组件尺寸而非间距令牌，集中在这一处具名常量里。
const double _kMd3FabClearance = 56 + kFloatingActionButtonMargin * 2;

const List<int> kTagPresetColors = [
  0xFFEF5350, // red
  0xFFEC407A, // pink
  0xFFAB47BC, // purple
  0xFF5C6BC0, // indigo
  0xFF42A5F5, // blue
  0xFF26A69A, // teal
  0xFF66BB6A, // green
  0xFFFFA726, // orange
  0xFF8D6E63, // brown
  0xFF78909C, // blue grey
  0xFF7E57C2, // deep purple
  0xFF26C6DA, // cyan
  0xFF9CCC65, // light green
  0xFFFFCA28, // amber
  0xFFFF7043, // deep orange
  0xFF8E8E93, // grey
];

/// 标签行长按 / 右键上下文菜单的动作。
enum _TagMenuAction { edit, merge, delete }

class TagManagementPage extends ConsumerStatefulWidget {
  const TagManagementPage({super.key});

  @override
  ConsumerState<TagManagementPage> createState() => _TagManagementPageState();
}

class _TagManagementPageState extends ConsumerState<TagManagementPage> {
  List<BookTagRow> _tags = [];
  final Map<int, int> _bookCounts = {};
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final db = ref.read(appProvider).database;
    final tags = await db.getAllTags();
    final Map<int, int> counts = {};
    for (final tag in tags) {
      counts[tag.id] = await db.countBooksForTag(tag.id);
    }
    if (mounted) {
      setState(() {
        _tags = tags;
        _loaded = true;
        _bookCounts.clear();
        _bookCounts.addAll(counts);
      });
    }
  }

  FushiDatabase get _db => ref.read(appProvider).database;

  Future<void> _createTag() async {
    final result = await _showTagEditDialog(
      title: t.tag_new,
      initialName: _search.text.trim(),
      initialColor: kTagPresetColors[_tags.length % kTagPresetColors.length],
    );
    if (result == null) return;
    try {
      await _db.createTag(result.name, result.color);
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.tag_name_duplicate)),
        );
        return;
      }
      rethrow;
    }
    _invalidateTagProviders();
    await _reload();
  }

  Future<void> _editTag(BookTagRow tag) async {
    final result = await _showTagEditDialog(
      title: tag.name,
      initialName: tag.name,
      initialColor: tag.colorValue,
    );
    if (result == null) return;
    try {
      await _db.updateTag(tag.id, name: result.name, colorValue: result.color);
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.tag_name_duplicate)),
        );
        return;
      }
      rethrow;
    }
    _invalidateTagProviders();
    await _reload();
  }

  /// 标签池变了（新建 / 改名 / 改色 / 合并 / 删除 / 排序）：库页标签栏与卡面 chip
  /// 读的是这些 provider，返回库页时要看到新状态。
  void _invalidateTagProviders() {
    ref.invalidate(allTagsProvider);
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(gameTagMapProvider);
    ref.invalidate(collectionTagMapProvider);
  }

  /// 长按（原地松手）/ 右键 / 行尾「更多」弹出上下文菜单：编辑 + 合并 + 删除。照
  /// 仓库既有卡片长按菜单范式（showMenu + Overlay.globalToLocal 换算）。桌面端鼠标
  /// 既无 swipe 又无 gamepad，删除此前无入口——本菜单补齐，同时保留 tap→编辑、
  /// swipe→删除、gamepad X→删除。
  Future<void> _showTagMenu(BookTagRow tag, Offset globalPosition) async {
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    // 与 media_collection_grid_detail_page 同理：globalPosition 是真实视口坐标，
    // 需经 Overlay 的 RenderBox 换算到根 Navigator Overlay 坐标系，界面缩放≠100%
    // 时才不偏移（scale=1 时为单位阵，逐像素等价）。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(anchor, anchor),
      Offset.zero & overlay.size,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final _TagMenuAction? action = await showFushiMenu<_TagMenuAction>(
      context: context,
      position: position,
      // 共享菜单行（MD3 圆角高亮行 / Apple 玻璃菜单行），删除走危险色。
      items: <PopupMenuEntry<_TagMenuAction>>[
        FushiPopupMenuItem<_TagMenuAction>(
          value: _TagMenuAction.edit,
          label: t.tag_manage_rename,
          icon: Icons.edit_outlined,
        ),
        if (_tags.length > 1)
          FushiPopupMenuItem<_TagMenuAction>(
            value: _TagMenuAction.merge,
            label: t.tag_manage_merge_action,
            icon: Icons.merge_type_rounded,
          ),
        FushiPopupMenuItem<_TagMenuAction>(
          value: _TagMenuAction.delete,
          label: t.dialog_delete,
          icon: Icons.delete_outline,
          color: scheme.error,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _TagMenuAction.edit:
        await _editTag(tag);
      case _TagMenuAction.merge:
        await _mergeTag(tag);
      case _TagMenuAction.delete:
        await _deleteTag(tag);
    }
  }

  /// 合并：选目标标签 → 确认 → 把 [source] 在五种宿主下的全部映射加到目标上，
  /// 再删除 [source]（不改数据层：逐条走各域 typed add，合集走 addTagToCollection）。
  Future<void> _mergeTag(BookTagRow source) async {
    final List<BookTagRow> others =
        _tags.where((BookTagRow tag) => tag.id != source.id).toList();
    if (others.isEmpty) return;
    final BookTagRow? target = await adaptiveModalSheet<BookTagRow>(
      context: context,
      builder: (BuildContext ctx) => _MergeTargetSheet(
        source: source,
        candidates: others,
      ),
    );
    if (target == null || !mounted) return;
    final FushiDestructiveConfirmResult? confirmed =
        await showAppDialog<FushiDestructiveConfirmResult>(
      context: context,
      builder: (_) => FushiDestructiveConfirmDialog(
        title: t.tag_manage_merge_title(name: source.name),
        message: t.tag_manage_merge_confirm(from: source.name, to: target.name),
        confirmLabel: t.tag_manage_merge_action,
        leadingIcon: Icons.merge_type_rounded,
      ),
    );
    if (confirmed == null || !mounted) return;
    await mergeTagInto(_db, sourceId: source.id, targetId: target.id);
    final Set<int> current = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (current.remove(source.id)) {
      current.add(target.id);
      ref.read(selectedTagIdsProvider.notifier).state = current;
    }
    _invalidateTagProviders();
    await _reload();
    if (!mounted) return;
    FushiToast.show(
      msg: t.tag_manage_merge_done(name: target.name),
      severity: ToastSeverity.success,
    );
  }

  Future<void> _deleteTag(BookTagRow tag) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => TagDeleteConfirmationDialog(
        tagName: tag.name,
      ),
    );
    if (confirmed != true) return;

    final current = Set<int>.from(ref.read(selectedTagIdsProvider));
    current.remove(tag.id);
    ref.read(selectedTagIdsProvider.notifier).state = current;

    await _db.deleteTag(tag.id);
    _invalidateTagProviders();
    await _reload();
  }

  /// 拖动把手重排：先改内存序（立即可见），再落库 sortOrder（失败有提示并重载）。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final List<BookTagRow> next = List<BookTagRow>.of(_tags);
    final BookTagRow moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    setState(() => _tags = next);
    final bool ok = await reorderTagsSafely(
      write: () =>
          _db.reorderTags(<int>[for (final BookTagRow tag in next) tag.id]),
    );
    if (!ok) {
      await _reload();
      return;
    }
    _invalidateTagProviders();
  }

  Future<TagEditResult?> _showTagEditDialog({
    required String title,
    required String initialName,
    required int initialColor,
  }) {
    return showAppDialog<TagEditResult>(
      context: context,
      builder: (ctx) => TagEditDialog(
        title: title,
        initialName: initialName,
        initialColor: initialColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    // 行首标签徽记的占位宽：M3E 40 的彩色圆角方，Apple 与行首图标同宽的色点列。
    final double leadingWidth = apple ? metrics.leadingIconSize : 40;
    final String query = _search.text;
    // 搜索态不能拖排（可见序 ≠ 全表序），只列匹配项。
    final bool searching = query.trim().isNotEmpty;
    final List<BookTagRow> visible = searching
        ? filterByMediaSearch<BookTagRow>(
            _tags,
            query,
            (BookTagRow tag) => <String>[tag.name],
          )
        : _tags;

    Widget row(BookTagRow tag, int index, int count) {
      final int items = _bookCounts[tag.id] ?? 0;
      return FushiGroupedListItem(
        index: index,
        count: count,
        // Apple 分隔线从名称起点开始（跳过色点列）。
        separatorIndent:
            metrics.rowHorizontal + leadingWidth + metrics.leadingGap,
        child: Dismissible(
          key: ValueKey(tag.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: EdgeInsets.only(right: tokens.spacing.card),
            // 与合集页滑动删除同一形态：实心 error 底 + onError 图标。
            color: theme.colorScheme.error,
            child: FushiIcon(
              Icons.delete_outline,
              color: theme.colorScheme.onError,
            ),
          ),
          confirmDismiss: (_) async {
            await _deleteTag(tag);
            return false;
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              // Gamepad: X = delete (the swipe-delete equivalent);
              // _deleteTag shows its own confirmation. A stays
              // activate = edit. Other buttons fall through (return
              // false) so focus traversal is unaffected.
              GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
                onInvoke: (GamepadButtonIntent intent) {
                  if (intent.button == GamepadButton.x) {
                    _deleteTag(tag);
                    return true;
                  }
                  return false;
                },
              ),
            },
            child: ContextMenuTrigger(
              // 右键菜单改由绑定表决定唤出键（默认仍是右键）；右键被别的动作占用时自动让位。
              onInvoke: (Offset position) => _showTagMenu(tag, position),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (LongPressStartDetails d) =>
                    _showTagMenu(tag, d.globalPosition),
                child: FushiListItem(
                  minHeight: apple ? null : 64,
                  leading: SizedBox(
                    width: leadingWidth,
                    child: Center(
                      child: _TagBadge(
                        name: tag.name,
                        color: Color(tag.colorValue),
                      ),
                    ),
                  ),
                  title: Text(tag.name),
                  subtitle: Text(t.tag_book_count(count: items)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Builder(
                        builder: (BuildContext buttonContext) =>
                            FushiIconButtonControl(
                          tooltip: t.shelf_toolbar_more,
                          icon: const FushiIcon(Icons.more_vert),
                          onPressed: () {
                            final RenderBox box =
                                buttonContext.findRenderObject()! as RenderBox;
                            _showTagMenu(
                              tag,
                              box.localToGlobal(box.size.center(Offset.zero)),
                            );
                          },
                        ),
                      ),
                      if (!searching)
                        ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: EdgeInsets.all(tokens.spacing.gap),
                            child: FushiIcon(
                              Icons.drag_handle_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  onTap: () => _editTag(tag),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        0,
        tokens.spacing.gap,
        0,
        tokens.spacing.gap * 1.5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TagSummaryCard(
            count: _tags.length,
            tagged: _bookCounts.values.fold<int>(0, (int a, int b) => a + b),
          ),
          SizedBox(height: tokens.spacing.gap * 1.5),
          FushiSearchField(
            fieldKey: const ValueKey<String>('tag_management_search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: t.tag_manage_search_hint,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {},
            onClear: () => setState(_search.clear),
          ),
        ],
      ),
    );

    final EdgeInsets listPadding = EdgeInsets.fromLTRB(
      tokens.spacing.page,
      0,
      tokens.spacing.page,
      // MD3 底部留出 FAB 的位置；Apple 新建在页头，不必留。
      tokens.spacing.gap + (apple ? 0 : _kMd3FabClearance),
    );

    final Widget body;
    if (!_loaded) {
      body = Center(child: adaptiveIndicator(context: context));
    } else if (_tags.isEmpty) {
      body = Center(
        child: FushiPlaceholderMessage(
          icon: Icons.label_outline,
          message: t.tag_no_tags_hint,
          // 空状态直接给「新建标签」主按钮（FAB 之外的第二个入口，首次进来的
          // 用户不必去找右下角）。
          action: FushiFilledButton(
            key: const ValueKey<String>('tag-management-empty-create'),
            onPressed: _createTag,
            child: Text(t.tag_new),
          ),
        ),
      );
    } else if (searching) {
      // 2026-10-06 M3E 重做：顶部摘要色块 + 搜索，下面整池标签读作一个分组
      // （MD3 分段卡 / Apple inset grouped）；行 = 彩色徽记 + 名称 + 条目数 +
      // 更多 + 拖动把手。错峰进场。
      body = FushiEntranceScope(
        child: ListView.builder(
          padding: listPadding,
          itemCount: visible.length + 1,
          itemBuilder: (BuildContext context, int i) {
            if (i == 0) return header;
            return FushiStaggeredEntrance(
              index: i - 1,
              child: row(visible[i - 1], i - 1, visible.length),
            );
          },
        ),
      );
    } else {
      body = FushiEntranceScope(
        child: ReorderableListView.builder(
          header: header,
          padding: listPadding,
          buildDefaultDragHandles: false,
          itemCount: visible.length,
          onReorder: _onReorder,
          itemBuilder: (BuildContext context, int i) => FushiStaggeredEntrance(
            key: ValueKey<int>(visible[i].id),
            index: i,
            child: row(visible[i], i, visible.length),
          ),
        ),
      );
    }

    return FushiPageScaffold(
      title: t.tag_manage_title,
      actions: <Widget>[
        // 新建入口按设计系统各取原生位置：Apple = 页头右上角「+」玻璃圆钮
        // （iOS / macOS 列表页的添加动作在导航栏），MD3 = 右下 FAB。
        if (apple)
          FushiIconButtonControl(
            key: const ValueKey<String>('tag-management-create'),
            icon: const FushiIcon(Icons.add),
            tooltip: t.tag_new,
            onPressed: _createTag,
          ),
      ],
      floatingActionButton: apple
          ? null
          : FushiGlassFab(
              // M3E：扩展 FAB（图标 + 文字），主操作一眼可见。
              child: FloatingActionButton.extended(
                onPressed: _createTag,
                tooltip: t.tag_new,
                icon: const FushiIcon(Icons.add),
                label: Text(t.tag_new),
              ),
            ),
      body: body,
    );
  }
}

/// 页首摘要色块（M3E）：饱和 primaryContainer 大色块 + Display 级大号数字（标签
/// 数）+ 已打标签条目数与拖排提示。Apple 不铺色块，只留文字层级。
class _TagSummaryCard extends StatelessWidget {
  const _TagSummaryCard({required this.count, required this.tagged});

  final int count;
  final int tagged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final bool plain = apple || eink;
    final Color fill =
        plain ? Colors.transparent : theme.colorScheme.primaryContainer;
    final Color fg = plain
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimaryContainer;
    return Container(
      padding: EdgeInsets.all(apple ? tokens.spacing.gap : tokens.spacing.card),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(28),
        border: eink ? Border.all(color: theme.colorScheme.outline) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            '$count',
            style: (apple
                    ? theme.textTheme.headlineMedium
                    : theme.textTheme.displayMedium)
                ?.copyWith(color: fg, fontWeight: FontWeight.w800, height: 1),
          ),
          SizedBox(width: tokens.spacing.gap * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.tag_manage_count(n: count),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: fg, fontWeight: FontWeight.w700),
                ),
                Text(
                  '${t.tag_book_count(count: tagged)} · '
                  '${t.tag_manage_reorder_hint}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listSubtitle
                      .copyWith(color: fg.withValues(alpha: 0.78)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 合并目标选择 sheet：列出其它标签（彩色 chip 云），点一个即返回。
class _MergeTargetSheet extends StatelessWidget {
  const _MergeTargetSheet({required this.source, required this.candidates});

  final BookTagRow source;
  final List<BookTagRow> candidates;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiModalSheetFrame(
      title: t.tag_manage_merge_title(name: source.name),
      leadingIcon: Icons.merge_type_rounded,
      scrollable: true,
      bodyPadding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        0,
        tokens.spacing.card,
        tokens.spacing.card,
      ),
      body: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final BookTagRow tag in candidates)
            FushiTagToggleChip(
              key: ValueKey<String>('tag_merge_target_${tag.id}'),
              label: tag.name,
              color: Color(tag.colorValue),
              state: TagCheckState.none,
              onTap: () => Navigator.of(context).pop(tag),
            ),
        ],
      ),
    );
  }
}

/// 把 [sourceId] 标签合并进 [targetId]：五种宿主（epub / srt / video / game /
/// collection）下凡挂了源标签的，都改挂目标标签（已挂的幂等），最后删除源标签。
/// 走各域 typed 方法（墓碑 / 同步时钟语义留在各自方法里），不改数据层。
Future<void> mergeTagInto(
  FushiDatabase db, {
  required int sourceId,
  required int targetId,
}) async {
  if (sourceId == targetId) return;
  for (final TagHostKind kind in TagHostKind.values) {
    for (final TagAssignmentRow row in await db.getTagAssignmentsForKind(kind)) {
      if (row.tagId != sourceId) continue;
      switch (kind) {
        case TagHostKind.epub:
          await db.addTagToBook(row.entryKey, targetId);
        case TagHostKind.srt:
          await db.addTagToSrtBook(row.entryKey, targetId);
        case TagHostKind.video:
          await db.addTagToVideoBook(row.entryKey, targetId);
        case TagHostKind.game:
          await db.addTagToGame(row.entryKey, targetId);
        case TagHostKind.collection:
          final int? collectionId = collectionIdOfTagEntryKey(row.entryKey);
          if (collectionId != null) {
            await db.addTagToCollection(collectionId, targetId);
          }
      }
    }
  }
  await db.deleteTag(sourceId);
}

/// 标签行首徽记：M3E 是 40 的彩色圆角方（饱和标签色 + 首字），Apple / 墨水屏是
/// 12dp 色点。标签色是用户内容，两套设计系统都如实显示。
class _TagBadge extends StatelessWidget {
  const _TagBadge({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final Color edge = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.12);
    if (isGlassDesign(context) || isEinkTheme(context)) {
      // 共享色块原语的圆点形态（不可点，没有水波 / 焦点）。
      return FushiColorSwatch(
        color: color,
        size: 12,
        shape: FushiColorSwatchShape.dot,
        borderColor: edge,
      );
    }
    final String trimmed = name.trim();
    final String initial =
        trimmed.isEmpty ? '#' : String.fromCharCode(trimmed.runes.first);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: edge),
      ),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: fushiTagOnColor(color),
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class TagDeleteConfirmationDialog extends StatelessWidget {
  const TagDeleteConfirmationDialog({
    required this.tagName,
    super.key,
  });

  final String tagName;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.dialog_delete,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.tag_delete_confirm(name: tagName),
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

class TagEditDialog extends StatefulWidget {
  const TagEditDialog({
    required this.title,
    required this.initialName,
    required this.initialColor,
    super.key,
  });
  final String title;
  final String initialName;
  final int initialColor;

  @override
  State<TagEditDialog> createState() => TagEditDialogState();
}

class TagEditDialogState extends State<TagEditDialog> {
  late final TextEditingController _nameController;
  late int _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedColor = widget.initialColor;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.96,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: widget.title,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 实时预览：输入名称 / 换颜色时，库页里那枚标签 chip 长什么样。
            Center(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _nameController,
                builder: (BuildContext context, TextEditingValue value, _) =>
                    FushiTagToggleChip(
                  label: value.text.trim().isEmpty
                      ? t.tag_name_hint
                      : value.text.trim(),
                  color: Color(_selectedColor),
                  state: TagCheckState.all,
                ),
              ),
            ),
            SizedBox(height: tokens.spacing.gap * 2),
            FushiTextField(
              controller: _nameController,
              labelText: t.tag_name_hint,
              autofocus: true,
            ),
            SizedBox(height: tokens.spacing.gap + 4),
            Text(t.tag_color, style: tokens.type.sectionLabel),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: kTagPresetColors.map((color) {
                final isSelected = _selectedColor == color;
                return FushiColorSwatch(
                  color: Color(color),
                  size: 40,
                  shape: FushiColorSwatchShape.dot,
                  selected: isSelected,
                  onTap: () => setState(() => _selectedColor = color),
                );
              }).toList(),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () {
                final name = _nameController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    FushiSnackBar(content: Text(t.tag_name_empty)),
                  );
                  return;
                }
                Navigator.pop(
                  context,
                  TagEditResult(name: name, color: _selectedColor),
                );
              },
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}

class TagEditResult {
  const TagEditResult({required this.name, required this.color});
  final String name;
  final int color;
}

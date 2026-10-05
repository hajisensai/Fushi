import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
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
];

/// 标签行长按 / 右键上下文菜单的动作。
enum _TagMenuAction { edit, delete }

class TagManagementPage extends ConsumerStatefulWidget {
  const TagManagementPage({super.key});

  @override
  ConsumerState<TagManagementPage> createState() => _TagManagementPageState();
}

class _TagManagementPageState extends ConsumerState<TagManagementPage> {
  List<BookTagRow> _tags = [];
  final Map<int, int> _bookCounts = {};

  @override
  void initState() {
    super.initState();
    _reload();
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
        _bookCounts.clear();
        _bookCounts.addAll(counts);
      });
    }
  }

  FushiDatabase get _db => ref.read(appProvider).database;

  Future<void> _createTag() async {
    final result = await _showTagEditDialog(
      title: t.tag_new,
      initialName: '',
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
    await _reload();
  }

  /// 长按（原地松手）/ 右键弹出上下文菜单：编辑 + 删除。照仓库既有卡片长按菜单
  /// 范式（[_showMemberMenu] 的 showMenu + Overlay.globalToLocal 换算）。桌面端鼠标
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
          label: t.dialog_edit,
          icon: Icons.edit_outlined,
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
      case _TagMenuAction.delete:
        await _deleteTag(tag);
    }
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
    await _reload();
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
    // 行首色点的占位宽：与同设计系统的行首图标同宽，标题起点与其它列表对齐。
    final double leadingWidth = apple ? metrics.leadingIconSize : 24;
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
          : FushiFab(
              onPressed: _createTag,
              tooltip: t.tag_new,
              icon: const FushiIcon(Icons.add),
            ),
      body: _tags.isEmpty
          ? Center(
              child: FushiPlaceholderMessage(
                icon: Icons.label_outline,
                message: t.tag_no_tags_hint,
                // 空状态直接给「新建标签」主按钮（FAB 之外的第二个入口，
                // 首次进来的用户不必去找右下角）。
                action: FushiFilledButton(
                  key: const ValueKey<String>('tag-management-empty-create'),
                  onPressed: _createTag,
                  child: Text(t.tag_new),
                ),
              ),
            )
          // 2026-10-04 标签管理重做：整池标签读作一个分组（MD3 分段卡 /
          // Apple inset grouped），行 = 色点 + 名称 + 行尾计数；底部留出 FAB
          // 的位置，末行不被悬浮按钮压住。
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                // MD3 底部留出 FAB 的位置；Apple 新建在页头，不必留。
                tokens.spacing.gap + (apple ? 0 : _kMd3FabClearance),
              ),
              itemCount: _tags.length,
              itemBuilder: (context, index) {
                final tag = _tags[index];
                final count = _bookCounts[tag.id] ?? 0;
                return FushiGroupedListItem(
                  index: index,
                  count: _tags.length,
                  // Apple 分隔线从名称起点开始（跳过色点列）。
                  separatorIndent:
                      metrics.rowHorizontal + leadingWidth + metrics.leadingGap,
                  child: Dismissible(
                    key: ValueKey(tag.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: EdgeInsets.only(right: tokens.spacing.card),
                      // 与合集页滑动删除同一形态：实心 error 底 + onError 图标
                      // （iOS 滑动删除也是实心系统红；Apple 下 error = 系统红）。
                      // 背景在分组行里面，跟着行的圆角裁切。
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
                        GamepadButtonIntent:
                            CallbackAction<GamepadButtonIntent>(
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
                            // 标签色是内容：只留一枚色点，不铺大色块底。
                            leading: SizedBox(
                              width: leadingWidth,
                              child: Center(
                                child: _TagColorDot(
                                  color: Color(tag.colorValue),
                                ),
                              ),
                            ),
                            title: Text(tag.name),
                            trailing: Text(
                              t.tag_book_count(count: count),
                              style: TextStyle(
                                color: apple
                                    ? appleColorsOf(context).secondaryLabel
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            onTap: () => _editTag(tag),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 标签行首的颜色点：12dp 实心圆 + 一圈极淡描边（浅色标签在白底、深色标签
/// 在黑底上都有边界）。标签色是用户内容，两套设计系统同一形态。
class _TagColorDot extends StatelessWidget {
  const _TagColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final Color edge = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.12);
    // 共享色块原语的圆点形态（不可点，没有水波 / 焦点）。
    return FushiColorSwatch(
      color: color,
      size: 12,
      shape: FushiColorSwatchShape.dot,
      borderColor: edge,
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
                  size: 32,
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

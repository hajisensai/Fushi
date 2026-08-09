import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/builtin_tags.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/utils.dart';

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
          SnackBar(content: Text(t.tag_name_duplicate)),
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
          SnackBar(content: Text(t.tag_name_duplicate)),
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
    final _TagMenuAction? action = await showMenu<_TagMenuAction>(
      context: context,
      position: position,
      items: <PopupMenuEntry<_TagMenuAction>>[
        PopupMenuItem<_TagMenuAction>(
          value: _TagMenuAction.edit,
          child: Row(
            children: <Widget>[
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 12),
              Text(t.dialog_edit),
            ],
          ),
        ),
        PopupMenuItem<_TagMenuAction>(
          value: _TagMenuAction.delete,
          child: Row(
            children: <Widget>[
              Icon(Icons.delete_outline, size: 20, color: scheme.error),
              const SizedBox(width: 12),
              Text(t.dialog_delete, style: TextStyle(color: scheme.error)),
            ],
          ),
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

  // TODO-1166：一键把内置星级标签（1⭐..5⭐）补入标签池。
  // 只增不删（[seedStarRatingTags] 命中同名即跳过），零误删风险：不会碰用户
  // 自建标签，也不会动任何书籍映射。老用户想切到星级评分点这里即可，旧的
  // 「在读/读完」标签由用户自行决定是否删除。
  Future<void> _seedStarTags() async {
    final int added = await seedStarRatingTags(_db);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added > 0 ? t.tag_seed_stars_added : t.tag_seed_stars_exists,
        ),
      ),
    );
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
    return FushiPageScaffold(
      title: t.tag_manage_title,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.star_outline),
          tooltip: t.tag_seed_stars,
          onPressed: _seedStarTags,
        ),
      ],
      floatingActionButton: FloatingActionButton(
        onPressed: _createTag,
        tooltip: t.tag_new,
        child: const Icon(Icons.add),
      ),
      body: _tags.isEmpty
          ? Center(
              child: FushiPlaceholderMessage(
                icon: Icons.label_outline,
                message: t.tag_no_tags_hint,
              ),
            )
          : ListView.builder(
              itemCount: _tags.length,
              itemBuilder: (context, index) {
                final tag = _tags[index];
                final count = _bookCounts[tag.id] ?? 0;
                return Dismissible(
                  key: ValueKey(tag.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: EdgeInsets.only(right: tokens.spacing.card),
                    color: theme.colorScheme.errorContainer,
                    child: Icon(
                      Icons.delete_outline,
                      color: theme.colorScheme.onErrorContainer,
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
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onLongPressStart: (LongPressStartDetails d) =>
                          _showTagMenu(tag, d.globalPosition),
                      onSecondaryTapDown: (TapDownDetails d) =>
                          _showTagMenu(tag, d.globalPosition),
                      child: FushiListItem(
                        leading: CircleAvatar(
                          backgroundColor: Color(tag.colorValue),
                          radius: 14,
                        ),
                        title: Text(tag.name),
                        trailing: Text(t.tag_book_count(count: count)),
                        onTap: () => _editTag(tag),
                      ),
                    ),
                  ),
                );
              },
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
                    SnackBar(content: Text(t.tag_name_empty)),
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

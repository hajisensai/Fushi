import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/utils.dart';

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

  HibikiDatabase get _db => ref.read(appProvider).database;

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

  Future<void> _deleteTag(BookTagRow tag) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.dialog_delete),
        content: Text(t.tag_delete_confirm(name: tag.name)),
        actions: [
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.dialog_delete),
          ),
        ],
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
    final theme = Theme.of(context);
    return HibikiPageScaffold(
      title: t.tag_manage_title,
      floatingActionButton: FloatingActionButton(
        onPressed: _createTag,
        child: const Icon(Icons.add),
      ),
      body: _tags.isEmpty
          ? Center(
              child: HibikiPlaceholderMessage(
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
                    padding: const EdgeInsets.only(right: 16),
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
                  child: HibikiListItem(
                    leading: CircleAvatar(
                      backgroundColor: Color(tag.colorValue),
                      radius: 14,
                    ),
                    title: Text(tag.name),
                    trailing: Text(
                      t.tag_book_count(count: count),
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => _editTag(tag),
                  ),
                );
              },
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
    return adaptiveAlertDialog(
      context: context,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HibikiTextField(
            controller: _nameController,
            labelText: t.tag_name_hint,
            autofocus: true,
          ),
          const SizedBox(height: 16),
          Text(t.tag_color, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kTagPresetColors.map((color) {
              final isSelected = _selectedColor == color;
              return HibikiColorSwatch(
                color: Color(color),
                size: 32,
                shape: HibikiColorSwatchShape.dot,
                selected: isSelected,
                onTap: () => setState(() => _selectedColor = color),
              );
            }).toList(),
          ),
        ],
      ),
      actions: [
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
    );
  }
}

class TagEditResult {
  const TagEditResult({required this.name, required this.color});
  final String name;
  final int color;
}

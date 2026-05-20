import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/i18n/strings.g.dart';

class TagPickerPage extends ConsumerStatefulWidget {
  const TagPickerPage({
    required this.bookId,
    this.isSrtBook = false,
    super.key,
  });
  final int bookId;
  final bool isSrtBook;

  @override
  ConsumerState<TagPickerPage> createState() => _TagPickerPageState();
}

class _TagPickerPageState extends ConsumerState<TagPickerPage> {
  List<BookTagRow> _allTags = [];
  Set<int> _selectedTagIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  HibikiDatabase get _db => ref.read(appProvider).database;

  Future<void> _load() async {
    final allTags = await _db.getAllTags();
    final bookTags = widget.isSrtBook
        ? await _db.getTagsForSrtBook(widget.bookId)
        : await _db.getTagsForBook(widget.bookId);
    if (mounted) {
      setState(() {
        _allTags = allTags;
        _selectedTagIds = bookTags.map((t) => t.id).toSet();
      });
    }
  }

  Future<void> _toggle(int tagId, bool selected) async {
    if (selected) {
      widget.isSrtBook
          ? await _db.addTagToSrtBook(widget.bookId, tagId)
          : await _db.addTagToBook(widget.bookId, tagId);
      setState(() => _selectedTagIds.add(tagId));
    } else {
      widget.isSrtBook
          ? await _db.removeTagFromSrtBook(widget.bookId, tagId)
          : await _db.removeTagFromBook(widget.bookId, tagId);
      setState(() => _selectedTagIds.remove(tagId));
    }
  }

  Future<void> _quickCreateTag() async {
    final result = await showDialog<TagEditResult>(
      context: context,
      builder: (ctx) => TagEditDialog(
        title: t.tag_new,
        initialName: '',
        initialColor:
            kTagPresetColors[_allTags.length % kTagPresetColors.length],
      ),
    );
    if (result == null) return;
    try {
      final newId = await _db.createTag(result.name, result.color);
      widget.isSrtBook
          ? await _db.addTagToSrtBook(widget.bookId, newId)
          : await _db.addTagToBook(widget.bookId, newId);
      await _load();
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.tag_name_duplicate)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.tag_label)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _quickCreateTag,
        icon: const Icon(Icons.add),
        label: Text(t.tag_new),
      ),
      body: _allTags.isEmpty
          ? Center(
              child: Text(
                t.tag_no_tags_hint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              itemCount: _allTags.length,
              itemBuilder: (context, index) {
                final tag = _allTags[index];
                final isChecked = _selectedTagIds.contains(tag.id);
                return CheckboxListTile(
                  value: isChecked,
                  onChanged: (v) => _toggle(tag.id, v ?? false),
                  secondary: CircleAvatar(
                    backgroundColor: Color(tag.colorValue),
                    radius: 14,
                  ),
                  title: Text(tag.name),
                );
              },
            ),
    );
  }
}

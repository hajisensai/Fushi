import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/utils.dart';

class TagPickerPage extends ConsumerStatefulWidget {
  /// EPUB 书：传 [bookKey]（书的主键）；SRT 书：传 [srtBookId]（srt_books 自增主键）
  /// 且 [isSrtBook] = true。两者互斥，按 [isSrtBook] 分派。
  const TagPickerPage({
    this.bookKey,
    this.srtBookId,
    this.isSrtBook = false,
    super.key,
  }) : assert(
          isSrtBook ? srtBookId != null : bookKey != null,
          'bookKey is required for EPUB books, srtBookId for SRT books',
        );
  final String? bookKey;
  final int? srtBookId;
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
        ? await _db.getTagsForSrtBook(widget.srtBookId!)
        : await _db.getTagsForBook(widget.bookKey!);
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
          ? await _db.addTagToSrtBook(widget.srtBookId!, tagId)
          : await _db.addTagToBook(widget.bookKey!, tagId);
      setState(() => _selectedTagIds.add(tagId));
    } else {
      widget.isSrtBook
          ? await _db.removeTagFromSrtBook(widget.srtBookId!, tagId)
          : await _db.removeTagFromBook(widget.bookKey!, tagId);
      setState(() => _selectedTagIds.remove(tagId));
    }
  }

  Future<void> _quickCreateTag() async {
    final result = await showAppDialog<TagEditResult>(
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
          ? await _db.addTagToSrtBook(widget.srtBookId!, newId)
          : await _db.addTagToBook(widget.bookKey!, newId);
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiPageScaffold(
      title: t.tag_label,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _quickCreateTag,
        icon: const Icon(Icons.add),
        label: Text(t.tag_new),
      ),
      body: _allTags.isEmpty
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(tokens.spacing.card),
                child: HibikiCard(
                  child: HibikiPlaceholderMessage(
                    icon: Icons.label_outline,
                    message: t.tag_no_tags_hint,
                  ),
                ),
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.all(tokens.spacing.card),
              itemCount: _allTags.length,
              separatorBuilder: (_, __) => SizedBox(height: tokens.spacing.gap),
              itemBuilder: (context, index) {
                final BookTagRow tag = _allTags[index];
                final bool selected = _selectedTagIds.contains(tag.id);
                return HibikiCard(
                  padding: EdgeInsets.zero,
                  selected: selected,
                  child: HibikiListItem(
                    minHeight: 64,
                    selected: selected,
                    onTap: () => _toggle(tag.id, !selected),
                    leading: CircleAvatar(
                      backgroundColor: Color(tag.colorValue),
                      radius: 14,
                    ),
                    title: Text(tag.name),
                    trailing: Checkbox(
                      value: selected,
                      onChanged: (bool? value) =>
                          _toggle(tag.id, value ?? false),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

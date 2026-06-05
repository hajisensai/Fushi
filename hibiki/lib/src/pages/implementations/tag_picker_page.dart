import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/utils.dart';

class TagPickerPage extends ConsumerStatefulWidget {
  /// 三种媒体三选一，共用同一标签池，按非空字段分派：
  /// EPUB 书传 [bookKey]（书主键）；SRT 书传 [srtBookId]（自增主键）且
  /// [isSrtBook]=true；视频书传 [videoBookUid]（video_books 的 book_uid）。
  const TagPickerPage({
    this.bookKey,
    this.srtBookId,
    this.videoBookUid,
    this.isSrtBook = false,
    super.key,
  }) : assert(
          videoBookUid != null ||
              (isSrtBook ? srtBookId != null : bookKey != null),
          'bookKey for EPUB, srtBookId for SRT, videoBookUid for video',
        );
  final String? bookKey;
  final int? srtBookId;
  final String? videoBookUid;
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

  bool get _isVideo => widget.videoBookUid != null;

  /// 读当前媒体已挂的标签（按媒体类型分派到对应 DB 查询）。
  Future<List<BookTagRow>> _currentTags() {
    if (_isVideo) return _db.getTagsForVideoBook(widget.videoBookUid!);
    if (widget.isSrtBook) return _db.getTagsForSrtBook(widget.srtBookId!);
    return _db.getTagsForBook(widget.bookKey!);
  }

  Future<void> _addTag(int tagId) {
    if (_isVideo) return _db.addTagToVideoBook(widget.videoBookUid!, tagId);
    if (widget.isSrtBook) return _db.addTagToSrtBook(widget.srtBookId!, tagId);
    return _db.addTagToBook(widget.bookKey!, tagId);
  }

  Future<void> _removeTag(int tagId) {
    if (_isVideo) {
      return _db.removeTagFromVideoBook(widget.videoBookUid!, tagId);
    }
    if (widget.isSrtBook) {
      return _db.removeTagFromSrtBook(widget.srtBookId!, tagId);
    }
    return _db.removeTagFromBook(widget.bookKey!, tagId);
  }

  Future<void> _load() async {
    final allTags = await _db.getAllTags();
    final bookTags = await _currentTags();
    if (mounted) {
      setState(() {
        _allTags = allTags;
        _selectedTagIds = bookTags.map((t) => t.id).toSet();
      });
    }
  }

  Future<void> _toggle(int tagId, bool selected) async {
    if (selected) {
      await _addTag(tagId);
      setState(() => _selectedTagIds.add(tagId));
    } else {
      await _removeTag(tagId);
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
      await _addTag(newId);
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

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi/utils.dart';

class TagPickerPage extends ConsumerStatefulWidget {
  /// 两种目标二选一，共用同一标签池：媒体条目传 [media]（统一媒体身份
  /// [MediaRef]：epub=bookKey / srt=SrtBooks.uid / video=bookUid /
  /// game=galgames.id）；合集传 [collectionId]（media_collections 主键）。
  ///
  /// 命名统一 Phase 3.3：取代旧的 bookKey / srtBookId / videoBookUid 三个可空
  /// 参数 + isSrtBook bool 分派链。
  const TagPickerPage({
    this.media,
    this.collectionId,
    super.key,
  }) : assert(
          (media != null) ^ (collectionId != null),
          'exactly one of: media / collectionId',
        );
  final MediaRef? media;
  final int? collectionId;

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

  FushiDatabase get _db => ref.read(appProvider).database;

  /// 读当前目标已挂的标签（合集直取；媒体按 [MediaKind] 穷尽分派）。
  /// v77 起 SRT 标签映射按 uid 落库，[MediaRef.entryKey]（= uid）直传，无需解析 id。
  Future<List<BookTagRow>> _currentTags() async {
    final int? collectionId = widget.collectionId;
    if (collectionId != null) return _db.getTagsForCollection(collectionId);
    final MediaRef media = widget.media!;
    switch (media.kind) {
      case MediaKind.epub:
        return _db.getTagsForBook(media.entryKey);
      case MediaKind.srt:
        return _db.getTagsForSrtBook(media.entryKey);
      case MediaKind.video:
        return _db.getTagsForVideoBook(media.entryKey);
      case MediaKind.game:
        return _db.getTagsForGame(media.entryKey);
    }
  }

  Future<void> _addTag(int tagId) async {
    final int? collectionId = widget.collectionId;
    if (collectionId != null) {
      return _db.addTagToCollection(collectionId, tagId);
    }
    final MediaRef media = widget.media!;
    switch (media.kind) {
      case MediaKind.epub:
        return _db.addTagToBook(media.entryKey, tagId);
      case MediaKind.srt:
        return _db.addTagToSrtBook(media.entryKey, tagId);
      case MediaKind.video:
        return _db.addTagToVideoBook(media.entryKey, tagId);
      case MediaKind.game:
        return _db.addTagToGame(media.entryKey, tagId);
    }
  }

  Future<void> _removeTag(int tagId) async {
    final int? collectionId = widget.collectionId;
    if (collectionId != null) {
      return _db.removeTagFromCollection(collectionId, tagId);
    }
    final MediaRef media = widget.media!;
    switch (media.kind) {
      case MediaKind.epub:
        return _db.removeTagFromBook(media.entryKey, tagId);
      case MediaKind.srt:
        return _db.removeTagFromSrtBook(media.entryKey, tagId);
      case MediaKind.video:
        return _db.removeTagFromVideoBook(media.entryKey, tagId);
      case MediaKind.game:
        return _db.removeTagFromGame(media.entryKey, tagId);
    }
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiPageScaffold(
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
                child: FushiCard(
                  child: FushiPlaceholderMessage(
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
                return FushiCard(
                  padding: EdgeInsets.zero,
                  selected: selected,
                  child: FushiListItem(
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

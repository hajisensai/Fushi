import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/utils.dart';

class ReaderHoshiHistoryPage extends HistoryReaderPage {
  const ReaderHoshiHistoryPage({super.key});

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderHoshiHistoryPageState();
}

class _ReaderHoshiHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  @override
  MediaType get mediaType => mediaSource.mediaType;

  @override
  ReaderHoshiSource get mediaSource => ReaderHoshiSource.instance;

  final Map<String, Future<_AudiobookInfo>> _audiobookInfoCache = {};

  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};
  List<MediaItem> _visibleEpubBooks = const [];
  List<SrtBook> _visibleSrtBooks = const [];

  static double _gridExtent(BuildContext context, BoxConstraints constraints) {
    return readerShelfGridExtentForLayout(
      mediaWidth: MediaQuery.sizeOf(context).width,
      contentWidth: constraints.maxWidth,
    );
  }

  void _refreshSrtBooks() {
    ref.invalidate(srtBooksProvider);
    _audiobookInfoCache.clear();
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedKeys.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelection(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) {
        _selectedKeys.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<MediaItem>> books =
        ref.watch(hoshiBooksProvider(appModel.targetLanguage));
    final AsyncValue<Set<int>?> filteredIds =
        ref.watch(filteredBookIdsProvider);
    final allTags = ref.watch(allTagsProvider);

    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: [
          _buildTagBar(allTags.valueOrNull ?? const []),
          Expanded(
            child: books.when(
              data: (bookList) {
                final Set<int>? filterSet = filteredIds.valueOrNull;
                final List<MediaItem> filtered;
                if (filterSet == null) {
                  filtered = bookList;
                } else {
                  filtered = bookList.where((item) {
                    final int? id = _parseBookId(item.mediaIdentifier);
                    return id != null && filterSet.contains(id);
                  }).toList();
                }
                return buildBody(filtered);
              },
              error: (error, stack) => buildError(
                error: error,
                stack: stack,
                refresh: () {
                  _refreshSrtBooks();
                  ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
                },
              ),
              loading: () => const SizedBox.shrink(),
            ),
          ),
          if (_selectionMode) _buildBatchActionBar(),
        ],
      ),
    );
  }

  Widget _buildTagBar(List<BookTagRow> allTags) {
    return _TagBarContent(
      tags: allTags,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      selectionMode: _selectionMode,
      onToggleSelectionMode: _toggleSelectionMode,
    );
  }

  void _toggleFilter(int tagId) {
    final current = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (current.contains(tagId)) {
      current.remove(tagId);
    } else {
      current.add(tagId);
    }
    ref.read(selectedTagIdsProvider.notifier).state = current;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final reordered = List<BookTagRow>.from(tags);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    final orderedIds = reordered.map((t) => t.id).toList();
    await ref.read(appProvider).database.reorderTags(orderedIds);
    ref.invalidate(allTagsProvider);
  }

  Future<void> _addTagToBook(int bookId, BookTagRow tag) async {
    final existing = ref.read(bookTagMapProvider).valueOrNull;
    final alreadyHas = existing?[bookId]?.any((t) => t.id == tag.id) ?? false;
    if (alreadyHas) {
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }
    await ref.read(appProvider).database.addTagToBook(bookId, tag.id);
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_book(name: tag.name));
    }
  }

  Future<void> _addTagToSrtBook(int srtBookId, BookTagRow tag) async {
    final existing = ref.read(srtBookTagMapProvider).valueOrNull;
    final alreadyHas =
        existing?[srtBookId]?.any((t) => t.id == tag.id) ?? false;
    if (alreadyHas) {
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }
    await ref.read(appProvider).database.addTagToSrtBook(srtBookId, tag.id);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(filteredSrtBookIdsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_book(name: tag.name));
    }
  }

  Widget? _buildTagLabels(int bookId) {
    final tagMap = ref.watch(bookTagMapProvider).valueOrNull;
    if (tagMap == null) return null;
    final tags = tagMap[bookId];
    if (tags == null || tags.isEmpty) return null;
    return _adaptiveTagColumn(tags);
  }

  Widget _tagChip(BookTagRow tag) {
    return Container(
      margin: const EdgeInsets.only(right: 3, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Color(tag.colorValue).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tag.name,
        style: TextStyle(
          fontSize: 9,
          color: ThemeData.estimateBrightnessForColor(Color(tag.colorValue)) ==
                  Brightness.dark
              ? Colors.white
              : Colors.black,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _overflowChip(int count) {
    return Container(
      margin: const EdgeInsets.only(right: 3, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          fontSize: 9,
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _adaptiveTagColumn(List<BookTagRow> tags) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const double chipHeight = 15.0;
        final double usable = constraints.maxHeight * 0.55;
        final int maxSlots =
            (usable / chipHeight).floor().clamp(1, tags.length);

        if (maxSlots >= tags.length) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [for (final tag in tags) _tagChip(tag)],
          );
        }

        final int visibleCount = maxSlots <= 1 ? 1 : maxSlots - 1;
        final int overflow = tags.length - visibleCount;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tag in tags.take(visibleCount)) _tagChip(tag),
            if (overflow > 0 && maxSlots > 1) _overflowChip(overflow),
          ],
        );
      },
    );
  }

  Widget buildBody(List<MediaItem> books) {
    final List<SrtBook> srtBooks =
        ref.watch(srtBooksProvider).valueOrNull ?? const [];
    return _buildBodyWithSrtBooks(books, srtBooks);
  }

  Widget _buildBodyWithSrtBooks(
      List<MediaItem> books, List<SrtBook> allSrtBooks) {
    final Set<int> srtTtuIds = {
      for (final b in allSrtBooks)
        if (b.ttuBookId > 0) b.ttuBookId,
    };
    final List<MediaItem> epubBooks = srtTtuIds.isEmpty
        ? books
        : books.where((item) {
            final int? id = _parseBookId(item.mediaIdentifier);
            return id == null || !srtTtuIds.contains(id);
          }).toList();

    final bool hasActiveFilter = ref.read(selectedTagIdsProvider).isNotEmpty;
    final Set<int>? srtFilterSet =
        ref.watch(filteredSrtBookIdsProvider).valueOrNull;
    final List<SrtBook> srtBooks;
    if (srtFilterSet != null) {
      srtBooks = allSrtBooks
          .where((b) => b.id != null && srtFilterSet.contains(b.id))
          .toList();
    } else if (hasActiveFilter) {
      srtBooks = const [];
    } else {
      srtBooks = allSrtBooks;
    }
    _visibleEpubBooks = epubBooks;
    _visibleSrtBooks = srtBooks;
    if (epubBooks.isEmpty && srtBooks.isEmpty) {
      return hasActiveFilter
          ? Center(
              child: JidoujishoPlaceholderMessage(
                icon: Icons.filter_list_off,
                message: t.tag_no_books_for_filter,
              ),
            )
          : buildPlaceholder();
    }
    if (hasActiveFilter && epubBooks.isEmpty) {
      return RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: mediaType.scrollController,
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(
            controller: mediaType.scrollController,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              if (srtBooks.isNotEmpty) ...[
                SliverToBoxAdapter(
                    child: _buildSectionHeader(t.srt_books_section)),
                SliverPadding(
                  padding: EdgeInsets.zero,
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _gridExtent(context, constraints),
                      childAspectRatio: mediaSource.aspectRatio,
                    ),
                    itemCount: srtBooks.length,
                    itemBuilder: (_, i) => _buildSrtCard(srtBooks[i]),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t.tag_no_books_for_filter,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: mediaType.scrollController,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          controller: mediaType.scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            if (srtBooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _buildSectionHeader(t.srt_books_section)),
              SliverPadding(
                padding: EdgeInsets.zero,
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _gridExtent(context, constraints),
                    childAspectRatio: mediaSource.aspectRatio,
                  ),
                  itemCount: srtBooks.length,
                  itemBuilder: (_, i) => _buildSrtCard(srtBooks[i]),
                ),
              ),
            ],
            if (epubBooks.isNotEmpty) ...[
              if (srtBooks.isNotEmpty)
                SliverToBoxAdapter(child: _buildSectionHeader(t.section_epub)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: mediaSource.aspectRatio,
                ),
                itemCount: epubBooks.length,
                itemBuilder: (_, i) => buildMediaItem(epubBooks[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        label,
        style: textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget? _buildSrtBookTagLabels(int srtBookId) {
    final tagMap = ref.watch(srtBookTagMapProvider).valueOrNull;
    if (tagMap == null) return null;
    final tags = tagMap[srtBookId];
    if (tags == null || tags.isEmpty) return null;
    return _adaptiveTagColumn(tags);
  }

  Widget _buildSrtCard(SrtBook book) {
    final String selKey = 'srt_${book.uid}';
    final tagWidget = book.id != null ? _buildSrtBookTagLabels(book.id!) : null;
    final card = _bookCardShell(
      cardKey: ValueKey<String>('srt_entry_${book.ttuBookId}'),
      selectionKey: selKey,
      onTap: () => _openSrtBook(book),
      onLongPress: () => _showSrtBookDialog(book),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildSrtCover(book),
          _titleOverlay(book.title),
          Positioned(
            top: 6,
            right: 6,
            child: _cardBadge(
              icon: Icons.subtitles_outlined,
              background: theme.colorScheme.secondaryContainer,
              foreground: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          if (tagWidget != null)
            Positioned(
              top: 6,
              left: 6,
              child: tagWidget,
            ),
        ],
      ),
    );
    if (book.id == null || _selectionMode) return card;
    return _BookDragTarget(
      bookId: book.id!,
      onTagDropped: (tag) => _addTagToSrtBook(book.id!, tag),
      child: card,
    );
  }

  Widget _buildSrtCover(SrtBook book) {
    if (book.coverPath != null && File(book.coverPath!).existsSync()) {
      return FadeInImage(
        imageErrorBuilder: (_, __, ___) => _coverPlaceholderIcon(
          Icons.subtitles_outlined,
        ),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(book.coverPath!)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    return _coverPlaceholderIcon(Icons.subtitles_outlined);
  }

  Widget _coverPlaceholderIcon(IconData icon) {
    return Center(
      child: Icon(
        icon,
        size: 40,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _bookCardShell({
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required Widget child,
    Key? cardKey,
    String? selectionKey,
  }) {
    final bool selected =
        selectionKey != null && _selectedKeys.contains(selectionKey);
    return Padding(
      key: cardKey,
      padding: Spacing.of(context).insets.all.normal,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _selectionMode && selectionKey != null
              ? () => _toggleSelection(selectionKey)
              : onTap,
          onLongPress: _selectionMode ? null : onLongPress,
          child: AspectRatio(
            aspectRatio: mediaSource.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                if (_selectionMode && selectionKey != null)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surface
                                  .withValues(alpha: 0.7),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                            width: 1.5,
                          ),
                        ),
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.check,
                          size: 14,
                          color: selected
                              ? theme.colorScheme.onPrimary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleOverlay(String title) {
    return LayoutBuilder(builder: (context, constraints) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: constraints.maxHeight * 0.38,
          width: double.infinity,
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surface.withValues(alpha: 0),
                theme.colorScheme.surface.withValues(alpha: 0.85),
              ],
            ),
          ),
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            softWrap: true,
            style: textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      );
    });
  }

  Widget _cardBadge({
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 14, color: foreground),
    );
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    return MediaItem(
      mediaIdentifier: ReaderHoshiSource.mediaIdentifierFor(book.ttuBookId),
      title: book.title,
      mediaTypeIdentifier: ReaderHoshiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHoshiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
      imageUrl:
          book.coverPath != null ? Uri.file(book.coverPath!).toString() : null,
    );
  }

  void _openSrtBook(SrtBook book) {
    if (book.ttuBookId <= 0) {
      HibikiToast.show(msg: t.srt_epub_not_ready);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderHoshiPage(
          bookId: book.ttuBookId,
          item: _srtBookMediaItem(book),
        ),
      ),
    );
  }

  List<DialogAction> _srtExtraActions(
      BuildContext dialogContext, SrtBook book) {
    final int bookId = book.ttuBookId;
    final MediaItem item = _srtBookMediaItem(book);
    return [
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () async {
          Navigator.pop(dialogContext);
          await _confirmDeleteSrtBook(book);
        },
      ),
      DialogQuickAction(
        label: t.srt_import_pick_cover,
        icon: Icons.image_outlined,
        onPressed: () async {
          Navigator.pop(dialogContext);
          await _pickSrtBookCover(book);
        },
      ),
      if (book.id != null)
        DialogQuickAction(
          label: t.tag_label,
          icon: Icons.sell_outlined,
          onPressed: () => _openSrtBookTagPicker(book.id!),
        ),
      if (bookId > 0) ...[
        DialogQuickAction(
          label: t.audio_import,
          icon: Icons.headphones_outlined,
          onPressed: () => _openAudioImport(item, bookId),
        ),
        DialogListAction(
          label: t.profile_book_profile,
          onPressed: () => _openBookProfilePicker(item, bookId),
        ),
        DialogListAction(
          label: t.book_css_editor_edit_css,
          onPressed: () {
            Navigator.pop(dialogContext);
            _openCssEditor(bookId);
          },
        ),
      ],
    ];
  }

  Future<void> _showSrtBookDialog(SrtBook book) async {
    await showAppDialog(
      context: context,
      builder: (ctx) => MediaItemDialogPage(
        item: _srtBookMediaItem(book),
        isHistory: true,
        extraActions: (_) => _srtExtraActions(ctx, book),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _pickSrtBookCover(SrtBook book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null || !mounted) return;
    final String? pickedPath = result.files.first.path;
    if (pickedPath == null) return;

    final Directory persistDir =
        await AudiobookStorage.ensurePersistDir(book.uid);
    final String ext = p.extension(pickedPath);
    final String dest = p.join(persistDir.path, 'cover$ext');
    await File(pickedPath).copy(dest);

    book.coverPath = dest;
    await SrtBookRepository(appModel.database).save(book);
    if (mounted) setState(() {});
  }

  void _selectAll() {
    setState(() {
      for (final item in _visibleEpubBooks) {
        _selectedKeys.add(item.mediaIdentifier);
      }
      for (final book in _visibleSrtBooks) {
        _selectedKeys.add('srt_${book.uid}');
      }
    });
  }

  void _invertSelection() {
    setState(() {
      final Set<String> allKeys = {
        for (final item in _visibleEpubBooks) item.mediaIdentifier,
        for (final book in _visibleSrtBooks) 'srt_${book.uid}',
      };
      final Set<String> inverted = allKeys.difference(_selectedKeys);
      _selectedKeys
        ..clear()
        ..addAll(inverted);
    });
  }

  Widget _buildBatchActionBar() {
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(
                t.batch_selected_count(n: _selectedKeys.length),
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _selectAll,
                child: Text(t.batch_select_all),
              ),
              TextButton(
                onPressed: _invertSelection,
                child: Text(t.batch_invert_selection),
              ),
              const Spacer(),
              IconButton(
                onPressed: _selectedKeys.isEmpty ? null : _batchShowTagPicker,
                icon: const Icon(Icons.sell_outlined),
                tooltip: t.tag_label,
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _selectedKeys.isEmpty ? null : _batchDeleteConfirm,
                icon: const Icon(Icons.delete_outline),
                tooltip: t.dialog_delete,
                color: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _batchDeleteConfirm() async {
    final int count = _selectedKeys.length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.dialog_delete,
        message: t.batch_delete_confirm(n: count),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    int deleted = 0;
    final Set<String> toDelete = Set.of(_selectedKeys);
    for (final key in toDelete) {
      if (key.startsWith('srt_')) {
        final String uid = key.substring(4);
        final SrtBookRepository repo = SrtBookRepository(appModel.database);
        final SrtBook? book = await repo.findByUid(uid);
        if (book != null) {
          if (book.ttuBookId > 0) {
            await ReaderHoshiSource.instance.deleteBook(
              db: appModel.database,
              bookId: book.ttuBookId,
            );
          }
          await repo.delete(uid);
          deleted++;
        }
      } else {
        final int? bookId = _parseBookId(key);
        if (bookId != null) {
          final bool ok = await ReaderHoshiSource.instance.deleteBook(
            db: appModel.database,
            bookId: bookId,
          );
          if (ok) deleted++;
        }
      }
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    _exitSelectionMode();
    HibikiToast.show(msg: t.batch_delete_success(n: deleted));
  }

  Future<void> _batchShowTagPicker() async {
    final allTags = ref.read(allTagsProvider).valueOrNull;
    if (allTags == null || allTags.isEmpty) {
      HibikiToast.show(msg: t.tag_no_tags_hint);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _BatchTagPickerDialog(
        allTags: allTags,
        selectedKeys: _selectedKeys,
        database: appModel.database,
        parseBookId: _parseBookId,
      ),
    );
    if (!mounted) return;
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    ref.invalidate(filteredSrtBookIdsProvider);
  }

  Future<void> _confirmDeleteSrtBook(SrtBook book) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.srt_delete_title,
        message: t.srt_delete_confirm(title: book.title),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    if (book.ttuBookId > 0) {
      await ReaderHoshiSource.instance.deleteBook(
        db: appModel.database,
        bookId: book.ttuBookId,
      );
    }
    await SrtBookRepository(appModel.database).delete(book.uid);
    if (mounted) {
      _refreshSrtBooks();
      ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
      setState(() {});
    }
  }

  @override
  Widget buildPlaceholder() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: mediaSource.icon,
        message: t.ttu_no_books_added,
      ),
    );
  }

  @override
  Widget buildMediaItemContent(MediaItem item) {
    return FutureBuilder<_AudiobookInfo>(
      future: _audiobookInfoCache.putIfAbsent(
          item.uniqueKey, () => _loadAudiobookInfo(item.uniqueKey)),
      builder: (context, snapshot) {
        final bool hasAudiobook = snapshot.data?.hasAudiobook ?? false;
        final HealthKind healthKind =
            snapshot.data?.healthKind ?? HealthKind.notApplicable;

        final int? bookId = _parseBookId(item.mediaIdentifier);
        final tagWidget = bookId != null ? _buildTagLabels(bookId) : null;

        return Stack(
          fit: StackFit.expand,
          children: [
            FadeInImage(
              imageErrorBuilder: (_, __, ___) =>
                  _coverPlaceholderIcon(Icons.menu_book_outlined),
              placeholder: MemoryImage(kTransparentImage),
              image: mediaSource.getDisplayThumbnailFromMediaItem(
                appModel: appModel,
                item: item,
              ),
              alignment: Alignment.topCenter,
              fit: BoxFit.fitHeight,
            ),
            _titleOverlay(mediaSource.getDisplayTitleFromMediaItem(item)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _progressBar(item),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: hasAudiobook
                  ? _audiobookBadge(healthKind)
                  : _cardBadge(
                      icon: Icons.menu_book_outlined,
                      background: theme.colorScheme.surfaceContainerHighest,
                      foreground: theme.colorScheme.onSurfaceVariant,
                    ),
            ),
            if (tagWidget != null)
              Positioned(
                top: 6,
                left: 6,
                child: tagWidget,
              ),
          ],
        );
      },
    );
  }

  Future<_AudiobookInfo> _loadAudiobookInfo(String bookUid) async {
    try {
      final AudiobookRepository repo = AudiobookRepository(appModel.database);
      final ab = await repo.findByBookUid(bookUid);
      if (ab == null) {
        return const _AudiobookInfo(
            hasAudiobook: false, healthKind: HealthKind.notApplicable);
      }
      final health = await repo.resolveHealth(ab);
      return _AudiobookInfo(hasAudiobook: true, healthKind: health.kind);
    } catch (e, st) {
      debugPrint(
        '[hibiki-audiobook] findByBookUid crashed for '
        'bookUid=$bookUid: $e\n$st',
      );
      return const _AudiobookInfo(
          hasAudiobook: false, healthKind: HealthKind.notApplicable);
    }
  }

  @override
  Widget buildMediaItem(MediaItem item) {
    final int? bookId = _parseBookId(item.mediaIdentifier);
    final card = _bookCardShell(
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      selectionKey: item.mediaIdentifier,
      onTap: () async {
        final MediaSource source = item.getMediaSource(appModel: appModel);
        await appModel.openMedia(
          ref: ref,
          mediaSource: source,
          item: item,
        );
      },
      onLongPress: () async {
        await showAppDialog(
          context: context,
          builder: (_) => MediaItemDialogPage(
            item: item,
            isHistory: isHistory,
            extraActions: extraActions,
          ),
        );
        if (isHistory) {
          setState(() {});
        }
      },
      child: buildMediaItemContent(item),
    );
    if (bookId == null) return card;
    if (_selectionMode) return card;
    return _BookDragTarget(
      bookId: bookId,
      onTagDropped: (tag) => _addTagToBook(bookId, tag),
      child: card,
    );
  }

  Widget _progressBar(MediaItem item) {
    double value = 0;
    if (item.duration > 0) {
      final double v = item.position / item.duration;
      if (v.isFinite) {
        value = v > 0.97 ? 1 : v;
      }
    }
    return LinearProgressIndicator(
      value: value,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
      minHeight: 3,
    );
  }

  Widget _audiobookBadge(HealthKind kind) {
    final ColorScheme cs = theme.colorScheme;
    final Color bg;
    final Color fg;
    switch (kind) {
      case HealthKind.failed:
        bg = cs.errorContainer;
        fg = cs.onErrorContainer;
      case HealthKind.partial:
        bg = cs.tertiaryContainer;
        fg = cs.onTertiaryContainer;
      case HealthKind.ok:
      case HealthKind.unrun:
      case HealthKind.running:
      case HealthKind.notApplicable:
        bg = cs.secondaryContainer;
        fg = cs.onSecondaryContainer;
    }
    return _cardBadge(
      icon: Icons.headphones,
      background: bg,
      foreground: fg,
    );
  }

  @override
  List<DialogAction> extraActions(MediaItem item) {
    final int? bookId = _parseBookId(item.mediaIdentifier);
    if (bookId == null) return const [];
    return <DialogAction>[
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () => _confirmDeleteEpub(item, bookId),
      ),
      DialogQuickAction(
        label: t.view_illustrations,
        icon: Icons.image_outlined,
        onPressed: () => _openIllustrations(item, bookId),
      ),
      DialogQuickAction(
        label: t.audiobook_import,
        icon: Icons.headphones_outlined,
        onPressed: () => _openAudiobookImport(item, bookId),
      ),
      DialogQuickAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openTagPicker(bookId),
      ),
      DialogListAction(
        label: t.profile_book_profile,
        onPressed: () => _openBookProfilePicker(item, bookId),
      ),
      DialogListAction(
        label: t.book_css_editor_edit_css,
        onPressed: () => _openCssEditor(bookId),
      ),
    ];
  }

  Future<void> _confirmDeleteEpub(MediaItem item, int bookId) async {
    Navigator.pop(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: t.srt_delete_confirm(title: item.title),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    final bool ok = await ReaderHoshiSource.instance.deleteBook(
      db: appModel.database,
      bookId: bookId,
    );
    if (!mounted) return;
    if (!ok) {
      HibikiToast.show(msg: t.epub_delete_error);
      return;
    }
    _refreshSrtBooks();
    ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
    setState(() {});
  }

  int? _parseBookId(String mediaIdentifier) =>
      ReaderHoshiSource.parseBookId(mediaIdentifier);

  void _openIllustrations(MediaItem item, int bookId) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => IllustrationsViewerPage(
          bookTitle: item.title,
          bookId: bookId,
        ),
      ),
    );
  }

  Future<void> _openAudioImport(MediaItem item, int bookId) async {
    Navigator.pop(context);
    await showDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookUid: item.uniqueKey,
        repo: AudiobookRepository(appModel.database),
        ttuBookId: bookId,
        audioOnly: true,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openAudiobookImport(MediaItem item, int bookId) async {
    Navigator.pop(context);
    await showDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookUid: item.uniqueKey,
        repo: AudiobookRepository(appModel.database),
        ttuBookId: bookId,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _openTagPicker(int bookId) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TagPickerPage(bookId: bookId)),
    ).then((_) {
      ref.invalidate(bookTagMapProvider);
      ref.invalidate(filteredBookIdsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  void _openSrtBookTagPicker(int srtBookId) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TagPickerPage(bookId: srtBookId, isSrtBook: true),
      ),
    ).then((_) {
      ref.invalidate(srtBookTagMapProvider);
      ref.invalidate(filteredSrtBookIdsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  Future<void> _openCssEditor(int bookId) async {
    final bool exists = await EpubStorage.bookExists(bookId);
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.book_css_editor_no_extract_dir)),
        );
      }
      return;
    }
    final String extractDir = await EpubStorage.bookPath(bookId);
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BookCssEditorPage(extractDir: extractDir),
        ),
      );
    }
  }

  void _openBookProfilePicker(MediaItem item, int bookId) {
    Navigator.pop(context);
    final String bookUid = item.uniqueKey;
    final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
    final ProfileUiState profileState = ref.read(profileViewModelProvider);

    showDialog<void>(
      context: context,
      builder: (ctx) => _BookProfileDialog(
        bookUid: bookUid,
        profileRepo: profileRepo,
        profiles: profileState.profiles,
        activeProfileName: profileState.activeProfile?.name ?? '',
      ),
    );
  }
}

class _TagBarContent extends ConsumerStatefulWidget {
  const _TagBarContent({
    required this.tags,
    required this.onToggleFilter,
    required this.onReorder,
    required this.selectionMode,
    required this.onToggleSelectionMode,
  });
  final List<BookTagRow> tags;
  final void Function(int tagId) onToggleFilter;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;
  final bool selectionMode;
  final VoidCallback onToggleSelectionMode;

  @override
  ConsumerState<_TagBarContent> createState() => _TagBarContentState();
}

class _TagBarContentState extends ConsumerState<_TagBarContent> {
  @override
  Widget build(BuildContext context) {
    final selectedIds = ref.watch(selectedTagIdsProvider);
    final theme = Theme.of(context);
    final t = Translations.of(context);

    final int trailingCount = widget.tags.isEmpty ? 1 : 2;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: widget.tags.length + trailingCount,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == widget.tags.length + trailingCount - 1) {
            return SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(
                  widget.selectionMode ? Icons.close : Icons.checklist,
                  size: 18,
                  color: widget.selectionMode
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: widget.selectionMode ? null : t.batch_select,
                onPressed: widget.onToggleSelectionMode,
              ),
            );
          }
          if (index == widget.tags.length && widget.tags.isNotEmpty) {
            return SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.settings,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TagManagementPage()),
                  ).then((_) {
                    ref.invalidate(allTagsProvider);
                    ref.invalidate(bookTagMapProvider);
                  });
                },
              ),
            );
          }
          final tag = widget.tags[index];
          final isSelected = selectedIds.contains(tag.id);
          if (widget.selectionMode) {
            return GestureDetector(
              onTap: () => widget.onToggleFilter(tag.id),
              child: _TagChip(
                tag: tag,
                isSelected: isSelected,
                isDimmed: false,
              ),
            );
          }
          return LongPressDraggable<BookTagRow>(
            data: tag,
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(16),
              child: _TagChip(tag: tag, isSelected: true, isDimmed: false),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child:
                  _TagChip(tag: tag, isSelected: isSelected, isDimmed: false),
            ),
            child: DragTarget<BookTagRow>(
              onWillAcceptWithDetails: (details) => details.data.id != tag.id,
              onAcceptWithDetails: (details) {
                final draggedTag = details.data;
                final oldIdx =
                    widget.tags.indexWhere((t) => t.id == draggedTag.id);
                final newIdx = widget.tags.indexWhere((t) => t.id == tag.id);
                if (oldIdx != -1 && newIdx != -1) {
                  widget.onReorder(oldIdx, newIdx);
                }
              },
              builder: (context, candidateData, rejectedData) {
                return GestureDetector(
                  onTap: () => widget.onToggleFilter(tag.id),
                  child: _TagChip(
                    tag: tag,
                    isSelected: isSelected,
                    isDimmed: candidateData.isNotEmpty,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.isSelected,
    required this.isDimmed,
  });
  final BookTagRow tag;
  final bool isSelected;
  final bool isDimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = Color(tag.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected
            ? tagColor.withValues(alpha: 0.2)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected ? tagColor : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: tagColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            tag.name,
            style: theme.textTheme.labelMedium?.copyWith(
              color: isDimmed
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _BookDragTarget extends StatefulWidget {
  const _BookDragTarget({
    required this.bookId,
    required this.onTagDropped,
    required this.child,
  });
  final int bookId;
  final void Function(BookTagRow tag) onTagDropped;
  final Widget child;

  @override
  State<_BookDragTarget> createState() => _BookDragTargetState();
}

class _BookDragTargetState extends State<_BookDragTarget> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<BookTagRow>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        setState(() => _isHovering = false);
        widget.onTagDropped(details.data);
      },
      onMove: (_) {
        if (!_isHovering) setState(() => _isHovering = true);
      },
      onLeave: (_) {
        if (_isHovering) setState(() => _isHovering = false);
      },
      builder: (context, candidateData, rejectedData) {
        return Stack(
          children: [
            widget.child,
            if (_isHovering)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.add_circle_outline,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

@visibleForTesting
class ReaderHistoryDeleteDialog extends StatelessWidget {
  const ReaderHistoryDeleteDialog({
    required this.title,
    required this.message,
    required this.onConfirm,
    super.key,
  });

  final String title;
  final String message;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.34,
        ),
        child: SingleChildScrollView(
          child: Text(
            message,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: onConfirm,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.errorContainer,
            foregroundColor: theme.colorScheme.onErrorContainer,
          ),
          child: Text(t.dialog_delete),
        ),
      ],
    );
  }
}

class _BookProfileDialog extends StatefulWidget {
  const _BookProfileDialog({
    required this.bookUid,
    required this.profileRepo,
    required this.profiles,
    required this.activeProfileName,
  });

  final String bookUid;
  final ProfileRepository profileRepo;
  final List<ProfileRow> profiles;
  final String activeProfileName;

  @override
  State<_BookProfileDialog> createState() => _BookProfileDialogState();
}

class _BookProfileDialogState extends State<_BookProfileDialog> {
  int? _selectedProfileId;
  bool _loading = true;
  late List<ProfileRow> _profiles;
  late String _activeProfileName;

  @override
  void initState() {
    super.initState();
    _profiles = widget.profiles;
    _activeProfileName = widget.activeProfileName;
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final int? current =
        await widget.profileRepo.getBookProfileId(widget.bookUid);

    if (_profiles.isEmpty || _activeProfileName.isEmpty) {
      _profiles = await widget.profileRepo.getAllProfiles();
      final int activeId = await widget.profileRepo.getActiveProfileId();
      for (final p in _profiles) {
        if (p.id == activeId) {
          _activeProfileName = p.name;
          break;
        }
      }
      if (_activeProfileName.isEmpty && _profiles.isNotEmpty) {
        _activeProfileName = _profiles.first.name;
      }
    }

    if (mounted) {
      setState(() {
        _selectedProfileId = current;
        _loading = false;
      });
    }
  }

  Future<void> _onChanged(int? profileId) async {
    setState(() => _selectedProfileId = profileId);
    if (profileId == null) {
      await widget.profileRepo.removeBookProfile(widget.bookUid);
    } else {
      await widget.profileRepo.setBookProfile(widget.bookUid, profileId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        t.profile_book_profile,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: _loading
          ? const SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator()),
            )
          : BookProfileDialogContent(
              activeProfileName: _activeProfileName,
              profiles: _profiles,
              selectedProfileId: _selectedProfileId,
              onChanged: _onChanged,
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}

@visibleForTesting
class BookProfileDialogContent extends StatelessWidget {
  const BookProfileDialogContent({
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    super.key,
  });

  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.46,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            RadioListTile<int?>(
              title: Text(
                t.profile_follow_default_current(name: activeProfileName),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              value: null,
              groupValue: selectedProfileId,
              onChanged: onChanged,
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
            for (final profile in profiles)
              RadioListTile<int?>(
                title: Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: profile.id,
                groupValue: selectedProfileId,
                onChanged: onChanged,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchTagPickerDialog extends StatefulWidget {
  const _BatchTagPickerDialog({
    required this.allTags,
    required this.selectedKeys,
    required this.database,
    required this.parseBookId,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedKeys;
  final HibikiDatabase database;
  final int? Function(String) parseBookId;

  @override
  State<_BatchTagPickerDialog> createState() => _BatchTagPickerDialogState();
}

class _BatchTagPickerDialogState extends State<_BatchTagPickerDialog> {
  final Set<int> _addTagIds = {};
  final Set<int> _removeTagIds = {};

  Future<void> _apply() async {
    final tr = Translations.of(context);
    final db = widget.database;

    final List<int> epubBookIds = [];
    final List<String> srtUids = [];
    for (final key in widget.selectedKeys) {
      if (key.startsWith('srt_')) {
        srtUids.add(key.substring(4));
      } else {
        final int? id = widget.parseBookId(key);
        if (id != null) epubBookIds.add(id);
      }
    }

    final List<int> srtBookIds = await _resolveSrtBookIds(srtUids);

    for (final tagId in _addTagIds) {
      for (final bookId in epubBookIds) {
        await db.addTagToBook(bookId, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.addTagToSrtBook(srtId, tagId);
      }
    }
    for (final tagId in _removeTagIds) {
      for (final bookId in epubBookIds) {
        await db.removeTagFromBook(bookId, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.removeTagFromSrtBook(srtId, tagId);
      }
    }

    if (!mounted) return;
    for (final tagId in _addTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      HibikiToast.show(
        msg: tr.batch_tag_added(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
      );
    }
    for (final tagId in _removeTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      HibikiToast.show(
        msg: tr.batch_tag_removed(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
      );
    }
    Navigator.pop(context);
  }

  Future<List<int>> _resolveSrtBookIds(List<String> uids) async {
    final List<int> ids = [];
    final repo = SrtBookRepository(widget.database);
    for (final uid in uids) {
      final book = await repo.findByUid(uid);
      if (book?.id != null) ids.add(book!.id!);
    }
    return ids;
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text(
        t.batch_tag_title,
        style: theme.textTheme.titleMedium,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.allTags.length,
          itemBuilder: (_, i) {
            final tag = widget.allTags[i];
            final bool adding = _addTagIds.contains(tag.id);
            final bool removing = _removeTagIds.contains(tag.id);
            final bool? value = adding ? true : (removing ? false : null);
            return CheckboxListTile(
              tristate: true,
              value: value,
              onChanged: (v) {
                setState(() {
                  _addTagIds.remove(tag.id);
                  _removeTagIds.remove(tag.id);
                  if (v == true) {
                    _addTagIds.add(tag.id);
                  } else if (v == false) {
                    _removeTagIds.add(tag.id);
                  }
                });
              },
              secondary: CircleAvatar(
                radius: 12,
                backgroundColor: Color(tag.colorValue),
              ),
              title: Text(tag.name),
              dense: true,
              visualDensity: VisualDensity.compact,
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed:
              _addTagIds.isEmpty && _removeTagIds.isEmpty ? null : _apply,
          child: Text(t.batch_tag_apply),
        ),
      ],
    );
  }
}

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

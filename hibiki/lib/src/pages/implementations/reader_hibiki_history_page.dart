import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:hibiki/utils.dart';

/// 自适应标签列在给定可用高度下能放几个 chip slot。
///
/// 根因守卫：当 [maxHeight] 无界（== infinity，例如标签覆盖层用
/// `Positioned(top, left)`（无 bottom/height）落进 `Stack(fit: StackFit.expand)`
/// 时拿到 unbounded 约束），旧实现 `(maxHeight * 0.55 / chipHeight).floor()` 会在
/// Infinity 上抛 `UnsupportedError: Infinity or NaN toInt` —— 表现为书本打 tag 后
/// 封面卡片渲染异常（debug 红框/错误占位）。无界时返回全部标签数，渲染全部、由父
/// 级自然裁剪，而不是吞异常或硬编码 slot。
@visibleForTesting
int adaptiveTagSlots({
  required double maxHeight,
  required int tagCount,
  double chipHeight = 22.0,
}) {
  if (tagCount <= 0) return 0;
  if (!maxHeight.isFinite) return tagCount;
  final double usable = maxHeight * 0.55;
  return (usable / chipHeight).floor().clamp(1, tagCount);
}

class ReaderHibikiHistoryPage extends HistoryReaderPage {
  const ReaderHibikiHistoryPage({super.key});

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderHibikiHistoryPageState();
}

class _ReaderHibikiHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  @override
  MediaType get mediaType => mediaSource.mediaType;

  @override
  ReaderHibikiSource get mediaSource => ReaderHibikiSource.instance;

  Future<Map<String, _AudiobookInfo>>? _batchAudiobookInfoFuture;
  Map<String, _AudiobookInfo> _batchAudiobookInfoResult = const {};

  Future<Map<String, _AudiobookInfo>> _loadAllAudiobookInfo() async {
    final repo = AudiobookRepository(appModel.database);
    final allAudiobooks = await repo.buildBookKeyMap();
    final result = <String, _AudiobookInfo>{};
    final healthFutures = <String, Future<AudiobookHealth>>{};
    for (final entry in allAudiobooks.entries) {
      healthFutures[entry.key] = repo.resolveHealth(entry.value);
    }
    final healths = <String, AudiobookHealth>{};
    await Future.wait(healthFutures.entries.map((e) async {
      healths[e.key] = await e.value;
    }));
    for (final entry in allAudiobooks.entries) {
      result[entry.key] = _AudiobookInfo(
        hasAudiobook: true,
        healthKind: healths[entry.key]?.kind ?? HealthKind.notApplicable,
      );
    }
    _batchAudiobookInfoResult = result;
    return result;
  }

  _AudiobookInfo _getAudiobookInfo(String bookKey) {
    return _batchAudiobookInfoResult[bookKey] ??
        const _AudiobookInfo(
            hasAudiobook: false, healthKind: HealthKind.notApplicable);
  }

  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};
  List<MediaItem> _visibleEpubBooks = const [];
  List<SrtBook> _visibleSrtBooks = const [];

  // 视频书单独分区：无 Riverpod provider，按需载入 state 并在导入后刷新。
  List<VideoBookRow> _videoBooks = const [];
  Future<List<VideoBookRow>>? _videoBooksFuture;

  VideoBookRepository get _videoRepo => VideoBookRepository(appModel.database);

  Future<List<VideoBookRow>> _loadVideoBooks() async {
    final List<VideoBookRow> rows = await _videoRepo.listAll();
    _videoBooks = rows;
    return rows;
  }

  void _refreshVideoBooks() {
    setState(() {
      _videoBooksFuture = _loadVideoBooks();
    });
  }

  static double _gridExtent(BuildContext context, BoxConstraints constraints) {
    return readerShelfGridExtentForLayout(
      mediaWidth: MediaQuery.sizeOf(context).width,
      contentWidth: constraints.maxWidth,
    );
  }

  void _refreshSrtBooks() {
    ref.invalidate(srtBooksProvider);
    _batchAudiobookInfoFuture = null;
    _batchAudiobookInfoResult = const {};
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
        ref.watch(hibikiBooksProvider(appModel.targetLanguage));
    final AsyncValue<Set<String>?> filteredIds =
        ref.watch(filteredBookIdsProvider);
    final allTags = ref.watch(allTagsProvider);

    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: [
          if (!isCupertinoPlatform(context)) _buildPageHeader(),
          _buildTagBar(allTags.valueOrNull ?? const []),
          Expanded(
            child: books.when(
              data: (bookList) {
                _batchAudiobookInfoFuture ??= _loadAllAudiobookInfo();
                _videoBooksFuture ??= _loadVideoBooks();
                final Set<String>? filterSet = filteredIds.valueOrNull;
                final List<MediaItem> filtered;
                if (filterSet == null) {
                  filtered = bookList;
                } else {
                  filtered = bookList.where((item) {
                    final String? key = _parseBookKey(item.mediaIdentifier);
                    return key != null && filterSet.contains(key);
                  }).toList();
                }
                return FutureBuilder<Map<String, _AudiobookInfo>>(
                  future: _batchAudiobookInfoFuture,
                  builder: (context, abSnapshot) =>
                      FutureBuilder<List<VideoBookRow>>(
                    future: _videoBooksFuture,
                    builder: (context, videoSnapshot) => buildBody(filtered),
                  ),
                );
              },
              error: (error, stack) => buildError(
                error: error,
                stack: stack,
                refresh: () {
                  _refreshSrtBooks();
                  ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
                },
              ),
              loading: () => buildLoading(),
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

  Widget _buildPageHeader() {
    return HibikiPageHeader(
      title: t.books,
      actions: <Widget>[
        mediaSource.buildBookImportButton(
          context: context,
          ref: ref,
          appModel: appModel,
        ),
        // 新导入视频入口门控在 kVideoImportEnabled 后（Phase 3）：已导入视频仍
        // 在书架展示、点开仍可播放查词，仅隐藏新建导入入口。一行可恢复。
        if (kVideoImportEnabled)
          _headerAction(
            tooltip: t.video_import_action,
            icon: Icons.movie_outlined,
            onTap: _openVideoImport,
          ),
        _headerAction(
          tooltip: t.collections,
          icon: Icons.collections_bookmark_outlined,
          onTap: _openCollections,
        ),
        _headerAction(
          tooltip: t.reading_statistics,
          icon: Icons.bar_chart_outlined,
          onTap: _openReadingStatistics,
        ),
      ],
    );
  }

  Widget _headerAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return HibikiIconButton(
      tooltip: tooltip,
      icon: icon,
      onTap: onTap,
    );
  }

  void _openCollections() {
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => const CollectionsPage()),
    );
  }

  void _openReadingStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => const ReadingStatisticsPage()),
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

  Future<void> _addTagToBook(String bookKey, BookTagRow tag) async {
    final existing = ref.read(bookTagMapProvider).valueOrNull;
    final alreadyHas = existing?[bookKey]?.any((t) => t.id == tag.id) ?? false;
    if (alreadyHas) {
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }
    await ref.read(appProvider).database.addTagToBook(bookKey, tag.id);
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

  Widget? _buildTagLabels(String bookKey) {
    final tagMap = ref.watch(bookTagMapProvider).valueOrNull;
    if (tagMap == null) return null;
    final tags = tagMap[bookKey];
    if (tags == null || tags.isEmpty) return null;
    return _adaptiveTagColumn(tags);
  }

  Widget _tagChip(BookTagRow tag) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: tag.name,
        color: Color(tag.colorValue),
      ),
    );
  }

  Widget _overflowChip(int count) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: '+$count',
      ),
    );
  }

  EdgeInsetsDirectional _cardTagChipPadding(HibikiDesignTokens tokens) {
    return EdgeInsetsDirectional.only(
      end: tokens.spacing.gap / 2,
      bottom: tokens.spacing.gap / 4,
    );
  }

  Widget _adaptiveTagColumn(List<BookTagRow> tags) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final int maxSlots = adaptiveTagSlots(
          maxHeight: constraints.maxHeight,
          tagCount: tags.length,
        );

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Set<String> srtBookKeys = {
      for (final b in allSrtBooks)
        if (b.bookKey.isNotEmpty) b.bookKey,
    };
    final List<MediaItem> epubBooks = srtBookKeys.isEmpty
        ? books
        : books.where((item) {
            final String? key = _parseBookKey(item.mediaIdentifier);
            return key == null || !srtBookKeys.contains(key);
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
    // 视频书无标签，标签筛选激活时整组隐藏（与 SRT 同策略）。
    final List<VideoBookRow> videoBooks =
        hasActiveFilter ? const [] : _videoBooks;
    _visibleEpubBooks = epubBooks;
    _visibleSrtBooks = srtBooks;
    if (epubBooks.isEmpty && srtBooks.isEmpty && videoBooks.isEmpty) {
      return hasActiveFilter
          ? Center(
              child: HibikiPlaceholderMessage(
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
            physics: desktopAwareScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.gap)),
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
                  padding:
                      EdgeInsets.all(tokens.spacing.card + tokens.spacing.gap),
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
            SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.gap)),
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
            if (videoBooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _buildSectionHeader(t.shelf_video_section)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: mediaSource.aspectRatio,
                ),
                itemCount: videoBooks.length,
                itemBuilder: (_, i) => _buildVideoCard(videoBooks[i]),
              ),
            ],
            if (epubBooks.isNotEmpty) ...[
              if (srtBooks.isNotEmpty || videoBooks.isNotEmpty)
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap,
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap / 4,
      ),
      child: Text(
        label,
        // Shared MD3 section label (labelLarge / primary / w600) — same role as
        // the settings detail section headers, replacing the ad-hoc styling.
        style: tokens.type.sectionLabel,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    final String selKey = 'srt_${book.uid}';
    final tagWidget = book.id != null ? _buildSrtBookTagLabels(book.id!) : null;
    final int? srtBookId = book.id;
    return _bookCardShell(
      cardKey: ValueKey<String>('srt_entry_${book.uid}'),
      focusId: HibikiFocusId('reader-shelf-srt-${book.uid}'),
      selectionKey: selKey,
      dragBookId: srtBookId,
      onTagDropped:
          srtBookId == null ? null : (tag) => _addTagToSrtBook(srtBookId, tag),
      onTap: () => _openSrtBook(book),
      onLongPress: () => _showSrtBookDialog(book),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildSrtCover(book),
          _titleOverlay(book.title),
          Positioned(
            top: overlayInset,
            right: overlayInset,
            child: _cardBadge(
              icon: Icons.subtitles_outlined,
              background: theme.colorScheme.secondaryContainer,
              foreground: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          if (tagWidget != null)
            Positioned(
              top: overlayInset,
              left: overlayInset,
              child: tagWidget,
            ),
        ],
      ),
    );
  }

  Widget _buildVideoCard(VideoBookRow book) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    return _bookCardShell(
      cardKey: ValueKey<String>('video_entry_${book.bookUid}'),
      focusId: HibikiFocusId('reader-shelf-video-${book.bookUid}'),
      onTap: () => _openVideoBook(book),
      onLongPress: () => _openVideoBook(book),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideoCover(book),
          _titleOverlay(book.title),
          Positioned(
            top: overlayInset,
            right: overlayInset,
            child: _cardBadge(
              icon: Icons.movie_outlined,
              background: theme.colorScheme.tertiaryContainer,
              foreground: theme.colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoCover(VideoBookRow book) {
    final String? cover = book.coverPath;
    if (cover != null && File(cover).existsSync()) {
      return FadeInImage(
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.movie_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(cover)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    return _coverPlaceholderIcon(Icons.movie_outlined);
  }

  void _openVideoBook(VideoBookRow book) {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) =>
            VideoHibikiPage(bookUid: book.bookUid, repo: _videoRepo),
      ),
    );
  }

  Future<void> _openVideoImport() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: _videoRepo),
    );
    if (bookUid != null) {
      _refreshVideoBooks();
    }
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
    HibikiFocusId? focusId,
    String? selectionKey,
    Object? dragBookId,
    void Function(BookTagRow tag)? onTagDropped,
  }) {
    final bool selected =
        selectionKey != null && _selectedKeys.contains(selectionKey);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    final double selectionInset = tokens.spacing.gap / 2;
    final double selectionPadding = tokens.spacing.gap / 4;
    final double selectionIconSize = tokens.spacing.gap * 1.75;
    // Gamepad long-press (hold A) on the focused card invokes the same
    // onLongPress as the mouse (book details / actions). In selection mode the
    // long-press is disabled (tap toggles selection), so it's a pass-through.
    final Widget card = GamepadLongPressActions(
      onLongPress: _selectionMode ? null : onLongPress,
      child: HibikiCard(
        key: cardKey,
        focusId: focusId,
        padding: EdgeInsets.zero,
        margin: EdgeInsets.all(tokens.spacing.rowVertical),
        selected: selected,
        onTap: _selectionMode && selectionKey != null
            ? () => _toggleSelection(selectionKey)
            : onTap,
        onLongPress: _selectionMode ? null : onLongPress,
        // 桌面端鼠标右键打开与长按相同的书籍上下文菜单（PC 用户惯例）。
        onSecondaryTap: _selectionMode ? null : onLongPress,
        child: AspectRatio(
          aspectRatio: mediaSource.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (_selectionMode && selectionKey != null)
                Positioned(
                  top: selectionInset,
                  left: selectionInset,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? selectionColor
                            : tokens.surfaces.page.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? selectionColor
                              : tokens.surfaces.outline,
                          width: 1.5,
                        ),
                      ),
                      padding: EdgeInsets.all(selectionPadding),
                      child: Icon(
                        Icons.check,
                        size: selectionIconSize,
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
                        color: tokens.surfaces.primary.withValues(alpha: 0.12),
                        borderRadius: tokens.radii.cardRadius,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (dragBookId == null || onTagDropped == null || _selectionMode) {
      return card;
    }
    return BookDragTarget(
      bookId: dragBookId,
      onTagDropped: onTagDropped,
      child: card,
    );
  }

  Widget _titleOverlay(String title) {
    return LayoutBuilder(builder: (context, constraints) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: constraints.maxHeight * 0.38,
          width: double.infinity,
          alignment: Alignment.bottomCenter,
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.spacing.gap * 0.75,
            tokens.spacing.gap / 2,
            tokens.spacing.gap * 0.75,
            tokens.spacing.gap * 0.75,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tokens.surfaces.page.withValues(alpha: 0),
                tokens.surfaces.page.withValues(alpha: 0.85),
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
              color: tokens.surfaces.onSurface,
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
    return HibikiBadge(
      icon: icon,
      background: background,
      foreground: foreground,
    );
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    return MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(book.bookKey),
      title: book.title,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
      imageUrl:
          book.coverPath != null ? Uri.file(book.coverPath!).toString() : null,
    );
  }

  void _openSrtBook(SrtBook book) {
    if (book.bookKey.isEmpty) {
      HibikiToast.show(msg: t.srt_epub_not_ready);
      return;
    }
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => HibikiAppUiScaleNeutralizer(
          child: ReaderHibikiPage(
            bookKey: book.bookKey,
            item: _srtBookMediaItem(book),
          ),
        ),
      ),
    );
  }

  List<DialogAction> _srtExtraActions(
      BuildContext dialogContext, SrtBook book) {
    final String bookKey = book.bookKey;
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
      if (bookKey.isNotEmpty) ...[
        DialogQuickAction(
          label: t.audio_import,
          icon: Icons.headphones_outlined,
          onPressed: () => _openAudioImport(item, bookKey),
        ),
        DialogListAction(
          label: t.profile_book_profile,
          onPressed: () => _openBookProfilePicker(item, bookKey),
        ),
        DialogListAction(
          label: t.book_css_editor_edit_css,
          onPressed: () {
            Navigator.pop(dialogContext);
            _openCssEditor(bookKey);
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - tokens.spacing.gap / 2,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: [
              Text(
                t.batch_selected_count(n: _selectedKeys.length),
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              TextButton(
                onPressed: _selectAll,
                child: Text(t.batch_select_all),
              ),
              TextButton(
                onPressed: _invertSelection,
                child: Text(t.batch_invert_selection),
              ),
              const Spacer(),
              HibikiIconButton(
                enabled: _selectedKeys.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                enabled: _selectedKeys.isNotEmpty,
                onTap: _batchDeleteConfirm,
                icon: Icons.delete_outline,
                tooltip: t.dialog_delete,
                enabledColor: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _batchDeleteConfirm() async {
    final int count = _selectedKeys.length;
    final bool? confirmed = await showAppDialog<bool>(
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
          if (book.bookKey.isNotEmpty) {
            await ReaderHibikiSource.instance.deleteBook(
              db: appModel.database,
              bookKey: book.bookKey,
            );
          }
          await repo.delete(uid);
          deleted++;
        }
      } else {
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) {
          final bool ok = await ReaderHibikiSource.instance.deleteBook(
            db: appModel.database,
            bookKey: bookKey,
          );
          if (ok) deleted++;
        }
      }
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
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
    await showAppDialog<void>(
      context: context,
      builder: (_) => _BatchTagPickerDialog(
        allTags: allTags,
        selectedKeys: _selectedKeys,
        database: appModel.database,
        parseBookKey: _parseBookKey,
      ),
    );
    if (!mounted) return;
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    ref.invalidate(filteredSrtBookIdsProvider);
  }

  Future<void> _confirmDeleteSrtBook(SrtBook book) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.srt_delete_title,
        message: t.srt_delete_confirm(title: book.title),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    if (book.bookKey.isNotEmpty) {
      await ReaderHibikiSource.instance.deleteBook(
        db: appModel.database,
        bookKey: book.bookKey,
      );
    }
    await SrtBookRepository(appModel.database).delete(book.uid);
    if (mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
      setState(() {});
    }
  }

  @override
  Widget buildPlaceholder() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HibikiPlaceholderMessage(
            icon: mediaSource.icon,
            message: t.ttu_no_books_added,
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          FilledButton.icon(
            icon: const Icon(Icons.library_add_outlined, size: 18),
            label: Text(t.srt_import),
            onPressed: () async {
              final bool? imported = await showAppDialog<bool>(
                context: context,
                builder: (_) => BookImportDialog(
                  repo: SrtBookRepository(appModel.database),
                  audiobookRepo: AudiobookRepository(appModel.database),
                  db: appModel.database,
                ),
              );
              if (imported == true) {
                ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
                ref.invalidate(srtBooksProvider);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget buildMediaItemContent(MediaItem item) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    // Audiobook info is keyed by the book's bookKey (the Audiobooks table key),
    // NOT the MediaItem.uniqueKey (which is the source-prefixed identifier).
    final info = _getAudiobookInfo(bookKey ?? '');
    final bool hasAudiobook = info.hasAudiobook;
    final HealthKind healthKind = info.healthKind;

    final tagWidget = bookKey != null ? _buildTagLabels(bookKey) : null;

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
          top: overlayInset,
          right: overlayInset,
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
            top: overlayInset,
            left: overlayInset,
            child: tagWidget,
          ),
      ],
    );
  }

  @override
  Widget buildMediaItem(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    return _bookCardShell(
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      focusId: HibikiFocusId('reader-shelf-book-${item.mediaIdentifier}'),
      selectionKey: item.mediaIdentifier,
      dragBookId: bookKey,
      onTagDropped:
          bookKey == null ? null : (tag) => _addTagToBook(bookKey, tag),
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
      color: theme.colorScheme.primary,
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
      icon: Icons.headphones_outlined,
      background: bg,
      foreground: fg,
    );
  }

  @override
  List<DialogAction> extraActions(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    if (bookKey == null) return const [];
    return <DialogAction>[
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () => _confirmDeleteEpub(item, bookKey),
      ),
      DialogQuickAction(
        label: t.view_illustrations,
        icon: Icons.image_outlined,
        onPressed: () => _openIllustrations(item, bookKey),
      ),
      DialogQuickAction(
        label: t.audiobook_import,
        icon: Icons.headphones_outlined,
        onPressed: () => _openAudiobookImport(item, bookKey),
      ),
      DialogQuickAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openTagPicker(bookKey),
      ),
      DialogListAction(
        label: t.profile_book_profile,
        onPressed: () => _openBookProfilePicker(item, bookKey),
      ),
      DialogListAction(
        label: t.book_css_editor_edit_css,
        onPressed: () => _openCssEditor(bookKey),
      ),
    ];
  }

  Future<void> _confirmDeleteEpub(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: t.srt_delete_confirm(title: item.title),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    final bool ok = await ReaderHibikiSource.instance.deleteBook(
      db: appModel.database,
      bookKey: bookKey,
    );
    if (!mounted) return;
    if (!ok) {
      HibikiToast.show(msg: t.epub_delete_error);
      return;
    }
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    setState(() {});
  }

  String? _parseBookKey(String mediaIdentifier) =>
      ReaderHibikiSource.parseBookKey(mediaIdentifier);

  Future<void> _openIllustrations(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted || row == null) return;
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => IllustrationsViewerPage(
          bookTitle: item.title,
          extractDir: row.extractDir,
        ),
      ),
    );
  }

  Future<void> _openAudioImport(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        audioOnly: true,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openAudiobookImport(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _openTagPicker(String bookKey) {
    Navigator.pop(context);
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => TagPickerPage(bookKey: bookKey)),
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
      adaptivePageRoute(
        builder: (_) => TagPickerPage(srtBookId: srtBookId, isSrtBook: true),
      ),
    ).then((_) {
      ref.invalidate(srtBookTagMapProvider);
      ref.invalidate(filteredSrtBookIdsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  Future<void> _openCssEditor(String bookKey) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    final String extractDir = row?.extractDir ?? '';
    final bool exists = await EpubStorage.bookDirExists(extractDir);
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.book_css_editor_no_extract_dir)),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.push(
        context,
        adaptivePageRoute<void>(
          builder: (_) => BookCssEditorPage(extractDir: extractDir),
        ),
      );
    }
  }

  void _openBookProfilePicker(MediaItem item, String bookKey) {
    Navigator.pop(context);
    final String bookUid = bookKey;
    final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
    final ProfileUiState profileState = ref.read(profileViewModelProvider);

    showAppDialog<void>(
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
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    final int trailingCount = widget.tags.isEmpty ? 1 : 2;

    return Container(
      height: tokens.spacing.gap * 5.5,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: tokens.surfaces.outline.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.gap * 0.75,
        ),
        itemCount: widget.tags.length + trailingCount,
        separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap * 0.75),
        itemBuilder: (context, index) {
          if (index == widget.tags.length + trailingCount - 1) {
            return _tagBarAction(
              icon:
                  widget.selectionMode ? Icons.close : Icons.checklist_outlined,
              tooltip: widget.selectionMode
                  ? MaterialLocalizations.of(context).closeButtonTooltip
                  : t.batch_select,
              selected: widget.selectionMode,
              onTap: widget.onToggleSelectionMode,
            );
          }
          if (index == widget.tags.length && widget.tags.isNotEmpty) {
            return _tagBarAction(
              icon: Icons.settings_outlined,
              tooltip: t.tag_manage,
              onTap: () {
                Navigator.push(
                  context,
                  adaptivePageRoute(builder: (_) => const TagManagementPage()),
                ).then((_) {
                  ref.invalidate(allTagsProvider);
                  ref.invalidate(bookTagMapProvider);
                });
              },
            );
          }
          final tag = widget.tags[index];
          final isSelected = selectedIds.contains(tag.id);
          if (widget.selectionMode) {
            return _tagFilterChip(
              tag: tag,
              isSelected: isSelected,
              isDimmed: false,
              onTap: () => widget.onToggleFilter(tag.id),
            );
          }
          return LongPressDraggable<BookTagRow>(
            data: tag,
            feedback: Material(
              color: Colors.transparent,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: tokens.radii.chipRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: _tagFilterChip(
                tag: tag,
                isSelected: true,
                isDimmed: false,
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _tagFilterChip(
                tag: tag,
                isSelected: isSelected,
                isDimmed: false,
              ),
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
                return _tagFilterChip(
                  tag: tag,
                  isSelected: isSelected,
                  isDimmed: candidateData.isNotEmpty,
                  onTap: () => widget.onToggleFilter(tag.id),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _tagBarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiIconButton(
      icon: icon,
      tooltip: tooltip,
      size: tokens.spacing.gap * 2.25,
      padding: EdgeInsets.all(tokens.spacing.gap * 0.875),
      enabledColor:
          selected ? tokens.surfaces.primary : tokens.surfaces.onVariant,
      onTap: onTap,
    );
  }

  Widget _tagFilterChip({
    required BookTagRow tag,
    required bool isSelected,
    required bool isDimmed,
    VoidCallback? onTap,
  }) {
    return HibikiTagChip(
      label: tag.name,
      color: Color(tag.colorValue),
      selected: isSelected,
      dimmed: isDimmed,
      tone: HibikiTagChipTone.surface,
      onTap: onTap,
    );
  }
}

@visibleForTesting
class BookDragTarget extends StatefulWidget {
  const BookDragTarget({
    required this.bookId,
    required this.onTagDropped,
    required this.child,
    super.key,
  });

  /// Drag-target identity marker (EPUB bookKey String or SRT srtBookId int).
  /// Only used to distinguish targets; the drop action is carried by
  /// [onTagDropped], so the concrete type is irrelevant here.
  final Object bookId;
  final void Function(BookTagRow tag) onTagDropped;
  final Widget child;

  @override
  State<BookDragTarget> createState() => _BookDragTargetState();
}

class _BookDragTargetState extends State<BookDragTarget> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color hoverColor = tokens.surfaces.primary;
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
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_isHovering)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hoverColor.withValues(alpha: 0.2),
                    borderRadius: tokens.radii.cardRadius,
                    border: Border.all(
                      color: hoverColor,
                      width: tokens.spacing.gap / 4,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.add_circle_outline,
                      color: hoverColor,
                      size: tokens.spacing.gap * 4,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: Icons.delete_outline,
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
          message,
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
              onPressed: onConfirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
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
    return BookProfileDialogFrame(
      loading: _loading,
      activeProfileName: _activeProfileName,
      profiles: _profiles,
      selectedProfileId: _selectedProfileId,
      onChanged: _onChanged,
      onClose: () => Navigator.pop(context),
    );
  }
}

@visibleForTesting
class BookProfileDialogFrame extends StatelessWidget {
  const BookProfileDialogFrame({
    required this.loading,
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    required this.onClose,
    super.key,
  });

  final bool loading;
  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 500,
      maxHeightFactor: 0.86,
      // HibikiModalSheetFrame manages its own header/body/footer layout and
      // scrolls its body internally. Leaving the dialog frame's default
      // scrollable:true would wrap it in a second SingleChildScrollView, giving
      // a confusing nested outer+inner double scroll. scrollable:false makes the
      // ConstrainedBox bound the sheet directly, matching every other dialog.
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.profile_book_profile,
        leadingIcon: Icons.manage_accounts_outlined,
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
        body: loading
            ? SizedBox(
                height: 64,
                child: Center(child: adaptiveIndicator(context: context)),
              )
            : BookProfileDialogContent(
                activeProfileName: activeProfileName,
                profiles: profiles,
                selectedProfileId: selectedProfileId,
                onChanged: onChanged,
              ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onClose,
            child: Text(t.dialog_close),
          ),
        ),
      ),
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
            AdaptiveSettingsSection(
              children: [
                _BookProfileOptionRow(
                  title: t.profile_follow_default_current(
                    name: activeProfileName,
                  ),
                  selected: selectedProfileId == null,
                  onTap: () => onChanged(null),
                ),
                for (final profile in profiles)
                  _BookProfileOptionRow(
                    title: profile.name,
                    selected: selectedProfileId == profile.id,
                    onTap: () => onChanged(profile.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProfileOptionRow extends StatelessWidget {
  const _BookProfileOptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color selectedColor = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;
    final Color idleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return AdaptiveSettingsRow(
      title: title,
      onTap: onTap,
      trailing: Icon(
        selected
            ? (cupertino
                ? CupertinoIcons.check_mark
                : Icons.radio_button_checked)
            : (cupertino ? CupertinoIcons.circle : Icons.radio_button_off),
        size: cupertino ? 20 : 22,
        color: selected ? selectedColor : idleColor,
      ),
    );
  }
}

class _BatchTagPickerDialog extends StatefulWidget {
  const _BatchTagPickerDialog({
    required this.allTags,
    required this.selectedKeys,
    required this.database,
    required this.parseBookKey,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedKeys;
  final HibikiDatabase database;
  final String? Function(String) parseBookKey;

  @override
  State<_BatchTagPickerDialog> createState() => _BatchTagPickerDialogState();
}

class _BatchTagPickerDialogState extends State<_BatchTagPickerDialog> {
  final Set<int> _addTagIds = {};
  final Set<int> _removeTagIds = {};

  Future<void> _apply() async {
    final tr = Translations.of(context);
    final db = widget.database;

    final List<String> epubBookKeys = [];
    final List<String> srtUids = [];
    for (final key in widget.selectedKeys) {
      if (key.startsWith('srt_')) {
        srtUids.add(key.substring(4));
      } else {
        final String? bookKey = widget.parseBookKey(key);
        if (bookKey != null) epubBookKeys.add(bookKey);
      }
    }

    final List<int> srtBookIds = await _resolveSrtBookIds(srtUids);

    for (final tagId in _addTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.addTagToBook(bookKey, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.addTagToSrtBook(srtId, tagId);
      }
    }
    for (final tagId in _removeTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.removeTagFromBook(bookKey, tagId);
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

  void _setTagIntent(BookTagRow tag, _BatchTagIntent intent) {
    setState(() {
      _addTagIds.remove(tag.id);
      _removeTagIds.remove(tag.id);
      switch (intent) {
        case _BatchTagIntent.keep:
          break;
        case _BatchTagIntent.add:
          _addTagIds.add(tag.id);
        case _BatchTagIntent.remove:
          _removeTagIds.add(tag.id);
      }
    });
  }

  _BatchTagIntent _tagIntent(BookTagRow tag) {
    if (_addTagIds.contains(tag.id)) return _BatchTagIntent.add;
    if (_removeTagIds.contains(tag.id)) return _BatchTagIntent.remove;
    return _BatchTagIntent.keep;
  }

  @override
  Widget build(BuildContext context) {
    return ReaderHistoryBatchTagDialogFrame(
      canApply: _addTagIds.isNotEmpty || _removeTagIds.isNotEmpty,
      onApply: _apply,
      body: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.allTags.length,
        itemBuilder: (_, i) {
          final tag = widget.allTags[i];
          return _BatchTagIntentRow(
            tag: tag,
            selected: _tagIntent(tag),
            onChanged: (intent) => _setTagIntent(tag, intent),
          );
        },
      ),
    );
  }
}

@visibleForTesting
class ReaderHistoryBatchTagDialogFrame extends StatelessWidget {
  const ReaderHistoryBatchTagDialogFrame({
    required this.body,
    required this.canApply,
    required this.onApply,
    super.key,
  });

  final Widget body;
  final bool canApply;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.batch_tag_title,
        leadingIcon: Icons.sell_outlined,
        scrollable: true,
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
        body: body,
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
              onPressed: canApply ? onApply : null,
              child: Text(t.batch_tag_apply),
            ),
          ],
        ),
      ),
    );
  }
}

enum _BatchTagIntent { keep, add, remove }

class _BatchTagIntentRow extends StatelessWidget {
  const _BatchTagIntentRow({
    required this.tag,
    required this.selected,
    required this.onChanged,
  });

  final BookTagRow tag;
  final _BatchTagIntent selected;
  final ValueChanged<_BatchTagIntent> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final ThemeData theme = Theme.of(context);
    final Color tagColor = Color(tag.colorValue);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return AdaptiveSettingsRow(
      title: tag.name,
      icon: cupertino ? CupertinoIcons.tag : Icons.sell_outlined,
      controlBelow: true,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 12, height: 12),
            ),
            SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
            Flexible(
              child: adaptiveSegmentedButton<_BatchTagIntent>(
                context: context,
                segments: [
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.keep,
                    tooltip: t.batch_tag_keep,
                    icon: Icon(
                      cupertino
                          ? CupertinoIcons.minus
                          : Icons.horizontal_rule_outlined,
                      size: 16,
                    ),
                  ),
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.add,
                    tooltip: t.batch_tag_add,
                    icon: Icon(
                      cupertino ? CupertinoIcons.plus : Icons.add,
                      size: 16,
                    ),
                  ),
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.remove,
                    tooltip: t.batch_tag_remove,
                    icon: Icon(
                      cupertino ? CupertinoIcons.xmark : Icons.remove,
                      size: 16,
                      color: selected == _BatchTagIntent.remove
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
                selected: {selected},
                onSelectionChanged: (values) {
                  if (values.isNotEmpty) onChanged(values.first);
                },
                style: kSettingsSegmentedStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

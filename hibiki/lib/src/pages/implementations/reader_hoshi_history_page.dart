import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
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

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<MediaItem>> books =
        ref.watch(hoshiBooksProvider(appModel.targetLanguage));

    return books.when(
      data: buildBody,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
        },
      ),
      loading: buildLoading,
    );
  }

  Widget buildBody(List<MediaItem> books) {
    return FutureBuilder<List<SrtBook>>(
      future: SrtBookRepository(appModel.database).listAll(),
      builder: (context, srtSnapshot) {
        final List<SrtBook> srtBooks = srtSnapshot.data ?? const [];
        return _buildBodyWithSrtBooks(books, srtBooks);
      },
    );
  }

  Widget _buildBodyWithSrtBooks(List<MediaItem> books, List<SrtBook> srtBooks) {
    final Set<int> srtBookIds = {
      for (final b in srtBooks)
        if (b.ttuBookId > 0) b.ttuBookId,
    };
    final List<MediaItem> epubBooks = srtBookIds.isEmpty
        ? books
        : books.where((MediaItem item) {
            final int? id = _parseBookId(item.mediaIdentifier);
            return id == null || !srtBookIds.contains(id);
          }).toList();

    if (epubBooks.isEmpty && srtBooks.isEmpty) {
      return buildPlaceholder();
    }
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: mediaType.scrollController,
      child: CustomScrollView(
        controller: mediaType.scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          if (srtBooks.isNotEmpty) ...[
            SliverToBoxAdapter(child: _buildSectionHeader(t.srt_books_section)),
            SliverPadding(
              padding: EdgeInsets.zero,
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 150,
                  childAspectRatio: mediaSource.aspectRatio,
                ),
                itemCount: srtBooks.length,
                itemBuilder: (_, i) => _buildSrtCard(srtBooks[i]),
              ),
            ),
          ],
          if (epubBooks.isNotEmpty) ...[
            if (srtBooks.isNotEmpty)
              SliverToBoxAdapter(child: _buildSectionHeader('EPUB')),
            SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                childAspectRatio: mediaSource.aspectRatio,
              ),
              itemCount: epubBooks.length,
              itemBuilder: (_, i) => buildMediaItem(epubBooks[i]),
            ),
          ],
        ],
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

  Widget _buildSrtCard(SrtBook book) {
    return _bookCardShell(
      onTap: () => _openSrtBook(book),
      onLongPress: () => _confirmDeleteSrtBook(book),
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
        ],
      ),
    );
  }

  Widget _buildSrtCover(SrtBook book) {
    if (book.coverPath != null && File(book.coverPath!).existsSync()) {
      return FadeInImage(
        key: UniqueKey(),
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
  }) {
    return Padding(
      padding: Spacing.of(context).insets.all.normal,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: AspectRatio(
            aspectRatio: mediaSource.aspectRatio,
            child: child,
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
          height: constraints.maxHeight * 0.32,
          width: double.infinity,
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
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

  void _openSrtBook(SrtBook book) {
    if (book.ttuBookId <= 0) {
      Fluttertoast.showToast(msg: t.srt_epub_not_ready);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderHoshiPage(
          bookId: book.ttuBookId,
          item: MediaItem(
            mediaIdentifier: ReaderHoshiSource.mediaIdentifierFor(book.ttuBookId),
            title: book.title,
            mediaTypeIdentifier:
                ReaderHoshiSource.instance.mediaType.uniqueKey,
            mediaSourceIdentifier: ReaderHoshiSource.instance.uniqueKey,
            position: 0,
            duration: 1,
            canDelete: false,
            canEdit: true,
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteSrtBook(SrtBook book) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.srt_delete_title),
        content: Text(t.srt_delete_confirm(title: book.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          _destructiveConfirmButton(
            label: t.dialog_delete,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
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
      future: _loadAudiobookInfo(item.uniqueKey),
      builder: (context, snapshot) {
        final bool hasAudiobook = snapshot.data?.hasAudiobook ?? false;
        final HealthKind healthKind =
            snapshot.data?.healthKind ?? HealthKind.notApplicable;

        return Stack(
          fit: StackFit.expand,
          children: [
            FadeInImage(
              key: UniqueKey(),
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
    return _bookCardShell(
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
  List<Widget> extraActions(MediaItem item) {
    final int? bookId = _parseBookId(item.mediaIdentifier);
    if (bookId == null) return const [];
    return <Widget>[
      _destructiveConfirmButton(
        label: t.dialog_delete,
        onPressed: () => _confirmDeleteEpub(item, bookId),
      ),
      TextButton(
        onPressed: () => _openIllustrations(item, bookId),
        child: Text(t.view_illustrations),
      ),
      TextButton(
        onPressed: () => _openAudiobookImport(item, bookId),
        child: Text(t.audiobook_import),
      ),
    ];
  }

  Widget _destructiveConfirmButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: theme.colorScheme.errorContainer,
        foregroundColor: theme.colorScheme.onErrorContainer,
      ),
      child: Text(label),
    );
  }

  Future<void> _confirmDeleteEpub(MediaItem item, int bookId) async {
    Navigator.pop(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.epub_delete_title),
        content: Text(t.srt_delete_confirm(title: item.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          _destructiveConfirmButton(
            label: t.dialog_delete,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final bool ok = await ReaderHoshiSource.instance.deleteBook(
      db: appModel.database,
      bookId: bookId,
    );
    if (!mounted) return;
    if (!ok) {
      Fluttertoast.showToast(msg: t.epub_delete_error);
      return;
    }
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
}

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

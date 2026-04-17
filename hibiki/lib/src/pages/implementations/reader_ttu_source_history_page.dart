import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/utils.dart';

/// A page for [ReaderTtuSource]'s tab body content when selected as a source
/// in the main menu.
class ReaderTtuSourceHistoryPage extends HistoryReaderPage {
  /// Create an instance of this tab page.
  const ReaderTtuSourceHistoryPage({
    super.key,
  });

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderTtuSourceHistoryPageState();
}

/// A base class for providing all tabs in the main menu. In large part, this
/// was implemented to define shortcuts for common lengthy methods across UI
/// code.
class _ReaderTtuSourceHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  @override
  MediaType get mediaType => mediaSource.mediaType;

  @override
  ReaderTtuSource get mediaSource => ReaderTtuSource.instance;

  final ValueNotifier<int> _tryAgainCountdownNotifier = ValueNotifier(0);
  Timer? _timer;

  @override
  Widget build(BuildContext context) {
    AsyncValue<LocalAssetsServer> server =
        ref.watch(ttuServerProvider(appModel.targetLanguage));

    return server.when(
        data: buildData,
        loading: buildLoading,
        error: (error, stack) {
          if (_tryAgainCountdownNotifier.value == 0) {
            _tryAgainCountdownNotifier.value = 5;
          }

          if (error is SocketException) {
            _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
              _tryAgainCountdownNotifier.value -= 1;
              if (_tryAgainCountdownNotifier.value <= 0) {
                ref.invalidate(ttuServerProvider(appModel.targetLanguage));
                _timer?.cancel();
                _timer = null;
              }
            });

            return Center(
              child: ValueListenableBuilder<int>(
                valueListenable: _tryAgainCountdownNotifier,
                builder: (_, __, ___) => JidoujishoPlaceholderMessage(
                  icon: Icons.lan,
                  message: '${t.server_port_in_use}\n${t.retrying_in.seconds(
                    n: _tryAgainCountdownNotifier.value,
                  )}',
                ),
              ),
            );
          }

          return buildError(
            error: error,
            stack: stack,
            refresh: () {
              ref.invalidate(ttuServerProvider(appModel.targetLanguage));
            },
          );
        });
  }

  Widget buildData(LocalAssetsServer server) {
    AsyncValue<List<MediaItem>> books =
        ref.watch(ttuBooksProvider(appModel.targetLanguage));

    return books.when(
      data: buildBody,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
        },
      ),
      loading: buildLoading,
    );
  }

  Widget buildBody(List<MediaItem> books) {
    final List<SrtBook> srtBooks =
        SrtBookRepository(appModel.database).listAll();

    // 字幕导入会把生成的 EPUB 也塞进 ttu IDB，这里把那几条 ID 从 EPUB 区剔除，
    // 避免同一本书同时出现在「字幕」和「EPUB」两个区。
    final Set<int> srtTtuIds = {
      for (final b in srtBooks)
        if (b.ttuBookId > 0) b.ttuBookId,
    };
    final List<MediaItem> epubBooks = srtTtuIds.isEmpty
        ? books
        : books.where((item) {
            final int? id = _parseTtuBookId(item.mediaIdentifier);
            return id == null || !srtTtuIds.contains(id);
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
          // spacing for the floating search bar
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
          // ── SRT section ───────────────────────────────────────────────────
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
          // ── EPUB section ──────────────────────────────────────────────────
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
    return GestureDetector(
      onTap: () => _openSrtBook(book),
      onLongPress: () => _confirmDeleteSrtBook(book),
      child: Container(
        padding: Spacing.of(context).insets.all.normal,
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            ColoredBox(
              color: Colors.grey.shade800.withValues(alpha: 0.3),
              child: AspectRatio(
                aspectRatio: mediaSource.aspectRatio,
                child: _buildSrtCover(book),
              ),
            ),
            LayoutBuilder(builder: (context, constraints) {
              return Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
                height: constraints.maxHeight * 0.25,
                width: double.maxFinite,
                color: Colors.black.withValues(alpha: 0.6),
                child: Text(
                  book.title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: textTheme.bodySmall!.copyWith(
                    color: Colors.white,
                    fontSize: textTheme.bodySmall!.fontSize! * 0.9,
                  ),
                ),
              );
            }),
            // headphones badge
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.subtitles_outlined,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSrtCover(SrtBook book) {
    if (book.coverPath != null && File(book.coverPath!).existsSync()) {
      return FadeInImage(
        key: UniqueKey(),
        imageErrorBuilder: (_, __, ___) => _srtPlaceholderIcon(),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(book.coverPath!)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    return _srtPlaceholderIcon();
  }

  Widget _srtPlaceholderIcon() {
    return Center(
      child: Icon(
        Icons.subtitles_outlined,
        size: 40,
        color: Colors.white.withValues(alpha: 0.4),
      ),
    );
  }

  void _openSrtBook(SrtBook book) {
    if (book.ttuBookId <= 0) {
      Fluttertoast.showToast(msg: t.srt_epub_not_ready);
      return;
    }
    final int port = ReaderTtuSource.instance
        .getPortForLanguage(appModel.targetLanguage);
    final String url =
        'http://localhost:$port/b.html?id=${book.ttuBookId}&title=${Uri.encodeComponent(book.title)}';
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderTtuSourcePage(
          item: MediaItem(
            mediaIdentifier: url,
            title: book.title,
            mediaTypeIdentifier:
                ReaderTtuSource.instance.mediaType.uniqueKey,
            mediaSourceIdentifier: ReaderTtuSource.instance.uniqueKey,
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!mounted) {
      return;
    }
    await SrtBookRepository(appModel.database).delete(book.uid);
    if (mounted) {
      setState(() {});
    }
  }

  /// This is shown as the body when [shouldPlaceholderBeShown] is true.
  @override
  Widget buildPlaceholder() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: mediaSource.icon,
        message: t.ttu_no_books_added,
      ),
    );
  }

  /// 书架卡片，附加有声书角标。
  @override
  Widget buildMediaItemContent(MediaItem item) {
    final bool hasAudiobook = AudiobookRepository(appModel.database)
            .findByBookUid(item.uniqueKey) !=
        null;

    return Container(
      padding: Spacing.of(context).insets.all.normal,
      child: Stack(
        alignment: Alignment.bottomLeft,
        children: [
          ColoredBox(
            color: Colors.grey.shade800.withValues(alpha: 0.3),
            child: AspectRatio(
              aspectRatio: mediaSource.aspectRatio,
              child: FadeInImage(
                key: UniqueKey(),
                imageErrorBuilder: (_, __, ___) => const SizedBox.shrink(),
                placeholder: MemoryImage(kTransparentImage),
                image: mediaSource.getDisplayThumbnailFromMediaItem(
                  appModel: appModel,
                  item: item,
                ),
                alignment: Alignment.topCenter,
                fit: BoxFit.fitHeight,
              ),
            ),
          ),
          LayoutBuilder(builder: (context, constraints) {
            return Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
              height: constraints.maxHeight * 0.25,
              width: double.maxFinite,
              color: Colors.black.withValues(alpha: 0.6),
              child: Text(
                mediaSource.getDisplayTitleFromMediaItem(item),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
                textAlign: TextAlign.center,
                softWrap: true,
                style: textTheme.bodySmall!.copyWith(
                    color: Colors.white,
                    fontSize: textTheme.bodySmall!.fontSize! * 0.9),
              ),
            );
          }),
          LinearProgressIndicator(
            value: (item.position / item.duration).isNaN ||
                    (item.position / item.duration) == double.infinity ||
                    (item.position == 0 && item.duration == 0)
                ? 0
                : ((item.position / item.duration) > 0.97)
                    ? 1
                    : (item.position / item.duration),
            backgroundColor: Colors.white.withValues(alpha: 0.6),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
            minHeight: 2,
          ),
          if (hasAudiobook)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.headphones,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按 ttu EPUB 书架卡片时，在基类 MediaItemDialogPage 里追加
  /// "导入音频 / 字幕" 按钮；仅对已导入 ttu（mediaIdentifier 含 `id=`）的书
  /// 展示。
  @override
  List<Widget> extraActions(MediaItem item) {
    final int? ttuBookId = _parseTtuBookId(item.mediaIdentifier);
    if (ttuBookId == null) {
      return const [];
    }
    return [
      TextButton(
        onPressed: () => _openAudiobookImport(item, ttuBookId),
        child: Text(t.audiobook_import),
      ),
    ];
  }

  int? _parseTtuBookId(String mediaIdentifier) {
    final Match? m = RegExp(r'[?&]id=(\d+)').firstMatch(mediaIdentifier);
    if (m == null) {
      return null;
    }
    return int.tryParse(m.group(1)!);
  }

  Future<void> _openAudiobookImport(MediaItem item, int ttuBookId) async {
    final int port = ReaderTtuSource.instance
        .getPortForLanguage(appModel.targetLanguage);
    // 先关掉 MediaItemDialogPage 自身
    Navigator.pop(context);
    await showDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookUid: item.uniqueKey,
        repo: AudiobookRepository(appModel.database),
        ttuBookId: ttuBookId,
        serverPort: port,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }
}

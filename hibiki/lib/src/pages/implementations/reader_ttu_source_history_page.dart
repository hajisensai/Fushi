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
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
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
    return FutureBuilder<List<SrtBook>>(
      future: SrtBookRepository(appModel.database).listAll(),
      builder: (context, srtSnapshot) {
        final List<SrtBook> srtBooks = srtSnapshot.data ?? const [];
        return _buildBodyWithSrtBooks(books, srtBooks);
      },
    );
  }

  Widget _buildBodyWithSrtBooks(List<MediaItem> books, List<SrtBook> srtBooks) {

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
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
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

  /// 共用的 M3 书卡外壳：圆角 12、`surfaceContainerLow` 底色，InkWell 放在
  /// 圆角 Material 内部，ripple 自然被裁到卡片形状。外层 padding 用
  /// `Spacing.insets.all.normal` 与 grid 其它空位匹配。
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

  /// 书名条：底部透明→`surface.withAlpha(0.85)` 渐变遮罩 + `onSurface` 字色，
  /// 取代旧的纯黑半透明块 + `Colors.white` 字。
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
          _destructiveConfirmButton(
            label: t.dialog_delete,
            onPressed: () => Navigator.pop(ctx, true),
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
    // 字幕导入时 payload 同时写进了 ttu IDB；只删 SrtBook 会让 IDB 条目
    // 变孤儿，下次进书架就在 EPUB 区多出一本。
    if (book.ttuBookId > 0) {
      await ReaderTtuSource.instance.deleteBookFromIdb(
        language: appModel.targetLanguage,
        bookId: book.ttuBookId,
      );
    }
    await SrtBookRepository(appModel.database).delete(book.uid);
    if (mounted) {
      ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
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

  /// EPUB 书架卡片；基类 `buildMediaItem` 会再套 Material+InkWell，我们在
  /// `_epubCardTap` / `_epubCardLongPress` 里复用同样的语义并把它们搬进圆角
  /// 卡里，所以这里直接返回卡片内部的 Stack（不再自带 padding / 外框）。
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
            if (hasAudiobook)
              Positioned(
                top: 6,
                right: 6,
                child: _audiobookBadge(healthKind),
              ),
          ],
        );
      },
    );
  }

  Future<_AudiobookInfo> _loadAudiobookInfo(String bookUid) async {
    try {
      final repo = AudiobookRepository(appModel.database);
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

  /// 覆盖基类的 `buildMediaItem`：把 Material+InkWell 搬进圆角卡壳里，ripple
  /// 才能跟随卡片形状；同时让 padding 与 SRT 卡保持一致。
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

  /// 角标按健康度上色：ok / unrun / running / notApplicable 走中性
  /// `secondaryContainer`，partial 走 `tertiaryContainer`（seed 下呈暖色，
  /// 起到警示作用但比错误低一档），failed 走 `errorContainer`。
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
    final int? ttuBookId = _parseTtuBookId(item.mediaIdentifier);
    if (ttuBookId == null) {
      return const [];
    }
    return <Widget>[
      _destructiveConfirmButton(
        label: t.dialog_delete,
        onPressed: () => _confirmDeleteEpub(item, ttuBookId),
      ),
      TextButton(
        onPressed: () => _openIllustrations(item, ttuBookId),
        child: Text(t.view_illustrations),
      ),
      TextButton(
        onPressed: () => _openAudiobookImport(item, ttuBookId),
        child: Text(t.audiobook_import),
      ),
    ];
  }


  /// 删除按钮统一样式：FilledButton + errorContainer（M3 破坏性操作），
  /// 替代原来的 TextButton + `colorScheme.error` 文字色。确认对话框和
  /// 长按菜单里的"删除"共享这一入口。
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

  Future<void> _confirmDeleteEpub(MediaItem item, int ttuBookId) async {
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
    if (confirmed != true || !mounted) {
      return;
    }
    final bool ok = await ReaderTtuSource.instance.deleteBookFromIdb(
      language: appModel.targetLanguage,
      bookId: ttuBookId,
    );
    if (!mounted) {
      return;
    }
    if (!ok) {
      Fluttertoast.showToast(msg: t.epub_delete_error);
      return;
    }
    ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
    setState(() {});
  }

  int? _parseTtuBookId(String mediaIdentifier) {
    final Match? m = RegExp(r'[?&]id=(\d+)').firstMatch(mediaIdentifier);
    if (m == null) {
      return null;
    }
    return int.tryParse(m.group(1)!);
  }

  void _openIllustrations(MediaItem item, int ttuBookId) {
    final int port = ReaderTtuSource.instance
        .getPortForLanguage(appModel.targetLanguage);
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => IllustrationsViewerPage(
          bookTitle: item.title,
          ttuBookId: ttuBookId,
          port: port,
        ),
      ),
    );
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

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

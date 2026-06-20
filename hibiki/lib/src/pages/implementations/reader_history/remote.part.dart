// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// remote domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryRemote on _ReaderHibikiHistoryPageState {
  Future<RemoteBookClient?> _resolveRemoteBookClient() async {
    final Future<RemoteBookClient?> Function()? injected =
        _pageWidget.remoteBookClientLoader;
    if (injected != null) return injected();

    final SyncRepository syncRepo = SyncRepository(appModel.database);
    if (await syncRepo.getBackendType() != SyncBackendType.hibikiServer) {
      return null;
    }
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return null;
    return backend;
  }

  Future<_RemoteBookState?> _loadRemoteBooks() async {
    final RemoteBookClient? client = await _resolveRemoteBookClient();
    _remoteBookClient = client;
    if (client == null) return null;
    try {
      final List<RemoteBookInfo> books = await client.listRemoteBooks();
      // #6: 远端与本地是同一本书时（同 bookKey）不在「配对设备」区重复展示。
      final List<EpubBookRow> localBooks =
          await appModel.database.getAllEpubBooks();
      final Set<String> localKeys =
          localBooks.map((EpubBookRow r) => r.bookKey).toSet();
      final List<RemoteBookInfo> withContent =
          books.where((RemoteBookInfo book) => book.hasContent).toList();
      return _RemoteBookState(
        books: dedupeRemoteBooks(
          remote: withContent,
          localBookKeys: localKeys,
          keyOf: sanitizeTtuFilename,
        ),
      );
    } catch (e) {
      debugPrint('[reader-shelf] remote book list failed: $e');
      return const _RemoteBookState(
        books: <RemoteBookInfo>[],
        failed: true,
      );
    }
  }

  void _refreshRemoteBooks() {
    _rebuild(() {
      _remoteBooksFuture = _loadRemoteBooks();
    });
  }

  Widget _buildRemoteBookSection(
    _RemoteBookState state,
    BoxConstraints constraints,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap,
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.card,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.devices_other_outlined,
                size: 18,
                color: colors.primary,
              ),
              SizedBox(width: tokens.spacing.gap),
              Text(t.remote_book_interconnect, style: tokens.type.sectionLabel),
              SizedBox(width: tokens.spacing.gap),
              Text(
                t.remote_book_paired_device,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (state.failed)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: Text(
                t.remote_book_load_failed,
                style: textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            )
          else if (state.books.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            GridView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _gridExtent(context, constraints),
                childAspectRatio: mediaSource.aspectRatio,
                crossAxisSpacing: tokens.spacing.gap,
                mainAxisSpacing: tokens.spacing.gap,
              ),
              itemCount: state.books.length,
              itemBuilder: (BuildContext context, int index) =>
                  _buildRemoteBookCard(state.books[index]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoteBookCard(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    return _bookCardShell(
      cardKey: ValueKey<String>('remote_book_card_$safeKey'),
      focusId: HibikiFocusId('reader-shelf-remote-book-$safeKey'),
      onTap: () => _downloadRemoteBook(book),
      onLongPress: () => _downloadRemoteBook(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildRemoteBookCover(book),
        coverBadge: _downloadingBooks.containsKey(book.title)
            ? RemoteDownloadProgressBadge(
                key: ValueKey<String>('remote_book_downloading_$safeKey'),
                progress: _downloadingBooks[book.title],
                tooltip: t.remote_book_downloading,
              )
            : IconButton.filledTonal(
                key: ValueKey<String>('remote_book_download_$safeKey'),
                tooltip: t.remote_book_download,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.download_outlined),
                onPressed: () => _downloadRemoteBook(book),
              ),
      ),
    );
  }

  Widget _buildRemoteBookCover(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    final String? coverPath = book.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return FadeInImage(
        key: ValueKey<String>('remote_book_cover_$safeKey'),
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(coverPath)),
        alignment: Alignment.topCenter,
        fit: _bookCardCoverFit,
      );
    }
    final String? coverUrl = book.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        key: ValueKey<String>('remote_book_cover_$safeKey'),
        headers: remoteCoverHeadersFor(_remoteBookClient),
        alignment: Alignment.topCenter,
        fit: _bookCardCoverFit,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
      );
    }
    return _coverPlaceholderIcon(Icons.menu_book_outlined);
  }

  Future<void> _downloadRemoteBook(RemoteBookInfo book) async {
    final RemoteBookClient? client = _remoteBookClient;
    // #3: 服务不可达 / 未鉴权时给明确提示，不再静默 return（用户点了像没反应）。
    if (client == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_unavailable)),
      );
      return;
    }
    // 同一本书已在下载中：忽略重复点击（卡片 tap/长按/按钮都指向这里）。
    if (_downloadingBooks.containsKey(book.title)) return;
    // #3: 标记下载中（先置不确定进度），卡片立刻显示进行中反馈。
    _rebuild(() => _downloadingBooks[book.title] = null);
    try {
      final File dest = await _remoteBookDestination(book);
      await client.getRemoteBook(
        book.downloadId,
        dest,
        onProgress: (double progress) {
          if (!mounted) return;
          _rebuild(() => _downloadingBooks[book.title] = progress);
        },
      );
      await _importRemoteBookFile(dest);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.downloadRemoteBook', e, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_download_failed)),
      );
      return;
    } finally {
      if (mounted) {
        _rebuild(() => _downloadingBooks.remove(book.title));
      } else {
        _downloadingBooks.remove(book.title);
      }
    }
    if (!mounted) return;
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    _refreshSrtBooks();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_book_downloaded)),
    );
  }

  Future<File> _remoteBookDestination(RemoteBookInfo book) async {
    final Future<File> Function(RemoteBookInfo book)? injected =
        _pageWidget.remoteBookDownloadDestination;
    if (injected != null) return injected(book);
    final Directory temp = await getTemporaryDirectory();
    final Directory dir = Directory(p.join(temp.path, 'hibiki_remote_books'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${_safeRemoteBookKey(book.title)}.epub'));
  }

  Future<void> _importRemoteBookFile(File file) async {
    final Future<void> Function(File file)? injected =
        _pageWidget.remoteBookImporter;
    if (injected != null) {
      await injected(file);
      return;
    }
    await EpubImporter.importFromPath(
      db: appModel.database,
      filePath: file.path,
      fileName: p.basename(file.path),
    );
  }

  String _safeRemoteBookKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
}

class _RemoteBookState {
  const _RemoteBookState({
    required this.books,
    this.failed = false,
  });

  final List<RemoteBookInfo> books;
  final bool failed;
}

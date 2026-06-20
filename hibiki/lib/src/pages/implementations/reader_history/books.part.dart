// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// books domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryBooks on _ReaderHibikiHistoryPageState {
  Widget? _buildSrtBookTagLabels(int srtBookId) => _tagLabelsFromMap(
        ref.watch(srtBookTagMapProvider).valueOrNull,
        srtBookId,
      );

  Widget _buildSrtCard(SrtBook book, {String? epubCoverUri}) {
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
      child: _bookCardLayout(
        title: book.title,
        cover: _buildSrtCover(book, epubCoverUri: epubCoverUri),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: Icons.subtitles_outlined,
          background: theme.colorScheme.secondaryContainer,
          foreground: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _buildSrtCover(SrtBook book, {String? epubCoverUri}) {
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    if (ownCoverPath != null) {
      return _buildFileCover(ownCoverPath, Icons.subtitles_outlined);
    }
    if (book.bookKey.isNotEmpty) {
      final Widget? linkedCover = _buildCoverFromUri(
        epubCoverUri,
        Icons.subtitles_outlined,
      );
      if (linkedCover != null) return linkedCover;
    }
    return _coverPlaceholderIcon(Icons.subtitles_outlined);
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    final String? imageUrl = ownCoverPath != null
        ? Uri.file(ownCoverPath).toString()
        : _epubCoverUrisByBookKey[book.bookKey];
    return MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(book.bookKey),
      title: book.title,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
      imageUrl: imageUrl,
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
      if (bookKey.isNotEmpty) ...[
        DialogQuickAction(
          label: t.audio_import,
          icon: Icons.headphones_outlined,
          onPressed: () => _openAudioImport(item, bookKey),
        ),
        DialogListAction(
          label: t.profile_book_profile,
          icon: Icons.account_circle_outlined,
          onPressed: () => _openBookProfilePicker(item, bookKey),
        ),
        DialogListAction(
          label: t.book_css_editor_edit_css,
          icon: Icons.code_outlined,
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
        showLaunchAction: false,
        extraActions: (_) => _srtExtraActions(ctx, book),
      ),
    );
    if (mounted) _rebuild(() {});
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
    if (mounted) _rebuild(() {});
  }

  void _selectAll() {
    _rebuild(() {
      for (final item in _visibleEpubBooks) {
        _selectedKeys.add(item.mediaIdentifier);
      }
      for (final book in _visibleSrtBooks) {
        _selectedKeys.add('srt_${book.uid}');
      }
    });
  }

  void _invertSelection() {
    _rebuild(() {
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
    if (!await _confirmMediaDelete(
      title: t.srt_delete_title,
      message: t.srt_delete_confirm(title: book.title),
    )) {
      return;
    }

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
      _rebuild(() {});
    }
  }

  /// 该书当前是否就是活动后台听书会话。
  bool _isBackgroundListeningBook(String bookKey) {
    final session = appModel.audiobookSession;
    return session.isActive && session.book?.bookKey == bookKey;
  }

  /// 书架长按菜单切「后台听书」（TODO-291 阶段2）。
  /// - 该书已是活动会话 → 停止后台听书。
  /// - 否则 → 启动该书的后台听书会话（无正在播用该书启动；有别的书在播则顶掉切到该书），
  ///   并拉起悬浮窗。无可播放音频时提示。
  Future<void> _toggleFloatingLyricFromShelf(String bookKey) async {
    Navigator.pop(context);
    if (_isBackgroundListeningBook(bookKey)) {
      await appModel.stopBackgroundListening();
      if (mounted) _rebuild(() {});
      return;
    }
    final BackgroundListenResult result =
        await appModel.startBackgroundListening(bookKey);
    if (!mounted) return;
    switch (result) {
      case BackgroundListenResult.started:
        break;
      case BackgroundListenResult.noAudio:
        HibikiToast.show(msg: t.floating_lyric_no_audio);
        break;
      case BackgroundListenResult.loadFailed:
        HibikiToast.show(msg: t.audiobook_load_error);
        break;
    }
    _rebuild(() {});
  }

  Future<void> _confirmDeleteEpub(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    if (!await _confirmMediaDelete(
      title: t.epub_delete_title,
      message: t.srt_delete_confirm(title: item.title),
    )) {
      return;
    }

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
    _rebuild(() {});
  }

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
      _rebuild(() {});
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
      _rebuild(() {});
    }
  }

  /// 文件拖入书架后的路由：分类 → 命中测试 → 决策 → 打开对应对话框/提示。
  /// [globalPosition] 为 [HibikiFileDropTarget] 透出的 Flutter global/view 坐标，
  /// 可直接与卡片登记表（同坐标系屏幕矩形）命中测试。
  void _handleShelfDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final DroppedFiles files = classifyDroppedFiles(paths);
    debugPrint(
      '[hibiki-drop] [reader-shelf] classified '
      'books=${files.books.length} subtitles=${files.subtitles.length} '
      'audios=${files.audios.length} videos=${files.videos.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length} '
      'global=$globalPosition',
    );
    final String? hitBookKey = _cardDropRegistry.hitTest(globalPosition);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.books,
      files: files,
      cardHit: hitBookKey != null,
    );
    switch (intent) {
      case DropIntent.importNewBook:
        _openBookImportPrefilled(
          epubPath: files.books.first,
          subtitlePath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.attachToBookCard:
        _openAudiobookPrefilled(
          bookKey: hitBookKey!,
          audioPaths: files.audios,
          alignmentPath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.needCardTarget:
        debugPrint('[hibiki-drop] [reader-shelf] intent=needCardTarget');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.importNewVideo:
        // 书架拖入视频 → 自动切到视频导入流程，带上文件（不再只提示让用户手动切，
        // TODO-558）。视频卡与书卡同页渲染，无需跨 tab 通信。
        _openVideoImportPrefilled(
          videoPath: files.videos.first,
          subtitlePath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.importNewPlaylist:
        _openPlaylistImportPrefilled(playlistPath: files.playlists.first);
      case DropIntent.unsupportedSurface:
        debugPrint('[hibiki-drop] [reader-shelf] intent=unsupportedSurface');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_unsupported_on_books)),
        );
      case DropIntent.attachToVideoCard:
      case DropIntent.ignore:
        break;
    }
  }

  /// 拖入书文件 → 打开 [BookImportDialog]，预填 EPUB（及可选字幕）路径。
  /// 复用 [ReaderHibikiSource.buildBookImportButton] 的 repo/打开/刷新范式。
  Future<void> _openBookImportPrefilled({
    required String epubPath,
    required String? subtitlePath,
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialEpubPath: epubPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
    if (imported == true && mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    }
  }

  /// 拖入字幕/音频到书卡 → 打开 [AudiobookImportDialog] 附加到该书，预填音频/对齐路径。
  /// 复用 [_openAudiobookImport] 的 extractDir 取法与刷新范式（此处无外层对话框需 pop）。
  Future<void> _openAudiobookPrefilled({
    required String bookKey,
    required List<String> audioPaths,
    required String? alignmentPath,
  }) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialAlignmentPath: alignmentPath,
      ),
    );
    if (mounted) {
      _rebuild(() {});
    }
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

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

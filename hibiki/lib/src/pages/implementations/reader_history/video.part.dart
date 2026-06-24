// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// video domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryVideo on _ReaderHibikiHistoryPageState {
  Future<List<VideoBookRow>> _loadVideoBooks() async {
    final List<VideoBookRow> rows = await _videoRepo.listAll();
    _videoBooks = rows;
    return rows;
  }

  void _refreshVideoBooks() {
    _rebuild(() {
      _videoBooksFuture = _loadVideoBooks();
    });
  }

  Widget? _buildVideoBookTagLabels(String bookUid) => _tagLabelsFromMap(
        ref.watch(videoBookTagMapProvider).valueOrNull,
        bookUid,
      );

  Widget _buildVideoCard(VideoBookRow book) {
    final tagWidget = _buildVideoBookTagLabels(book.bookUid);
    return _bookCardShell(
      // 视频卡保留 16:9 友好的视频比例，不随 TODO-786 收窄到书封比例。
      slotAspectRatio: kShelfVideoCardAspectRatio,
      cardKey: ValueKey<String>('video_entry_${book.bookUid}'),
      focusId: HibikiFocusId('reader-shelf-video-${book.bookUid}'),
      dragBookId: book.bookUid,
      onTagDropped: (tag) => _addTagToVideoBook(book.bookUid, tag),
      onTap: () => _openVideoBook(book),
      onLongPress: () => _showVideoBookDialog(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildVideoCover(book),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: Icons.movie_outlined,
          background: theme.colorScheme.tertiaryContainer,
          foreground: theme.colorScheme.onTertiaryContainer,
        ),
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
        fit: _bookCardCoverFit,
      );
    }
    return _coverPlaceholderIcon(Icons.movie_outlined);
  }

  void _openVideoBook(VideoBookRow book) {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralized(
            bookUid: book.bookUid, repo: _videoRepo),
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

  Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag) async {
    final existing = ref.read(videoBookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[bookUid]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToVideoBook(bookUid, tag.id),
      invalidate: <ProviderOrFamily>[
        videoBookTagMapProvider,
        filteredVideoBookUidsProvider,
      ],
      // 视频用专属成功文案，区别于书籍入口（守卫 video_tags_menu_source_guard）。
      successMsg: t.tag_added_to_video(name: tag.name),
    );
  }

  /// 长按视频卡：打开与书籍一致的封面背景动作面板。播放仍由卡片点击负责。
  void _showVideoBookDialog(VideoBookRow book) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _buildVideoCover(book),
        title: book.title,
        showLaunchAction: false,
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.tag_label,
            icon: Icons.sell_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _openVideoTagPicker(book.bookUid);
            },
          ),
          DialogQuickAction(
            label: t.video_rename,
            icon: Icons.drive_file_rename_outline,
            onPressed: () {
              Navigator.pop(dialogContext);
              _renameVideoBook(book);
            },
          ),
          DialogQuickAction(
            label: t.srt_import_pick_cover,
            icon: Icons.image_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickVideoCover(book);
            },
          ),
          DialogQuickAction(
            label: t.video_import_pick_subtitle,
            icon: Icons.subtitles_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickVideoSubtitle(book);
            },
          ),
        ],
        dangerActions: <DialogDangerAction>[
          DialogDangerAction(
            label: t.dialog_delete,
            onPressed: () {
              Navigator.pop(dialogContext);
              _confirmDeleteVideoBook(book);
            },
          ),
        ],
      ),
    );
  }

  void _openVideoTagPicker(String bookUid) {
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => TagPickerPage(videoBookUid: bookUid),
      ),
    ).then((_) {
      ref.invalidate(videoBookTagMapProvider);
      ref.invalidate(filteredVideoBookUidsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  /// 设置视频封面：选图 → 经共享 [setVideoCoverFromPickedFile]（拷盘 + 驱逐旧
  /// 缓存 + 落库）→ 刷新。与视频 tab 换封面共用同一入口。
  Future<void> _pickVideoCover(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final String? pickedPath = result?.files.first.path;
    if (pickedPath == null || !mounted) return;
    await setVideoCoverFromPickedFile(
      repo: _videoRepo,
      bookUid: book.bookUid,
      pickedPath: pickedPath,
    );
    if (mounted) _refreshVideoBooks();
  }

  Future<void> _renameVideoBook(VideoBookRow book) async {
    final TextEditingController controller =
        TextEditingController(text: book.title);
    final String? newTitle = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.video_rename_hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    controller.dispose();
    final String? trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == book.title) return;
    await _videoRepo.updateTitle(book.bookUid, trimmed);
    if (mounted) _refreshVideoBooks();
  }

  Future<void> _pickVideoSubtitle(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    final String? subtitlePath = result?.files.single.path;
    if (subtitlePath == null || !mounted) return;
    await _attachSubtitleToVideoBook(book, subtitlePath);
  }

  Future<void> _attachSubtitleToVideoBook(
    VideoBookRow book,
    String subtitlePath,
  ) async {
    final SubtitleAttachResult result = await attachSubtitleToVideoBook(
      repo: _videoRepo,
      book: book,
      subtitlePath: subtitlePath,
    );
    if (!mounted) return;
    final String message;
    switch (result.outcome) {
      case SubtitleAttachOutcome.attached:
        message = t.video_subtitle_attached_to_video(
          title: book.title,
          count: result.cueCount,
        );
        _refreshVideoBooks();
      case SubtitleAttachOutcome.playlistNeedsPlayer:
        message = t.video_subtitle_attach_playlist_hint;
      case SubtitleAttachOutcome.unsupported:
        message = t.video_subtitle_import_unsupported;
      case SubtitleAttachOutcome.copyFailed:
        message = t.video_subtitle_import_failed;
      case SubtitleAttachOutcome.emptyCues:
        message = t.video_subtitle_load_failed(label: result.label);
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDeleteVideoBook(VideoBookRow book) async {
    if (!await _confirmMediaDelete(
      title: t.video_delete_title,
      message: t.video_delete_confirm(title: book.title),
    )) {
      return;
    }
    // ① 删 DB 行（含字幕 cue，事务内）。删前先抓被删 book 自己的封面/字幕路径——
    //    删后行没了就查不到了，删除回收要拿它来精确删自己的资产。
    final String? deletedCover = book.coverPath;
    final String? deletedSubtitle = book.subtitleSource;
    await _videoRepo.deleteVideoBook(book.bookUid);
    // ② 回收 app 拥有的封面/字幕副本：只删被删 book 自己那两个明确路径，并用「全库
    //    其余 book 的引用集」做护栏（仍被别本引用则保留）。绝不全库 sweep 字幕目录
    //    （那会误删别的播放列表各集的导入副本 = 永久数据丢失，BUG-276 复核退回）。
    //    videoPath 是用户原始文件、不在这两个目录里，绝不会被删。
    await _reclaimVideoDiskSpace(
      deletedBookUid: book.bookUid,
      deletedCoverPath: deletedCover,
      deletedSubtitlePath: deletedSubtitle,
    );
    if (mounted) {
      ref.invalidate(videoBookTagMapProvider);
      ref.invalidate(filteredVideoBookUidsProvider);
      _refreshVideoBooks();
    }
  }

  /// 删除视频后回收磁盘：精确删被删 book 自己的封面/字幕副本 + 安全的封面历史 GC
  /// + SQLite `VACUUM`（回收 freelist/WAL）。失败不应阻断删除流程（DB 行已删），
  /// 只记日志。VACUUM 必须在事务外调用。
  ///
  /// 关键：**不**对 `video_subtitles/` 做全库 sweep——播放列表只在 DB 存最后选中那集
  /// 的字幕路径，全库 sweep 会把别的播放列表各集的导入副本当孤儿删掉（永久数据丢失，
  /// BUG-276 复核退回）。字幕只删被删 book 自己 [deletedSubtitlePath]、且经「全库其余
  /// 引用集」护栏（仍被别本引用则保留）。封面文件名与 bookUid 1:1 绑定、引用集完整，
  /// 故可安全地全库清历史孤儿。
  Future<void> _reclaimVideoDiskSpace({
    required String deletedBookUid,
    required String? deletedCoverPath,
    required String? deletedSubtitlePath,
  }) async {
    try {
      // 删除后「全库其余 book」的引用集：被删 book 已不在 listAll，但仍显式排除其
      // uid 以防并发/事务时序，且用作封面历史 GC 的完整保留集。
      final ({Set<String> covers, Set<String> subtitles}) refs =
          await _videoRepo.collectReferencedAssetPaths(
        excludeBookUid: deletedBookUid,
      );
      // ① 精确删被删 book 自己的封面/字幕（仍被别本引用则保留）。
      await VideoStorage.deleteBookAssets(
        deletedCoverPath: deletedCoverPath,
        deletedSubtitlePath: deletedSubtitlePath,
        stillReferencedCoverPaths: refs.covers,
        stillReferencedSubtitlePaths: refs.subtitles,
      );
      // ② 安全的封面历史 GC：清掉已删视频遗留的孤儿封面（封面引用集完整）。
      await VideoStorage.gcOrphanCovers(referencedCoverPaths: refs.covers);
    } catch (e) {
      debugPrint('ReaderHistory: video asset GC failed: $e');
    }
    try {
      await appModel.database.customStatement('VACUUM');
      await appModel.database
          .customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      debugPrint('ReaderHistory: VACUUM after video delete failed: $e');
    }
  }

  /// 书架拖入视频 → 打开 [VideoImportDialog] 预填视频/字幕路径（自动切到视频导入，
  /// 带上拖入文件，用户无需重选）。复用 [_openVideoImport] 的 repo/刷新范式。
  Future<void> _openVideoImportPrefilled({
    required String videoPath,
    required String? subtitlePath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: _videoRepo,
        initialVideoPath: videoPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
    if (bookUid != null && mounted) _refreshVideoBooks();
  }

  /// 书架拖入 m3u8/m3u 播放列表 → 打开 [VideoImportDialog] 预填 playlist 路径，
  /// 对话框自动解析多集落库（与视频 tab 同一路径），关闭后刷新视频列表。
  Future<void> _openPlaylistImportPrefilled({
    required String playlistPath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: _videoRepo,
        initialPlaylistPath: playlistPath,
      ),
    );
    if (bookUid != null && mounted) _refreshVideoBooks();
  }
}

// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// TODO-919 / BUG-441：判定一条 [SrtBook] 是否为「EPUB 有声书配对行」。
///
/// TODO-894 起，EPUB 有声书导入会额外落一条 `srt_books` 行（stable uid
/// `srtbook_epub_<bookKey>`）以打通同步导出。该行 [SrtBook.bookKey] 非空
/// 且携带音频（[SrtBook.audioPaths] 非空或 [SrtBook.audioRoot] 非空）。书架对
/// 这种行渲染时应保留有声书语义的耳机角标（与 `_audiobookBadge` 一致），而不是
/// 纯字幕书的字幕角标。纯字幕书（无 EPUB 关联，[SrtBook.bookKey] 为空）仍用字幕
/// 角标——消除特殊情况只在这一处判据。
bool isEpubBackedAudiobookSrt(SrtBook book) {
  if (book.bookKey.isEmpty) return false;
  final List<String>? audioPaths = book.audioPaths;
  final bool hasAudioPaths = audioPaths != null && audioPaths.isNotEmpty;
  final String? audioRoot = book.audioRoot;
  final bool hasAudioRoot = audioRoot != null && audioRoot.isNotEmpty;
  return hasAudioPaths || hasAudioRoot;
}

/// books domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryBooks on _ReaderHibikiHistoryPageState {
  Widget? _buildSrtBookTagLabels(int srtBookId) => _tagLabelsFromMap(
        ref.watch(srtBookTagMapProvider).valueOrNull,
        srtBookId,
      );

  /// [selectable]（默认 true）= 多选态可单独勾选。块2：合集行成员卡传 false
  /// （selectionKey 置空 → 不画勾、不可单独勾），点击照常开书。
  /// [removeFromCollection] 非空（合集详情页成员卡）时给长按 / 右键对话框补「移出合集」
  /// 动作，让键盘/手柄用户（聚焦长按 A 弹此对话框，不经网格指针菜单）也能移出。
  Widget _buildSrtCard(SrtBook book,
      {String? epubCoverUri,
      bool selectable = true,
      VoidCallback? removeFromCollection}) {
    final String selKey = 'srt_${book.uid}';
    final tagWidget = book.id != null ? _buildSrtBookTagLabels(book.id!) : null;
    final int? srtBookId = book.id;
    // TODO-919 / BUG-441：EPUB 有声书配对行（TODO-894 落的 srt_books）保留耳机角标，
    // 纯字幕书仍用字幕角标。
    // TODO-935 ①A：引用导入后原音频断链 → 角标改成错误态「文件丢失」提示。
    final bool audioMissing = _srtBookHasMissingAudio(book);
    final IconData badgeIcon = audioMissing
        ? Icons.error_outline
        : isEpubBackedAudiobookSrt(book)
            ? Icons.headphones_outlined
            : Icons.subtitles_outlined;
    // TODO-1094：书架 SRT 卡书名必须与长按对话框同源——两者都基于同一
    // [_srtBookMediaItem]，再经 [MediaSource.getDisplayTitleFromMediaItem] 应用
    // 编辑弹窗写入的 override_title 偏好。以前直接读 DB 原始列 book.title，忽略
    // override，导致「编辑书名」保存后网格仍显示旧名。
    final MediaItem srtItem = _srtBookMediaItem(book);
    final String displayTitle =
        mediaSource.getDisplayTitleFromMediaItem(srtItem);
    return _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('srt_entry_${book.uid}'),
      focusId: HibikiFocusId('reader-shelf-srt-${book.uid}'),
      selectionKey: selectable ? selKey : null,
      dragBookId: srtBookId,
      onTagDropped:
          srtBookId == null ? null : (tag) => _addTagToSrtBook(srtBookId, tag),
      onTap: () => _openSrtBook(book),
      onLongPress: () =>
          _showSrtBookDialog(book, removeFromCollection: removeFromCollection),
      child: _bookCardLayout(
        title: displayTitle,
        cover: _buildSrtCover(book, epubCoverUri: epubCoverUri),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: badgeIcon,
          tooltip: audioMissing ? t.audiobook_audio_missing : null,
          background: audioMissing
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          foreground: audioMissing
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSecondaryContainer,
        ),
        // BUG-728：EPUB-backed 有声书只以 SRT 卡出现，进度条走与 EPUB 卡同一个
        // [_progressBar]（读 srtItem.position/duration，来自共享 EpubBooks 行）。
        // 纯字幕书无进度真值则不传 metadata，保持原样（无进度条）。
        metadata: _srtBookHasProgress(book) ? _progressBar(srtItem) : null,
      ),
    );
  }

  Widget _buildSrtCover(SrtBook book, {String? epubCoverUri}) {
    // TODO-919 / BUG-441：占位/封面 fallback 图标随卡片类型走——EPUB 有声书配对行
    // 用耳机，纯字幕书用字幕，与角标保持同一判据。
    final IconData fallbackIcon = isEpubBackedAudiobookSrt(book)
        ? Icons.headphones_outlined
        : Icons.subtitles_outlined;
    // TODO-1191：SRT 卡封面优先用「编辑信息」弹窗写入的 override thumbnail（经
    // [MediaSource.setOverrideThumbnailFromMediaItem]，与 EPUB 等其它书卡同源）。
    // 以前 SRT 卡只读 book.coverPath（旧外层「选择封面图片」专有写入），忽略
    // override，导致在编辑信息弹窗里选的封面在网格卡上不生效。现在统一到 override，
    // 无 override 再退回 book.coverPath（向后兼容历史外层写入的封面）与关联 EPUB 封面。
    final String overrideCoverPath =
        ReaderHibikiSource.instance.getOverrideThumbnailFilename(
      appModel: appModel,
      item: _srtBookMediaItem(book),
    );
    final String? existingOverride = _existingCoverFilePath(overrideCoverPath);
    if (existingOverride != null) {
      return _buildFileCover(existingOverride, fallbackIcon);
    }
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    if (ownCoverPath != null) {
      return _buildFileCover(ownCoverPath, fallbackIcon);
    }
    if (book.bookKey.isNotEmpty) {
      final Widget? linkedCover = _buildCoverFromUri(
        epubCoverUri,
        fallbackIcon,
      );
      if (linkedCover != null) return linkedCover;
    }
    return _coverPlaceholderIcon(fallbackIcon);
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    final String? imageUrl = ownCoverPath != null
        ? Uri.file(ownCoverPath).toString()
        : _epubCoverUrisByBookKey[book.bookKey];
    // BUG-728：EPUB-backed 有声书在书架只以 SRT 卡出现（其 EPUB 卡被过滤），进度
    // 复用同一本 EpubBooks 行已算好的 position/duration（含听书 normCharOffset 回退）。
    // 无 EPUB backing 的纯字幕书没有字符进度真值，退回 0/1（进度条按 [_srtBookHasProgress]
    // 门控不渲染，不灌水）。
    final ({int position, int duration})? prog =
        _epubProgressByBookKey[book.bookKey];
    return MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(book.bookKey),
      title: book.title,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: prog?.position ?? 0,
      duration: prog?.duration ?? 1,
      canDelete: false,
      canEdit: true,
      imageUrl: imageUrl,
    );
  }

  /// BUG-728：SRT 卡是否有可展示的阅读进度真值。仅 EPUB-backed 有声书（其 bookKey
  /// 命中 [_epubProgressByBookKey]，进度来自共享的 EpubBooks 行 + reader_positions）
  /// 才画进度条；纯字幕书无字符进度，返回 false，保持无进度条（不显永远空的条）。
  bool _srtBookHasProgress(SrtBook book) =>
      book.bookKey.isNotEmpty &&
      _epubProgressByBookKey.containsKey(book.bookKey);

  Future<void> _openSrtBook(SrtBook book) async {
    if (book.bookKey.isEmpty) {
      HibikiToast.show(msg: t.srt_epub_not_ready);
      return;
    }
    // BUG-456: SRT books must use the normal media entry so AppModel registers
    // ReaderHibikiSource; direct page pushes leave currentMediaSource null.
    await appModel.openMedia(
      ref: ref,
      mediaSource: ReaderHibikiSource.instance,
      item: _srtBookMediaItem(book),
    );
  }

  List<DialogAction> _srtExtraActions(BuildContext dialogContext, SrtBook book,
      {VoidCallback? removeFromCollection}) {
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
      // 合集详情页成员卡：给可聚焦长按对话框补「移出合集」（键盘/手柄移出入口）。
      if (removeFromCollection != null)
        DialogListAction(
          label: t.collection_remove_member,
          icon: Icons.remove_circle_outline,
          onPressed: () {
            Navigator.pop(dialogContext);
            removeFromCollection();
          },
        ),
      if (_srtBookHasMissingAudio(book))
        DialogQuickAction(
          label: t.audiobook_relocate,
          icon: Icons.find_replace_outlined,
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _relocateSrtBookAudio(book);
          },
        ),
      if (bookKey.isNotEmpty) ...[
        // TODO-1191：与 EPUB 卡菜单对称补「查看插画」。仅在该 SRT 书有对应
        // EpubBooks 行（[_epubBackedBookKeys] 命中 = extractDir 存在）时展示，
        // 复用 EPUB 侧同一 [_openIllustrations]（自行 Navigator.pop + 打开
        // [IllustrationsViewerPage]，无插图时页面友好占位）。「选择封面图片」照旧
        // 保留——EPUB 卡不能选封面、SRT 卡可选是合理差异。
        if (_epubBackedBookKeys.contains(bookKey))
          DialogQuickAction(
            label: t.view_illustrations,
            icon: Icons.image_outlined,
            onPressed: () => _openIllustrations(item, bookKey),
          ),
        DialogQuickAction(
          label: t.audio_import,
          icon: Icons.headphones_outlined,
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _openAudioImport(book);
          },
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
        // TODO-1068：SRT/有声书卡长按菜单对称补「悬浮字幕」项（与 EPUB 侧
        // extraActions 一致）。复用同一 i18n key、同一回调、同一平台门控；
        // bookKey 非空才可用，_toggleFloatingLyricFromShelf 按 bookKey 解析。
        if (Platform.isAndroid || Platform.isWindows)
          DialogListAction(
            label: _isBackgroundListeningBook(bookKey)
                ? '${t.floating_lyric_toggle_action} ✓'
                : t.floating_lyric_toggle_action,
            icon: Icons.subtitles_outlined,
            onPressed: () => _toggleFloatingLyricFromShelf(bookKey),
          ),
      ],
    ];
  }

  Future<void> _showSrtBookDialog(SrtBook book,
      {VoidCallback? removeFromCollection}) async {
    await showAppDialog(
      context: context,
      builder: (ctx) => MediaItemDialogPage(
        item: _srtBookMediaItem(book),
        isHistory: true,
        showLaunchAction: false,
        // TODO-1094：SRT 无自选封面且未关联 EPUB 封面时，长按对话框显示与网格
        // `_buildSrtCover` 同判据的占位图标（耳机/字幕），而非整块隐藏封面区。
        coverFallbackIcon: isEpubBackedAudiobookSrt(book)
            ? Icons.headphones_outlined
            : Icons.subtitles_outlined,
        extraActions: (_) => _srtExtraActions(ctx, book,
            removeFromCollection: removeFromCollection),
      ),
    );
    if (mounted) _rebuild(() {});
  }

  /// TODO-935 ①A：字幕书引用导入后原音频被移动/删除 → 任一 audioPaths 断链。
  /// 仅对 files 模式（audioPaths）判定；folder 模式（audioRoot）不在本期范围。
  bool _srtBookHasMissingAudio(SrtBook book) {
    final List<String>? paths = book.audioPaths;
    if (paths == null || paths.isEmpty) return false;
    return AudiobookStorage.hasMissingPaths(paths);
  }

  /// 重新定位断链音频：让用户重选文件 → 重写 [SrtBook.audioPaths] → 落库。
  /// 复用与导入一致的「引用原路径」语义（重选的桌面真实路径直接存）。
  Future<void> _relocateSrtBookAudio(SrtBook book) async {
    final List<String> picked = await _pickSrtAudioFiles();
    if (picked.isEmpty || !mounted) return;
    book.audioPaths = picked;
    await SrtBookRepository(appModel.database).save(book);
    if (mounted) {
      _refreshSrtBooks();
      _rebuild(() {});
      HibikiToast.show(msg: t.audiobook_relocate_done);
    }
  }

  /// 该 epub bookKey 是否已折进某合集（= 合集成员，不作散卡单选/全选）。
  bool _isEpubCollectionMember(String? bookKey) =>
      bookKey != null && _primaryCollectionByEntry.containsKey('epub|$bookKey');

  /// 该 srt uid 是否已折进某合集。
  bool _isSrtCollectionMember(String uid) =>
      _primaryCollectionByEntry.containsKey('srt|$uid');

  void _selectAll() {
    _rebuild(() {
      // 散卡：只选未折进合集的可见书（折进的成员由整合集选中，不单独勾）。
      for (final item in _visibleEpubBooks) {
        if (_isEpubCollectionMember(_parseBookKey(item.mediaIdentifier))) {
          continue;
        }
        _selectedKeys.add(item.mediaIdentifier);
      }
      for (final book in _visibleSrtBooks) {
        if (_isSrtCollectionMember(book.uid)) continue;
        _selectedKeys.add('srt_${book.uid}');
      }
      _selectedCollectionIds.addAll(_visibleCollectionIds);
    });
  }

  void _invertSelection() {
    _rebuild(() {
      final Set<String> allKeys = {
        for (final item in _visibleEpubBooks)
          if (!_isEpubCollectionMember(_parseBookKey(item.mediaIdentifier)))
            item.mediaIdentifier,
        for (final book in _visibleSrtBooks)
          if (!_isSrtCollectionMember(book.uid)) 'srt_${book.uid}',
      };
      final Set<String> inverted = allKeys.difference(_selectedKeys);
      _selectedKeys
        ..clear()
        ..addAll(inverted);
      final Set<int> allCollections = _visibleCollectionIds.toSet();
      final Set<int> invertedCollections =
          allCollections.difference(_selectedCollectionIds);
      _selectedCollectionIds
        ..clear()
        ..addAll(invertedCollections);
    });
  }

  Widget _buildBatchActionBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 块2/3/4：计数与按钮可用态涵盖散卡选中集 + 合集选中集。
    final int selectedCount =
        _selectedKeys.length + _selectedCollectionIds.length;
    final bool hasSelection =
        _selectedKeys.isNotEmpty || _selectedCollectionIds.isNotEmpty;
    // 复查 #5：组合按钮 noop 档（0 合集 0 散卡 / 仅 1 合集且无散卡）不再当启用态死按钮，
    // 只在真能组合（新建 / 并入 / 合并）时才可点，与 [_batchCombineIntoSeries] 同判据。
    final bool canCombine = classifyCombine(
          collectionCount: _selectedCollectionIds.length,
          looseCount: _selectedKeys.length,
        ) !=
        CombineTier.noop;

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
                t.batch_selected_count(n: selectedCount),
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
                key: const ValueKey<String>('reader_shelf_batch_combine'),
                enabled: canCombine,
                onTap: _batchCombineIntoSeries,
                // 组合成系列用 playlist_add，与页头「收藏夹」入口的
                // collections_bookmark_outlined 区分开（二者语义无关，避免同图标歧义）。
                icon: Icons.playlist_add,
                tooltip: t.combine_into_series,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                // 打标签只作用于散卡媒体（合集无直接标签），故按散卡选中集可用态。
                enabled: _selectedKeys.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                key: const ValueKey<String>('reader_shelf_batch_delete'),
                enabled: hasSelection,
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

  /// 块4：批量删除区分解散/删媒体。
  /// - 选中合集 → 解散（[HibikiDatabase.deleteMediaCollection]：只解除分组，不删媒体本体）；
  /// - 选中散卡 → 删媒体本体（EPUB/SRT，现状语义）；
  /// - 混选 → 确认框文案写明「删 N 个媒体、解散 M 个合集」。
  Future<void> _batchDeleteConfirm() async {
    final int mediaCount = _selectedKeys.length;
    final int collectionCount = _selectedCollectionIds.length;
    if (mediaCount == 0 && collectionCount == 0) return;
    final String message = collectionCount == 0
        ? t.batch_delete_confirm(n: mediaCount)
        : mediaCount == 0
            ? t.batch_dissolve_confirm(m: collectionCount)
            : t.batch_delete_mixed_confirm(n: mediaCount, m: collectionCount);
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.dialog_delete,
        message: message,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    // 先解散选中合集（只删合集容器 + 成员引用行，绝不删媒体本体）。
    final Set<int> toDissolve = Set<int>.of(_selectedCollectionIds);
    int dissolved = 0;
    for (final int id in toDissolve) {
      final int removed = await appModel.database.deleteMediaCollection(id);
      if (removed > 0) dissolved++;
    }

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
          // BUG-439：以前无条件 deleted++，即便 repo.delete 实际没删到行也计数，
          // 末尾照样弹「已删除 N 本」谎报。改为只对真删掉的 srt_books 行计数。
          final int removed = await repo.delete(uid);
          if (removed > 0) deleted++;
        }
      } else {
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) {
          final DeleteBookResult result =
              await ReaderHibikiSource.instance.deleteBook(
            db: appModel.database,
            bookKey: bookKey,
          );
          if (result.deleted) deleted++;
        }
      }
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    // 解散后合集映射失效，重取（合集行随之消失）。
    _shelfMapsFuture = _loadShelfMaps();
    _exitSelectionMode();
    // 复查 #7：零成功（deleted==0 且 dissolved==0）时兜底文案按「选择构成」诚实分派——
    // 只选散卡（collectionCount==0）说「已删除 0 本」，否则说「已解散 0 个合集」；不再
    // 无条件谎报解散类别（对齐 BUG-439 诚实计数精神）。
    final String successMsg = deleted > 0 && dissolved > 0
        ? t.batch_delete_mixed_success(n: deleted, m: dissolved)
        : deleted > 0
            ? t.batch_delete_success(n: deleted)
            : collectionCount == 0
                ? t.batch_delete_success(n: deleted)
                : t.batch_dissolve_success(m: dissolved);
    HibikiToast.show(msg: successMsg);
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

  /// 块3：批量「组合」按钮三档自适应（[classifyCombine]）。书架选择键经
  /// shelfSelectionToEntry 解码成 (mediaType, entryKey)：
  /// - 仅散卡 → 命名弹窗新建合集（[_combineCreateNew]）；
  /// - 恰 1 合集 + 若干散卡 → 散卡并入该合集（[_combineAddToExisting]，不弹命名）；
  /// - ≥2 合集（可带散卡）→ 合并成一个（[_combineMergeCollections]，默认名=成员最多合集名）。
  Future<void> _batchCombineIntoSeries() async {
    final List<int> collectionIds = _selectedCollectionIds.toList()..sort();
    final List<ShelfEntryRef> looseRefs = <ShelfEntryRef>[
      for (final String key in _selectedKeys)
        if (shelfSelectionToEntry(key, ShelfSelectionSurface.books)
            case final ShelfEntryRef ref)
          ref,
    ];
    final CombineTier tier = classifyCombine(
      collectionCount: collectionIds.length,
      looseCount: looseRefs.length,
    );
    switch (tier) {
      case CombineTier.noop:
        return;
      case CombineTier.createNew:
        await _combineCreateNew(looseRefs);
      case CombineTier.addToExisting:
        await _combineAddToExisting(collectionIds.single, looseRefs);
      case CombineTier.mergeCollections:
        await _combineMergeCollections(collectionIds, looseRefs);
    }
  }

  /// 档1：仅散卡 → 命名弹窗新建合集，逐条 addToCollection。
  Future<void> _combineCreateNew(List<ShelfEntryRef> refs) async {
    // TODO-1125 B：预填合集默认名——收集选中条目标题（epub 用 mediaIdentifier、srt 用
    // 'srt_<uid>' 与选择键同编码匹配），经 deriveSeriesDefaultName 剥卷号取公共前缀；
    // 推导为空则兜底 t.series_default_name（「新系列」）。
    final List<String> memberTitles = <String>[
      for (final MediaItem item in _visibleEpubBooks)
        if (_selectedKeys.contains(item.mediaIdentifier)) item.title,
      for (final SrtBook book in _visibleSrtBooks)
        if (_selectedKeys.contains('srt_${book.uid}')) book.title,
    ];
    final String defaultName = deriveSeriesDefaultName(
      memberTitles,
      fallback: t.series_default_name,
    );
    // TODO-947：把选中的前 4 本书封面传进命名弹窗，铺成手机文件夹式网格缩略预览，
    // 让用户在确认合并时直观看到「我把哪几本合并进去了」。
    final List<Widget> previewCovers = <Widget>[
      for (final MediaItem item in _visibleEpubBooks)
        if (_selectedKeys.contains(item.mediaIdentifier))
          _slotCover(
            _ShelfBookSlot(epub: item),
            _epubCoverUrisByBookKey,
          ),
      for (final SrtBook book in _visibleSrtBooks)
        if (_selectedKeys.contains('srt_${book.uid}'))
          _slotCover(
            _ShelfBookSlot(srt: book),
            _epubCoverUrisByBookKey,
          ),
    ].take(4).toList();
    final String? name = await showCollectionNameDialog(
      context: context,
      title: t.create_series,
      initialName: defaultName,
      previewCovers: previewCovers,
    );
    if (name == null || !mounted) return;
    final int collectionId =
        await appModel.database.createMediaCollection(name);
    for (final ShelfEntryRef ref in refs) {
      await appModel.database
          .addToCollection(collectionId, ref.mediaType, ref.entryKey);
    }
    if (!mounted) return;
    _exitSelectionMode();
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
    HibikiToast.show(msg: t.series_created);
  }

  /// 档2：恰 1 合集 + 若干散卡 → 散卡并入该合集（不弹命名）。
  Future<void> _combineAddToExisting(
    int collectionId,
    List<ShelfEntryRef> refs,
  ) async {
    for (final ShelfEntryRef ref in refs) {
      await appModel.database
          .addToCollection(collectionId, ref.mediaType, ref.entryKey);
    }
    if (!mounted) return;
    _exitSelectionMode();
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
    HibikiToast.show(msg: t.batch_add_to_collection_success(n: refs.length));
  }

  /// 档3：≥2 合集（可带散卡）→ 合并成一个。目标 = 成员最多合集（其名作默认名，
  /// 确认框可改名）；目标吸收其余合集成员（addToCollection）+ 散卡加入，其余合集
  /// deleteMediaCollection 解散（只解除分组，不删媒体本体）。
  Future<void> _combineMergeCollections(
    List<int> collectionIds,
    List<ShelfEntryRef> refs,
  ) async {
    final HibikiDatabase db = appModel.database;
    final Map<int, List<MediaCollectionItemRow>> itemsById =
        <int, List<MediaCollectionItemRow>>{};
    for (final int id in collectionIds) {
      itemsById[id] = await db.getCollectionItems(id);
    }
    final MergeTargetChoice choice = chooseMergeTarget(
      <({int id, String name, int memberCount})>[
        for (final int id in collectionIds)
          (
            id: id,
            name: _collectionsById[id]?.name ?? '',
            memberCount: itemsById[id]!.length,
          ),
      ],
    );
    if (!mounted) return;
    final String? name = await showCollectionNameDialog(
      context: context,
      title: t.collection_merge_title,
      initialName: choice.defaultName,
    );
    if (name == null || !mounted) return;
    final int targetId = choice.targetId;
    // 复查 #6（TOCTOU）：成员快照上面是在命名确认框「之前」取的，框开着期间若有新成员
    // 同步进源合集，用旧快照迁移会漏掉这些新成员，随后 deleteMediaCollection 把它们连
    // 同源合集一起删掉 → 分组丢失。确认后、迁移前对每个源合集「重取」最新成员再迁移，
    // addToCollection 幂等去重，重复成员无副作用。
    for (final int id in collectionIds) {
      if (id == targetId) continue;
      final List<MediaCollectionItemRow> members =
          await db.getCollectionItems(id);
      for (final MediaCollectionItemRow m in members) {
        await db.addToCollection(targetId, m.mediaType, m.entryKey);
      }
      await db.deleteMediaCollection(id);
    }
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(targetId, ref.mediaType, ref.entryKey);
    }
    await db.renameMediaCollection(targetId, name);
    if (!mounted) return;
    _exitSelectionMode();
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
    HibikiToast.show(msg: t.collection_merged);
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

    final DeleteBookResult result =
        await ReaderHibikiSource.instance.deleteBook(
      db: appModel.database,
      bookKey: bookKey,
    );
    if (!mounted) return;
    if (!result.deleted) {
      // TODO-1359：不再只弹笼统的「删除书籍失败」——把 deleteBook 回报的原因（同时已
      // 写入 ErrorLogService，可在日志页导出）拼进 toast，让用户知道为什么删不掉。
      final String reason = result.failureReason ?? '';
      HibikiToast.show(
        msg: reason.isEmpty
            ? t.epub_delete_error
            : '${t.epub_delete_error}: $reason',
      );
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
        context: context,
        builder: (_) => IllustrationsViewerPage(
          bookTitle: item.title,
          extractDir: row.extractDir,
          bookKey: bookKey,
          database: appModel.database,
        ),
      ),
    );
  }

  /// TODO-1032：书架卡片菜单「导入音频」。该入口只对 SRT 字幕书可见
  /// （[_srtExtraActions] 唯一调用方），音频真值必须落 SrtBooks.audioPaths，
  /// 与「重新定位」/阅读器内导入归一；旧实现误弹 AudiobookImportDialog 把音频写进
  /// Audiobooks 表，导致 SrtBook 音频对话框查不到、显示空表单。
  Future<void> _openAudioImport(SrtBook book) async {
    final List<String> picked = await _pickSrtAudioFiles();
    if (picked.isEmpty || !mounted) return;

    HibikiToast.show(msg: t.dialog_importing);
    try {
      await SrtBookRepository(appModel.database)
          .replaceAudio(uid: book.uid, pickedPaths: picked);
      if (mounted) {
        _refreshSrtBooks();
        _rebuild(() {});
        HibikiToast.show(msg: t.audiobook_import_success);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHistory.openAudioImport', e, stack);
      debugPrint('[ReaderHistory] openAudioImport failed: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_import_error);
    }
  }

  Future<List<String>> _pickSrtAudioFiles() async {
    final Set<String> audioExtensions = AudiobookStorage.audioExtensions
        .map((String ext) => ext.replaceFirst('.', ''))
        .toSet();
    final List<String> paths = await pickRealFilePaths(
      context: context,
      appModel: appModel,
      allowedExtensions: audioExtensions,
    );
    paths.sort(compareAudioFilePath);
    return paths;
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
          audioPaths: files.audios,
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
      case DropIntent.importVideoUrl:
        // 书架拖入网络流 URL → 自动切到视频导入（预填 URL 并入库），与拖视频文件的
        // 自动切换一致（TODO-1306）。
        _openStreamImportPrefilled(streamUrl: files.urls.first);
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
    List<String> audioPaths = const <String>[],
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialEpubPath: epubPath,
        initialSubtitlePath: subtitlePath,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
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
          context: context,
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

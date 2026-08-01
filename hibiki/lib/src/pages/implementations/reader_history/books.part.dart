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
/// P4：SRT/有声书卡上屏名统一入口——过 display-title 门面应用编辑弹窗写入的
/// override。门面按身份分派：bookKey 非空走 EPUB 共享身份 `hoshi://book/<key>`，
/// 空串哨兵（standalone SRT）走 `hoshi://srtbook/<uid>`（BUG-1018 A3，与
/// `_srtBookMediaItem` 同一套分派）。
String _srtDisplayTitle(SrtBook book) => displayTitleForBook(
      bookKey: book.bookKey,
      srtUid: book.uid,
      rawTitle: book.title,
    );

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
  /// [focusIdPrefix]：详情页渲染路径传 'collection-detail-' 隔离焦点 id 命名空间
  /// （BUG-1009，见 [_buildCollectionMemberCard]）；书架路径恒空串（id 不变）。
  Widget _buildSrtCard(SrtBook book,
      {String? epubCoverUri,
      bool selectable = true,
      VoidCallback? removeFromCollection,
      String focusIdPrefix = ''}) {
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
      focusId: HibikiFocusId('${focusIdPrefix}reader-shelf-srt-${book.uid}'),
      selectionKey: selectable ? selKey : null,
      dragBookId: srtBookId,
      onTagDropped:
          srtBookId == null ? null : (tag) => _addTagToSrtBook(srtBookId, tag),
      // 拖卡进合集：SRT 的合集身份是 **uid**，不是上面打标签用的 int 主键
      // `srtBookId`（`_addSrtToCollection` 同源）——两者不可混用。
      dragMediaRef: MediaRef(kind: MediaKind.srt, entryKey: book.uid),
      dragLabel: displayTitle,
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
        // 纯字幕书无进度真值则不传 metadata，保持原样（无进度条）。已手动标记读完的
        // 有声书（按配对 bookKey 命中 [_completedBookKeys]）进度条恒满格 + 区分色。
        metadata: _srtBookHasProgress(book)
            ? _progressBar(
                srtItem,
                completed: book.bookKey.isNotEmpty &&
                    _completedBookKeys.contains(book.bookKey),
              )
            : null,
        // BUG-990：两阶段下载末段卡已变 SRT 卡但有声书包仍在下 → 继续显示加载覆盖层。
        loadingOverlay: _audiobookDownloadingOverlay(book.bookKey),
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
      // BUG-1018 (A3)：standalone SRT 书（bookKey 空串哨兵）用自己的稳定身份
      // `hoshi://srtbook/<uid>`——以前所有 standalone SRT 书共享
      // mediaIdentifierFor('')，override 书名/封面互相踩、作者保存静默 no-op。
      // EPUB 配对行照旧走 bookKey 身份（与 EPUB 卡同源，进度/override 共享）。
      mediaIdentifier: book.bookKey.isNotEmpty
          ? ReaderHibikiSource.mediaIdentifierFor(book.bookKey)
          : ReaderHibikiSource.mediaIdentifierForSrtUid(book.uid),
      title: book.title,
      // BUG-1018 (A3)：standalone SRT 书作者列真值在 srt_books.author，回填供
      // 编辑对话框预填/保存往返。EPUB 配对行作者真值在 epubBooks.author（编辑
      // 保存按 bookKey 写穿），此处不冒充。
      author: book.bookKey.isEmpty ? book.author : null,
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
      // 单卡「加入合集」：与 EPUB 卡菜单对称，纯字幕书（bookKey 为空）也可加入；
      // entryKey 编码与 shelfSelectionToEntry 对 'srt_<uid>' 选择键的解码一致（= uid）。
      // 合集详情页成员卡语境（已注入「移出合集」）不显示——同一条目在详情页语境下
      // 再加合集没有意义。
      if (removeFromCollection == null)
        DialogListAction(
          label: t.add_to_collection,
          icon: Icons.collections_bookmark_outlined,
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _addSrtToCollection(book);
          },
        ),
      // 统一三库页卡菜单：SRT 卡与 EPUB/视频/游戏卡对称含「标签」项（用户
      // 2026-07-28 拍板推翻 TODO-455；内部自行收起本对话框）。身份 =
      // SrtBooks.uid（与合集/批量选择键解码一致）。
      DialogListAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openMediaTagPicker(
          MediaRef(kind: MediaKind.srt, entryKey: book.uid),
        ),
      ),
      if (bookKey.isNotEmpty) ...[
        // 与 EPUB 卡菜单对称：手动「标记为已读完 / 取消」。有声书完成状态与 EPUB 共用
        // 同一 EpubBooks.completedAt（按配对 bookKey），故复用同一 [_toggleBookCompleted]。
        DialogListAction(
          label: _completedBookKeys.contains(bookKey)
              ? t.book_mark_uncompleted_action
              : t.book_mark_completed_action,
          icon: _completedBookKeys.contains(bookKey)
              ? Icons.check_circle
              : Icons.check_circle_outline,
          onPressed: () => _toggleBookCompleted(bookKey),
        ),
        // TODO-1191：与 EPUB 卡菜单对称补「查看插画」。仅在该 SRT 书有对应
        // EpubBooks 行（[_epubBackedBookKeys] 命中 = extractDir 存在）时展示，
        // 复用 EPUB 侧同一 [_openIllustrations]（自行 Navigator.pop + 打开
        // [IllustrationsViewerPage]，无插图时页面友好占位）。菜单里的「选择封面
        // 图片」动作已移除——选封面统一走「编辑信息」弹窗的封面字段（EPUB / SRT 皆可）。
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

  /// 单卡「加入合集」（SRT/有声书卡菜单入口）：弹共享的合集选择弹窗（新建合集
  /// 默认名 = 该书标题剥卷号，与批量档1同款推导）；加入成功后按
  /// [_combineAddToExisting] 同款刷新（重取分组映射 + 重绘）。
  Future<void> _addSrtToCollection(SrtBook book) async {
    final bool added = await showAddToCollectionDialog(
      context: context,
      database: appModel.database,
      mediaType: MediaKind.srt,
      entryKey: book.uid,
      // P4：用户看到的默认合集名用改名后的显示名（身份 entryKey 仍是 raw uid）。
      defaultNewName: deriveSeriesDefaultName(
        <String>[_srtDisplayTitle(book)],
        fallback: t.series_default_name,
      ),
    );
    if (!added || !mounted) return;
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
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
      bookKey != null &&
      _primaryCollectionByEntry
          .containsKey(MediaKind.epub.compositeKey(bookKey));

  /// 该 srt uid 是否已折进某合集。
  bool _isSrtCollectionMember(String uid) =>
      _primaryCollectionByEntry.containsKey(MediaKind.srt.compositeKey(uid));

  /// 全选 / 反选的候选散卡键：只含未折进合集的可见书（折进的成员由整合集选中，
  /// 不单独勾）。两处共用同一份资格判据，避免全选与反选口径漂开。
  Set<String> _selectableLooseKeys() => <String>{
        for (final item in _visibleEpubBooks)
          if (!_isEpubCollectionMember(_parseBookKey(item.mediaIdentifier)))
            item.mediaIdentifier,
        for (final book in _visibleSrtBooks)
          if (!_isSrtCollectionMember(book.uid)) 'srt_${book.uid}',
      };

  void _selectAll() {
    _rebuild(() => _selection.selectAll(
          loose: _selectableLooseKeys(),
          collections: _visibleCollectionIds,
        ));
  }

  void _invertSelection() {
    _rebuild(() => _selection.invert(
          loose: _selectableLooseKeys(),
          collections: _visibleCollectionIds,
        ));
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

    // 全 app elevation 0 纪律：去阴影改上边框分隔（巡检 PR-3）；窄屏 + 大字体下
    // 「已选 N / 全选 / 反选」改 Wrap 自动换行（旧 Row 全员不可收缩必溢出）。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - tokens.spacing.gap / 2,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: tokens.spacing.gap,
                  children: <Widget>[
                    Text(
                      t.batch_selected_count(n: selectedCount),
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextButton(
                      onPressed: _selectAll,
                      child: Text(t.batch_select_all),
                    ),
                    TextButton(
                      onPressed: _invertSelection,
                      child: Text(t.batch_invert_selection),
                    ),
                  ],
                ),
              ),
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
    // 先剔幽灵键再取数：确认框里的 N / M 必须是真会被删的条数。
    if (!await _pruneStaleSelection() || !mounted) return;
    final int mediaCount = _selectedKeys.length;
    final int collectionCount = _selectedCollectionIds.length;
    if (mediaCount == 0 && collectionCount == 0) return;
    final String message = collectionCount == 0
        ? t.batch_delete_confirm(n: mediaCount)
        : mediaCount == 0
            ? t.batch_dissolve_confirm(m: collectionCount)
            : t.batch_delete_mixed_confirm(n: mediaCount, m: collectionCount);
    final DeleteScope? scope = await showAppDialog<DeleteScope>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.dialog_delete,
        message: message,
        // 纯解散合集（mediaCount==0）不碰媒体本体，不能挂「会删解压目录/有声书」
        // 的披露；只有真删散卡时才披露真实删除范围。
        disclosure: mediaCount == 0
            ? null
            : buildDeletionDisclosure(
                target: DeletionDisclosureTarget.shelfBook,
              ),
        onConfirm: (DeleteScope s) => Navigator.pop(ctx, s),
      ),
    );
    if (scope == null || !mounted) return;

    // 先解散选中合集（只删合集容器 + 成员引用行，绝不删媒体本体）。
    final Set<int> toDissolve = Set<int>.of(_selectedCollectionIds);
    int dissolved = 0;
    for (final int id in toDissolve) {
      final int removed =
          await deleteMediaCollectionWithAssets(appModel.database, id);
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
              scope: scope,
            );
          }
          // BUG-439：以前无条件 deleted++，即便 repo.delete 实际没删到行也计数，
          // 末尾照样弹「已删除 N 本」谎报。改为只对真删掉的 srt_books 行计数。
          // TODO-2470 死角①：纯字幕书（bookKey 空）没有上面那次 deleteBook，
          // scope 以前到这里就被丢弃、勾了「从所有设备删除」完全无效。propagateDeletion
          // 由 repo 按 standalone 判据决定写不写墓碑（srt-backed 已由 deleteBook 写过）。
          final int removed = await repo.delete(uid,
              propagateDeletion: scope == DeleteScope.syncEverywhere);
          if (removed > 0) deleted++;
        }
      } else {
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) {
          final DeleteBookResult result =
              await ReaderHibikiSource.instance.deleteBook(
            db: appModel.database,
            bookKey: bookKey,
            scope: scope,
          );
          if (result.deleted) deleted++;
        }
      }
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
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

  /// 批量操作前把选中集收敛到真实存在的条目上，真剔掉了就明说。
  ///
  /// 与视频库同一纪律（见 `home_video_page._pruneStaleSelection`）：选中集不随库
  /// 变化剪枝，多选态期间同步下架 / 别处删除都会留下幽灵键，落库时撞外键——打标签
  /// 会把弹窗卡死在 loading、组合会静默失败、确认框数字是虚数。
  ///
  /// 存在性全集取**全库**而非可见集：被搜索或标签筛掉的书仍然存在，用户先勾后筛
  /// 是合法用法，不该被悄悄剔掉。
  ///
  /// 返回剔完后是否还有东西可做。
  Future<bool> _pruneStaleSelection() async {
    if (_selection.isEmpty) return false;
    final HibikiDatabase db = appModel.database;
    // 存在性真值必须取自**书架选择键的来源表**，不是名字相近的 `media_items`：
    // 书架 EPUB 卡的选择键是 `ReaderHibikiSource.mediaIdentifierFor(bookKey)`，
    // bookKey 的真值在 `epub_books`（`hibikiBooksProvider` 也是从这里取的）；
    // `getAllMediaItems()` 是另一张表、另一套 mediaIdentifier 语义，拿它做判据
    // 会把全部选中项误判成幽灵键而整批剔光。
    final List<EpubBookRow> epubBooks = await db.getAllEpubBooks();
    final List<SrtBook> srtBooks = await SrtBookRepository(db).listAll();
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    if (!mounted) return false;
    final int dropped = _selection.retainExisting(
      loose: <String>{
        for (final EpubBookRow row in epubBooks)
          ReaderHibikiSource.mediaIdentifierFor(row.bookKey),
        for (final SrtBook book in srtBooks) 'srt_${book.uid}',
      },
      collections: <int>{for (final MediaCollectionRow c in collections) c.id},
    );
    if (dropped == 0) return _selection.isNotEmpty;
    _rebuild(() {});
    HibikiToast.show(
      msg: t.batch_selection_stale_skipped(
        n: dropped + _selection.length,
        m: dropped,
      ),
    );
    return _selection.isNotEmpty;
  }

  Future<void> _batchShowTagPicker() async {
    // 幽灵键会让 bookTags 外键插入抛异常，弹窗把落库 await 在 loading 态里，
    // 一抛就永远转圈（卡死）。必须在开弹窗前剔干净。
    if (!await _pruneStaleSelection() || !mounted) return;
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
    // 幽灵键会让 addToCollection 撞外键且无人 catch（用户只看到「点了没反应」）。
    if (!await _pruneStaleSelection() || !mounted) return;
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
    // P4：标题过 display-title 门面——用户看到的默认合集名应是改名后的新名
    // （合集成员身份 entryKey 仍是 raw，不受影响）。
    final List<String> memberTitles = <String>[
      for (final MediaItem item in _visibleEpubBooks)
        if (_selectedKeys.contains(item.mediaIdentifier))
          displayTitleForBook(item: item, rawTitle: item.title),
      for (final SrtBook book in _visibleSrtBooks)
        if (_selectedKeys.contains('srt_${book.uid}')) _srtDisplayTitle(book),
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
        // 原样搬家现有成员行：行值可能是对端未知种类，走 raw 版防静默丢成员。
        await db.addToCollectionRaw(targetId, m.mediaType, m.entryKey);
      }
      await deleteMediaCollectionWithAssets(db, id);
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
    // P4：确认弹窗给人看，书名过门面（删除本体仍按 raw bookKey/uid 身份执行）。
    final DeleteScope? scope = await _confirmMediaDelete(
      title: t.srt_delete_title,
      message: t.srt_delete_confirm(title: _srtDisplayTitle(book)),
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ),
    );
    if (scope == null) return;

    if (book.bookKey.isNotEmpty) {
      await ReaderHibikiSource.instance.deleteBook(
        db: appModel.database,
        bookKey: book.bookKey,
        scope: scope,
      );
    }
    // TODO-2470 死角①：纯字幕书（bookKey 空）不走上面的 deleteBook，删除范围必须在
    // 这里落地，否则勾了「从所有设备删除」静默无效。
    await SrtBookRepository(appModel.database).delete(book.uid,
        propagateDeletion: scope == DeleteScope.syncEverywhere);
    if (mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
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
    // P4：确认弹窗给人看，书名过门面（删除本体仍按 raw bookKey 身份执行）。
    final DeleteScope? scope = await _confirmMediaDelete(
      title: t.epub_delete_title,
      message: t.srt_delete_confirm(
        title: displayTitleForBook(item: item, rawTitle: item.title),
      ),
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ),
    );
    if (scope == null) return;

    final DeleteBookResult result =
        await ReaderHibikiSource.instance.deleteBook(
      db: appModel.database,
      bookKey: bookKey,
      scope: scope,
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
    ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
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
          // P4：页标题给人看，过门面；插画定位身份走 extractDir/bookKey（raw）。
          bookTitle: displayTitleForBook(item: item, rawTitle: item.title),
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

    // 目录（漫画页图文件夹）没有扩展名，纯分类函数分不出来——把真实文件系统判据
    // 注入进去（分类层本身仍不碰 IO）。
    final DroppedFiles files = classifyDroppedFiles(
      paths,
      isDirectory: (String pth) => Directory(pth).existsSync(),
      // 图片型 .zip（一包页图的漫画）与 Yomitan 词典包同形，要真读包才分得出——
      // 与导入对话框的分派同一判据，两条入口对「这算不算漫画」回答一致。
      isImageArchive: MangaModule.isImageArchive,
    );
    debugPrint(
      '[hibiki-drop] [reader-shelf] classified '
      'books=${files.books.length} subtitles=${files.subtitles.length} '
      'audios=${files.audios.length} videos=${files.videos.length} '
      'mangas=${files.mangas.length} '
      'unsupportedMangas=${files.unsupportedMangas.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length} '
      'global=$globalPosition',
    );
    final String? hitBookKey = _cardDropRegistry.hitTest(globalPosition);
    // 漫画库是同一个页面的 mangaOnly 壳，但落点语义不同（见 DropSurface.manga）。
    final DropIntent intent = decideDropIntent(
      surface: _mangaOnly ? DropSurface.manga : DropSurface.books,
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
      case DropIntent.importNewManga:
        // 漫画（.mokuro / .cbz / 页图目录 / 图片型 zip）走漫画自己的导入对话框。
        // 决策层本来就把漫画和书分成了两个 intent，此前两个 intent 却落到同一个
        // 对话框；现在落点跟着 intent 走，载体身份不再在半路丢失。
        _openMangaImportPrefilled(mangaPath: files.mangas.first);
      case DropIntent.unsupportedMangaArchive:
        debugPrint(
          '[hibiki-drop] [reader-shelf] intent=unsupportedMangaArchive',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_manga_archive_unsupported)),
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
      ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
    }
  }

  /// 拖入漫画 → 打开 [MangaImportDialog]，预填漫画路径（目录 / .cbz / .mokuro /
  /// 图片型 zip）。刷新范式与 [_openBookImportPrefilled] 一致：漫画与书共用
  /// `EpubBooks` 表和同一块书架，故失效的 provider 也相同。
  Future<void> _openMangaImportPrefilled({required String mangaPath}) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(
        db: appModel.database,
        initialPath: mangaPath,
      ),
    );
    if (imported == true && mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
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

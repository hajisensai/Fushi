// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// remote domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryRemote on _ReaderHibikiHistoryPageState {
  Future<RemoteBookClient?> _resolveRemoteBookClient() async {
    final Future<RemoteBookClient?> Function()? injected =
        _pageWidget.remoteBookClientLoader;
    if (injected != null) return injected();

    final SyncRepository syncRepo = SyncRepository(appModel.database);
    final SyncBackendType type = await syncRepo.getBackendType();

    // 局域网互联（hibiki 自有 server）：仍走裸 HibikiClientSyncBackend（含 live 库
    // API 的 listRemoteBooks/getRemoteBook），不变。
    if (type == SyncBackendType.hibikiServer) {
      final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
      if (!await backend.restoreAuth(syncRepo)) return null;
      return backend;
    }

    // 云盘备份后端（Google Drive 等）：经 resolveSyncBackend 得带解混淆装饰层的
    // 后端，鉴权恢复成功后用 CloudRemoteBookClient 把远端书库适配成可下载条目
    // （TODO-665 阶段1）。鉴权失败返 null（书架不显示远端区）。
    final SyncBackend backend = resolveSyncBackend(type);
    if (!await backend.restoreAuth(syncRepo)) return null;
    final String rootFolderId = await backend.findOrCreateRootFolder();
    return CloudRemoteBookClient(
      backend: backend,
      rootFolderId: rootFolderId,
    );
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
    // TODO-655b: 本地书 SliverGrid 直接挂 CustomScrollView 全宽布局；远端 section
    // 不能再用一个带左右 padding 的 Container 包住 GridView（否则 GridView 的实际
    // 可用宽 = 全宽 - 2*padding，而 maxCrossAxisExtent 仍按全宽算 → 远端 cell 比本地
    // 窄、卡片变小）。改为：只 header 自带水平 padding（对齐 _buildSectionHeader），
    // GridView 不裹水平 padding，与本地 sliver grid 同宽基准。
    final double headerPadding = tokens.spacing.rowHorizontal * 0.75;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              headerPadding,
              tokens.spacing.gap,
              headerPadding,
              0,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.devices_other_outlined,
                  size: 18,
                  color: colors.primary,
                ),
                SizedBox(width: tokens.spacing.gap),
                Text(t.remote_book_interconnect,
                    style: tokens.type.sectionLabel),
                SizedBox(width: tokens.spacing.gap),
                Text(
                  t.remote_book_paired_device,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (state.failed)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                headerPadding,
                tokens.spacing.gap,
                headerPadding,
                tokens.spacing.card,
              ),
              child: Text(
                t.remote_book_load_failed,
                style: textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            )
          else if (state.books.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Padding(
              padding: EdgeInsetsDirectional.only(bottom: tokens.spacing.card),
              child: GridView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: kShelfBookCardAspectRatio,
                  crossAxisSpacing: tokens.spacing.gap,
                  mainAxisSpacing: tokens.spacing.gap,
                ),
                itemCount: state.books.length,
                itemBuilder: (BuildContext context, int index) =>
                    _buildRemoteBookCard(state.books[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoteBookCard(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    return _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('remote_book_card_$safeKey'),
      focusId: HibikiFocusId('reader-shelf-remote-book-$safeKey'),
      onTap: () => _downloadRemoteBook(book),
      // 短按仍直接下载（无本地副本不能直接读，下载合理）；长按 / 桌面右键
      // （_bookCardShell.onSecondaryTap 同绑 onLongPress）改弹选项面板，与本地
      // 书卡长按一致（TODO-768 / BUG-416）。
      onLongPress: () => _showRemoteBookDialog(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildRemoteBookCover(book),
        // TODO-655a：远端书卡右上角是下载按钮 / 下载进度，类型徽章（有声书耳机 /
        // 普通书本）放左上角，与本地书卡（buildMediaItemContent）的类型语义一致。
        leadingBadge: _buildRemoteBookTypeBadge(book, safeKey),
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

  /// 长按 / 桌面右键远端书卡：弹出与本地书卡一致的封面背景动作面板
  /// （[MediaItemDialogFrame] 复用，不重写），列出可对该远端书执行的动作。
  ///
  /// 动作：
  /// * 「下载」→ 复用 [_downloadRemoteBook]（与短按、封面下载按钮同一入口，
  ///   内部已对重复下载去重）。
  /// * 「信息」→ 弹基本元数据（书名 + 是否含有声书）。
  /// * 「删除远端」→ 仅当远端后端支持删除（[HibikiClientSyncBackend] 互联后端，
  ///   有 deleteRemoteBook/deleteRemoteAudiobook）才显示；云盘后端
  ///   （[CloudRemoteBookClient]）无此能力，按类型门控隐藏（真实能力边界）。
  void _showRemoteBookDialog(RemoteBookInfo book) {
    final RemoteBookClient? client = _remoteBookClient;
    final bool canDelete = client is HibikiClientSyncBackend;
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _buildRemoteBookCover(book),
        title: book.title,
        showLaunchAction: false,
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.remote_book_download,
            icon: Icons.download_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _downloadRemoteBook(book);
            },
          ),
          DialogQuickAction(
            label: t.remote_book_info,
            icon: Icons.info_outline,
            onPressed: () {
              Navigator.pop(dialogContext);
              _showRemoteBookInfo(book);
            },
          ),
        ],
        dangerActions: <DialogDangerAction>[
          if (canDelete)
            DialogDangerAction(
              label: t.dialog_delete,
              onPressed: () {
                Navigator.pop(dialogContext);
                _confirmDeleteRemoteBook(book, client);
              },
            ),
        ],
      ),
    );
  }

  /// 展示远端书的基本元数据（书名 + 是否含有声书）。纯信息弹窗。
  void _showRemoteBookInfo(RemoteBookInfo book) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(book.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (book.hasAudiobook) Text(t.remote_book_info_has_audiobook),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  /// 删除互联后端上的远端书（含其有声书），删完刷新远端列表。仅互联后端可达
  /// （[HibikiClientSyncBackend.deleteRemoteBook] / [deleteRemoteAudiobook]）。
  Future<void> _confirmDeleteRemoteBook(
    RemoteBookInfo book,
    HibikiClientSyncBackend backend,
  ) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(book.title),
        content: Text(t.sync_compare_delete_confirm(name: book.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await backend.deleteRemoteBook(book.title);
      if (book.hasAudiobook) {
        await backend.deleteRemoteAudiobook(book.downloadId);
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.deleteRemoteBook', e, stack);
    }
    if (!mounted) return;
    _refreshRemoteBooks();
  }

  /// 远端书卡左上角类型徽章：有有声书 → 耳机徽章（与本地 _audiobookBadge 同色，
  /// 远端无健康度信息，用默认 secondaryContainer），否则普通书本徽章（与本地
  /// _cardBadge 一致）。带稳定 key 供 widget 测试定位（TODO-655a）。
  Widget _buildRemoteBookTypeBadge(RemoteBookInfo book, String safeKey) {
    final ColorScheme cs = theme.colorScheme;
    final Widget badge = book.hasAudiobook
        ? _cardBadge(
            icon: Icons.headphones_outlined,
            background: cs.secondaryContainer,
            foreground: cs.onSecondaryContainer,
          )
        : _cardBadge(
            icon: Icons.menu_book_outlined,
            background: cs.surfaceContainerHighest,
            foreground: cs.onSurfaceVariant,
          );
    return KeyedSubtree(
      key: ValueKey<String>('remote_book_type_badge_$safeKey'),
      child: badge,
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
          // EPUB 占前半段进度，留后半段给有声书（有声书包通常更大）。否则
          // EPUB 下完后进度卡 100% 但有声书还在拉，用户以为完了。
          final double scaled = book.hasAudiobook ? progress * 0.5 : progress;
          _rebuild(() => _downloadingBooks[book.title] = scaled);
        },
      );
      final String? localBookKey = await _importRemoteBookFile(dest);
      // EPUB 导入成功后才接有声书；EPUB 失败已在上面 throw，不会走到这里。
      await _downloadRemoteAudiobook(book, client, localBookKey);
    } on _RemoteAudiobookException catch (e, stack) {
      // EPUB 已成功入库，只是有声书没拉到：给专用可见提示（不静默吞），并照常
      // 刷新书架（EPUB 行已在）。不在 finally 后再弹「下载成功」。
      ErrorLogService.instance.log(
          'ReaderHibikiHistoryPage.downloadRemoteAudiobook', e.cause, stack);
      _rebuild(() => _downloadingBooks.remove(book.title));
      if (!mounted) return;
      ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
      _refreshSrtBooks();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_audiobook_download_failed)),
      );
      return;
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

  /// EPUB 导入成功后，按需补下该书的有声书包（750a 手动下载补音频）。
  ///
  /// 仅当远端书带有声书（[RemoteBookInfo.hasAudiobook]）才动作；下载经
  /// [HibikiClientSyncBackend.getRemoteAudiobook]（live API 仅存在于互联后端，
  /// 云盘后端 [CloudRemoteBookClient] 无此能力，按类型分支跳过——这是真实能力
  /// 边界，非掩盖性特例）。解包经 [SyncAssetPackageService.importAudioDatabasePackage]，
  /// 用刚导入的本地 EPUB 的 [localBookKey] 作 `bookKeyOverride` 把音频绑定到本地书。
  ///
  /// 下载用的远端 bookKey = [RemoteBookInfo.downloadId]（= host 传来的真实
  /// `bookKey ?? title`），与 EPUB 下载（getRemoteBook(book.downloadId)）同源，
  /// 即 host 端 `Audiobooks.bookKey`（= host EPUB 的 bookKey）。不要再按书名
  /// 重算 ttu 文件名——书名重名加后缀或迁移时会算出 host 不存在的 key 致 404
  /// （BUG-414 回归根因）。
  ///
  /// 失败处理：有声书下载/导入失败抛出 [_RemoteAudiobookException]，由调用方
  /// 转成可见错误提示（不静默吞）；EPUB 已成功入库，故不回滚 EPUB。
  Future<void> _downloadRemoteAudiobook(
    RemoteBookInfo book,
    RemoteBookClient client,
    String? localBookKey,
  ) async {
    if (!book.hasAudiobook) return;
    // 注入式测试钩子：绕过 backend 类型门，直接驱动下载/导入接线（与
    // [_pageWidget.remoteBookImporter] 同模式，让接线在 widget 测试可落地）。
    final Future<File> Function(String remoteBookKey)? injectedFetch =
        _pageWidget.remoteAudiobookFetcher;
    final Future<void> Function(File package, String? bookKeyOverride)?
        injectedImport = _pageWidget.remoteAudiobookImporter;

    // 生产路径：有声书 live API 仅存在于互联后端。云盘后端无此能力，按类型分支
    // 跳过（真实能力边界）。注入钩子缺省时才据此门控。
    if (injectedFetch == null &&
        injectedImport == null &&
        client is! HibikiClientSyncBackend) {
      return;
    }

    // host 传来的真实 bookKey（= `book.bookKey ?? book.title`），与 EPUB 下载
    // (:getRemoteBook(book.downloadId)) 同源。书名重名/迁移时按书名重算 ttu 文件名
    // 会算出 host 不存在的 key 致 404（BUG-414），故复用 downloadId 消除不对称。
    final String remoteBookKey = book.downloadId;
    File? audioTmp;
    try {
      if (injectedFetch != null) {
        audioTmp = await injectedFetch(remoteBookKey);
      } else {
        audioTmp = await _remoteAudiobookDestination(book);
        await (client as HibikiClientSyncBackend).getRemoteAudiobook(
          remoteBookKey,
          audioTmp,
          onProgress: (double progress) {
            if (!mounted) return;
            // 有声书占进度后半段（0.5..1.0）。
            _rebuild(
                () => _downloadingBooks[book.title] = 0.5 + progress * 0.5);
          },
        );
      }

      if (injectedImport != null) {
        await injectedImport(audioTmp, localBookKey);
      } else {
        await SyncAssetPackageService(db: appModel.database)
            .importAudioDatabasePackage(
          packageFile: audioTmp,
          audioDatabaseRoot: _audiobookDatabaseRoot(),
          bookKeyOverride: localBookKey,
        );
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.downloadRemoteAudiobook', e, stack);
      // 包成可见错误：调用方 catch 后弹专用提示，不与 EPUB 失败混淆。
      throw _RemoteAudiobookException(e);
    } finally {
      // 临时音频包用完即删（导入已落盘到 audiobook 根目录，不依赖临时文件）。
      if (audioTmp != null && injectedFetch == null) {
        try {
          if (audioTmp.existsSync()) audioTmp.deleteSync();
        } catch (_) {
          // best-effort temp cleanup
        }
      }
    }
  }

  /// 有声书包下载临时目标文件（`.hibikiaudio`）。
  Future<File> _remoteAudiobookDestination(RemoteBookInfo book) async {
    final Directory temp = await getTemporaryDirectory();
    final Directory dir =
        Directory(p.join(temp.path, 'hibiki_remote_audiobooks'));
    await dir.create(recursive: true);
    return File(
        p.join(dir.path, '${_safeRemoteBookKey(book.title)}.hibikiaudio'));
  }

  /// 本地有声书解包落盘根目录（与 [AppModelLibraryHostService] 同源
  /// `<appDirectory>/audiobooks`，确保导入位置与 host 导入一致）。
  Directory _audiobookDatabaseRoot() =>
      Directory(p.join(appModel.appDirectory.path, 'audiobooks'));

  Future<File> _remoteBookDestination(RemoteBookInfo book) async {
    final Future<File> Function(RemoteBookInfo book)? injected =
        _pageWidget.remoteBookDownloadDestination;
    if (injected != null) return injected(book);
    final Directory temp = await getTemporaryDirectory();
    final Directory dir = Directory(p.join(temp.path, 'hibiki_remote_books'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${_safeRemoteBookKey(book.title)}.epub'));
  }

  /// 导入下载到本地的 EPUB，返回本地入库的 bookKey（= `sanitizeTtuFilename`
  /// 后的存储标题，可能因同名冲突重命名而与远端书名派生 key 不同）。注入的测试
  /// importer 不返回 key 时返回 null（音频接线据此降级跳过 override 绑定）。
  Future<String?> _importRemoteBookFile(File file) async {
    final Future<String?> Function(File file)? injected =
        _pageWidget.remoteBookImporter;
    if (injected != null) {
      return injected(file);
    }
    return EpubImporter.importFromPath(
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

/// 有声书下载/导入失败的内部信号：[_downloadRemoteBook] 据此与 EPUB 失败区分，
/// 弹专用提示而非通用「下载失败」。[cause] 是底层真实异常（已记日志）。
class _RemoteAudiobookException implements Exception {
  const _RemoteAudiobookException(this.cause);
  final Object cause;

  @override
  String toString() => '_RemoteAudiobookException: $cause';
}

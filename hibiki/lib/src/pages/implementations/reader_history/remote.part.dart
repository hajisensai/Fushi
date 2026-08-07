// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// remote domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryRemote on _ReaderHibikiHistoryPageState {
  Future<RemoteBookClient?> _resolveRemoteBookClient() async {
    final Future<RemoteBookClient?> Function()? injected =
        _pageWidget.remoteBookClientLoader;
    if (injected != null) return injected();

    final SyncRepository syncRepo = SyncRepository(appModel.database);

    // 互联（局域网 hibiki server）已从 backendType 解耦成独立开关，可与云备份并存。
    // 互联启用且已配对对端时优先用它的 live 库 API（listRemoteBooks/getRemoteBook），
    // 因为端到端 live 库比云盘备份更适合浏览对端在读书。未启用/未配对则回退云后端。
    // 注：两源同时展示（互联对端 + 云盘 远端书合并去重）留作后续，本轮先「有互联走
    // 互联，否则走云」——满足「选了云备份仍能看到互联对端」的核心诉求。
    if (await syncRepo.isInterconnectEnabled()) {
      final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
      if (await backend.restoreAuth(syncRepo)) return backend;
    }

    // 云盘备份后端（Google Drive 等）：经 resolveSyncBackend 得带解混淆装饰层的
    // 后端，鉴权恢复成功后用 CloudRemoteBookClient 把远端书库适配成可下载条目
    // （TODO-665 阶段1）。鉴权失败返 null（书架不显示远端区）。
    final SyncBackendType type = await syncRepo.getBackendType();
    final SyncBackend backend = resolveSyncBackend(type);
    if (!await backend.restoreAuth(syncRepo)) return null;
    final String rootFolderId = await backend.findOrCreateRootFolder();
    return CloudRemoteBookClient(
      backend: backend,
      backendType: type,
      rootFolderId: rootFolderId,
    );
  }

  /// 是否应该去问远端要书列表。
  ///
  /// BUG-1181：漫画书架（`mangaOnly`）和书架是**同一个 State 类**的两个实例，都注册了
  /// [_onShellTabActivated]，且该回调判的是 `== HomeTab.books`。于是切到书架会触发两次
  /// 完整拉取，漫画那次的结果在 build 里被 `!_mangaOnly` 直接丢掉——纯浪费一整轮网络。
  ///
  /// BUG-1182：`showRemoteEntries` 开关此前只在 build 的 `showRemote` 处生效（本文件
  /// 上游 `reader_hibiki_history_page.dart` 的 remote 门控），拉取照发不误。关掉「显示
  /// 远端条目」的用户仍然全额付网络代价，只是结果被丢弃。门控前移到取数之前。
  /// 用 `appModelNoUpdate`（不 watch）：本门控只读 prefsRepo，与 AppModel 的通知无关；
  /// 而本 getter 会在 prefsRepo 回调等非 build 时机被调用，那里 `ref.watch` 非法。
  bool get _shouldLoadRemoteBooks =>
      !_mangaOnly && appModelNoUpdate.prefsRepo.showRemoteEntries;

  Future<_RemoteBookState?> _loadRemoteBooks(
      {bool forceRefresh = false}) async {
    if (!_shouldLoadRemoteBooks) {
      _remoteBookClient = null;
      return null;
    }
    final RemoteBookClient? client = await _resolveRemoteBookClient();
    _remoteBookClient = client;
    if (client == null) return null;
    try {
      // BUG-1180：经共享缓存取清单——切回书架 tab（[_onShellTabActivated]）不再必然
      // 打一轮网络，TTL 内直接复用；首页 dashboard 刚拉过的同一份列表也在这里命中。
      // 缓存只包住「问对端要清单」这一步，下面的本地库查询与去重仍每次照跑，所以本地
      // 新增/删除的书立即反映在混排网格里。
      // 槽 = 来源身份 + 域（BUG-1202）：互联对端与云盘书库都往 books 域写，共用一个
      // 槽会让「关掉互联开关 / 换云盘后端」之后 TTL 内看到上一个来源的书。
      final List<RemoteBookInfo> books = await _remoteCache.read(
        sourceId: client.remoteLibrarySourceId,
        key: RemoteLibraryCacheKeys.books,
        forceRefresh: forceRefresh,
        fetch: client.listRemoteBooks,
      );
      // #6: 远端与本地是同一本书时（同 bookKey）不在混排网格重复展示（只显示本地卡）。
      final List<EpubBookRow> localBooks =
          await appModel.database.getAllEpubBooks();
      final Set<String> localKeys =
          localBooks.map((EpubBookRow r) => r.bookKey).toSet();
      final List<RemoteBookInfo> withContent =
          books.where((RemoteBookInfo book) => book.hasContent).toList();
      // 纯 SRT（standalone）远端有声书：仅互联后端有 live 有声书 API。列出对端全部
      // 有声书，只留 standalone（bookKey 空、身份=uid）且本地无同 uid SrtBook 的项，
      // 作为可下载占位卡。云盘后端无此 API → 空列表（占位卡不出现，与能力边界一致）。
      final List<RemoteAudiobookInfo> remoteSrt =
          await _loadStandaloneRemoteSrtAudiobooks(
        client,
        forceRefresh: forceRefresh,
      );
      return _RemoteBookState(
        books: dedupeRemoteBooks(
          remote: withContent,
          localBookKeys: localKeys,
          keyOf: sanitizeTtuFilename,
        ),
        srtAudiobooks: remoteSrt,
      );
    } catch (e) {
      // spec §2.4 离线语义：拉取失败 → 占位卡不出现（failed 门控），只剩本地库。
      debugPrint('[reader-shelf] remote book list failed: $e');
      return _RemoteBookState(
        books: const <RemoteBookInfo>[],
        failed: true,
      );
    }
  }

  /// 非强制的远端书重载：切回书架 tab（BUG-992）、本地有声书列表变动等「可能只是本地
  /// 变了」的信号走这里。远端清单本身经 [RemoteLibraryCache] 的 TTL 判断是否真要联网，
  /// 所以切页面不会再变成一轮网络往返（BUG-1180）。要**强制**穿透缓存只有一个入口：
  /// 用户显式下拉刷新（[_pullToRefreshBooks]）。
  void _refreshRemoteBooks() {
    _rebuild(() {
      _remoteBooksFuture = _loadRemoteBooks();
    });
  }

  /// 下拉刷新 = **手动同步**：先跑一遍云备份 / 互联同步，再强制重拉远端书列表（并失效
  /// 本地书 / 有声书列表 provider 一并重读），await 全程完成后指示器才收起。
  ///
  /// 顶层 tab 保活（[HomePage] 的 `_keepAliveTabs`）后，切回书架不再隐式重拉远端，
  /// 故给用户一个**显式**强制刷新入口——对端设备 / 云盘新增的书，不重启 app 也能刷出来。
  ///
  /// 同步必须排在重读列表**之前**：同步会往本地库里落新书和新进度，先刷列表就会漏掉
  /// 本次同步的产物，用户得再下拉一次才看得见。没配同步后端时
  /// [runManualSyncWithFeedback] 直接返回 notConfigured（且不弹提示），退化成纯列表
  /// 刷新——与加同步之前的行为一字不差。
  /// [_loadRemoteBooks] 内部吞异常返回 failed 态，await 不会抛，指示器必定收起。
  Future<void> _pullToRefreshBooks() async {
    await runManualSyncWithFeedback(
      context: context,
      appModel: appModel,
      // 绝大多数用户没配云同步，每次下拉都弹「同步不可用」是纯噪音；已有同步在飞时
      // 用户下拉，数据照样会更新，不必打断。冲突/错误提示仍然照给。
      announceNotConfigured: false,
      announceBusy: false,
    );
    if (!mounted) return;
    ref.invalidate(hibikiBooksProvider);
    ref.invalidate(srtBooksProvider);
    _batchAudiobookInfoFuture = null;
    _batchAudiobookInfoResult = const <String, _AudiobookInfo>{};
    // 显式下拉 = 用户要最新的：强制穿透 [RemoteLibraryCache] 的 TTL（BUG-1180）。
    final Future<_RemoteBookState?> future = _loadRemoteBooks(
      forceRefresh: true,
    );
    _rebuild(() {
      _remoteBooksFuture = future;
      // 合集折叠映射也一并重载：下拉刷新前若后台同步落了新合集成员，只失效书列表
      // 而不重载 _shelfMapsFuture 会让新成员仍不成组（合集不渲染）。
      _shelfMapsFuture = _loadShelfMaps();
    });
    await future;
  }

  /// 多端库联合视图占位卡（spec 2026-07-12 §2.1）：正常书卡尺寸 + 远端封面 +
  /// 云角标 ☁（[_remoteBookCoverWithCloudBadge]），混排进书架主网格（[_ShelfBookSlot.remote]
  /// → [_buildShelfGroupCard] 散卡路径）。短按/下载按钮复用现有下载→入库链
  /// （[_downloadRemoteBook]），完成后原地变正常卡（下载后 dedup 去重隐藏占位）。
  Widget _buildRemoteBookCard(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    return _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('remote_book_card_$safeKey'),
      focusId: FushiFocusId('reader-shelf-remote-book-$safeKey'),
      onTap: () => _downloadRemoteBook(book),
      // 短按仍直接下载（无本地副本不能直接读，下载合理）；长按 / 桌面右键
      // （_bookCardShell.onSecondaryTap 同绑 onLongPress）改弹选项面板，与本地
      // 书卡长按一致（TODO-768 / BUG-416）。
      onLongPress: () => _showRemoteBookDialog(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _remoteBookCoverWithCloudBadge(book, safeKey),
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
  /// * 「删除远端」→ 仅当远端后端支持删除（[InterconnectSyncBackend] 互联后端，
  ///   有 deleteRemoteBook/deleteRemoteAudiobook）才显示；云盘后端
  ///   （[CloudRemoteBookClient]）无此能力，按类型门控隐藏（真实能力边界）。
  void _showRemoteBookDialog(RemoteBookInfo book) {
    final RemoteBookClient? client = _remoteBookClient;
    final bool canDelete = client is InterconnectSyncBackend;
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
          // 「信息」弹窗目前只有一条附加元数据（是否含有声书）；无附加信息时弹出
          // 即空壳，隐藏入口（巡检 PR-3 最小改法——待远端元数据丰富后再放开）。
          if (book.hasAudiobook)
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

  /// 删除互联后端上的远端书（含其有声书），删完强制刷新远端列表。仅互联后端可达
  /// （[InterconnectSyncBackend.deleteRemoteBook] / [deleteRemoteAudiobook]）。
  ///
  /// 身份键统一用 [RemoteBookInfo.downloadId]（= `bookKey ?? title`），与下载 / 有声书
  /// 删除同键（BUG-414 定下的纪律）。host 端 `_findBookByTitleOrKey` 两种键都能命中，
  /// 故对老 host 也安全；此前这里单独传 `book.title` 属遗漏。
  Future<void> _confirmDeleteRemoteBook(
    RemoteBookInfo book,
    InterconnectSyncBackend backend,
  ) async {
    final bool? confirmed = await _confirmRemoteDelete(book.title);
    if (confirmed != true) return;
    bool failed = false;
    try {
      await backend.deleteRemoteBook(book.downloadId);
      if (book.hasAudiobook) {
        await backend.deleteRemoteAudiobook(book.downloadId);
      }
    } catch (e, stack) {
      failed = true;
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.deleteRemoteBook', e, stack);
    }
    if (!mounted) return;
    // 失败必须给可见提示：原实现只写日志就刷新列表，书还在原处、用户以为自己看错了。
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_delete_failed)),
      );
      return;
    }
    _forceRefreshRemoteBooks();
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

  /// 远端封面 + 云角标 ☁（spec §2.1）：封面右上角是下载按钮/进度徽章、左上角是类型
  /// 徽章，故云角标叠在**左下角**（互不遮挡）。带稳定 key 供 widget 测试定位占位卡。
  Widget _remoteBookCoverWithCloudBadge(RemoteBookInfo book, String safeKey) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _buildRemoteBookCover(book),
        PositionedDirectional(
          bottom: 6,
          start: 6,
          child: _remoteCloudBadge(
            key: ValueKey<String>('remote_book_cloud_badge_$safeKey'),
          ),
        ),
      ],
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
        // BUG-959: 降采样解码，已下载书封面同样避免整帧撑爆 ImageCache。
        image: resizedFileImage(File(coverPath)),
        alignment: Alignment.topCenter,
        fit: _bookCardCoverFit,
      );
    }
    final String? coverUrl = book.coverUrl;
    // TODO-1235（TODO-961 回归）：封面走互联同款钉扎客户端拉取，不再用 Image.network
    // （Flutter 内部 HttpClient 无 badCertificateCallback，https 自签握手必失败）。
    final RemoteCoverFetcher? fetcher =
        remoteCoverFetcherFor(_remoteBookClient);
    if (coverUrl != null && coverUrl.isNotEmpty && fetcher != null) {
      return Image(
        // BUG-847：按稳定书 identifier（title）磁盘缓存，冷启动/滚动不重下。
        image: RemoteCoverImage(coverUrl, fetcher, cacheKey: book.title),
        key: ValueKey<String>('remote_book_cover_$safeKey'),
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
    // BUG-990：在 try 外持有「已标记有声书下载中的本地 bookKey」，供 finally 清理
    // （localBookKey 在 try 内声明、finally 不可见）。
    String? markedAudiobookKey;
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
      // TODO-616 §0🔴2：远端书的排序/系列归属（以 downloadId 登记的 shelf_entry）
      // 在下载后延续。EPUB 落库后 bookKey 可能漂移（标题派生 + 同名重命名，BUG-414），
      // 故把 ShelfEntries 的 entryKey 从 downloadId 改键到本地 bookKey。改键迁移是
      // EPUB 行 commit 之后的独立 DAO 事务（非同一事务），失败不阻断下载主流程——
      // 失败留旧 downloadId 孤儿行交读取期过滤兜底。仅在真发生漂移时迁移。
      if (localBookKey != null && localBookKey != book.downloadId) {
        try {
          await appModel.database.migrateShelfEntryKey(
              MediaKind.epub, book.downloadId, localBookKey);
        } catch (e, stack) {
          // 排序/系列元数据迁移失败不能让已成功的下载失败。
          ErrorLogService.instance
              .log('ReaderHibikiHistoryPage.migrateShelfEntryKey', e, stack);
        }
      }
      // tags 稳健档：LWW 合并 host 传来的标签时钟 + 移除墓碑（删除/改名跨端传播、
      // 防复活）。host 带 tagsAddedAt/tagTombstones（v2）→ mergeRemoteBookTags；旧 host
      // 只有 tags 名单 → 合成 addedAt=1 退化为「只增 + 尊重本地移除墓碑」（向后兼容）。
      // localBookKey 为 null（注入测试 importer 不返 key）即跳过。
      if (localBookKey != null &&
          (book.tagsAddedAt.isNotEmpty ||
              book.tagTombstones.isNotEmpty ||
              book.tags.isNotEmpty)) {
        final Map<String, int> remoteAddedAt = book.tagsAddedAt.isNotEmpty
            ? book.tagsAddedAt
            : <String, int>{
                for (final String name in book.tags)
                  if (name.isNotEmpty) name: 1,
              };
        await appModel.database.mergeRemoteBookTags(
          localBookKey,
          remoteAddedAt: remoteAddedAt,
          remoteTombstones: book.tagTombstones,
        );
      }
      // BUG-813：把该书在 host 端的阅读进度 + 有声书播放断点一并拉回本地，手动下载
      // 远端书时不再丢「阅读记录」（放在有声书下载之前、独立吞错，保证进度回填不被
      // 有声书失败连带跳过）。
      await _downloadRemoteBookProgress(book, client, localBookKey);
      // BUG-990：EPUB 已落库、有声书未落库的空窗起点——标记本地 bookKey「有声书下载中」，
      // 让被 provider 自动刷新顶替出来的本地卡（EPUB / SRT）继续显示加载覆盖层，不露出
      // 「无转圈的普通书」。清理统一在下方 finally（覆盖成功 / 两类失败全部出口）。
      if (localBookKey != null && book.hasAudiobook) {
        markedAudiobookKey = localBookKey;
        _rebuild(() => _downloadingAudiobookKeys.add(localBookKey));
      }
      // EPUB 导入成功后才接有声书；EPUB 失败已在上面 throw，不会走到这里。
      await _downloadRemoteAudiobook(book, client, localBookKey);
    } on _RemoteAudiobookException catch (e, stack) {
      // EPUB 已成功入库，只是有声书没拉到：给专用可见提示（不静默吞），并照常
      // 刷新书架（EPUB 行已在）。不在 finally 后再弹「下载成功」。
      ErrorLogService.instance.log(
          'ReaderHibikiHistoryPage.downloadRemoteAudiobook', e.cause, stack);
      _rebuild(() => _downloadingBooks.remove(book.title));
      if (!mounted) return;
      ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
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
      // 单点清理（覆盖成功 + _RemoteAudiobookException + 通用 catch 的所有 return 出口）：
      // Dart 的 finally 在 catch 内 return 之后仍执行，故 audiobook 键只在此清一次即可。
      void clear() {
        _downloadingBooks.remove(book.title);
        if (markedAudiobookKey != null) {
          _downloadingAudiobookKeys.remove(markedAudiobookKey);
        }
      }

      if (mounted) {
        _rebuild(clear);
      } else {
        clear();
      }
    }
    if (!mounted) return;
    ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
    _refreshSrtBooks();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_book_downloaded)),
    );
  }

  /// EPUB 导入成功后，把该书在 host 端的**阅读进度**（reader_positions）与**有声书
  /// 播放断点**（prefs）拉回本地（BUG-813）。此前进度双向同步只在整库「立即同步」
  /// sweep 里对**已在本地**的书跑（[SyncOrchestrator._syncBookProgressLive] /
  /// `_syncAudiobookPositionLive`），手动下载动作本身零回填 → 下到的书「没有阅读记录」。
  ///
  /// 契约与 sweep 同源：用 host 端真实 key [RemoteBookInfo.downloadId] 拉取，写本地用
  /// 刚导入的 [localBookKey]（标题派生 key 可能漂移，BUG-414）。live progress API 仅
  /// 存在于互联后端；云盘后端跳过（真实能力边界）。新下载的书本地无既有进度，host
  /// 侧有记录（updatedAtMs>0）即直接落库。书进度与有声书断点各自 try/catch 吞错，
  /// 绝不阻断主下载。
  Future<void> _downloadRemoteBookProgress(
    RemoteBookInfo book,
    RemoteBookClient client,
    String? localBookKey,
  ) async {
    if (localBookKey == null) return;

    // 书阅读进度 → reader_positions（新书本地无行，host 有记录即落）。
    // `remoteBookProgress` 是 [RemoteBookClient] 接口方法（互联 + 云盘后端都实现），
    // 故不按后端类型门控——两种远端来源下载都能带回阅读进度。
    try {
      final RemoteBookProgress remote =
          await client.remoteBookProgress(book.downloadId);
      if (remote.updatedAtMs > 0) {
        await appModel.database.upsertReaderPosition(ReaderPositionsCompanion(
          bookKey: Value(localBookKey),
          sectionIndex: Value(remote.sectionIndex),
          normCharOffset: Value(remote.normCharOffset),
          charOffset: Value(remote.charOffset),
          updatedAt: Value(remote.updatedAtMs),
        ));
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.downloadRemoteBookProgress', e, stack);
    }

    // 有声书播放断点 → prefs（与 resume/播放写键空间同源，见 sync sweep）。
    // `remoteAudiobookPosition` 仅互联后端具备（live API），故此段按类型门控。
    if (book.hasAudiobook && client is InterconnectSyncBackend) {
      try {
        final ({int positionMs, int updatedAtMs}) pos =
            await client.remoteAudiobookPosition(book.downloadId);
        if (pos.updatedAtMs > 0) {
          await appModel.database.setPrefTyped<int>(
              audiobookPositionPrefKey(localBookKey), pos.positionMs);
          await appModel.database.setPrefTyped<int>(
              audiobookPositionAtPrefKey(localBookKey), pos.updatedAtMs);
        }
      } catch (e, stack) {
        ErrorLogService.instance.log(
            'ReaderHibikiHistoryPage.downloadRemoteAudiobookPosition',
            e,
            stack);
      }
    }
  }

  /// EPUB 导入成功后，按需补下该书的有声书包（750a 手动下载补音频）。
  ///
  /// 仅当远端书带有声书（[RemoteBookInfo.hasAudiobook]）才动作；下载经
  /// [InterconnectSyncBackend.getRemoteAudiobook]（live API 仅存在于互联后端，
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
        client is! InterconnectSyncBackend) {
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
        await (client as InterconnectSyncBackend).getRemoteAudiobook(
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

  /// 拉取对端「纯 SRT（standalone）有声书」清单：仅互联后端有 live 有声书 API，
  /// 只留 standalone（bookKey 空、身份=uid）且本地无同 uid SrtBook 的项作占位卡。
  /// 云盘后端无此能力 → 空列表（占位卡不出现，与真实能力边界一致，不静默 fail-open）。
  Future<List<RemoteAudiobookInfo>> _loadStandaloneRemoteSrtAudiobooks(
    RemoteBookClient client, {
    bool forceRefresh = false,
  }) async {
    if (client is! InterconnectSyncBackend) {
      return const <RemoteAudiobookInfo>[];
    }
    List<RemoteAudiobookInfo> all;
    try {
      // BUG-1180：与书清单同缓存策略——切回 tab 不再重打这一枪。
      all = await _remoteCache.read(
        sourceId: client.remoteLibrarySourceId,
        key: RemoteLibraryCacheKeys.audiobooks,
        forceRefresh: forceRefresh,
        fetch: client.listRemoteAudiobooks,
      );
    } catch (e) {
      debugPrint('[reader-shelf] remote audiobook list failed: $e');
      return const <RemoteAudiobookInfo>[];
    }
    final List<SrtBookRow> localSrt = await appModel.database.getAllSrtBooks();
    final Set<String> localUids = localSrt.map((SrtBookRow r) => r.uid).toSet();
    return <RemoteAudiobookInfo>[
      for (final RemoteAudiobookInfo ab in all)
        if (ab.isStandaloneSrt &&
            ab.identity.isNotEmpty &&
            !localUids.contains(ab.identity))
          ab,
    ];
  }

  /// 纯 SRT 远端有声书占位卡：耳机类型徽章 + 云角标 + 下载按钮/进度。短按/下载按钮
  /// 走 [_downloadRemoteSrtAudiobook]（拉包 → importAudioDatabasePackage 纯 SRT 分支
  /// → 落 SrtBooks 行），完成后原地变本地 SRT 卡（重拉远端列表按 uid dedup 隐藏占位）。
  Widget _buildRemoteSrtCard(RemoteAudiobookInfo book) {
    final String title = book.title ?? book.identity;
    final String safeKey = _safeRemoteBookKey(title);
    final String dlKey = 'srt:${book.identity}';
    final bool downloading = _downloadingBooks.containsKey(dlKey);
    final ColorScheme cs = theme.colorScheme;
    return _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('remote_srt_card_$safeKey'),
      focusId: FushiFocusId('reader-shelf-remote-srt-$safeKey'),
      onTap: () => _downloadRemoteSrtAudiobook(book),
      // 长按 / 右键：弹动作面板，与远端 EPUB 卡（[_showRemoteBookDialog]）一致
      // （巡检 PR-3——旧行为长按直接开始下载，重手势与轻点击等价且不可预览动作）。
      onLongPress: () => _showRemoteSrtDialog(book),
      child: _bookCardLayout(
        title: title,
        cover: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _coverPlaceholderIcon(Icons.headphones_outlined),
            PositionedDirectional(
              bottom: 6,
              start: 6,
              child: _remoteCloudBadge(
                key: ValueKey<String>('remote_srt_cloud_badge_$safeKey'),
              ),
            ),
          ],
        ),
        leadingBadge: KeyedSubtree(
          key: ValueKey<String>('remote_srt_type_badge_$safeKey'),
          child: _cardBadge(
            icon: Icons.headphones_outlined,
            background: cs.secondaryContainer,
            foreground: cs.onSecondaryContainer,
          ),
        ),
        coverBadge: downloading
            ? RemoteDownloadProgressBadge(
                key: ValueKey<String>('remote_srt_downloading_$safeKey'),
                progress: _downloadingBooks[dlKey],
                tooltip: t.remote_book_downloading,
              )
            : IconButton.filledTonal(
                key: ValueKey<String>('remote_srt_download_$safeKey'),
                tooltip: t.remote_book_download,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.download_outlined),
                onPressed: () => _downloadRemoteSrtAudiobook(book),
              ),
      ),
    );
  }

  /// 长按 / 桌面右键纯 SRT 远端占位卡：弹与远端 EPUB 卡一致的动作面板
  /// （[MediaItemDialogFrame] 复用）。
  ///
  /// 动作：「下载」+「删除」。此处曾注明「互联删除 API 面向 EPUB 关联包，standalone
  /// SRT 不接删除，真实能力边界」——那条描述偏保守：`DELETE /api/library/audiobooks/
  /// <identity>` 的 host 端 identity 解析同时查 `Audiobooks(bookKey)` 与 `SrtBooks(uid)`，
  /// 传 uid 本就能命中，缺的只是这个 UI 入口。
  void _showRemoteSrtDialog(RemoteAudiobookInfo book) {
    final String title = book.title ?? book.identity;
    final RemoteBookClient? client = _remoteBookClient;
    final bool canDelete = client is InterconnectSyncBackend;
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _coverPlaceholderIcon(Icons.headphones_outlined),
        title: title,
        showLaunchAction: false,
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.remote_book_download,
            icon: Icons.download_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _downloadRemoteSrtAudiobook(book);
            },
          ),
        ],
        dangerActions: <DialogDangerAction>[
          if (canDelete)
            DialogDangerAction(
              label: t.dialog_delete,
              onPressed: () {
                Navigator.pop(dialogContext);
                _confirmDeleteRemoteSrt(book, client);
              },
            ),
        ],
      ),
    );
  }

  /// 删除互联对端 host 上的纯 SRT 有声书（身份键 = uid），删完强制刷新远端列表。
  /// 反馈与 [_confirmDeleteRemoteBook] 同款：失败必给可见提示，不静默。
  Future<void> _confirmDeleteRemoteSrt(
    RemoteAudiobookInfo book,
    InterconnectSyncBackend backend,
  ) async {
    final String title = book.title ?? book.identity;
    final bool? confirmed = await _confirmRemoteDelete(title);
    if (confirmed != true) return;
    bool failed = false;
    try {
      await backend.deleteRemoteAudiobook(book.identity);
    } catch (e, stack) {
      failed = true;
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.deleteRemoteSrt', e, stack);
    }
    if (!mounted) return;
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_delete_failed)),
      );
      return;
    }
    _forceRefreshRemoteBooks();
  }

  /// 远端删除的统一二次确认框（文案明说「从远端删除、本地保留、不可撤销」）。
  Future<bool?> _confirmRemoteDelete(String name) {
    return showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(name),
        content: Text(t.sync_compare_delete_confirm(name: name)),
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
  }

  /// 远端删除后的列表重取：**必须** forceRefresh 穿透 [RemoteLibraryCache] 的 TTL。
  /// 非强制的 [_refreshRemoteBooks] 会命中缓存，让刚删掉的条目在 TTL 内继续显示成
  /// 幽灵卡片（远端书删除的既有毛病）。
  void _forceRefreshRemoteBooks() {
    _rebuild(() {
      _remoteBooksFuture = _loadRemoteBooks(forceRefresh: true);
    });
  }

  /// 下载纯 SRT 远端有声书：`getRemoteAudiobook(identity=uid)` 拉 `.hibikiaudio` 包 →
  /// `importAudioDatabasePackage` 纯 SRT 分支落 SrtBooks 行（bookKey 恒空、cue 走 uid）。
  /// 只互联后端可达（云盘无 live 有声书 API）。完成后刷新书架（占位卡按 uid dedup 隐藏）。
  Future<void> _downloadRemoteSrtAudiobook(RemoteAudiobookInfo book) async {
    final RemoteBookClient? client = _remoteBookClient;
    if (client is! InterconnectSyncBackend) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_unavailable)),
      );
      return;
    }
    final String dlKey = 'srt:${book.identity}';
    if (_downloadingBooks.containsKey(dlKey)) return;
    _rebuild(() => _downloadingBooks[dlKey] = null);
    File? audioTmp;
    try {
      audioTmp = await _remoteSrtDestination(book);
      await client.getRemoteAudiobook(
        book.identity,
        audioTmp,
        onProgress: (double progress) {
          if (!mounted) return;
          _rebuild(() => _downloadingBooks[dlKey] = progress);
        },
      );
      await SyncAssetPackageService(db: appModel.database)
          .importAudioDatabasePackage(
        packageFile: audioTmp,
        audioDatabaseRoot: _audiobookDatabaseRoot(),
        // 纯 SRT 包无 audiobook 段：importAudioDatabasePackage 走 standalone 分支、
        // 忽略 bookKeyOverride，bookKey 保持空、身份=uid。
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.downloadRemoteSrtAudiobook', e, stack);
      if (audioTmp != null) {
        try {
          if (audioTmp.existsSync()) audioTmp.deleteSync();
        } catch (_) {/* best-effort */}
      }
      if (mounted) {
        _rebuild(() => _downloadingBooks.remove(dlKey));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.remote_book_download_failed)),
        );
      } else {
        _downloadingBooks.remove(dlKey);
      }
      return;
    }
    try {
      if (audioTmp.existsSync()) audioTmp.deleteSync();
    } catch (_) {/* best-effort */}
    if (!mounted) {
      _downloadingBooks.remove(dlKey);
      return;
    }
    _rebuild(() => _downloadingBooks.remove(dlKey));
    _refreshSrtBooks(); // 失效本地 SRT provider + 重拉远端（按 uid dedup 隐藏占位）
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_book_downloaded)),
    );
  }

  /// 纯 SRT 有声书包下载临时目标文件（`.hibikiaudio`）。
  Future<File> _remoteSrtDestination(RemoteAudiobookInfo book) async {
    final Directory temp = await getTemporaryDirectory();
    final Directory dir =
        Directory(p.join(temp.path, 'hibiki_remote_audiobooks'));
    await dir.create(recursive: true);
    final String safeKey = _safeRemoteBookKey(book.title ?? book.identity);
    return File(p.join(dir.path, 'srt_$safeKey.hibikiaudio'));
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

  /// 云角标 ☁：共享 [CoverBadge]（PR-0 收口的封面角标胶囊，统一各处手抄的
  /// alpha/圆角/eink 实底）。多端库联合视图占位卡的「远端 / 未下载」标识（spec §2.1）。
  Widget _remoteCloudBadge({Key? key}) {
    return CoverBadge(key: key, icon: Icons.cloud_outlined, iconSize: 13);
  }
}

class _RemoteBookState {
  const _RemoteBookState({
    required this.books,
    this.srtAudiobooks = const <RemoteAudiobookInfo>[],
    this.failed = false,
  });

  final List<RemoteBookInfo> books;

  /// 纯 SRT（standalone）远端有声书（互联后端 listRemoteAudiobooks 的 standalone 项，
  /// 本地无同 uid 的 SrtBook）。云盘后端无 live 有声书 API → 恒空。
  final List<RemoteAudiobookInfo> srtAudiobooks;

  /// 远端目录拉取失败（离线/未配对/后端不可达）：占位卡不渲染（spec §2.4）。
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

part of '../local_library_host_service.dart';

/// 漫画域：互联漫画源的页表与页图供给（**只读**）。
///
/// 与书域刻意分开：书域那三个端点（导出 / 导入 / 删除）搬的是「整卷 zip 包」，语义是
/// 「把这本书搬到我这儿来」；本域搬的是「页」，语义是「我在你那儿翻页」。前者早已存在
/// （`repackageMangaBook` + `/api/library/books/<id>`），后者才是把对端库当成一个**漫画
/// 源**（浏览 → 在线读）所缺的那半条链。
///
/// 两种漫画行、同一个域（BUG-2474）：
///   · **单卷本地漫画**（mokuro 导入 / EPUB 转化）：`<extractDir>/{manga.json, images/…}`，
///     一本 = 一卷 = 一章，页表就是根 `manga.json` 的 `pages`。
///   · **章节式在线漫画**（Mihon / Aidoku 书架条目）：根 `manga.json` 是占位（pages 空），
///     真正的页在 `<extractDir>/chapters/<digest>/{manga.json, images/…}`，每章一份。
///     `mangaManifest` 对它返回**已完整下载**的章表（`chapters`，pages 为空），页表按章
///     走 [mangaChapterManifest] / [mangaChapterPageFile]。
mixin _LocalLibraryHostManga on _LocalLibraryHostBase, _LocalLibraryHostShared {
  @override
  Future<RemoteMangaManifest> mangaManifest(String bookKey) async {
    _assertSafeName(bookKey);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final MokuroPayload? volume = await _readExportableVolume(row);
    if (volume != null) return _volumeManifest(row, volume);
    final List<RemoteMangaChapterInfo> chapters = await _downloadedChapters(
      row,
    );
    if (chapters.isEmpty) {
      throw StateError('manga book has no readable content: $bookKey');
    }
    return RemoteMangaManifest(
      bookKey: row.bookKey,
      title: row.title,
      readingMode: row.mangaReadingMode,
      pages: const <RemoteMangaPageInfo>[],
      chapters: chapters,
    );
  }

  @override
  Future<File> mangaPageFile(
    String bookKey,
    int index, {
    String? expectedKeyDigest,
  }) async {
    _assertSafeName(bookKey);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final String imagesRoot = MangaStorage.imagesDirectory(row.extractDir).path;
    // 对端每翻一页打一次这里。这份 manga.json 没变过（缓存命中）就不再重做「整份
    // 读 + 解析 + 逐页核对」：它上次已按 [hasExportableMangaContent] 过关，这次
    // 只核对被请求的那一页（[_pageFile]）。判据文件就是根 `manga.json`，行里记的
    // 是别的文件名时不走这条近路。
    final File json = _mangaJsonFile(row);
    if (p.basename(json.path) == kMangaPackageMarker) {
      final MokuroPayload? cached = await _mangaPayloads.lookup(json);
      if (cached != null) {
        _checkExpectedPage(
          expectedKeyDigest,
          _downloadedPageKey(cached, index),
          bookKey,
          index,
        );
        return await _pageFile(
          payload: cached,
          imagesRoot: imagesRoot,
          index: index,
          label: bookKey,
        );
      }
    }
    final MokuroPayload? volume = await _readExportableVolume(row);
    if (volume == null) {
      throw StateError('manga book has no volume pages: $bookKey');
    }
    _checkExpectedPage(
      expectedKeyDigest,
      _downloadedPageKey(volume, index),
      bookKey,
      index,
    );
    return _pageFile(
      payload: volume,
      imagesRoot: imagesRoot,
      index: index,
      label: bookKey,
    );
  }

  @override
  Future<RemoteMangaManifest> mangaChapterManifest(
    String bookKey,
    String chapterDigest,
  ) async {
    _assertSafeName(bookKey);
    _assertChapterDigest(chapterDigest);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final Directory chapterDir = mangaChapterDirectoryByDigest(
      row.extractDir,
      chapterDigest,
    );
    final MokuroPayload? payload = await _readDownloadedChapter(chapterDir);
    if (payload != null) {
      return _volumeManifest(
        row,
        payload,
        sourcePages: await _chapterSourcePages(chapterDir),
      );
    }
    // 没下载的章：本机运行时能取就现取页表（页尺寸未知报 0，对端按图片实测）。
    final _OnlineChapterSource source = _requireOnlineChapter(
      row,
      chapterDigest,
    );
    final List<String?> keys = await source.reader.chapterPageKeys(
      bookKey: row.bookKey,
      sourceMetadata: source.sourceMetadata,
      chapter: source.chapter,
    );
    final int count = keys.length;
    if (count <= 0) {
      throw StateError(
        'online manga chapter has no pages: $bookKey/$chapterDigest',
      );
    }
    return RemoteMangaManifest(
      bookKey: row.bookKey,
      title: row.title,
      readingMode: row.mangaReadingMode,
      pages: <RemoteMangaPageInfo>[
        for (int i = 0; i < count; i++)
          RemoteMangaPageInfo(
            index: i,
            name: '$i',
            width: 0,
            height: 0,
            key: _sourcePageIdentity(keys[i]),
          ),
      ],
    );
  }

  @override
  Future<File> mangaChapterPageFile(
    String bookKey,
    String chapterDigest,
    int index, {
    String? expectedKeyDigest,
  }) async {
    _assertSafeName(bookKey);
    _assertChapterDigest(chapterDigest);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final Directory chapterDir = mangaChapterDirectoryByDigest(
      row.extractDir,
      chapterDigest,
    );
    final String imagesRoot = mangaChapterImagesDirectory(chapterDir).path;
    // 这一章的 manga.json 没变过（缓存命中）：它上次已按「完整下载」过关，这次
    // 只核对被请求的那一页，不再对整章每一页 stat（一章 N 页读完是 N² 次）。那一页
    // 不在（越界 / 文件被删）就回到下面的完整判定，结论与没有缓存时一致。
    final MokuroPayload? cached = await _mangaPayloads.lookup(
      mangaChapterJsonFile(chapterDir),
    );
    if (cached != null && index >= 0 && index < cached.images.length) {
      final String? path = await MangaStorage.resolvePageFilePathAsync(
        imagesRoot,
        MangaStorage.pageRelativePath(cached.images[index].url),
      );
      if (path != null) {
        await _checkExpectedChapterPage(
          expectedKeyDigest,
          chapterDir,
          cached,
          '$bookKey/$chapterDigest',
          index,
        );
        return File(path);
      }
    }
    final MokuroPayload? payload = await _readDownloadedChapter(chapterDir);
    if (payload == null) {
      return _onlineChapterPageFile(
        row,
        chapterDigest,
        index,
        expectedKeyDigest,
      );
    }
    await _checkExpectedChapterPage(
      expectedKeyDigest,
      chapterDir,
      payload,
      '$bookKey/$chapterDigest',
      index,
    );
    return _pageFile(
      payload: payload,
      imagesRoot: imagesRoot,
      index: index,
      label: '$bookKey/$chapterDigest',
    );
  }

  /// [readDownloadedChapterPayload] 的完整判定；过关的 payload 记进 [_mangaPayloads]
  /// （没过关的清掉旧记录）。stat 取在读之前：读的途中文件被重写，记下的是「旧
  /// stat + 新内容」，下次 stat 对不上自然重读，不会把旧内容配上新 stat。
  Future<MokuroPayload?> _readDownloadedChapter(Directory chapterDir) async {
    final File json = mangaChapterJsonFile(chapterDir);
    final FileStat stat = await json.stat();
    final MokuroPayload? payload = await readDownloadedChapterPayload(
      chapterDir,
    );
    _mangaPayloads.store(json, stat, payload);
    return payload;
  }

  /// 单卷 / 单章的页表：payload 的 `pages` 顺序，带 OCR 生产者报告的尺寸。
  ///
  /// 已下载的章带上 [sourcePages]（章目录的源端页身份旁注）：旁注认得的页报源端
  /// 身份——与这章没下载时 [mangaChapterManifest] 现取报的是同一个值，所以 host
  /// 中途把章下完，对端手上的页表、下载续跑账本照旧对得上，不必重开、整章重下。
  /// 旁注认不得的页（旧下载没有旁注、源端没给身份、`manga.json` 已换过内容）报
  /// 按文件认页的身份。
  RemoteMangaManifest _volumeManifest(
    EpubBookRow row,
    MokuroPayload payload, {
    List<MangaChapterSourcePage?> sourcePages =
        const <MangaChapterSourcePage?>[],
  }) => RemoteMangaManifest(
    bookKey: row.bookKey,
    title: row.title,
    readingMode: row.mangaReadingMode,
    pages: <RemoteMangaPageInfo>[
      for (int i = 0; i < payload.images.length; i++)
        RemoteMangaPageInfo(
          index: i,
          name: MangaStorage.pageRelativePath(payload.images[i].url),
          width: payload.images[i].size.width.round(),
          height: payload.images[i].size.height.round(),
          key:
              _sourcePageIdentity(
                mangaChapterSourcePageKey(sourcePages, payload, i),
              ) ??
              _downloadedPageKey(payload, i),
        ),
    ],
  );

  /// 源端页身份 [sourceKey] 对外的形状：与没下载的章（[mangaChapterManifest] /
  /// [_onlineChapterPageFile]）同一口径。null 进 null 出。
  static String? _sourcePageIdentity(String? sourceKey) =>
      sourceKey == null ? null : 'source\u0000$sourceKey';

  /// 章目录 [chapterDir] 的源端页身份旁注（按文件修改时间与大小缓存，见
  /// [_sourcePagesCache]）。
  Future<List<MangaChapterSourcePage?>> _chapterSourcePages(
    Directory chapterDir,
  ) async {
    final File file = mangaChapterSourcePagesFile(chapterDir);
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      _sourcePagesCache.remove(file.path);
      return const <MangaChapterSourcePage?>[];
    }
    final _CachedSourcePages? hit = _sourcePagesCache.remove(file.path);
    if (hit != null && hit.size == stat.size && hit.modified == stat.modified) {
      _sourcePagesCache[file.path] = hit;
      return hit.pages;
    }
    final List<MangaChapterSourcePage?> pages =
        await readMangaChapterSourcePages(chapterDir);
    _sourcePagesCache[file.path] = (
      modified: stat.modified,
      size: stat.size,
      pages: pages,
    );
    while (_sourcePagesCache.length > _kSourcePagesCacheCapacity) {
      _sourcePagesCache.remove(_sourcePagesCache.keys.first);
    }
    return pages;
  }

  /// 已下载的章第 [index] 页的取页核对（HBK-AUDIT-205）：页表里报过的两种身份都认
  /// ——按文件认页的（旁注出现前 / 旧 host 报的页表），与旁注记的源端身份（这章
  /// 下载前对端拿到的页表，或下载后本 host 报的页表）。两种都对不上才 409。
  Future<void> _checkExpectedChapterPage(
    String? expectedKeyDigest,
    Directory chapterDir,
    MokuroPayload payload,
    String label,
    int index,
  ) async {
    if (expectedKeyDigest == null) return;
    final String? fileKey = _downloadedPageKey(payload, index);
    if (fileKey != null &&
        remoteMangaPageKeyDigest(fileKey) == expectedKeyDigest) {
      return;
    }
    _checkExpectedPage(
      expectedKeyDigest,
      _sourcePageIdentity(
        mangaChapterSourcePageKey(
          await _chapterSourcePages(chapterDir),
          payload,
          index,
        ),
      ),
      label,
      index,
    );
  }

  /// 已落盘的第 [index] 页的身份：文件名 + 尺寸认页（同一份下载里不会变；整章
  /// 重下换了内容的，尺寸几乎总会跟着变）。越界为 null。
  static String? _downloadedPageKey(MokuroPayload payload, int index) {
    if (index < 0 || index >= payload.images.length) return null;
    final MokuroImage image = payload.images[index];
    return 'file\u0000${MangaStorage.pageRelativePath(image.url)}'
        '\u0000${image.size.width.round()}'
        'x${image.size.height.round()}';
  }

  /// 取页请求带了 [expectedKeyDigest]（HBK-AUDIT-205）：这一页此刻的身份
  /// [actualKey] 必须与它相同；认不出（null，含页序已越界）或不同都抛
  /// [MangaPageChanged] → 409——客户端带着身份来取，说明它手上的页表已过期。
  static void _checkExpectedPage(
    String? expectedKeyDigest,
    String? actualKey,
    String label,
    int index,
  ) {
    if (expectedKeyDigest == null) return;
    if (actualKey != null &&
        remoteMangaPageKeyDigest(actualKey) == expectedKeyDigest) {
      return;
    }
    throw MangaPageChanged('manga page changed at the host: $label#$index');
  }

  /// 第 [index] 页的页图文件。路径解析 + 穿越守卫恒在 host 侧（client 只送 index，
  /// 从不送路径）。用的是本仓阅读器读本地漫画时的**同一个**
  /// `MangaStorage.resolvePageFilePath`——安全边界靠复制粘贴维持，抄漏一处就是真漏洞。
  Future<File> _pageFile({
    required MokuroPayload payload,
    required String imagesRoot,
    required int index,
    required String label,
  }) async {
    if (index < 0 || index >= payload.images.length) {
      throw StateError('manga page out of range: $label#$index');
    }
    final String? path = await MangaStorage.resolvePageFilePathAsync(
      imagesRoot,
      MangaStorage.pageRelativePath(payload.images[index].url),
    );
    if (path == null) {
      throw StateError('manga page not found: $label#$index');
    }
    return File(path);
  }

  /// 章节式在线漫画对端可读的章，按 `chaptersJson`（书架条目的章表，源给的顺序）：
  /// 已完整下载的章（[readDownloadedChapterPayload]），加上本机运行时能按需取页时
  /// 的其余各章（[OnlineMangaHostReader]）。
  ///
  /// 章表从 `epub_books.chaptersJson` 读而不是 `sourceMetadata`：前者就是一列
  /// `{key,name,number,scanlator,uploadedAt,raw}`，引擎不必认识 app 侧的书架条目
  /// 类型；后者是运行时描述符，形状随 Mihon / Aidoku 各异。
  Future<List<RemoteMangaChapterInfo>> _downloadedChapters(
    EpubBookRow row,
  ) async {
    final bool online = _servesOnlineMangaChapters(_onlineMangaReader, row);
    final List<RemoteMangaChapterInfo> chapters = <RemoteMangaChapterInfo>[];
    for (final Map<String, Object?> json in _mangaChapterItems(row)) {
      final String key = json['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      final MokuroPayload? payload = row.extractDir.isEmpty
          ? null
          : await readDownloadedChapterPayload(
              mangaChapterDirectoryByDigest(
                row.extractDir,
                mangaChapterDigest(key),
              ),
            );
      // 没下载的章只在本机运行时能现取时列出（页数要等打开那章才知道，报 0）。
      if (payload == null && !online) continue;
      final int uploadedAt = (json['uploadedAt'] as num?)?.toInt() ?? 0;
      final String scanlator = json['scanlator']?.toString() ?? '';
      chapters.add(
        RemoteMangaChapterInfo(
          key: key,
          name: json['name']?.toString() ?? '',
          pageCount: payload?.images.length ?? 0,
          number: (json['number'] as num?)?.toDouble(),
          scanlator: scanlator.isEmpty ? null : scanlator,
          uploadedAt: uploadedAt <= 0 ? null : uploadedAt,
        ),
      );
    }
    return chapters;
  }

  /// 没下载的章第 [index] 页：经本机运行时现取，落成临时文件交给
  /// `serveFileWithRange`（与已下载页同一条响应路径，Range / Content-Type 不分叉）。
  ///
  /// 临时文件按 (bookKey, 章, 页序 + 源端页身份) 定名、同页复用：对端翻回来不重复
  /// 打源站；源端换了页（页身份变了，audit-035）就是另一个文件，不会把旧版的页图
  /// 当新页表的这一页端出去。运行时给不出身份的页只按页序定名（旧口径）。文件在
  /// [onlineMangaPageCacheRoot] 下、按章有界保留（[pruneOnlineMangaPageCache]），
  /// 不进书目录（那是「已下载」的判据，混进去会让半章冒充下载完成）。
  ///
  /// 同一页的并发请求（阅读器显示 + 预取、或两台对端）合并成一次现取：各自落盘再
  /// 改名会让两路在同一个目标上打架（Windows 上暂存文件还开着时改名直接拒绝）。
  Future<File> _onlineChapterPageFile(
    EpubBookRow row,
    String chapterDigest,
    int index,
    String? expectedKeyDigest,
  ) async {
    final _OnlineChapterSource source = _requireOnlineChapter(
      row,
      chapterDigest,
    );
    if (index < 0) {
      throw StateError('manga page out of range: ${row.bookKey}#$index');
    }
    final Directory dir = Directory(
      p.join(
        onlineMangaPageCacheRoot().path,
        mangaChapterDigest(row.bookKey),
        chapterDigest,
      ),
    );
    // 页表在运行时那边有缓存，这里取身份不打源站。
    final List<String?> pageKeys = await source.reader.chapterPageKeys(
      bookKey: row.bookKey,
      sourceMetadata: source.sourceMetadata,
      chapter: source.chapter,
    );
    if (index >= pageKeys.length) {
      throw StateError('manga page out of range: ${row.bookKey}#$index');
    }
    final String? pageKey = pageKeys[index];
    // 与页表端点报的 `RemoteMangaPageInfo.key` 同一口径（[mangaChapterManifest]）。
    _checkExpectedPage(
      expectedKeyDigest,
      _sourcePageIdentity(pageKey),
      '${row.bookKey}/$chapterDigest',
      index,
    );
    final String stem = pageKey == null
        ? '$index'
        : '$index-${mangaChapterDigest(pageKey)}';
    final File? cached = await _cachedOnlinePage(dir, stem);
    if (cached != null) return cached;
    // 判缓存与登记在途之间没有 await：同一 isolate 内这两步是原子的。
    final String key = p.join(dir.path, stem);
    final Future<File>? running = _onlinePageFetches[key];
    if (running != null) return running;
    final Future<File> fetch = _fetchOnlinePage(
      source,
      row,
      dir,
      index,
      stem,
      pageKey,
    );
    _onlinePageFetches[key] = fetch;
    try {
      return await fetch;
    } finally {
      if (identical(_onlinePageFetches[key], fetch)) {
        _onlinePageFetches.remove(key);
      }
    }
  }

  Future<File> _fetchOnlinePage(
    _OnlineChapterSource source,
    EpubBookRow row,
    Directory dir,
    int index,
    String stem,
    String? pageKey,
  ) async {
    final Uint8List bytes;
    try {
      // 带上定文件名用的那个身份：运行时在取图所用的同一份页表上核对。页表若在
      // 两步之间被淘汰、重解析成换了页的一份，就抛 [MangaPageChanged]，不会把
      // 另一页落到这个身份的缓存文件名下。
      bytes = await source.reader.chapterPage(
        bookKey: row.bookKey,
        sourceMetadata: source.sourceMetadata,
        chapter: source.chapter,
        index: index,
        expectedPageKey: pageKey,
      );
    } on RangeError {
      throw StateError('manga page out of range: ${row.bookKey}#$index');
    }
    if (bytes.isEmpty) {
      throw StateError('online manga page is empty: ${row.bookKey}#$index');
    }
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      // 新开一章才清一次：每页都扫整棵缓存树不值。整棵树的 stat / 删除放进
      // 一次性后台 isolate（本 isolate 在 app 里就是 UI isolate）。
      await pruneOnlineMangaPageCacheInIsolate(
        onlineMangaPageCacheRoot().path,
        dir.path,
      );
    }
    final File file = File(
      p.join(dir.path, '$stem${onlineMangaPageExtension(bytes)}'),
    );
    // 暂存名带进程内唯一后缀：同进程的并发已在上面合并，这里防的是另一个进程
    // （同机另开的 host）同时写同一页。扩展名仍是 `.part`，[_cachedOnlinePage] 不认。
    final File staging = File(
      '${file.path}.$pid-${DateTime.now().microsecondsSinceEpoch}-'
      '${_onlinePageStagingSeq++}.part',
    );
    await staging.writeAsBytes(bytes, flush: true);
    try {
      return await staging.rename(file.path);
    } on FileSystemException {
      // 另一个进程先产出了同一页（目标在、非空，且可能正被它 serve 着，Windows
      // 上覆盖会被拒）：那份就是这一页，丢掉自己的暂存用它。其余情况照常抛。
      if (await file.exists() && await file.length() > 0) {
        await staging.delete();
        return file;
      }
      rethrow;
    }
  }

  /// [dir] 里名为 [stem]（页序 + 页身份摘要）的已落好的缓存文件（暂存 `.part` 与
  /// 空文件不算）。
  Future<File?> _cachedOnlinePage(Directory dir, String stem) async {
    if (!await dir.exists()) return null;
    try {
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is File &&
            p.extension(entity.path) != '.part' &&
            p.basenameWithoutExtension(entity.path) == stem &&
            await entity.length() > 0) {
          return entity;
        }
      }
    } on FileSystemException {
      // 目录在列举途中被清理（[pruneOnlineMangaPageCache]）：当作没有缓存，现取。
    }
    return null;
  }

  /// [chapterDigest] 对应的、可由本机运行时现取的章；取不了一律 [StateError] → 404。
  _OnlineChapterSource _requireOnlineChapter(
    EpubBookRow row,
    String chapterDigest,
  ) {
    final OnlineMangaHostReader? reader = _onlineMangaReader;
    final String? metadata = row.sourceMetadata;
    if (reader == null ||
        metadata == null ||
        !_servesOnlineMangaChapters(reader, row)) {
      throw StateError(
        'manga chapter not downloaded: ${row.bookKey}/$chapterDigest',
      );
    }
    for (final Map<String, Object?> json in _mangaChapterItems(row)) {
      final String key = json['key']?.toString() ?? '';
      if (key.isNotEmpty && mangaChapterDigest(key) == chapterDigest) {
        return (reader: reader, sourceMetadata: metadata, chapter: json);
      }
    }
    throw StateError('manga chapter not found: ${row.bookKey}/$chapterDigest');
  }

  /// digest 是路径段：判形即穿越守卫（24 位小写十六进制之外一律 [ArgumentError] → 403）。
  void _assertChapterDigest(String digest) {
    if (!isMangaChapterDigest(digest)) {
      throw ArgumentError.value(
        digest,
        'chapterDigest',
        'not a chapter digest',
      );
    }
  }

  /// 章级阅读进度（[MangaChapterProgressHost]，拍板 design-ic-manga-chapter-progress）：漫画
  /// [bookKey] 的全部 `manga_chapter_states`。书不在库 / 不是漫画 → null。
  @override
  Future<Map<String, RemoteMangaChapterState>?> readMangaChapterProgress(
    String bookKey,
  ) async {
    final EpubBookRow? row = await _mangaRowOrNull(bookKey);
    if (row == null) return null;
    return readMangaChapterStates(_db, row.uid);
  }

  /// 按章 LWW 合并对端上报的章状态（[landMangaChapterStates]，一个事务内读-比较-写），返回合并后的
  /// 全部章状态。书不在库 / 不是漫画 → null，不写孤儿行（同书进度 `putBookProgressChecked`）。
  @override
  Future<Map<String, RemoteMangaChapterState>?> mergeMangaChapterProgress(
    String bookKey,
    Map<String, RemoteMangaChapterState> incoming,
  ) async {
    final EpubBookRow? row = await _mangaRowOrNull(bookKey);
    if (row == null) return null;
    await landMangaChapterStates(
      _db,
      bookUid: row.uid,
      incoming: incoming,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    return readMangaChapterStates(_db, row.uid);
  }

  /// [_requireMangaRow] 的「没有就 null」版（uid 为空的行也当没有：章状态按 uid 记）。
  Future<EpubBookRow?> _mangaRowOrNull(String bookKey) async {
    if (bookKey.isEmpty) return null;
    try {
      final EpubBookRow row = await _requireMangaRow(bookKey);
      return row.uid.isEmpty ? null : row;
    } on StateError {
      return null;
    }
  }

  /// [bookKey] 对应的漫画行；不存在 / 不是漫画 一律 [StateError] → 404。
  ///
  /// 「有内容」不在这里判：单卷（根 `manga.json`）与章节式（`chapters/`）的判据不同，
  /// 各端点按自己那一种把关，与 `/api/library/books` 的 `hasMangaContent` /
  /// `hasMangaChapters` 分别同源——否则会出现「清单说有、翻页说没有」的分裂（BUG-2400）。
  ///
  /// 先按主键取一行；wire 上传来的也可能是书名（`_findBookByTitleOrKey` 的旧契约），
  /// 主键没命中才回落到全表按书名找——对端每翻一页都走这里，不能回回把整库
  /// （含每本书的 `chaptersJson`）读出来线性找。
  Future<EpubBookRow> _requireMangaRow(String bookKey) async {
    final EpubBookRow? row =
        await _db.getEpubBook(bookKey) ??
        _findBookByTitleOrKey(await _db.getAllEpubBooks(), bookKey);
    if (row == null) {
      throw StateError('manga book not found: $bookKey');
    }
    if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) {
      throw StateError('book is not manga: $bookKey');
    }
    return row;
  }

  /// 该书的 `manga.json`。行里的 `epubPath` 才是权威文件名（与阅读器一致），
  /// 缺列时回落到布局常量。
  File _mangaJsonFile(EpubBookRow row) => File(
    p.join(
      row.extractDir,
      row.epubPath.isEmpty ? kMangaPackageMarker : row.epubPath,
    ),
  );

  /// 单卷判据（[hasExportableMangaContent]）与页表一次读完：过关返回 payload 并记进
  /// [_mangaPayloads]（缓存里的 payload 都是过了关的），不过关 null。
  ///
  /// 判据文件是根 [kMangaPackageMarker]；行里记的 `manga.json` 就是它时（常态）只读
  /// 一遍。行里记的是别的文件名时判据与页表不是同一份文件，照旧判完再读页表文件。
  /// stat 取在读之前，理由同 [_readDownloadedChapter]。
  ///
  /// 读 + 解析 + 逐页核对在一次性后台 isolate 里做（200 页带 OCR 的卷约 16 ms，
  /// 本 isolate 在 app 里就是 UI isolate）。
  Future<MokuroPayload?> _readExportableVolume(EpubBookRow row) async {
    final File json = _mangaJsonFile(row);
    final FileStat stat = await json.stat();
    final String extractDir = row.extractDir;
    final String jsonPath = json.path;
    final bool rootMarker = p.equals(
      jsonPath,
      p.join(extractDir, kMangaPackageMarker),
    );
    final MokuroPayload? payload = await readExportableVolumeInIsolate(
      extractDir: extractDir,
      jsonPath: jsonPath,
      rootMarker: rootMarker,
    );
    _mangaPayloads.store(json, stat, payload);
    return payload;
  }
}

/// 最近读过的几份 `manga.json`（单卷的根文件与章节式的各章文件）解析结果。
///
/// 键是文件路径，命中条件是文件的修改时间与大小都没变：OCR / 大模型识别 / 重新
/// 下载重写 `manga.json` 会改掉其中至少一项，自然失效，不需要谁来通知。只收
/// **已过关**的 payload（单卷 = `hasExportableMangaContent`，一章 =
/// `readDownloadedChapterPayload` 非 null），所以命中即可跳过整份重读与逐页核对。
///
/// 有界（[capacity] 份，最近最少使用先淘汰）：一份带 OCR 的 200 页卷解析后是 MB
/// 级对象，对端同时在读的卷 / 章通常只有一两份。实测 200 页 × 15 块的卷每次
/// 「读 + 解析」约 16 ms，原先每页请求一次，app 当 host 时压在主 isolate 上。
class _MangaPayloadCache {
  _MangaPayloadCache({required this.capacity}) : assert(capacity > 0);

  final int capacity;

  /// 插入序 = 最近使用序（命中时摘下重插到队尾）。
  final Map<String, _CachedMangaPayload> _entries =
      <String, _CachedMangaPayload>{};

  /// [json] 现在的修改时间与大小都和记下时一样才给；否则 null（并丢掉旧记录）。
  Future<MokuroPayload?> lookup(File json) async {
    final _CachedMangaPayload? entry = _entries.remove(json.path);
    if (entry == null) return null;
    final FileStat stat = await json.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != entry.size ||
        stat.modified != entry.modified) {
      return null;
    }
    // stat 期间别的请求可能已存了更新的一份：不覆盖它。
    _entries.putIfAbsent(json.path, () => entry);
    return entry.payload;
  }

  /// 记下 [json] 在 [stat] 时刻的解析结果；[payload] 为 null（没过关）只清旧记录。
  void store(File json, FileStat stat, MokuroPayload? payload) {
    _entries.remove(json.path);
    if (payload == null || stat.type != FileSystemEntityType.file) return;
    _entries[json.path] = (
      modified: stat.modified,
      size: stat.size,
      payload: payload,
    );
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}

typedef _CachedMangaPayload = ({
  DateTime modified,
  int size,
  MokuroPayload payload,
});

/// 进程级共享（与 [_onlinePageFetches] 同理：键是磁盘路径，与哪个 host 服务实例
/// 无关）。
final _MangaPayloadCache _mangaPayloads = _MangaPayloadCache(capacity: 4);

/// 最近读过的几份章目录源端页身份旁注（键 = 旁注路径）。命中条件同
/// [_MangaPayloadCache]：文件的修改时间与大小都没变——下载服务每次重下都整份重写
/// 旁注，自然失效。对端按源端身份逐页取图时每页都要核对一次，不缓存就是每页一次
/// 读 + 解析。进程级共享，理由同 [_mangaPayloads]。
final Map<String, _CachedSourcePages> _sourcePagesCache =
    <String, _CachedSourcePages>{};
const int _kSourcePagesCacheCapacity = 8;

typedef _CachedSourcePages = ({
  DateTime modified,
  int size,
  List<MangaChapterSourcePage?> pages,
});

/// 在途的现取页（键 = 缓存目录 + 页号）：同页并发请求共用一次现取。缓存目录是
/// 进程级共享的，所以这张表也是进程级的，而不是挂在某个 host 服务实例上。
final Map<String, Future<File>> _onlinePageFetches = <String, Future<File>>{};

int _onlinePageStagingSeq = 0;

typedef _OnlineChapterSource = ({
  OnlineMangaHostReader reader,
  String sourceMetadata,
  Map<String, Object?> chapter,
});

/// 该在线漫画行能否由本机运行时按需取页：有装配、描述符被运行时认领、章表非空。
/// 清单（`hasMangaChapters`）与各章端点共用这一条，「清单说有、翻页说没有」不会分裂。
bool _servesOnlineMangaChapters(
  OnlineMangaHostReader? reader,
  EpubBookRow row,
) {
  final String? metadata = row.sourceMetadata;
  if (reader == null || metadata == null || metadata.isEmpty) return false;
  if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) return false;
  return reader.canServe(metadata) && _mangaChapterItems(row).isNotEmpty;
}

/// `EpubBooks.chaptersJson` 里的各章（坏 JSON / 非数组一律视为无章）。
List<Map<String, Object?>> _mangaChapterItems(EpubBookRow row) {
  final Object? decoded;
  try {
    decoded = jsonDecode(row.chaptersJson);
  } on Object {
    return const <Map<String, Object?>>[];
  }
  if (decoded is! List<Object?>) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? item in decoded)
      if (item is Map<Object?, Object?>) item.cast<String, Object?>(),
  ];
}

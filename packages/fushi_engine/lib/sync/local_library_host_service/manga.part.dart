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
    if (hasExportableMangaContent(row.extractDir)) {
      return _volumeManifest(row, _readMangaPayload(row));
    }
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
  Future<File> mangaPageFile(String bookKey, int index) async {
    _assertSafeName(bookKey);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    if (!hasExportableMangaContent(row.extractDir)) {
      throw StateError('manga book has no volume pages: $bookKey');
    }
    return _pageFile(
      payload: _readMangaPayload(row),
      imagesRoot: MangaStorage.imagesDirectory(row.extractDir).path,
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
    final MokuroPayload? payload = await readDownloadedChapterPayload(
      chapterDir,
    );
    if (payload != null) return _volumeManifest(row, payload);
    // 没下载的章：本机运行时能取就现取页表（页尺寸未知报 0，对端按图片实测）。
    final _OnlineChapterSource source = _requireOnlineChapter(
      row,
      chapterDigest,
    );
    final int count = await source.reader.chapterPageCount(
      bookKey: row.bookKey,
      sourceMetadata: source.sourceMetadata,
      chapter: source.chapter,
    );
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
          RemoteMangaPageInfo(index: i, name: '$i', width: 0, height: 0),
      ],
    );
  }

  @override
  Future<File> mangaChapterPageFile(
    String bookKey,
    String chapterDigest,
    int index,
  ) async {
    _assertSafeName(bookKey);
    _assertChapterDigest(chapterDigest);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final Directory chapterDir = mangaChapterDirectoryByDigest(
      row.extractDir,
      chapterDigest,
    );
    final MokuroPayload? payload = await readDownloadedChapterPayload(
      chapterDir,
    );
    if (payload == null) {
      return _onlineChapterPageFile(row, chapterDigest, index);
    }
    return _pageFile(
      payload: payload,
      imagesRoot: mangaChapterImagesDirectory(chapterDir).path,
      index: index,
      label: '$bookKey/$chapterDigest',
    );
  }

  /// 单卷 / 单章的页表：payload 的 `pages` 顺序，带 OCR 生产者报告的尺寸。
  RemoteMangaManifest _volumeManifest(EpubBookRow row, MokuroPayload payload) =>
      RemoteMangaManifest(
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
            ),
        ],
      );

  /// 第 [index] 页的页图文件。路径解析 + 穿越守卫恒在 host 侧（client 只送 index，
  /// 从不送路径）。用的是本仓阅读器读本地漫画时的**同一个**
  /// `MangaStorage.resolvePageFilePath`——安全边界靠复制粘贴维持，抄漏一处就是真漏洞。
  File _pageFile({
    required MokuroPayload payload,
    required String imagesRoot,
    required int index,
    required String label,
  }) {
    if (index < 0 || index >= payload.images.length) {
      throw StateError('manga page out of range: $label#$index');
    }
    final String? path = MangaStorage.resolvePageFilePath(
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
  /// 临时文件按 (bookKey, 章, 页) 定名、同页复用：对端翻回来不重复打源站。文件在
  /// [onlineMangaPageCacheRoot] 下、按章有界保留（[pruneOnlineMangaPageCache]），
  /// 不进书目录（那是「已下载」的判据，混进去会让半章冒充下载完成）。
  ///
  /// 同一页的并发请求（阅读器显示 + 预取、或两台对端）合并成一次现取：各自落盘再
  /// 改名会让两路在同一个目标上打架（Windows 上暂存文件还开着时改名直接拒绝）。
  Future<File> _onlineChapterPageFile(
    EpubBookRow row,
    String chapterDigest,
    int index,
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
    final File? cached = _cachedOnlinePage(dir, index);
    if (cached != null) return cached;
    // 判缓存与登记在途之间没有 await：同一 isolate 内这两步是原子的。
    final String key = p.join(dir.path, '$index');
    final Future<File>? running = _onlinePageFetches[key];
    if (running != null) return running;
    final Future<File> fetch = _fetchOnlinePage(source, row, dir, index);
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
  ) async {
    final Uint8List bytes;
    try {
      bytes = await source.reader.chapterPage(
        bookKey: row.bookKey,
        sourceMetadata: source.sourceMetadata,
        chapter: source.chapter,
        index: index,
      );
    } on RangeError {
      throw StateError('manga page out of range: ${row.bookKey}#$index');
    }
    if (bytes.isEmpty) {
      throw StateError('online manga page is empty: ${row.bookKey}#$index');
    }
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
      // 新开一章才清一次：每页都扫整棵缓存树不值。
      pruneOnlineMangaPageCache(onlineMangaPageCacheRoot(), keep: dir);
    }
    final File file = File(
      p.join(dir.path, '$index${onlineMangaPageExtension(bytes)}'),
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
      if (file.existsSync() && file.lengthSync() > 0) {
        await staging.delete();
        return file;
      }
      rethrow;
    }
  }

  /// [dir] 里第 [index] 页已落好的缓存文件（暂存 `.part` 与空文件不算）。
  File? _cachedOnlinePage(Directory dir, int index) {
    if (!dir.existsSync()) return null;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is File &&
          p.extension(entity.path) != '.part' &&
          p.basenameWithoutExtension(entity.path) == '$index' &&
          entity.lengthSync() > 0) {
        return entity;
      }
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

  /// [bookKey] 对应的漫画行；不存在 / 不是漫画 一律 [StateError] → 404。
  ///
  /// 「有内容」不在这里判：单卷（根 `manga.json`）与章节式（`chapters/`）的判据不同，
  /// 各端点按自己那一种把关，与 `/api/library/books` 的 `hasMangaContent` /
  /// `hasMangaChapters` 分别同源——否则会出现「清单说有、翻页说没有」的分裂（BUG-2400）。
  Future<EpubBookRow> _requireMangaRow(String bookKey) async {
    final EpubBookRow? row = _findBookByTitleOrKey(
      await _db.getAllEpubBooks(),
      bookKey,
    );
    if (row == null) {
      throw StateError('manga book not found: $bookKey');
    }
    if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) {
      throw StateError('book is not manga: $bookKey');
    }
    return row;
  }

  /// 读该书的 `manga.json`。行里的 `epubPath` 才是权威文件名（与阅读器一致），
  /// 缺列时回落到布局常量。
  MokuroPayload _readMangaPayload(EpubBookRow row) {
    final String fileName = row.epubPath.isEmpty
        ? kMangaPackageMarker
        : row.epubPath;
    return parseMangaJson(
      File(p.join(row.extractDir, fileName)).readAsStringSync(),
    );
  }
}

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

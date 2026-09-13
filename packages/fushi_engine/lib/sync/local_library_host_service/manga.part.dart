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
    if (payload == null) {
      throw StateError('manga chapter not downloaded: $bookKey/$chapterDigest');
    }
    return _volumeManifest(row, payload);
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
      throw StateError('manga chapter not downloaded: $bookKey/$chapterDigest');
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

  /// 章节式在线漫画在 host 上已完整下载的章，按 `chaptersJson`（书架条目的章表，
  /// 源给的顺序）逐章问 [readDownloadedChapterPayload]。
  ///
  /// 章表从 `epub_books.chaptersJson` 读而不是 `sourceMetadata`：前者就是一列
  /// `{key,name,number,scanlator,uploadedAt,raw}`，引擎不必认识 app 侧的书架条目
  /// 类型；后者是运行时描述符，形状随 Mihon / Aidoku 各异。
  Future<List<RemoteMangaChapterInfo>> _downloadedChapters(
    EpubBookRow row,
  ) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(row.chaptersJson);
    } on Object {
      return const <RemoteMangaChapterInfo>[];
    }
    if (decoded is! List<Object?>) return const <RemoteMangaChapterInfo>[];
    final List<RemoteMangaChapterInfo> chapters = <RemoteMangaChapterInfo>[];
    for (final Object? item in decoded) {
      if (item is! Map<Object?, Object?>) continue;
      final Map<String, Object?> json = item.cast<String, Object?>();
      final String key = json['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      final MokuroPayload? payload = await readDownloadedChapterPayload(
        mangaChapterDirectoryByDigest(row.extractDir, mangaChapterDigest(key)),
      );
      if (payload == null) continue;
      final int uploadedAt = (json['uploadedAt'] as num?)?.toInt() ?? 0;
      final String scanlator = json['scanlator']?.toString() ?? '';
      chapters.add(
        RemoteMangaChapterInfo(
          key: key,
          name: json['name']?.toString() ?? '',
          pageCount: payload.images.length,
          number: (json['number'] as num?)?.toDouble(),
          scanlator: scanlator.isEmpty ? null : scanlator,
          uploadedAt: uploadedAt <= 0 ? null : uploadedAt,
        ),
      );
    }
    return chapters;
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

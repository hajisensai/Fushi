part of '../local_library_host_service.dart';

/// 漫画域：互联漫画源的页表与页图供给（**只读**）。
///
/// 与书域刻意分开：书域那三个端点（导出 / 导入 / 删除）搬的是「整卷 zip 包」，语义是
/// 「把这本书搬到我这儿来」；本域搬的是「页」，语义是「我在你那儿翻页」。前者早已存在
/// （`repackageMangaBook` + `/api/library/books/<id>`），后者才是把对端库当成一个**漫画
/// 源**（浏览 → 在线读）所缺的那半条链。
///
/// 一本 = 一卷 = 一章：漫画在本仓是 `EpubBooks` 里 `format=='manga'` 的一行，磁盘布局
/// `<extractDir>/{manga.json, images/…}`，卷内没有章节结构。互联漫画源据此把「一本」
/// 映射成「一部作品的唯一一章」。
mixin _LocalLibraryHostManga on _LocalLibraryHostBase, _LocalLibraryHostShared {
  @override
  Future<RemoteMangaManifest> mangaManifest(String bookKey) async {
    _assertSafeName(bookKey);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final MokuroPayload payload = _readMangaPayload(row);
    return RemoteMangaManifest(
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
  }

  @override
  Future<File> mangaPageFile(String bookKey, int index) async {
    _assertSafeName(bookKey);
    final EpubBookRow row = await _requireMangaRow(bookKey);
    final MokuroPayload payload = _readMangaPayload(row);
    if (index < 0 || index >= payload.images.length) {
      throw StateError('manga page out of range: $bookKey#$index');
    }
    // 路径解析 + 穿越守卫恒在 host 侧（client 只送 index，从不送路径）。用的是本仓
    // 阅读器读本地漫画时的**同一个** `MangaStorage.resolvePageFilePath`——安全边界靠
    // 复制粘贴维持，抄漏一处就是真漏洞。
    final String? path = MangaStorage.resolvePageFilePath(
      MangaStorage.imagesDirectory(row.extractDir).path,
      MangaStorage.pageRelativePath(payload.images[index].url),
    );
    if (path == null) {
      throw StateError('manga page not found: $bookKey#$index');
    }
    return File(path);
  }

  /// [bookKey] 对应的漫画行；不存在 / 不是漫画 / 无可读内容一律 [StateError] → 404。
  ///
  /// 「有内容」判据复用清单侧的 [hasExportableMangaContent]，与 `/api/library/books`
  /// 的 `hasMangaContent` 严格同源：否则会出现「清单说有、翻页说没有」的分裂——正是
  /// BUG-2400 里那种「占位空合集被标成可下载」的形状。
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
    if (!hasExportableMangaContent(row.extractDir)) {
      throw StateError('manga book has no readable content: $bookKey');
    }
    return row;
  }

  /// 读该书的 `manga.json`。行里的 `epubPath` 才是权威文件名（与阅读器一致），
  /// 缺列时回落到布局常量。
  MokuroPayload _readMangaPayload(EpubBookRow row) {
    final String fileName =
        row.epubPath.isEmpty ? kMangaPackageMarker : row.epubPath;
    return parseMangaJson(
      File(p.join(row.extractDir, fileName)).readAsStringSync(),
    );
  }
}

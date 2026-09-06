part of '../local_library_host_service.dart';

/// 书籍域（B4 按域拆出）：清单（标签 / 主合集 / 改名 / 进度）、导出 / 导入 / 删除、阅读进度、封面路径。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostBooks on _LocalLibraryHostBase, _LocalLibraryHostShared {
  // ── 书籍 ─────────────────────────────────────────────────────────────────

  /// bookKey → 标签名列表 的一趟映射（TODO-1165，避免逐条 N+1 查询）。
  /// 复用 DB 层 SQL 过滤的批查（review-reuse-2：内层 map 的 key 即标签名，
  /// 别再全表拉 assignments 手工 join）。
  Future<Map<String, List<String>>> _tagNamesByBookKey() async =>
      (await _db.allBookTagAddedAtByName()).map(
          (String key, Map<String, int> byName) =>
              MapEntry(key, byName.keys.toList()));

  /// host 当前书库清单（从 EpubBooks 表读）。
  /// [RemoteBookInfo.hasContent] 为 true 当且仅当该书存在可导出的 EPUB 根目录。
  @override
  Future<List<RemoteBookInfo>> listBooks() async {
    final List<EpubBookRow> rows = await _db.getAllEpubBooks();
    // 该书是否已配「可经 live-sync 导出」的有声书。判据必须与 [listAudiobooks] /
    // [exportAudiobook] 完全同源——仅 Audiobooks 行还不够，导出格式需 srtBookUid，
    // 故只有同时具备 SrtBooks 行的 bookKey 才算可下载（TODO-778）。否则 EPUB 对齐
    // 有声书（有 Audiobook 无 SrtBook）会亮徽章 + 可点下载，但 exportAudiobook
    // 抛 StateError → 服务端 404。
    final Set<String> audiobookKeys = await _srtBackedAudiobookKeys();
    final Map<String, List<String>> tagsByBookKey = await _tagNamesByBookKey();
    // tags 稳健档：host 为每本书带上标签 LWW 时钟（名→加入戳）+ 移除墓碑，供 client
    // mergeRemoteBookTags 传播 host 侧的删除/改名、防复活（旧 client 忽略这些键、按
    // tags 名单只增，向后兼容）。批量一趟查（旧实现逐书 2 次查询，大库清单端点 O(N)
    // 次 DB 往返）。
    final Map<String, Map<String, int>> tagAddedAtByKey =
        await _db.allBookTagAddedAtByName();
    final Map<String, Map<String, int>> tagTombByKey =
        await _db.allTagTombstonesByName(MediaKind.epub);
    final Map<String, RemoteCollectionMembership> membership =
        await _primaryCollectionMembership();
    // BUG-1488：host 上用户改过的书名（`preferences` 的 override 覆盖层）随清单
    // 下发，否则 peer 永远只看得到 raw `epub_books.title`。一趟 prefs 读。
    final Map<String, OverrideTitleEntry> overrideTitles =
        await _overrideTitleByBookKey();
    // 阅读进度内联（首页仪表盘「继续」的互联数据源）：percent 与本地首页同源同算
    // （MediaItems.position/duration），最近阅读时刻取 reader_positions.updatedAt。
    // 各一趟批查；旧 client 忽略这两个 additive 字段。
    final Map<String, ({int percent, int updatedAtMs})> progressByKey =
        await _bookProgressByKey();
    // BUG-812：srt-backed 有声书（同 bookKey 既有 EpubBooks 又有 SrtBooks 行）加入合集
    // 时以 **`srt|<uid>`** 存进成员表（本地书架把它当 SRT 卡渲染、经 srt|uid 折叠），
    // 而非 `epub|<bookKey>`。互联 client 把这类书作为 EPUB 占位卡收下，只查 `epub|bookKey`
    // 会 miss → RemoteBookInfo.collection=null → 有声书不折进合集。这里补一趟
    // bookKey→srtUid 映射，供下面按 srt 成员键兜底查归属，让有声书 EPUB 卡也带上
    // collection（client 经现有注入循环折进合集，与本地书架对称、不依赖后台 sweep）。
    final Map<String, String> srtUidByBookKey = <String, String>{
      for (final SrtBookRow s in await _db.getAllSrtBooks())
        if (s.bookKey.isNotEmpty) s.bookKey: s.uid,
    };
    return rows.map((EpubBookRow r) {
      // EPUB 行的 coverPath 是 EPUB 内部相对 href，必须拼 extractDir 才是磁盘真
      // 路径；直接 _existingFilePath(相对href) 恒 false → 远端书卡没封面（#4）。
      final String? coverPath = resolveEpubCoverFilePath(
        extractDir: r.extractDir,
        coverPath: r.coverPath,
      );
      final BookFormat format = BookFormat.parseOrEpub(r.format);
      return RemoteBookInfo(
        title: r.title,
        // BUG-1488：只在真改过名时非 null（toJson 亦只在与 title 不同时写键）。
        displayTitle: overrideTitles[r.bookKey]?.title,
        // BUG-1502：改名时刻随行，让 client 端做 LWW 而不是 insert-if-absent。
        displayTitleAt: overrideTitles[r.bookKey]?.updatedAt ?? 0,
        bookKey: r.bookKey,
        // hasContent（EPUB 内容树可导出）按 format 门控（互联完整支持批次）：由
        // EPUB 转化来的漫画行 extractDir 里仍留着 EPUB 解压树，旧判据会把它当可
        // 下载 EPUB 打包——把整套页图 + manga.json 塞进 zip，client 落地成一本
        // 夹带全部页图的「文字书」、漫画身份静默丢失（坏包）。漫画内容走
        // hasMangaContent + 漫画包通道。
        hasContent: format == BookFormat.epub &&
            resolveExtractedEpubRoot(r.extractDir) != null,
        format: format.dbValue,
        hasMangaContent: format == BookFormat.manga &&
            File(p.join(r.extractDir, kMangaPackageMarker)).existsSync(),
        mangaReadingMode: r.mangaReadingMode,
        hasEmbeddedCover: coverPath != null,
        coverPath: coverPath,
        hasAudiobook: audiobookKeys.contains(r.bookKey),
        tags: tagsByBookKey[r.bookKey] ?? const <String>[],
        tagsAddedAt: tagAddedAtByKey[r.bookKey] ?? const <String, int>{},
        tagTombstones: tagTombByKey[r.bookKey] ?? const <String, int>{},
        // 合集成员键（v83）：epub 成员行 entryKey = 本机 epub_books.uid，书侧组键
        // 用 r.uid（§2.3 任务5.1 的 wire 面貌仍是 bookKey，与本地键域无关）。
        // epub|bookKey 兜底：sync 落地的透传行（书当时还没下载）在下一轮 apply
        // 收敛前仍以对端 bookKey 为键，窗口期内按 bookKey 也查一把，归属不闪断。
        // srt-backed 有声书兜底：该书以 srt|uid 入合集时，epub 两键都 miss，
        // 回退查 srt|uid（BUG-812）。散卡（三键都无）= null。
        collection: membership[MediaKind.epub.compositeKey(r.uid)] ??
            membership[MediaKind.epub.compositeKey(r.bookKey)] ??
            (srtUidByBookKey[r.bookKey] != null
                ? membership[
                    MediaKind.srt.compositeKey(srtUidByBookKey[r.bookKey]!)]
                : null),
        progressPercent: progressByKey[r.bookKey]?.percent ?? 0,
        progressUpdatedAtMs: progressByKey[r.bookKey]?.updatedAtMs ?? 0,
        // BUG-1119：EpubBooks 行都是可下载 EPUB，显式标 epub（srt-backed 有声书
        // 的 EPUB 卡语义仍是 epub——与本地 _bookMediaKind 按 hoshi://book/ 身份判
        // epub 一致，勿标成 srt 造成两端同书异 kind）。standalone SRT 书（身份
        // hoshi://srtbook/<uid>，无 EpubBooks 行）今天不在本清单，进清单是独立
        // follow-up。
        kind: MediaKind.epub,
      );
    }).toList();
  }

  /// 批查「bookKey → 用户自定义显示名」（BUG-1488）。
  ///
  /// 改名不改 `epub_books.title`（标题派生 bookKey 是跨端身份，改列 = 十来张子表
  /// 连坐改键），而是往 `preferences` 写一行覆盖，key 形如
  /// `src:reader_fushi:override_title://fushi://book/<bookKey>`。三段前缀分别由
  /// [dbSourcePrefKey] / [MediaSource.overrideTitleKeyFor] /
  /// [ReaderFushiSource.mediaIdentifierFor] 各自的真相源拼出，本层零硬编码字符串。
  ///
  /// 只认**规范**键形态：BUG-1317 之前的旧键（源键出现两次）由读取期回退在 host
  /// 自己的书架上就地重写成规范键，而改名动作本身恒写规范键，所以旧形态只可能
  /// 属于「BUG-1317 之前改的名 + 此后从未在本机显示过」的书，可忽略。
  /// bookKey → (host 上的显示名, 它的 LWW 毫秒戳)。
  ///
  /// BUG-1502：戳来自 `preferences.updated_at`，随清单一起下发，让 client 端能对
  /// 「本机也改过名」的书做 last-write-wins（此前只能 insert-if-absent，host 的
  /// **第二次**改名永远传不过去）。实现共享给推书方向（BUG-1503），见
  /// [readOverrideTitlesByBookKey]。
  Future<Map<String, OverrideTitleEntry>> _overrideTitleByBookKey() =>
      readOverrideTitlesByBookKey(_db);

  /// 批查全库书籍阅读进度「bookKey → (percent 0..100, 最近阅读毫秒戳)」。
  ///
  /// percent 与本地首页仪表盘「继续」完全同算：`MediaItems.position/duration`
  /// （书的 MediaItem.mediaIdentifier = `hoshi://book/<bookKey>`）；时刻取
  /// `reader_positions.updatedAt`。两趟全表读，无逐书查询。
  Future<Map<String, ({int percent, int updatedAtMs})>>
      _bookProgressByKey() async {
    // v82：reader_positions 键 = 书 uid，wire/mediaId 面貌仍是 bookKey——
    // 经 epub_books 反查（uid → bookKey）后出 wire。
    final Map<String, String> bookKeyByUid = <String, String>{
      for (final EpubBookRow b in await _db.getAllEpubBooks())
        if (b.uid.isNotEmpty) b.uid: b.bookKey,
    };
    final Map<String, int> updatedAtByKey = <String, int>{
      for (final ReaderPositionRow r in await _db.getAllReaderPositions())
        if (bookKeyByUid[r.bookUid] case final String key) key: r.updatedAt,
    };
    final Map<String, ({int percent, int updatedAtMs})> out =
        <String, ({int percent, int updatedAtMs})>{};
    for (final MediaOpenHistoryRow m in await _db.getAllMediaOpenHistory()) {
      final RegExpMatch? match = _fushiBookKeyPattern.firstMatch(m.mediaId);
      if (match == null) continue;
      final String bookKey = match.group(1)!;
      if (m.duration <= 0 || m.position <= 0) continue;
      out[bookKey] = (
        percent: ((m.position / m.duration) * 100).clamp(0, 100).round(),
        updatedAtMs: updatedAtByKey[bookKey] ?? 0,
      );
    }
    return out;
  }

  /// 即时把书名为 [title] 的书 extractDir 重打包成 .epub 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]；
  /// 书不存在或 extractDir 为空/不存在时抛 [StateError]。
  @override
  Future<File> exportBook(String title) async {
    _assertSafeName(title);
    final List<EpubBookRow> rows = await _db.getAllEpubBooks();
    final EpubBookRow? row = _findBookByTitleOrKey(rows, title);
    if (row == null) {
      throw StateError('book not found: $title');
    }
    final BookFormat format = BookFormat.parseOrEpub(row.format);
    // 漫画（互联完整支持批次）：包 = 书目录整树 zip（manga.json 标记 + 页图），
    // 与 EPUB 包同端点、导入侧内容嗅探分流。扩展名仍 .epub（端点/tmp 命名契约
    // 不变，内容即真相）。
    if (format == BookFormat.manga) {
      final Directory tmpDir =
          Directory.systemTemp.createTempSync('hibiki_book_export');
      final File out = File(p.join(tmpDir.path, '${row.bookKey}.epub'));
      final bool ok = await repackageMangaBook(row.extractDir, out.path);
      if (!ok) {
        throw StateError('manga book has no exportable content: $title');
      }
      return out;
    }
    if (format != BookFormat.epub ||
        resolveExtractedEpubRoot(row.extractDir) == null) {
      // PDF（无互联内容通道）/ EPUB 树缺失：与旧行为一致抛 StateError → 404。
      throw StateError('book has no exportable EPUB root: $title');
    }

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_book_export');
    // 文件名用 title 但扩展名用 .epub，保证重导入时 fileName 是合法 epub 名。
    final String safeBasename = '${row.bookKey}.epub';
    final File out = File(p.join(tmpDir.path, safeBasename));
    final bool ok = await repackageExtractedEpub(row.extractDir, out.path);
    if (!ok) {
      throw StateError('repackage produced no output for book: $title');
    }
    return out;
  }

  /// 把 [epubFile] 导入 host 书库。
  ///
  /// 生产使用时需在构造器传入 [importBookFromFile] 回调
  /// （例如 `(f) => EpubImporter.importFromPath(db: db, filePath: f.path, fileName: p.basename(f.path))`）。
  /// 回调为 null 时抛 [UnsupportedError]。
  ///
  /// BUG-1503：回调返回**落地后的真实 bookKey**（`EpubImporter.importFromPath` 的
  /// 返回值），显示名才有地方挂——它不能由 [displayTitle] 或 URL 里的 title 推，
  /// 重名时 importer 会加 `(2)` 后缀，派生键随之不同。
  @override
  Future<void> importBook(
    File epubFile, {
    String? displayTitle,
    int displayTitleAt = 0,
  }) async {
    final Future<String?> Function(File)? importer = _importBookFromFile;
    if (importer == null) {
      throw UnsupportedError(
        'importBook requires importBookFromFile callback to be provided',
      );
    }
    String? bookKey;
    await _runExclusive(() async {
      bookKey = await importer(epubFile);
    });
    await _adoptPushedDisplayTitle(
      bookKey: bookKey,
      displayTitle: displayTitle,
      displayTitleAt: displayTitleAt,
    );
  }

  /// 把推送方随书带来的显示名落成 host 本机的 override，last-write-wins
  /// （BUG-1503 + BUG-1502）。
  ///
  /// 与 client 端下载后的采纳（`_adoptRemoteBookDisplayTitle`）和备份合并
  /// （`BackupMergeEngine._mergeOverrideTitlePrefs`）共用同一条裁决规则：严格更新
  /// 才覆盖、平局保留本机、本机没有该行则无条件采纳。三条通道语义不一致就等于没修。
  ///
  /// 走 `MediaSource.adoptOverrideTitleIfNewer` 而不是裸写 DB：host 是个正在跑的
  /// app，`MediaSource` 有一层内存偏好缓存，只写 DB 的话 host 书架会一直显示旧名
  /// 直到重启（而且 `getPreference` 的 miss 会把 null 反写进缓存）。
  Future<void> _adoptPushedDisplayTitle({
    required String? bookKey,
    required String? displayTitle,
    required int displayTitleAt,
  }) async {
    if (bookKey == null ||
        bookKey.isEmpty ||
        displayTitle == null ||
        displayTitle.isEmpty) {
      return;
    }
    try {
      final ReaderFushiSource source = ReaderFushiSource.instance;
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey(bookKey),
        title: displayTitle,
        updatedAt: displayTitleAt,
      );
    } catch (e, stack) {
      // 书已经入库了——显示名没落上不该把整个 PUT 变成 HTTP 500。
      ErrorLogService.instance
          .log('LocalLibraryHostService.adoptPushedDisplayTitle', e, stack);
    }
  }

  /// 从 host 书库删除书名为 [title] 的书（DB 行 + 磁盘目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteBook(String title) async {
    _assertSafeName(title);
    await _runExclusive(() async {
      final List<EpubBookRow> rows = await _db.getAllEpubBooks();
      final EpubBookRow? row = _findBookByTitleOrKey(rows, title);
      if (row == null) return; // 幂等：不存在则静默跳过

      // 先让注入的磁盘清理回调运行（AudiobookStorage / SrtBook 等 DB 行外资源），
      // 在 DB deleteEpubBook 事务之前拿到 row 数据（事务后 row 即消失）。
      await _cleanupBookOnDisk?.call(row);

      // DB 事务：删除 EpubBooks 行及其所有关联行（readerPositions / bookmarks /
      // srtBooks / audioCues / audiobooks）。见 HBK-AUDIT-041。
      // TODO-1195 part B：用户删书记墓碑，避免旧备份合并导入时复活。
      await _db.deleteEpubBook(row.bookKey, tombstone: true);

      // extractDir 磁盘目录：DB 删除后再清理（与 reader_fushi_source 同顺序）。
      if (row.extractDir.isNotEmpty) {
        final Directory dir = Directory(row.extractDir);
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });
  }

  /// 读 host 端书 [bookKey] 的阅读进度（TODO-767）。直读 host 自己的
  /// `reader_positions` 表（与 host 本地阅读该书时同一真相源）；无记录返回
  /// [RemoteBookProgress.empty]。
  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async {
    // v82：wire 键 bookKey → 本地子表键 uid 换算；书不在库视同无记录。
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null || book.uid.isEmpty) return RemoteBookProgress.empty;
    final ReaderPositionRow? row = await _db.getReaderPosition(book.uid);
    if (row == null) return RemoteBookProgress.empty;
    return RemoteBookProgress(
      sectionIndex: row.sectionIndex,
      normCharOffset: row.normCharOffset,
      charOffset: row.charOffset,
      updatedAtMs: row.updatedAt,
    );
  }

  /// 把 client 上报的书 [bookKey] 进度写入 host 自己的 `reader_positions`
  /// （TODO-767）。
  ///
  /// 冲突解决「取较新时间戳」（[resolveBookProgressSync]）：仅当 [progress] 严格
  /// 新于 host 已存时间戳才覆盖，避免旧设备滞后上报回退新进度。胜出方等于 host 已存
  /// 进度时 no-op（不写库）。负 normCharOffset clamp 0。
  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    // host 书库不存在该 bookKey → no-op，不写孤儿 `reader_positions` 行。
    // （reader_positions 无外键也无 GC，任意 client 上报任意 bookKey 都会落库；
    // 之后 host 若导入同名 sanitize bookKey 的书，恢复时会取到来自别处设备、host
    // 从没读过的陈旧位置 = 进度污染。与视频 `updateVideoBookPosition`「UPDATE
    // 不存在即 no-op」语义对齐。syncContent 开时 client 独有书已先经
    // `_syncBooksContentLive` importBook 推成 host 书，故正常同步不被此闸门误挡。）
    final EpubBookRow? hostBook = await _db.getEpubBook(bookKey);
    if (hostBook == null || hostBook.uid.isEmpty) return;
    final RemoteBookProgress current = await getBookProgress(bookKey);
    final RemoteBookProgress incoming = RemoteBookProgress(
      sectionIndex: progress.sectionIndex < 0 ? 0 : progress.sectionIndex,
      normCharOffset: progress.normCharOffset < 0 ? 0 : progress.normCharOffset,
      charOffset: progress.charOffset,
      updatedAtMs: progress.updatedAtMs,
    );
    final RemoteBookProgress winner =
        resolveBookProgressSync(local: current, remote: incoming);
    if (winner.sectionIndex == current.sectionIndex &&
        winner.normCharOffset == current.normCharOffset &&
        winner.charOffset == current.charOffset &&
        winner.updatedAtMs == current.updatedAtMs) {
      return; // host 已存更新或相等，no-op。
    }
    await _runExclusive(() async {
      await _db.upsertReaderPosition(ReaderPositionsCompanion(
        bookUid: Value(hostBook.uid),
        sectionIndex: Value(winner.sectionIndex),
        normCharOffset: Value(winner.normCharOffset),
        charOffset: Value(winner.charOffset),
        updatedAt: Value(winner.updatedAtMs),
      ));
    });
  }

  /// 按 [id]（downloadId：bookKey 或 title）单查书封面磁盘路径（对称
  /// [videoCoverPath]）。优先按 bookKey 单行查；未命中（旧 client 用 title 当
  /// downloadId）回退全表按 title/bookKey 匹配——仍只是一次 DB 查询 + 几次 stat，
  /// 没有旧 listBooks 的逐书标签/有声书/合集重活。
  @override
  Future<String?> bookCoverPath(String id) async {
    EpubBookRow? row = await _db.getEpubBook(id);
    row ??= _findBookByTitleOrKey(await _db.getAllEpubBooks(), id);
    if (row == null) return null;
    return resolveEpubCoverFilePath(
      extractDir: row.extractDir,
      coverPath: row.coverPath,
    );
  }
}

// ── 本域私有的顶层 helper（原 LocalLibraryHostService 的 private static；mixin 体内看不到
//    宿主类的 static，故提到库顶层）。

EpubBookRow? _findBookByTitleOrKey(
  List<EpubBookRow> rows,
  String titleOrBookKey,
) =>
    rows.cast<EpubBookRow?>().firstWhere(
          (EpubBookRow? r) =>
              r!.bookKey == titleOrBookKey || r.title == titleOrBookKey,
          orElse: () => null,
        );

final RegExp _fushiBookKeyPattern = RegExp(r'^fushi://book/(.+)$');

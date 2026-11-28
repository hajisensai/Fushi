part of '../sync_orchestrator.dart';

extension _CloudBookContentRecovery on SyncOrchestrator {
  /// 云盘用 TTU 规范书名作身份。这里只为仍在本机书库的条目补正文，
  /// 绝不通过 ensureBookFolder 造云端目录，也不走会重新登记书目的导入入口。
  Future<void> _recoverMissingCloudBooks(
    SyncRunReport report, {
    required String root,
    required RemoteListingSnapshot? listing,
    required Set<String> vetoedBookKeys,
  }) async {
    final BookContentRecovery recovery = BookContentRecovery(
      db: _db,
      tempDir: _tempDir,
    );
    final Map<String, EpubBookRow> candidates = <String, EpubBookRow>{};
    final Map<String, List<SyncFileRef>> folders =
        <String, List<SyncFileRef>>{};
    try {
      final List<EpubBookRow> missing = await recovery.missingBooks();
      for (final EpubBookRow book in missing) {
        final String name = sanitizeTtuFilename(book.title);
        if (name.isEmpty ||
            isReservedSyncFolderName(name) ||
            vetoedBookKeys.contains(book.bookKey) ||
            BookFormat.tryParse(book.format) == BookFormat.pdf) {
          continue;
        }
        if (listing != null &&
            _uniqueCloudRecoveryAsset(book, listing.entriesOf(name)) == null) {
          continue;
        }
        candidates[name] = book;
      }
      if (candidates.isEmpty) return;

      // 同名本机书即使只有一本缺文件，也无法单靠云端目录名确认是哪一本。
      final Set<String> seen = <String>{};
      for (final EpubBookMeta book in await _db.getEpubBookMetas()) {
        final String name = sanitizeTtuFilename(book.title);
        if (!seen.add(name)) candidates.remove(name);
      }
      if (candidates.isEmpty) return;

      // 整根快照可复用文件项，但会把同名目录折叠在同一个键里。
      // 仅有恢复候选时再读一次目录身份，确保同名目录唯一。
      _checkpoint();
      for (final SyncFileRef folder in await _backend.listBooks(root)) {
        if (candidates.containsKey(folder.name)) {
          (folders[folder.name] ??= <SyncFileRef>[]).add(folder);
        }
      }
    } on SyncAuthError {
      rethrow;
    } on SyncCancelledException {
      rethrow;
    } catch (error) {
      _noteDimensionError(report, 'list cloud books for recovery', error);
      return;
    }

    final List<({EpubBookRow book, SyncFileRef folder})> work =
        <({EpubBookRow book, SyncFileRef folder})>[
          for (final MapEntry<String, List<SyncFileRef>> entry
              in folders.entries)
            if (entry.value.length == 1)
              (book: candidates[entry.key]!, folder: entry.value.single),
        ];
    for (int index = 0; index < work.length; index++) {
      _checkpoint();
      final (:book, :folder) = work[index];
      try {
        final List<AssetEntry> entries =
            listing?.entriesOf(folder.name) ??
            await _backend.listChildren(folder.id);
        final AssetEntry? asset = _uniqueCloudRecoveryAsset(book, entries);
        if (asset == null) continue;
        _checkpoint();
        _emit(
          SyncPhase.books,
          itemIndex: index,
          itemTotal: work.length,
          title: book.title,
        );
        if (await recovery.restore(
          book,
          checkCanPlace: _checkpoint,
          download: (File destination) => _backend.getAsset(
            asset.id,
            destination,
            onProgress: (double fraction, [int? bytesDone]) => _emit(
              SyncPhase.books,
              itemIndex: index,
              itemTotal: work.length,
              title: book.title,
              fileFraction: fraction,
              fileBytes: bytesDone,
            ),
          ),
        )) {
          report.booksRecovered++;
        }
      } on SyncAuthError {
        rethrow;
      } on SyncCancelledException {
        rethrow;
      } catch (error) {
        _noteDimensionError(
          report,
          'recover cloud book "${book.title}"',
          error,
        );
      }
    }
  }
}

AssetEntry? _uniqueCloudRecoveryAsset(
  EpubBookRow book,
  Iterable<AssetEntry> entries,
) {
  final String epubName = cloudEpubContentFileName(book.title);
  final String mangaName = cloudMangaContentFileName(book.title);
  final List<AssetEntry> matches = <AssetEntry>[
    for (final AssetEntry entry in entries)
      if (!entry.isFolder &&
          (entry.name == epubName || entry.name == mangaName))
        entry,
  ];
  if (matches.length != 1) return null;
  final AssetEntry asset = matches.single;
  // 漫画旧包使用 .epub 名，实际内容格式仍由落盘前的正文校验决定。
  return asset.name == epubName ||
          BookFormat.tryParse(book.format) == BookFormat.manga
      ? asset
      : null;
}

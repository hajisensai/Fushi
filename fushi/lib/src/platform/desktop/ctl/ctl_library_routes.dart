import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_entries.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_import.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// library 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/library_commands.dart`）。
///
/// 条目键统一是 `<store>:<id>`（见 [LibraryCtlKey]）：`book:<bookKey>`（书 / PDF /
/// 漫画）、`srt:<uid>`（有声书）、`video:<bookUid>`、`game:<id>`。每条路由都落到
/// 库页按钮背后的那个方法上，不另写业务逻辑：
///
/// - 列书：[ReaderFushiSource.getBooksFromDb]（书架同源）+ [SrtBookRepository.listAll]
///   + [VideoBookRepository.listAll] + [GalgameRepository.games]；
/// - 删除：[ReaderFushiSource.deleteBook] / [SrtBookRepository.delete]（书架单删）、
///   [deleteVideoBooksWithDecision]（视频页单删）、[GalgameRepository.remove]（游戏库「移除」）；
/// - 打开：[AppModel.openMedia]（书架点卡）、[MangaSeriesPage]（漫画先进作品页）、
///   [VideoFushiPage.neutralized]（视频页 / 外部打开同一出口）、[GalgameDetailPage]
///   （与统计页一致：只进详情页，绝不静默拉起游戏）；
/// - 导入：见 `ctl_library_import.dart`；
/// - 扫描：[SourceLibraryScanner.scan]（来源页「重新扫描」）。
List<CtlRoute> buildLibraryCtlRoutes(DesktopCtlContext context) {
  final _LibraryCtlHandlers handlers = _LibraryCtlHandlers(context);
  return <CtlRoute>[
    CtlRoute.get(kLibraryCtlItemsPath, handlers.listItems),
    CtlRoute.get('$kLibraryCtlItemsPath/:key', handlers.getItem),
    CtlRoute.delete('$kLibraryCtlItemsPath/:key', handlers.removeItem),
    CtlRoute.post('$kLibraryCtlItemsPath/:key/open', handlers.openItem),
    CtlRoute.post(kLibraryCtlImportPath, handlers.importPaths),
    CtlRoute.get(kLibraryCtlHistoryPath, handlers.history),
    CtlRoute.get(kLibraryCtlSourcesPath, handlers.listSources),
    CtlRoute.post(kLibraryCtlScanPath, handlers.scan),
  ];
}

const String kLibraryCtlRoot = '/api/admin/library';
const String kLibraryCtlItemsPath = '$kLibraryCtlRoot/items';
const String kLibraryCtlImportPath = '$kLibraryCtlRoot/import';
const String kLibraryCtlHistoryPath = '$kLibraryCtlRoot/history';
const String kLibraryCtlSourcesPath = '$kLibraryCtlRoot/sources';
const String kLibraryCtlScanPath = '$kLibraryCtlRoot/scan';

/// `library history` 缺省条数。
const int kLibraryCtlHistoryDefaultLimit = 20;

class _LibraryCtlHandlers {
  _LibraryCtlHandlers(this._context);

  final DesktopCtlContext _context;

  AppModel get _app => _context.appModel;
  FushiDatabase get _db => _app.database;

  // ── 门控 ─────────────────────────────────────────────────────────────

  bool _kindVisible(LibraryCtlKind kind) =>
      _app.moduleVisibility.isEnabled(kind.module);

  void _requireKindVisible(LibraryCtlKind kind) {
    if (!_kindVisible(kind)) {
      throw CtlFailure.rejected(
        '「${kind.wireName}」所属模块已在设置里关闭（${kind.module.name}）',
      );
    }
  }

  /// 已迁移只读态：与 [AppModel.openMedia] 同一闸门，写库的命令一律挡下。
  void _requireWritable() {
    if (_app.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  LibraryCtlKey _parseKey(CtlCall call) {
    final String raw = call.params['key'] ?? '';
    final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
    if (key == null) {
      throw CtlFailure.badRequest(
        '条目键「$raw」格式不对，应为 book:/srt:/video:/game: 前缀加 id（见 library ls）',
      );
    }
    return key;
  }

  Set<LibraryCtlKind>? _parseKinds(CtlCall call) {
    final String? raw = call.optString('kind');
    if (raw == null) return null;
    final Set<LibraryCtlKind> kinds = <LibraryCtlKind>{};
    for (final String part in raw.split(',')) {
      if (part.trim().isEmpty) continue;
      final LibraryCtlKind? kind = LibraryCtlKind.tryParse(part);
      if (kind == null) {
        throw CtlFailure.badRequest(
          'kind「$part」不认识，可选：'
          '${LibraryCtlKind.values.map((LibraryCtlKind k) => k.wireName).join('/')}',
        );
      }
      kinds.add(kind);
    }
    return kinds.isEmpty ? null : kinds;
  }

  // ── ls / get ─────────────────────────────────────────────────────────

  Future<Object?> listItems(CtlCall call) async {
    final Set<LibraryCtlKind>? requested = _parseKinds(call);
    final Set<LibraryCtlKind> visible = <LibraryCtlKind>{
      for (final LibraryCtlKind kind in requested ?? LibraryCtlKind.values)
        if (_kindVisible(kind)) kind,
    };
    final List<LibraryCtlKind> hidden = <LibraryCtlKind>[
      for (final LibraryCtlKind kind in requested ?? LibraryCtlKind.values)
        if (!visible.contains(kind)) kind,
    ];
    final List<LibraryCtlEntry> all = await _collectEntries(visible);
    final List<LibraryCtlEntry> filtered = filterLibraryCtlEntries(
      all,
      kinds: visible,
      search: call.optString('search'),
    );
    final int? limit = call.optInt('limit');
    final List<LibraryCtlEntry> shown = limit == null || limit <= 0
        ? filtered
        : filtered.take(limit).toList(growable: false);
    return <String, Object?>{
      'total': filtered.length,
      'items': <Object?>[
        for (final LibraryCtlEntry entry in shown) entry.toJson(),
      ],
      if (hidden.isNotEmpty)
        'hiddenKinds': <String>[
          for (final LibraryCtlKind kind in hidden) kind.wireName,
        ],
    };
  }

  /// 把书架 / 视频库 / 游戏库的条目换成 [LibraryCtlEntry]。[kinds] 之外的域不读。
  Future<List<LibraryCtlEntry>> _collectEntries(
    Set<LibraryCtlKind> kinds,
  ) async {
    final List<LibraryCtlEntry> out = <LibraryCtlEntry>[];
    final bool wantsBooks = kinds.any(
      (LibraryCtlKind k) =>
          k == LibraryCtlKind.book ||
          k == LibraryCtlKind.pdf ||
          k == LibraryCtlKind.manga ||
          k == LibraryCtlKind.audiobook,
    );
    if (wantsBooks) out.addAll(await _bookEntries());
    if (kinds.contains(LibraryCtlKind.video)) out.addAll(await _videoEntries());
    if (kinds.contains(LibraryCtlKind.game)) out.addAll(await _gameEntries());
    return out;
  }

  /// 书架同源：`getBooksFromDb`（进度 / 封面 / 改名覆盖）+ 瘦投影 meta（format /
  /// 导入时刻 / 读完标记）+ 字幕书。与书架一致，被字幕书配对的 EPUB 只以有声书出现。
  Future<List<LibraryCtlEntry>> _bookEntries() async {
    final List<MediaItem> books = await ReaderFushiSource.instance
        .getBooksFromDb(appModel: _app);
    final Map<String, EpubBookMeta> metas = <String, EpubBookMeta>{
      for (final EpubBookMeta meta in await _db.getEpubBookMetas())
        meta.bookKey: meta,
    };
    final List<SrtBook> srtBooks = await SrtBookRepository(_db).listAll();
    final Set<String> pairedBookKeys = <String>{
      for (final SrtBook srt in srtBooks)
        if (srt.bookKey.isNotEmpty) srt.bookKey,
    };
    final Map<String, int> percentByBookKey = <String, int>{};
    final List<LibraryCtlEntry> out = <LibraryCtlEntry>[];
    for (final MediaItem item in books) {
      final String? bookKey = ReaderFushiSource.parseBookKey(
        item.mediaIdentifier,
      );
      if (bookKey == null || bookKey.isEmpty) continue;
      final EpubBookMeta? meta = metas[bookKey];
      final int percent = libraryCtlPercent(
        position: item.position,
        duration: item.duration,
      );
      percentByBookKey[bookKey] = percent;
      final LibraryCtlKind kind = LibraryCtlKind.forBookFormat(
        BookFormat.parseOrEpub(meta?.format),
      );
      if (kind == LibraryCtlKind.book && pairedBookKeys.contains(bookKey)) {
        continue;
      }
      out.add(
        LibraryCtlEntry(
          key: LibraryCtlKey(LibraryCtlStore.book, bookKey),
          kind: kind,
          title: displayTitleForBook(item: item, rawTitle: item.title),
          rawTitle: item.title,
          author: item.author,
          percent: percent,
          completed: meta?.completedAt != null,
          importedAt: meta?.importedAt,
        ),
      );
    }
    for (final SrtBook srt in srtBooks) {
      final EpubBookMeta? meta = srt.bookKey.isEmpty
          ? null
          : metas[srt.bookKey];
      out.add(
        LibraryCtlEntry(
          key: LibraryCtlKey(LibraryCtlStore.srt, srt.uid),
          kind: LibraryCtlKind.audiobook,
          title: displayTitleForBook(
            bookKey: srt.bookKey,
            srtUid: srt.uid,
            rawTitle: srt.title,
          ),
          rawTitle: srt.title,
          author: srt.author,
          percent: srt.bookKey.isEmpty ? null : percentByBookKey[srt.bookKey],
          completed: meta?.completedAt != null,
          importedAt: srt.importedAt,
        ),
      );
    }
    out.sort(
      (LibraryCtlEntry a, LibraryCtlEntry b) =>
          (b.importedAt ?? 0).compareTo(a.importedAt ?? 0),
    );
    return out;
  }

  Future<List<LibraryCtlEntry>> _videoEntries() async {
    final List<VideoBookRow> rows = await VideoBookRepository(_db).listAll();
    final List<LibraryCtlEntry> out = <LibraryCtlEntry>[
      for (final VideoBookRow row in rows) _videoEntry(row),
    ];
    out.sort(
      (LibraryCtlEntry a, LibraryCtlEntry b) =>
          (b.importedAt ?? 0).compareTo(a.importedAt ?? 0),
    );
    return out;
  }

  LibraryCtlEntry _videoEntry(VideoBookRow row) => LibraryCtlEntry(
    key: LibraryCtlKey(LibraryCtlStore.video, row.bookUid),
    kind: LibraryCtlKind.video,
    title: row.title,
    positionMs: row.lastPositionMs,
    completed: row.completedAt != null,
    importedAt: row.importedAt,
    recentAt: row.lastPlayedAt,
  );

  Future<List<GalgameEntry>> _games() async {
    final GalgameRepository repo = _app.galgameRepo;
    if (!repo.isLoaded) await repo.load();
    return repo.games;
  }

  Future<List<LibraryCtlEntry>> _gameEntries() async => <LibraryCtlEntry>[
    for (final GalgameEntry game in await _games()) _gameEntry(game),
  ];

  LibraryCtlEntry _gameEntry(GalgameEntry game) => LibraryCtlEntry(
    key: LibraryCtlKey(LibraryCtlStore.game, game.id),
    kind: LibraryCtlKind.game,
    title: game.displayName,
    rawTitle: game.name,
    playSeconds: game.totalPlaySeconds,
    recentAt: game.lastPlayedMs > 0 ? game.lastPlayedMs : null,
  );

  Future<GalgameEntry?> _findGame(String id) async {
    for (final GalgameEntry game in await _games()) {
      if (game.id == id) return game;
    }
    return null;
  }

  Future<Object?> getItem(CtlCall call) async {
    final LibraryCtlKey key = _parseKey(call);
    switch (key.store) {
      case LibraryCtlStore.book:
        final EpubBookRow? row = await _db.getEpubBook(key.id);
        if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        final BookFormat format = BookFormat.parseOrEpub(row.format);
        final LibraryCtlKind kind = LibraryCtlKind.forBookFormat(format);
        _requireKindVisible(kind);
        final MediaItem? item = await ReaderFushiSource.instance
            .mediaItemForBookKey(key.id);
        final SrtBook? srt = await SrtBookRepository(_db).findByBookKey(key.id);
        return <String, Object?>{
          'key': key.wire,
          'kind': kind.wireName,
          'title': item == null
              ? row.title
              : displayTitleForBook(item: item, rawTitle: row.title),
          'rawTitle': row.title,
          if (row.author != null) 'author': row.author,
          'format': format.dbValue,
          if (item != null)
            'percent': libraryCtlPercent(
              position: item.position,
              duration: item.duration,
            ),
          'completed': row.completedAt != null,
          'chapterCount': row.chapterCount,
          'importedAt': row.importedAt,
          if (row.language != null) 'language': row.language,
          'extractDir': row.extractDir,
          if (row.sourceId != null) 'sourceId': row.sourceId,
          if (srt != null)
            'audiobookKey': '${LibraryCtlStore.srt.prefix}:${srt.uid}',
        };
      case LibraryCtlStore.srt:
        _requireKindVisible(LibraryCtlKind.audiobook);
        final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
        if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        return <String, Object?>{
          'key': key.wire,
          'kind': LibraryCtlKind.audiobook.wireName,
          'title': displayTitleForBook(
            bookKey: srt.bookKey,
            srtUid: srt.uid,
            rawTitle: srt.title,
          ),
          'rawTitle': srt.title,
          if (srt.author != null) 'author': srt.author,
          if (srt.bookKey.isNotEmpty)
            'bookKey': '${LibraryCtlStore.book.prefix}:${srt.bookKey}',
          'srtPath': srt.srtPath,
          if (srt.audioRoot != null) 'audioRoot': srt.audioRoot,
          'audioFiles': srt.audioPaths?.length ?? 0,
          'importedAt': srt.importedAt,
          if (srt.language != null) 'language': srt.language,
          'openable': srt.bookKey.isNotEmpty,
        };
      case LibraryCtlStore.video:
        _requireKindVisible(LibraryCtlKind.video);
        final VideoBookRow? row = await VideoBookRepository(
          _db,
        ).getByBookUid(key.id);
        if (row == null) throw CtlFailure.notFound('视频库里没有 ${key.wire}');
        return <String, Object?>{
          ..._videoEntry(row).toJson(),
          'videoPath': row.videoPath,
          if (row.subtitleSource != null) 'subtitleSource': row.subtitleSource,
          'currentEpisode': row.currentEpisode,
          'hasPlaylist': row.playlistJson != null,
          if (row.sourceId != null) 'sourceId': row.sourceId,
          if (row.language != null) 'language': row.language,
        };
      case LibraryCtlStore.game:
        _requireKindVisible(LibraryCtlKind.game);
        final GalgameEntry? game = await _findGame(key.id);
        if (game == null) throw CtlFailure.notFound('游戏库里没有 ${key.wire}');
        return <String, Object?>{
          ..._gameEntry(game).toJson(),
          'exePath': game.exePath,
          'workdir': game.workdir,
          'playStatus': game.playStatus.name,
          if (game.language != null) 'language': game.language,
          'exeExists': File(game.exePath).existsSync(),
        };
    }
  }

  // ── rm ───────────────────────────────────────────────────────────────

  /// 与各库页的单条删除同一方法、同一顺序；删除确认框的三个选项对应 body 的
  /// `everywhere` / `deleteFiles` / `deleteStatistics`（默认全不勾，与确认框一致）。
  Future<Object?> removeItem(CtlCall call) async {
    final LibraryCtlKey key = _parseKey(call);
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('删除需要 confirm: true（CLI 用 --yes）');
    }
    _requireWritable();
    final DeleteDecision decision = DeleteDecision(
      scope: call.optBool('everywhere') == true
          ? DeleteScope.syncEverywhere
          : DeleteScope.keepLocalOnly,
      deleteLocalFiles: call.optBool('deleteFiles') == true,
      deleteStatistics: call.optBool('deleteStatistics') == true,
    );
    switch (key.store) {
      case LibraryCtlStore.book:
        return _removeBook(key, decision);
      case LibraryCtlStore.srt:
        return _removeSrtBook(key, decision);
      case LibraryCtlStore.video:
        return _removeVideo(key, decision);
      case LibraryCtlStore.game:
        return _removeGame(key, decision);
    }
  }

  void _refreshShelf() {
    _context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    _context.ref.invalidate(srtBooksProvider);
  }

  /// 书架 EPUB / PDF / 漫画卡「删除」（`_confirmDeleteEpub`）。
  Future<Object?> _removeBook(
    LibraryCtlKey key,
    DeleteDecision decision,
  ) async {
    final EpubBookRow? row = await _db.getEpubBook(key.id);
    if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    _requireKindVisible(
      LibraryCtlKind.forBookFormat(BookFormat.parseOrEpub(row.format)),
    );
    if (decision.deleteLocalFiles) {
      // 先停止引用再销毁实体：正在播的就是这本时，句柄不放掉删除必然失败。
      await _app.audiobookSession.stopIfPlayingAny(<String>[key.id]);
    }
    final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
      db: _db,
      bookKey: key.id,
      scope: decision.scope,
      deleteLocalFiles: decision.deleteLocalFiles,
      deleteStatistics: decision.deleteStatistics,
    );
    if (!result.deleted) {
      throw CtlFailure.conflict('删除失败：${result.failureReason ?? '原因未知'}');
    }
    _refreshShelf();
    return _deletedJson(key, row.title, decision, result.localFiles);
  }

  /// 书架字幕书卡「删除」（`_confirmDeleteSrtBook`）。
  Future<Object?> _removeSrtBook(
    LibraryCtlKey key,
    DeleteDecision decision,
  ) async {
    _requireKindVisible(LibraryCtlKind.audiobook);
    final SrtBookRepository repo = SrtBookRepository(_db);
    final SrtBook? book = await repo.findByUid(key.id);
    if (book == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    // 纯字幕书（bookKey 空）不提供「同时删除统计数据」：它的统计只能按 title 定位，
    // 会连坐同名 EPUB（确认框同样不摆这个勾选框）。
    if (decision.deleteStatistics &&
        !ReaderFushiSource.srtBookOffersStatisticsDeletion(book)) {
      throw const CtlFailure.rejected('纯字幕书不支持连同统计一起删（会连坐同名书的统计）');
    }
    if (decision.deleteLocalFiles) {
      await _app.audiobookSession.stopIfPlayingAny(<String>[
        book.uid,
        if (book.bookKey.isNotEmpty) book.bookKey,
      ]);
    }
    LocalFileDeleteReport localFiles = const LocalFileDeleteReport();
    if (book.bookKey.isNotEmpty) {
      final DeleteBookResult result = await ReaderFushiSource.instance
          .deleteBook(
            db: _db,
            bookKey: book.bookKey,
            scope: decision.scope,
            deleteLocalFiles: decision.deleteLocalFiles,
            deleteStatistics: decision.deleteStatistics,
          );
      localFiles = localFiles.merge(result.localFiles);
    }
    final SrtBookDeleteResult srtResult = await repo.delete(
      book.uid,
      propagateDeletion: decision.scope == DeleteScope.syncEverywhere,
      deleteLocalFiles: decision.deleteLocalFiles,
    );
    localFiles = localFiles.merge(srtResult.localFiles);
    _refreshShelf();
    return _deletedJson(key, book.title, decision, localFiles);
  }

  /// 视频页单删（`_confirmDelete` → [deleteVideoBooksWithDecision]）。
  Future<Object?> _removeVideo(
    LibraryCtlKey key,
    DeleteDecision decision,
  ) async {
    _requireKindVisible(LibraryCtlKind.video);
    final VideoBookRepository repo = VideoBookRepository(_db);
    final VideoBookRow? row = await repo.getByBookUid(key.id);
    if (row == null) throw CtlFailure.notFound('视频库里没有 ${key.wire}');
    final VideoLibraryDeleteResult result;
    try {
      result = await deleteVideoBooksWithDecision(
        repo: repo,
        database: _db,
        pipeline: _app.videoDownloadPipelineService,
        bookUids: <String>[key.id],
        decision: decision,
      );
    } on StateError catch (e) {
      // 刮削资料清理占着操作闸门（视频页同一处会弹「删除失败」toast）：稍后再试。
      throw CtlFailure.conflict('删除失败：${e.message}');
    }
    if (result.deleted == 0) {
      final String reason = result.failed.isEmpty
          ? '没有删掉任何行'
          : '${result.failed.first.error}';
      throw CtlFailure.conflict('删除失败：$reason');
    }
    return _deletedJson(key, row.title, decision, result.localFiles);
  }

  /// 游戏库「移除」（`_removeGame`）：只从库移除，绝不删磁盘上的游戏文件。
  Future<Object?> _removeGame(
    LibraryCtlKey key,
    DeleteDecision decision,
  ) async {
    _requireKindVisible(LibraryCtlKind.game);
    if (decision.deleteLocalFiles) {
      throw const CtlFailure.rejected('游戏只从库里移除，不提供删除游戏文件');
    }
    final GalgameEntry? game = await _findGame(key.id);
    if (game == null) throw CtlFailure.notFound('游戏库里没有 ${key.wire}');
    if (decision.deleteStatistics) {
      // 与游戏库页同一纪律：统计删除 best-effort，失败只记日志、不拦移除。
      try {
        await _db.deleteGameStatisticsForId(game.id);
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'Ctl.library.deleteGameStatistics',
          e,
          stack,
        );
      }
    }
    await _app.galgameRepo.remove(game.id);
    return _deletedJson(
      key,
      game.displayName,
      decision,
      const LocalFileDeleteReport(),
    );
  }

  Map<String, Object?> _deletedJson(
    LibraryCtlKey key,
    String title,
    DeleteDecision decision,
    LocalFileDeleteReport localFiles,
  ) => <String, Object?>{
    'deleted': true,
    'key': key.wire,
    'title': title,
    'everywhere': decision.scope == DeleteScope.syncEverywhere,
    if (decision.deleteLocalFiles) 'removedFiles': localFiles.removed.length,
    if (localFiles.failures.isNotEmpty)
      'fileFailures': <String>[
        for (final LocalFileDeleteFailure failure in localFiles.failures)
          failure.toString(),
      ],
  };

  // ── open ─────────────────────────────────────────────────────────────

  /// 与库页点卡同一入口；不等页面关闭就返回（CLI 不该挂到用户关掉阅读器）。
  Future<Object?> openItem(CtlCall call) async {
    final LibraryCtlKey key = _parseKey(call);
    final String? at = call.optString('at');
    final NavigatorState? navigator = _context.navigator;
    if (navigator == null) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    if (_app.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态，不能打开媒体');
    }
    switch (key.store) {
      case LibraryCtlStore.book:
        return _openBook(key, key.id, at);
      case LibraryCtlStore.srt:
        _requireKindVisible(LibraryCtlKind.audiobook);
        final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
        if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        if (srt.bookKey.isEmpty) {
          // 与书架 `_openSrtBook` 同一判据：纯字幕书的 EPUB 还没生成，打不开。
          throw const CtlFailure.rejected('这本字幕书还没有生成可阅读的正文');
        }
        return _openBook(key, srt.bookKey, at);
      case LibraryCtlStore.video:
        return _openVideo(key, navigator, at);
      case LibraryCtlStore.game:
        _requireKindVisible(LibraryCtlKind.game);
        if (at != null) throw const CtlFailure.badRequest('游戏不支持 --at');
        final GalgameEntry? game = await _findGame(key.id);
        if (game == null) throw CtlFailure.notFound('游戏库里没有 ${key.wire}');
        await _context.focusMainWindow();
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (BuildContext _) =>
                  GalgameDetailPage(gameId: game.id, initialTab: 0),
            ),
          ),
        );
        return _openedJson(key, game.displayName, 'game_detail');
    }
  }

  Future<Object?> _openBook(
    LibraryCtlKey key,
    String bookKey,
    String? at,
  ) async {
    final MediaItem? item = await ReaderFushiSource.instance
        .mediaItemForBookKey(bookKey);
    if (item == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    final bool isManga =
        item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey;
    final bool isEpub =
        item.mediaSourceIdentifier == ReaderFushiSource.instance.uniqueKey;
    _requireKindVisible(
      key.store == LibraryCtlStore.srt
          ? LibraryCtlKind.audiobook
          : isManga
          ? LibraryCtlKind.manga
          : isEpub
          ? LibraryCtlKind.book
          : LibraryCtlKind.pdf,
    );
    Bookmark? jump;
    if (at != null) {
      if (!isEpub) {
        throw const CtlFailure.badRequest('--at 只支持 EPUB 书（章号）与视频（时间点）');
      }
      final int? sectionIndex = parseCtlChapterIndex(at);
      if (sectionIndex == null) {
        throw CtlFailure.badRequest('--at 对书是 1 起计的章号，收到「$at」');
      }
      // 与在线小说详情页「从某章开读」同一做法：章首书签交给阅读器。
      jump = Bookmark(
        sectionIndex: sectionIndex,
        normCharOffset: 0,
        label: '',
        createdAt: DateTime.now(),
      );
    }
    await _context.focusMainWindow();
    final String title = displayTitleForBook(item: item, rawTitle: item.title);
    if (isManga && jump == null) {
      // 书架点漫画卡先进作品页（不走 openMedia），由作品页再开阅读器。
      unawaited(
        _context.navigator!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) => MangaSeriesPage(
              target: ShelfMangaSeriesTarget(bookKey, item: item),
            ),
          ),
        ),
      );
      return _openedJson(key, title, 'manga_series');
    }
    final MediaSource source = item.getMediaSource(appModel: _app);
    unawaited(
      _app.openMedia(
        ref: _context.ref,
        mediaSource: source,
        item: item,
        waitUntilClosed: false,
        initialBookmarkJump: jump,
      ),
    );
    return _openedJson(key, title, 'reader');
  }

  Future<Object?> _openVideo(
    LibraryCtlKey key,
    NavigatorState navigator,
    String? at,
  ) async {
    _requireKindVisible(LibraryCtlKind.video);
    final VideoBookRepository repo = VideoBookRepository(_db);
    final VideoBookRow? row = await repo.getByBookUid(key.id);
    if (row == null) throw CtlFailure.notFound('视频库里没有 ${key.wire}');
    int? startMs;
    if (at != null) {
      startMs = parseCtlTimestampMs(at);
      if (startMs == null) {
        throw CtlFailure.badRequest('--at 对视频是时间点（秒 / m:ss / h:mm:ss），收到「$at」');
      }
    }
    // 与统计页打开视频同一口径：属于合集就作为合集一集打开（剧集面板 / 连播）。
    final Map<String, int> primary = await _db.getPrimaryCollectionIdByEntry();
    final int? collectionId =
        primary[MediaKind.video.compositeKey(row.bookUid)];
    await _context.focusMainWindow();
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage.neutralized(
            bookUid: row.bookUid,
            repo: repo,
            playlistCollectionId: collectionId,
            initialCueStartMs: startMs,
          ),
        ),
      ),
    );
    return _openedJson(key, row.title, 'video_player');
  }

  Map<String, Object?> _openedJson(
    LibraryCtlKey key,
    String title,
    String page,
  ) => <String, Object?>{
    'opened': true,
    'key': key.wire,
    'title': title,
    'page': page,
  };

  // ── import ───────────────────────────────────────────────────────────

  Future<Object?> importPaths(CtlCall call) async {
    _requireWritable();
    final List<String> paths = call.stringList('paths');
    if (paths.isEmpty) throw const CtlFailure.badRequest('paths 缺失');
    for (final String path in paths) {
      if (!File(path).isAbsolute) {
        throw CtlFailure.badRequest('路径必须是绝对路径：$path');
      }
    }
    final String? kindRaw = call.optString('kind');
    final LibraryCtlKind? kind = kindRaw == null
        ? null
        : LibraryCtlKind.tryParse(kindRaw);
    if (kindRaw != null && kind == null) {
      throw CtlFailure.badRequest('kind「$kindRaw」不认识');
    }
    if (kind == LibraryCtlKind.pdf) {
      throw const CtlFailure.badRequest(
        'PDF 不用指定 --kind（自动识别）；要导成漫画用 --kind manga',
      );
    }
    final String duplicate = call.optString('duplicate') ?? 'skip';
    if (duplicate != 'skip' && duplicate != 'suffix') {
      throw const CtlFailure.badRequest('duplicate 只能是 skip 或 suffix');
    }
    final LibraryCtlImporter importer = LibraryCtlImporter(
      db: _db,
      galgameRepo: _app.galgameRepo,
      isKindEnabled: _kindVisible,
      keepDuplicates: duplicate == 'suffix',
      ingestVideoFile: _context.ingestExternalVideo,
    );
    final List<LibraryCtlImportResult> results = await importer.importAll(
      paths,
      kind: kind,
    );
    _refreshShelf();
    final bool anyFailure = results.any(
      (LibraryCtlImportResult r) => r.status.isFailure,
    );
    return <String, Object?>{
      if (anyFailure) 'ok': false,
      'results': <Object?>[
        for (final LibraryCtlImportResult result in results) result.toJson(),
      ],
    };
  }

  // ── history ──────────────────────────────────────────────────────────

  /// 最近打开流：书侧读 `media_open_history`（[AppModel.openMedia] 记账的那张表），
  /// 视频侧读 `VideoBooks.lastPlayedAt`，游戏读 `lastPlayedMs`，合并倒序。
  Future<Object?> history(CtlCall call) async {
    final int limit = call.optInt('limit') ?? kLibraryCtlHistoryDefaultLimit;
    final List<LibraryCtlEntry> candidates = <LibraryCtlEntry>[];
    final bool booksVisible =
        _kindVisible(LibraryCtlKind.book) || _kindVisible(LibraryCtlKind.manga);
    if (booksVisible) {
      final List<LibraryCtlEntry> books = await _bookEntries();
      final Map<String, LibraryCtlEntry> byIdentity = <String, LibraryCtlEntry>{
        for (final LibraryCtlEntry entry in books)
          if (entry.key.store == LibraryCtlStore.book)
            ReaderFushiSource.mediaIdentifierFor(entry.key.id): entry
          else
            ReaderFushiSource.mediaIdentifierForSrtUid(entry.key.id): entry,
      };
      // 配对有声书在书架上只以字幕书出现，但打开时记账的是 EPUB 身份。
      for (final SrtBook srt in await SrtBookRepository(_db).listAll()) {
        if (srt.bookKey.isEmpty) continue;
        final LibraryCtlEntry? entry =
            byIdentity[ReaderFushiSource.mediaIdentifierForSrtUid(srt.uid)];
        if (entry != null) {
          byIdentity[ReaderFushiSource.mediaIdentifierFor(srt.bookKey)] = entry;
        }
      }
      for (final MediaOpenHistoryRow row
          in await _db.getAllMediaOpenHistory()) {
        final LibraryCtlEntry? entry = byIdentity[row.mediaId];
        if (entry == null || !_kindVisible(entry.kind)) continue;
        candidates.add(entry.withRecentAt(row.openedAt));
      }
    }
    if (_kindVisible(LibraryCtlKind.video)) {
      candidates.addAll(await _videoEntries());
    }
    if (_kindVisible(LibraryCtlKind.game)) {
      candidates.addAll(await _gameEntries());
    }
    final List<LibraryCtlEntry> merged = mergeLibraryCtlHistory(
      candidates,
      limit: limit,
    );
    return <String, Object?>{
      'items': <Object?>[
        for (final LibraryCtlEntry entry in merged) entry.toJson(),
      ],
    };
  }

  // ── sources / scan ───────────────────────────────────────────────────

  /// 来源库种类（`MediaSources.mediaKind`）→ 可见性模块。
  bool _sourceKindVisible(String mediaKind) =>
      switch (SourceLibraryKind.tryParse(mediaKind)) {
        SourceLibraryKind.book => _kindVisible(LibraryCtlKind.book),
        SourceLibraryKind.video => _kindVisible(LibraryCtlKind.video),
        SourceLibraryKind.manga => _kindVisible(LibraryCtlKind.manga),
        null => false,
      };

  Future<List<MediaSourceRow>> _sources(CtlCall call) async {
    final String? kind = call.optString('kind');
    if (kind != null && SourceLibraryKind.tryParse(kind) == null) {
      throw CtlFailure.badRequest('来源种类只能是 book / video / manga，收到「$kind」');
    }
    final List<MediaSourceRow> rows = kind == null
        ? await _db.getAllMediaSources()
        : await _db.getMediaSourcesByKind(kind);
    return rows
        .where((MediaSourceRow r) => _sourceKindVisible(r.mediaKind))
        .toList(growable: false);
  }

  Map<String, Object?> _sourceJson(MediaSourceRow row) => <String, Object?>{
    'id': row.id,
    'label': row.label,
    'kind': row.mediaKind,
    'transport': row.transport,
    'path': row.rootPath,
    'mediaCount': row.mediaCount,
    if (row.lastScannedAt != null)
      'lastScannedAt': row.lastScannedAt!.millisecondsSinceEpoch,
    if (row.lastScanError != null) 'lastScanError': row.lastScanError,
  };

  Future<Object?> listSources(CtlCall call) async => <String, Object?>{
    'sources': <Object?>[
      for (final MediaSourceRow row in await _sources(call)) _sourceJson(row),
    ],
  };

  /// 来源页「重新扫描」同一方法：逐个来源 [SourceLibraryScanner.scan]（它自己吞
  /// 异常并写回 lastScanError）。视频来源扫完**不会**自动刮削——那条编排挂在首页
  /// 的刮削任务控制器上，控制通道拿不到。
  Future<Object?> scan(CtlCall call) async {
    _requireWritable();
    final int? sourceId = call.optInt('source');
    List<MediaSourceRow> targets = await _sources(call);
    if (sourceId != null) {
      targets = targets
          .where((MediaSourceRow r) => r.id == sourceId)
          .toList(growable: false);
      if (targets.isEmpty) {
        throw CtlFailure.notFound('没有 id=$sourceId 的来源（或其模块已关闭）');
      }
    }
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    for (final MediaSourceRow row in targets) {
      final SourceScanSummary summary = await SourceLibraryScanner(
        _db,
      ).scan(row);
      results.add(<String, Object?>{
        'id': row.id,
        'label': row.label,
        'kind': row.mediaKind,
        'path': row.rootPath,
        'ok': summary.succeeded,
        'discovered': summary.discoveredPaths.length,
        'imported': summary.importedMediaCount,
        if (summary.createdVideoUids.isNotEmpty)
          'createdVideos': summary.createdVideoUids.length,
        if (summary.error != null) 'error': summary.error,
      });
    }
    _refreshShelf();
    return <String, Object?>{
      if (results.any((Map<String, Object?> r) => r['ok'] == false))
        'ok': false,
      'results': results,
    };
  }
}

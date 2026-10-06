/// `fushi_cli library import` 的执行层：把本机路径分派给 app **已有**的导入原语，
/// 全程不弹交互框（重复处置只有 [DuplicatePolicy.skip] / [DuplicatePolicy.suffix]）。
///
/// 分类复用拖放与导入对话框的两道判据，不自造扩展名表：
/// 1. [classifyDroppedFiles]（拖放落点同一份）先把视频 / 字幕 / 音频 / 词典包 / 种子
///    这些「不是书也不是漫画」的东西筛出去——否则下一道的文本兜底会把 `.mp3`
///    当纯文本转成 EPUB；
/// 2. [classifyImportCarrier]（导入对话框同一份）定书 / PDF / 文本 / 漫画载体。
///
/// 落地方法与对话框逐一对应：EPUB → [EpubImporter.importFromPath]、文本 →
/// [TextToEpub.convert] + [EpubImporter.import]、PDF → [PdfImporter.importFromPath]、
/// 漫画 → [MangaModule]、有声书 → [importDiscoveryAudiobook]（发现页自动入库同一份
/// 对齐管线）、游戏 → [filterOutDuplicateGameExes] + [GalgameRepository.addAll]、
/// 视频 / 书目录 → [addLocalFolderAsSource]（拖目录进视频页同一函数）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/video/external_video.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_entries.dart';

/// 宿主没提供外部视频入库入口时（测试夹具）的提示；播放列表（m3u8）同样走这里。
const String kLibraryCtlVideoFileHint =
    '视频文件请用 `fushi_cli open <文件>`（外部打开：入库并播放），'
    '或把所在目录用 `library import <目录> --kind video` 登记成来源';

class LibraryCtlImporter {
  LibraryCtlImporter({
    required FushiDatabase db,
    required GalgameRepository galgameRepo,
    required bool Function(LibraryCtlKind kind) isKindEnabled,
    required bool keepDuplicates,
    Future<String?> Function(String path)? ingestVideoFile,
  }) : _ingestVideoFile = ingestVideoFile,
       _db = db,
       _galgameRepo = galgameRepo,
       _isKindEnabled = isKindEnabled,
       _policy = keepDuplicates
           ? const DuplicatePolicy.suffix()
           : const DuplicatePolicy.skip();

  final FushiDatabase _db;
  final GalgameRepository _galgameRepo;
  final bool Function(LibraryCtlKind kind) _isKindEnabled;
  final DuplicatePolicy _policy;
  final Future<String?> Function(String path)? _ingestVideoFile;

  /// 视频单文件：走外部打开同一个入库入口（按路径去重，同一文件重复导入复用旧条目）。
  Future<LibraryCtlImportResult> _importVideoFile(String path) async {
    final LibraryCtlImportResult? gated = _moduleGate(
      path,
      LibraryCtlKind.video,
    );
    if (gated != null) return gated;
    final Future<String?> Function(String path)? ingest = _ingestVideoFile;
    if (ingest == null || !isSupportedVideoFile(path)) {
      return _unsupported(
        path,
        kLibraryCtlVideoFileHint,
        kind: LibraryCtlKind.video,
      );
    }
    final String? bookUid = await ingest(path);
    if (bookUid == null) {
      return LibraryCtlImportResult(
        path: path,
        status: LibraryCtlImportStatus.failed,
        kind: LibraryCtlKind.video,
        message: '视频入库失败（原因见 app 内提示）',
      );
    }
    return LibraryCtlImportResult(
      path: path,
      status: LibraryCtlImportStatus.imported,
      kind: LibraryCtlKind.video,
      keys: <String>[LibraryCtlKey(LibraryCtlStore.video, bookUid).wire],
    );
  }

  /// 逐个路径导入。`--kind audiobook` 时全部路径（目录递归展开）合起来是**一本**
  /// 有声书的素材（正文 + 字幕 + 音频）。
  Future<List<LibraryCtlImportResult>> importAll(
    List<String> paths, {
    LibraryCtlKind? kind,
  }) async {
    if (kind == LibraryCtlKind.audiobook) {
      return <LibraryCtlImportResult>[await _importAudiobook(paths)];
    }
    final List<LibraryCtlImportResult> results = <LibraryCtlImportResult>[];
    for (final String path in paths) {
      try {
        results.add(await _importOne(path, kind));
      } on DuplicateImportCancelledException {
        results.add(
          LibraryCtlImportResult(
            path: path,
            status: LibraryCtlImportStatus.skipped,
            message: '同名条目已在库',
          ),
        );
      } catch (e) {
        results.add(
          LibraryCtlImportResult(
            path: path,
            status: LibraryCtlImportStatus.failed,
            kind: kind,
            message: '$e',
          ),
        );
      }
    }
    return results;
  }

  LibraryCtlImportResult _unsupported(
    String path,
    String message, {
    LibraryCtlKind? kind,
  }) => LibraryCtlImportResult(
    path: path,
    status: LibraryCtlImportStatus.unsupported,
    kind: kind,
    message: message,
  );

  /// 模块关着就不入库（导进一个用户看不见的库比报错更糟）。
  LibraryCtlImportResult? _moduleGate(String path, LibraryCtlKind kind) {
    if (_isKindEnabled(kind)) return null;
    return _unsupported(
      path,
      '「${kind.wireName}」所属模块已在设置里关闭（${kind.module.name}）',
      kind: kind,
    );
  }

  Future<LibraryCtlImportResult> _importOne(
    String path,
    LibraryCtlKind? kind,
  ) async {
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      return LibraryCtlImportResult(
        path: path,
        status: LibraryCtlImportStatus.failed,
        kind: kind,
        message: '路径不存在',
      );
    }
    final bool isDirectory = type == FileSystemEntityType.directory;
    switch (kind) {
      case LibraryCtlKind.video:
        if (!isDirectory) return _importVideoFile(path);
        return _addSource(path, LibraryCtlKind.video, SourceLibraryKind.video);
      case LibraryCtlKind.game:
        return _importGame(path, isDirectory: isDirectory);
      case LibraryCtlKind.book:
        if (isDirectory) {
          return _addSource(path, LibraryCtlKind.book, SourceLibraryKind.book);
        }
        return _importBookLike(path);
      case LibraryCtlKind.manga:
        return _importMangaCarrier(path, _carrierOf(path), allowPdf: true);
      case LibraryCtlKind.pdf:
      case LibraryCtlKind.audiobook:
      case null:
        break;
    }
    if (isDirectory) {
      // 与书架 / 漫画库拖目录同义：目录 = 一卷（或一批卷）漫画。
      return _importMangaCarrier(path, _carrierOf(path), allowPdf: false);
    }
    if (p.extension(path).toLowerCase() == '.exe') {
      return _importGame(path, isDirectory: false);
    }
    return _importBookLike(path);
  }

  ImportCarrier _carrierOf(String path) => classifyImportCarrier(
    path,
    isDirectory: (String candidate) => Directory(candidate).existsSync(),
    isImageArchive: MangaModule.isImageArchive,
    directoryHasPageImages: MangaModule.directoryHasPageImages,
    directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
    directoryMokuroFileCount: MangaModule.directoryMokuroFileCount,
  );

  /// 单个文件、没指定（或指定 book）种类：先过拖放分类筛掉非书非漫画的东西，
  /// 再按载体身份落到书或漫画。
  Future<LibraryCtlImportResult> _importBookLike(String path) async {
    final DroppedFiles dropped = classifyDroppedFiles(<String>[
      path,
    ], isImageArchive: MangaModule.isImageArchive);
    if (dropped.mangas.isNotEmpty) {
      return _importMangaCarrier(path, _carrierOf(path), allowPdf: false);
    }
    if (dropped.books.isNotEmpty) {
      final ImportCarrier carrier = _carrierOf(path);
      if (carrier.isManga) {
        // 图片型 EPUB / zip：对话框同样把它转交漫画流程。
        return _importMangaCarrier(path, carrier, allowPdf: false);
      }
      return _importBookCarrier(path, carrier);
    }
    if (dropped.torrents.isNotEmpty) {
      return _unsupported(path, '种子文件请交给下载中心（不在 library 域）');
    }
    if (dropped.videos.isNotEmpty) return _importVideoFile(path);
    if (dropped.playlists.isNotEmpty) {
      return _unsupported(
        path,
        kLibraryCtlVideoFileHint,
        kind: LibraryCtlKind.video,
      );
    }
    if (dropped.subtitles.isNotEmpty || dropped.audios.isNotEmpty) {
      return _unsupported(
        path,
        '字幕 / 音频要和正文一起导成有声书：'
        '`library import <正文> <字幕> <音频…> --kind audiobook`',
        kind: LibraryCtlKind.audiobook,
      );
    }
    if (dropped.dictionaries.isNotEmpty) {
      return _unsupported(path, '词典包请用 dictionary 命令导入');
    }
    return _unsupported(path, '不认识的文件类型（${p.extension(path)}）');
  }

  /// 书籍侧三种载体（导入对话框 `_importEpubOnly` 同一分派）。
  Future<LibraryCtlImportResult> _importBookCarrier(
    String path,
    ImportCarrier carrier,
  ) async {
    final LibraryCtlKind kind = carrier == ImportCarrier.pdf
        ? LibraryCtlKind.pdf
        : LibraryCtlKind.book;
    final LibraryCtlImportResult? gated = _moduleGate(path, kind);
    if (gated != null) return gated;
    final String fileName = p.basename(path);
    final String title = p.basenameWithoutExtension(path);
    final String bookKey;
    switch (carrier) {
      case ImportCarrier.pdf:
        bookKey = await PdfImporter.importFromPath(
          db: _db,
          filePath: path,
          fileName: fileName,
          title: title,
          policy: _policy,
        );
      case ImportCarrier.text:
        final Uint8List bytes = await TextToEpub.convert(
          file: File(path),
          title: title,
        );
        bookKey = await EpubImporter.import(
          db: _db,
          bytes: bytes,
          fileName: '$title.epub',
          policy: _policy,
        );
      case ImportCarrier.epub:
        bookKey = await EpubImporter.importFromPath(
          db: _db,
          filePath: path,
          fileName: fileName,
          policy: _policy,
        );
      case ImportCarrier.mangaFolder:
      case ImportCarrier.mangaBatchFolder:
      case ImportCarrier.mangaMokuro:
      case ImportCarrier.mangaArchive:
        return _importMangaCarrier(path, carrier, allowPdf: false);
    }
    return _imported(path, kind, bookKey);
  }

  LibraryCtlImportResult _imported(
    String path,
    LibraryCtlKind kind,
    String bookKey,
  ) => LibraryCtlImportResult(
    path: path,
    status: LibraryCtlImportStatus.imported,
    kind: kind,
    keys: <String>[LibraryCtlKey(LibraryCtlStore.book, bookKey).wire],
  );

  /// 漫画四种载体（+ `--kind manga` 时 PDF 转漫画），走 [MangaModule] 门面。
  Future<LibraryCtlImportResult> _importMangaCarrier(
    String path,
    ImportCarrier carrier, {
    required bool allowPdf,
  }) async {
    final LibraryCtlImportResult? gated = _moduleGate(
      path,
      LibraryCtlKind.manga,
    );
    if (gated != null) return gated;
    switch (carrier) {
      case ImportCarrier.mangaFolder:
        return _imported(
          path,
          LibraryCtlKind.manga,
          await MangaModule.importImageFolder(
            db: _db,
            path: path,
            policy: _policy,
          ),
        );
      case ImportCarrier.mangaMokuro:
        final String? mokuro = Directory(path).existsSync()
            ? MangaModule.directorySingleMokuroPath(path)
            : path;
        if (mokuro == null) {
          return _unsupported(
            path,
            '目录里找不到唯一的 .mokuro',
            kind: LibraryCtlKind.manga,
          );
        }
        return _imported(
          path,
          LibraryCtlKind.manga,
          await MangaModule.importMokuro(
            db: _db,
            path: mokuro,
            policy: _policy,
          ),
        );
      case ImportCarrier.mangaArchive:
        return _imported(
          path,
          LibraryCtlKind.manga,
          await MangaModule.importArchive(db: _db, path: path, policy: _policy),
        );
      case ImportCarrier.mangaBatchFolder:
        return _batchResult(
          path,
          await MangaModule.importBatchFolder(db: _db, path: path),
        );
      case ImportCarrier.pdf:
        if (!allowPdf) {
          return _importBookCarrier(path, carrier);
        }
        return _imported(
          path,
          LibraryCtlKind.manga,
          await MangaModule.importPdfAsManga(
            db: _db,
            path: path,
            title: p.basenameWithoutExtension(path),
            policy: _policy,
          ),
        );
      case ImportCarrier.epub:
      case ImportCarrier.text:
        return _unsupported(
          path,
          '不是漫画载体（页图目录 / .mokuro / 图片压缩包 / PDF）',
          kind: LibraryCtlKind.manga,
        );
    }
  }

  /// 整卷文件目录逐卷导入（批量入口自身就是 skip 语义：同名卷记 duplicate）。
  LibraryCtlImportResult _batchResult(
    String path,
    MangaBatchImportReport report,
  ) {
    final String summary =
        '新增 ${report.importedCount} 卷，已在库 ${report.duplicateCount} 卷，'
        '非漫画 ${report.notMangaCount} 个，失败 ${report.failedCount} 个';
    final LibraryCtlImportStatus status = report.importedCount > 0
        ? LibraryCtlImportStatus.imported
        : report.failedCount > 0
        ? LibraryCtlImportStatus.failed
        : LibraryCtlImportStatus.skipped;
    return LibraryCtlImportResult(
      path: path,
      status: status,
      kind: LibraryCtlKind.manga,
      message: summary,
    );
  }

  Future<LibraryCtlImportResult> _addSource(
    String path,
    LibraryCtlKind kind,
    SourceLibraryKind sourceKind,
  ) async {
    final LibraryCtlImportResult? gated = _moduleGate(path, kind);
    if (gated != null) return gated;
    final AddLocalFolderResult result = await addLocalFolderAsSource(
      db: _db,
      mediaKind: sourceKind.dbValue,
      path: path,
    );
    final bool added = result.outcome == AddLocalFolderOutcome.added;
    return LibraryCtlImportResult(
      path: path,
      status: added
          ? LibraryCtlImportStatus.sourceAdded
          : LibraryCtlImportStatus.sourceExists,
      kind: kind,
      message: added
          ? '已登记为来源（id=${result.sourceId}）并扫描：${result.rootPath}'
          : '已是来源库：${result.rootPath}（要重扫用 library scan）',
    );
  }

  /// 游戏：单个 exe 直接登记；目录按发现页同一启发式挑主程序。
  Future<LibraryCtlImportResult> _importGame(
    String path, {
    required bool isDirectory,
  }) async {
    final LibraryCtlImportResult? gated = _moduleGate(
      path,
      LibraryCtlKind.game,
    );
    if (gated != null) return gated;
    final List<String> exes;
    if (isDirectory) {
      final List<String> files = <String>[];
      final Map<String, int> sizes = <String, int>{};
      for (final FileSystemEntity entity in Directory(
        path,
      ).listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          files.add(entity.path);
          sizes[entity.path] = entity.lengthSync();
        }
      }
      final DiscoveryImportPlan plan = classifyDiscoveryDirectory(
        DiscoveryMediaKind.game,
        files,
        fileSizes: sizes,
      );
      if (plan is! RegisterGameExesPlan) {
        return _unsupported(
          path,
          '目录里找不到游戏主程序（.exe）',
          kind: LibraryCtlKind.game,
        );
      }
      exes = plan.exePaths;
    } else {
      if (p.extension(path).toLowerCase() != '.exe') {
        return _unsupported(path, '游戏只认 .exe 或游戏目录', kind: LibraryCtlKind.game);
      }
      exes = <String>[path];
    }
    if (!_galgameRepo.isLoaded) await _galgameRepo.load();
    final List<String> fresh = filterOutDuplicateGameExes(
      _galgameRepo.games,
      exes,
    );
    if (fresh.isEmpty) {
      return LibraryCtlImportResult(
        path: path,
        status: LibraryCtlImportStatus.skipped,
        kind: LibraryCtlKind.game,
        message: '这个游戏已在库',
      );
    }
    final DateTime base = DateTime.now();
    // 批内 id 用微秒错开，防同微秒撞 id（同游戏库拖拽入库 / 发现页登记）。
    final List<GalgameEntry> entries = <GalgameEntry>[
      for (int i = 0; i < fresh.length; i++)
        newGalgameEntryFromExe(
          fresh[i],
          now: base.add(Duration(microseconds: i)),
        ),
    ];
    await _galgameRepo.addAll(entries);
    return LibraryCtlImportResult(
      path: path,
      status: LibraryCtlImportStatus.imported,
      kind: LibraryCtlKind.game,
      keys: <String>[
        for (final GalgameEntry entry in entries)
          LibraryCtlKey(LibraryCtlStore.game, entry.id).wire,
      ],
    );
  }

  /// 有声书：全部路径（目录递归展开）= 一本书的素材，按发现页同一分类挑正文 /
  /// 字幕 / 音频，再走同一条对齐入库管线。正文同名已在库时不自动附着音频（有损
  /// 操作，交互入口是有声书导入对话框）。
  Future<LibraryCtlImportResult> _importAudiobook(List<String> paths) async {
    final String label = paths.join(' ');
    final LibraryCtlImportResult? gated = _moduleGate(
      label,
      LibraryCtlKind.audiobook,
    );
    if (gated != null) return gated;
    final List<String> files = <String>[];
    for (final String path in paths) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) {
        return LibraryCtlImportResult(
          path: path,
          status: LibraryCtlImportStatus.failed,
          kind: LibraryCtlKind.audiobook,
          message: '路径不存在',
        );
      }
      if (type == FileSystemEntityType.directory) {
        for (final FileSystemEntity entity in Directory(
          path,
        ).listSync(recursive: true, followLinks: false)) {
          if (entity is File) files.add(entity.path);
        }
      } else {
        files.add(path);
      }
    }
    final DiscoveryImportPlan plan = classifyDiscoveryDirectory(
      DiscoveryMediaKind.audiobook,
      files,
    );
    final Future<String?> Function()? run = _audiobookRunner(plan);
    if (run == null) {
      return _unsupported(
        label,
        libraryCtlBlockerMessage(_audiobookBlocker(plan)),
        kind: LibraryCtlKind.audiobook,
      );
    }
    try {
      final String? bookKey = await run();
      if (bookKey == null) {
        return LibraryCtlImportResult(
          path: label,
          status: LibraryCtlImportStatus.skipped,
          kind: LibraryCtlKind.audiobook,
          message: '同名条目已在库',
        );
      }
      // 独立字幕书的正文 EPUB 生成失败时导入器回的是 SrtBook.uid（bookKey 为空）。
      final SrtBookRepository srtRepo = SrtBookRepository(_db);
      final SrtBook? srt =
          await srtRepo.findByBookKey(bookKey) ??
          await srtRepo.findByUid(bookKey);
      return LibraryCtlImportResult(
        path: label,
        status: LibraryCtlImportStatus.imported,
        kind: LibraryCtlKind.audiobook,
        keys: <String>[
          if (srt != null)
            LibraryCtlKey(LibraryCtlStore.srt, srt.uid).wire
          else
            LibraryCtlKey(LibraryCtlStore.book, bookKey).wire,
        ],
      );
    } on DiscoveryImportBlockedException catch (e) {
      return LibraryCtlImportResult(
        path: label,
        status:
            e.blocker == DiscoveryImportBlocker.audiobookBookAlreadyInLibrary
            ? LibraryCtlImportStatus.skipped
            : LibraryCtlImportStatus.failed,
        kind: LibraryCtlKind.audiobook,
        message: libraryCtlBlockerMessage(e.blocker),
      );
    } catch (e) {
      return LibraryCtlImportResult(
        path: label,
        status: LibraryCtlImportStatus.failed,
        kind: LibraryCtlKind.audiobook,
        message: '$e',
      );
    }
  }

  /// 有声书分类结果 → 入库动作；null = 本入口不执行（原因见 [_audiobookBlocker]）。
  ///
  /// 与发现页自动入库同一分类、同一组引擎导入器：有正文走对齐，只有字幕 + 音频
  /// 成独立字幕书。只有音频（[TranscribeAudiobookPlan]）不在这里转录——那要几个
  /// 小时，CLI 同步等不了；与无头服务端一样以「缺字幕」挡下。
  Future<String?> Function()? _audiobookRunner(DiscoveryImportPlan plan) =>
      switch (plan) {
        AlignAudiobookPlan() => () => importDiscoveryAudiobook(
          db: _db,
          srtBookRepo: SrtBookRepository(_db),
          audiobookRepo: AudiobookRepository(_db),
          plan: plan,
        ),
        SubtitleAudiobookPlan() => () => importDiscoverySubtitleAudiobook(
          db: _db,
          srtBookRepo: SrtBookRepository(_db),
          plan: plan,
        ),
        _ => null,
      };

  static DiscoveryImportBlocker _audiobookBlocker(DiscoveryImportPlan plan) =>
      switch (plan) {
        UnsupportedPlan(:final DiscoveryImportBlocker blocker) => blocker,
        TranscribeAudiobookPlan() =>
          DiscoveryImportBlocker.audiobookMissingSubtitle,
        _ => DiscoveryImportBlocker.unknownFileType,
      };
}

/// 发现页导入阻断码 → 命令行文案。
String libraryCtlBlockerMessage(DiscoveryImportBlocker blocker) =>
    switch (blocker) {
      DiscoveryImportBlocker.unknownFileType => '认不出文件类型',
      DiscoveryImportBlocker.audiobookMissingText => '缺正文（EPUB 或文本）',
      DiscoveryImportBlocker.audiobookMissingSubtitle =>
        '缺字幕（.srt/.lrc/.vtt/.ass/.ssa）',
      DiscoveryImportBlocker.audiobookMissingAudio => '缺音频文件',
      DiscoveryImportBlocker.audiobookBookAlreadyInLibrary =>
        '同名正文已在库，不自动附着音频；请在书架该书的菜单里导入有声书',
      DiscoveryImportBlocker.gameNoExecutable => '找不到游戏主程序',
      DiscoveryImportBlocker.archiveToolMissing => '解压需要 7-Zip 命令行',
      DiscoveryImportBlocker.archiveExtractionFailed => '解压失败',
      DiscoveryImportBlocker.unsupportedOnThisHost => '本机不支持这种导入',
    };

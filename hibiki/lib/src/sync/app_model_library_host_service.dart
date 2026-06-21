import 'dart:io';

import 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:hibiki/src/media/video/video_subtitle_source.dart'
    show
        EmbeddedSubtitleTrack,
        listEmbeddedSubtitleTracks,
        subtitleFormatForCodec;
import 'package:hibiki/src/media/video/video_sidecar.dart'
    show findSidecarSubtitle;
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_manager.dart'
    show repackageExtractedEpub, resolveExtractedEpubRoot;
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 用真实 Hibiki 库（Drift DB + [SyncAssetPackageService]）实现 host 库服务。
///
/// 库变动经注入的 [runExclusive] 串行（生产传 `runExclusiveWithSync`），
/// 并经 [refreshDictionaryCache] 刷新内存词典缓存。
/// 抽象不直接依赖 AppModel，便于测试用内存 DB 注入。
///
/// ## 构造参数说明
///
/// | 参数 | 用途 | 生产传值 |
/// |---|---|---|
/// | [importBookFromFile] | 把 .epub 导入书库的真实逻辑 | `EpubImporter.importFromPath` |
/// | [cleanupBookOnDisk] | deleteBook 时清理 DB 行以外的磁盘资源（Audiobook persist dir 等） | `ReaderHibikiSource.instance.deleteBook` 磁盘部分 |
/// | [localAudioEntries] | 当前已注册的本地音频来源列表（T3.1）| `AppModel.localAudioEntries` |
/// | [localAudioStagingDir] | importLocalAudio 解包用临时目录（T3.1）| `Directory.systemTemp` 或应用 temp |
/// | [onLocalAudioImported] | 注册已解包的本地音频包（T3.1）| `AppModel.importSyncedLocalAudioDb` |
/// | [audioDatabaseRoot] | importAudiobook 音频文件落盘根目录（T3.1）| AppModel 的 audiobook root |
/// | [videoSubtitleLangCode] | 视频 sidecar 字幕匹配语言代码（P4-1）| AppModel 目标学习语言 |
///
/// T2/T3 后续接线任务会在 AppModel 初始化时传入真实值。
class AppModelLibraryHostService implements HibikiLibraryHostService {
  AppModelLibraryHostService({
    required HibikiDatabase db,
    required Directory dictionaryResourceRoot,
    required SyncAssetPackageService packages,
    required Future<void> Function() refreshDictionaryCache,
    required Future<void> Function(Future<void> Function() body) runExclusive,
    Future<void> Function(File epubFile)? importBookFromFile,
    Future<void> Function(EpubBookRow row)? cleanupBookOnDisk,
    List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
    Directory? localAudioStagingDir,
    Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
    Directory? audioDatabaseRoot,
    Future<void> Function(String displayName)? removeLocalAudioEntry,
    String videoSubtitleLangCode = 'ja',
  })  : _db = db,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _packages = packages,
        _refreshDictionaryCache = refreshDictionaryCache,
        _runExclusive = runExclusive,
        _importBookFromFile = importBookFromFile,
        _cleanupBookOnDisk = cleanupBookOnDisk,
        _localAudioEntries = localAudioEntries,
        _localAudioStagingDir = localAudioStagingDir,
        _onLocalAudioImported = onLocalAudioImported,
        _audioDatabaseRoot = audioDatabaseRoot,
        _removeLocalAudioEntry = removeLocalAudioEntry,
        _videoSubtitleLangCode = videoSubtitleLangCode;

  final HibikiDatabase _db;
  final Directory _dictionaryResourceRoot;
  final SyncAssetPackageService _packages;
  final Future<void> Function() _refreshDictionaryCache;
  final Future<void> Function(Future<void> Function() body) _runExclusive;

  /// 书籍导入回调（可选；null 时 importBook 抛 [UnsupportedError]）。
  /// 生产传 `(f) => EpubImporter.importFromPath(db: db, filePath: f.path, fileName: p.basename(f.path))`。
  final Future<void> Function(File epubFile)? _importBookFromFile;

  /// 书籍磁盘清理回调（可选；null 时只执行 DB 删除，跳过 AudiobookStorage/SrtBook 清理）。
  /// 生产传 ReaderHibikiSource 实例的磁盘清理部分。
  final Future<void> Function(EpubBookRow row)? _cleanupBookOnDisk;

  // ── 本地音频（T3.1）──────────────────────────────────────────────────────

  /// 当前已注册的本地音频来源列表。生产传 AppModel.localAudioEntries。
  final List<LocalAudioDbEntry> _localAudioEntries;

  /// importLocalAudio 解包用临时目录。null 时用 Directory.systemTemp。
  final Directory? _localAudioStagingDir;

  /// 本地音频包解包后的注册回调（可选；null 时 importLocalAudio 抛 [UnsupportedError]）。
  /// 生产传 AppModel.importSyncedLocalAudioDb。
  final Future<void> Function(LocalAudioPackageContents)? _onLocalAudioImported;

  // ── 有声书（T3.1）────────────────────────────────────────────────────────

  /// importAudiobook 音频文件落盘根目录（可选；null 时 importAudiobook 抛 [UnsupportedError]）。
  /// 生产传 AppModel 的 audioDatabaseRoot。
  final Directory? _audioDatabaseRoot;

  /// deleteLocalAudio 回调（可选；null 时 deleteLocalAudio 仅做名称校验，静默跳过删除）。
  /// 生产传按 displayName 从 LocalAudioManager 移除条目的回调（T3.4 接线）。
  final Future<void> Function(String displayName)? _removeLocalAudioEntry;

  // ── 视频（P4-1）──────────────────────────────────────────────────────────────

  /// 视频 sidecar 字幕匹配的目标语言代码（默认 'ja'）。
  /// 生产传 AppModel.targetLanguage.langCode（P4 接线任务完成后注入真实值）。
  final String _videoSubtitleLangCode;

  static const String _dictionaryAssetSuffix = '.hibikidict';

  /// 校验词典名称不含路径穿越字符。
  ///
  /// 名称为空、或含 `/`、`\`、`..` 时抛 [ArgumentError]，
  /// 确保服务层自身也防御路径穿越，不依赖上层端点网关的单点防护。
  static void _assertSafeName(String name) {
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('..')) {
      throw ArgumentError.value(name, 'name', 'unsafe dictionary name');
    }
  }

  static EpubBookRow? _findBookByTitleOrKey(
    List<EpubBookRow> rows,
    String titleOrBookKey,
  ) =>
      rows.cast<EpubBookRow?>().firstWhere(
            (EpubBookRow? r) =>
                r!.bookKey == titleOrBookKey || r.title == titleOrBookKey,
            orElse: () => null,
          );

  static String? _existingFilePath(String? path) {
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  /// host 当前实时词典清单（从 DictionaryMeta 表读）。
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async {
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    return <RemoteDictionaryInfo>[
      for (final DictionaryMetaRow r in rows)
        RemoteDictionaryInfo(name: r.name, type: r.type),
    ];
  }

  /// 即时把名为 [name] 的实时词典打包成临时 .hibikidict 文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  /// 名称含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<File> exportDictionary(String name) async {
    _assertSafeName(name);
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    final bool exists = rows.any((DictionaryMetaRow r) => r.name == name);
    if (!exists) throw StateError('dictionary not found: $name');

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_dict_export');
    final File out = File(p.join(tmpDir.path, '$name$_dictionaryAssetSuffix'));
    await _packages.exportDictionaryPackage(
      dictionaryName: name,
      dictionaryResourceRoot: _dictionaryResourceRoot,
      outputFile: out,
    );
    return out;
  }

  /// 把 [packageFile]（.hibikidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  @override
  Future<void> importDictionary(File packageFile) async {
    await _runExclusive(() async {
      await _packages.importDictionaryPackage(
        packageFile: packageFile,
        dictionaryResourceRoot: _dictionaryResourceRoot,
      );
      await _refreshDictionaryCache();
    });
  }

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  /// 名称含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteDictionary(String name) async {
    _assertSafeName(name);
    await _runExclusive(() async {
      await _db.deleteDictionaryMeta(name);
      final Directory dir =
          Directory(p.join(_dictionaryResourceRoot.path, name));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      await _refreshDictionaryCache();
    });
  }

  // ── 书籍 ─────────────────────────────────────────────────────────────────

  /// host 当前书库清单（从 EpubBooks 表读）。
  /// [RemoteBookInfo.hasContent] 为 true 当且仅当该书存在可导出的 EPUB 根目录。
  @override
  Future<List<RemoteBookInfo>> listBooks() async {
    final List<EpubBookRow> rows = await _db.getAllEpubBooks();
    // 该书是否已配有声书：bookKey 出现在 Audiobooks 表（与本地书卡
    // `_getAudiobookInfo` / `AudiobookRepository.buildBookKeyMap` 同源，TODO-655a）。
    final Set<String> audiobookKeys = <String>{
      for (final AudiobookRow a in await _db.getAllAudiobooks()) a.bookKey,
    };
    return rows.map((EpubBookRow r) {
      // EPUB 行的 coverPath 是 EPUB 内部相对 href，必须拼 extractDir 才是磁盘真
      // 路径；直接 _existingFilePath(相对href) 恒 false → 远端书卡没封面（#4）。
      final String? coverPath = resolveEpubCoverFilePath(
        extractDir: r.extractDir,
        coverPath: r.coverPath,
      );
      return RemoteBookInfo(
        title: r.title,
        bookKey: r.bookKey,
        hasContent: resolveExtractedEpubRoot(r.extractDir) != null,
        hasCover: coverPath != null,
        coverPath: coverPath,
        hasAudiobook: audiobookKeys.contains(r.bookKey),
      );
    }).toList();
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
    if (resolveExtractedEpubRoot(row.extractDir) == null) {
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
  @override
  Future<void> importBook(File epubFile) async {
    final Future<void> Function(File)? importer = _importBookFromFile;
    if (importer == null) {
      throw UnsupportedError(
        'importBook requires importBookFromFile callback to be provided',
      );
    }
    await _runExclusive(() => importer(epubFile));
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
      await _db.deleteEpubBook(row.bookKey);

      // extractDir 磁盘目录：DB 删除后再清理（与 reader_hibiki_source 同顺序）。
      if (row.extractDir.isNotEmpty) {
        final Directory dir = Directory(row.extractDir);
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });
  }

  // ── 本地音频（T3.1）────────────────────────────────────────────────────────

  /// host 当前本地音频来源清单（从注入的 [_localAudioEntries] 取 displayName）。
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async {
    return <RemoteLocalAudioInfo>[
      for (final LocalAudioDbEntry e in _localAudioEntries)
        RemoteLocalAudioInfo(displayName: e.displayName),
    ];
  }

  /// 即时把 displayName 为 [displayName] 的本地音频库打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该来源或其 DB 文件不存在时抛 [StateError]。
  @override
  Future<File> exportLocalAudio(String displayName) async {
    _assertSafeName(displayName);
    final LocalAudioDbEntry? entry =
        _localAudioEntries.cast<LocalAudioDbEntry?>().firstWhere(
              (LocalAudioDbEntry? e) => e!.displayName == displayName,
              orElse: () => null,
            );
    if (entry == null) {
      throw StateError('local audio not found: $displayName');
    }
    final File dbFile = File(entry.path);
    if (!dbFile.existsSync()) {
      throw StateError('local audio DB file not found: ${entry.path}');
    }

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_local_audio_export');
    final File out = File(p.join(tmpDir.path, '$displayName.hibikiaudiolib'));
    await _packages.exportLocalAudioPackage(
      displayName: entry.displayName,
      enabled: entry.enabled,
      sources: entry.sources,
      dbFile: dbFile,
      outputFile: out,
    );
    return out;
  }

  /// 把本地音频包文件导入 host（解包 + 注册）。
  /// 需要在构造器传入 [onLocalAudioImported] 回调；回调为 null 时抛 [UnsupportedError]。
  @override
  Future<void> importLocalAudio(File packageFile) async {
    final Future<void> Function(LocalAudioPackageContents)? callback =
        _onLocalAudioImported;
    if (callback == null) {
      throw UnsupportedError(
        'importLocalAudio requires onLocalAudioImported callback to be provided',
      );
    }
    await _runExclusive(() async {
      final Directory stagingDir =
          _localAudioStagingDir ?? Directory.systemTemp;
      final LocalAudioPackageContents contents =
          await _packages.importLocalAudioPackage(
        packageFile: packageFile,
        stagingDir: stagingDir,
      );
      await callback(contents);
    });
  }

  /// 从 host 删除 displayName 为 [displayName] 的本地音频来源。
  ///
  /// 注：本地音频来源的注册信息存于 Preferences（不在 Drift DB），删除需经
  /// [_removeLocalAudioEntry] 回调，生产由 AppModel 注入。回调为 null 时静默
  /// 跳过实际删除（等同 no-op，保持幂等）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteLocalAudio(String displayName) async {
    _assertSafeName(displayName);
    final Future<void> Function(String)? remover = _removeLocalAudioEntry;
    if (remover == null) return; // 回调未注入：静默跳过（幂等）
    await _runExclusive(() => remover(displayName));
  }

  // ── 有声书包（T3.1）────────────────────────────────────────────────────────

  /// host 当前可导出的有声书清单。
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    final List<RemoteAudiobookInfo> result = <RemoteAudiobookInfo>[];
    for (final AudiobookRow r in rows) {
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(r.bookKey);
      if (srt == null) continue;
      result.add(RemoteAudiobookInfo(bookKey: r.bookKey, title: srt.title));
    }
    return result;
  }

  /// 即时把 bookKey 为 [bookKey] 的有声书打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [bookKey] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到有声书（Audiobooks 行或 SrtBooks 行缺失）时抛 [StateError]。
  @override
  Future<File> exportAudiobook(String bookKey) async {
    _assertSafeName(bookKey);

    final AudiobookRow? ab = await _db.getAudiobookByBookKey(bookKey);
    if (ab == null) {
      throw StateError('audiobook not found for bookKey: $bookKey');
    }
    final SrtBookRow? srt = await _db.getSrtBookByBookKey(bookKey);
    if (srt == null) {
      throw StateError('srtBook not found for bookKey: $bookKey');
    }

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_audiobook_export');
    final File out = File(p.join(tmpDir.path, '$bookKey.hibikiaudio'));
    await _packages.exportAudioDatabasePackage(
      bookKey: bookKey,
      srtBookUid: srt.uid,
      outputFile: out,
    );
    return out;
  }

  /// 把有声书包文件导入 host（解包写 DB + 音频文件）。
  /// 需要在构造器传入 [audioDatabaseRoot]；为 null 时抛 [UnsupportedError]。
  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {
    final Directory? root = _audioDatabaseRoot;
    if (root == null) {
      throw UnsupportedError(
        'importAudiobook requires audioDatabaseRoot to be provided',
      );
    }
    await _runExclusive(() async {
      await _packages.importAudioDatabasePackage(
        packageFile: packageFile,
        audioDatabaseRoot: root,
        bookKeyOverride: bookKeyOverride,
      );
    });
  }

  /// 从 host 删除 bookKey 为 [bookKey] 的有声书（Audiobooks/SrtBooks/AudioCues 行
  /// + 磁盘音频目录）。[bookKey] 含路径穿越字符时抛 [ArgumentError]；
  /// 不存在则静默跳过（幂等）。
  @override
  Future<void> deleteAudiobook(String bookKey) async {
    _assertSafeName(bookKey);
    await _runExclusive(() async {
      final AudiobookRow? ab = await _db.getAudiobookByBookKey(bookKey);
      if (ab == null) return; // 幂等：不存在则静默跳过

      // 先取 audioRoot，再删 DB 行（磁盘清理在 DB 删除后，同 deleteBook 顺序）。
      final String? audioRoot = ab.audioRoot;

      // 删除 SrtBooks 行（按 bookKey），其关联的 SrtBook 级别 audioCues 由事务处理。
      // getSrtBookByBookKey 先拿 uid，再用 deleteSrtBookByUid 级联删 audioCue 行。
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(bookKey);
      if (srt != null) {
        await _db.deleteSrtBookByUid(srt.uid);
      }

      // 删除 Audiobooks 行（及其 audioCues 级联，via deleteAudiobookByBookKey）。
      await _db.deleteAudiobookByBookKey(bookKey);

      // 磁盘音频目录。
      if (audioRoot != null && audioRoot.isNotEmpty) {
        final Directory dir = Directory(audioRoot);
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });
  }

  // ── 视频（P4-1，只读）────────────────────────────────────────────────────────

  /// host 当前视频清单（从 VideoBooks 表读，按 importedAt DESC 排序）。
  ///
  /// [sizeBytes] 取 videoPath 对应文件的大小（stat），文件不存在时为 null。
  /// [durationMs] 目前恒为 null（DB 无 duration 列，后续由 ffprobe/libmpv 填充）。
  /// [hasSubtitle] 当前视频文件旁能找到外挂字幕时为 true。
  @override
  Future<List<RemoteVideoInfo>> listVideos() async {
    final List<VideoBookRow> rows = await _db.allVideoBooks();
    // 按 importedAt 降序（null 排最后）
    rows.sort((VideoBookRow a, VideoBookRow b) {
      final DateTime? ta = a.importedAt;
      final DateTime? tb = b.importedAt;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[];
    for (final VideoBookRow row in rows) {
      videos.add(await _videoInfoFromRow(row));
    }
    return videos;
  }

  /// 构建单条 [RemoteVideoInfo]（内部辅助，不做 IO 之外的副作用）。
  Future<RemoteVideoInfo> _videoInfoFromRow(VideoBookRow row) async {
    final String videoPath = row.videoPath;
    int? sizeBytes;
    bool hasSubtitle = false;
    String? subtitleFileName;
    List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks =
        const <RemoteVideoEmbeddedSubtitleTrack>[];

    if (videoPath.isNotEmpty) {
      final File f = File(videoPath);
      if (f.existsSync()) {
        try {
          sizeBytes = f.lengthSync();
        } catch (_) {
          // stat 失败：保守返回 null
        }
        // 检查外挂字幕 sidecar
        final String? sub =
            findSidecarSubtitle(videoPath, langCode: _videoSubtitleLangCode);
        if (sub != null && File(sub).existsSync()) {
          hasSubtitle = true;
          subtitleFileName = p.basename(sub);
        }
        embeddedSubtitleTracks = await _embeddedSubtitleTracksForVideo(
          videoPath,
        );
        if (embeddedSubtitleTracks.any(
          (RemoteVideoEmbeddedSubtitleTrack track) => track.isText,
        )) {
          hasSubtitle = true;
        }
      }
    }

    final String? coverPath = _existingFilePath(row.coverPath);
    // TODO-653: 把 host 端记录的播放断点带进清单条目，供 client 跨设备恢复。
    final ({int positionMs, int updatedAtMs}) progress =
        await getVideoPosition(row.bookUid);
    return RemoteVideoInfo(
      id: row.bookUid,
      title: row.title,
      sizeBytes: sizeBytes,
      hasSubtitle: hasSubtitle,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: embeddedSubtitleTracks,
      // durationMs: 暂为 null，DB 无此列（后续接线任务填充）
      hasCover: coverPath != null,
      coverPath: coverPath,
      positionMs: progress.positionMs,
      positionUpdatedAtMs: progress.updatedAtMs,
    );
  }

  Future<List<RemoteVideoEmbeddedSubtitleTrack>>
      _embeddedSubtitleTracksForVideo(
    String videoPath,
  ) async {
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoPath);
    return <RemoteVideoEmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack track in tracks)
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: track.streamIndex,
          codec: track.codec,
          language: track.language,
          title: track.title,
          isText: subtitleFormatForCodec(track.codec) != null,
        ),
    ];
  }

  /// 按 [id]（即 `VideoBooks.bookUid`）反查真实视频文件。
  ///
  /// **只查 DB**，不接受外部文件路径。文件不存在或 id 未知时返回 null。
  @override
  Future<File?> resolveVideoFile(String id) async {
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    final String path = row.videoPath;
    if (path.isEmpty) return null;
    final File f = File(path);
    return f.existsSync() ? f : null;
  }

  /// 按 [id] 查找对应视频的外挂字幕文件（sidecar）。
  ///
  /// 用 [langCode] 优先匹配带语言标记的字幕（如 `.ja.srt`）；内封字幕不在此列。
  /// 找不到外挂字幕或视频未知时返回 null。
  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
  }) async {
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    final String videoPath = row.videoPath;
    if (videoPath.isEmpty) return null;
    final String effectiveLangCode =
        langCode.isEmpty ? _videoSubtitleLangCode : langCode;
    final String? subPath =
        findSidecarSubtitle(videoPath, langCode: effectiveLangCode);
    if (subPath == null) return null;
    final File f = File(subPath);
    return f.existsSync() ? f : null;
  }

  /// 读 host 端 [id] 视频的播放断点（TODO-653）。落 host 自己的
  /// `video_remote_position_<bookUid>` + `video_remote_position_at_<bookUid>` prefs
  /// （与 host 本地播放该视频时同一键空间）；无记录返回 (0, 0)。
  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id,
  ) async {
    final int positionMs =
        await _db.getPrefTyped<int>(videoRemotePositionPrefKey(id), 0);
    final int updatedAtMs =
        await _db.getPrefTyped<int>(videoRemotePositionAtPrefKey(id), 0);
    return (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }

  /// 把 client 上报的 [id] 视频断点写入 host（TODO-653）。
  ///
  /// 冲突解决「取较新时间戳」（[resolveVideoPositionSync]）：仅当 [updatedAtMs] 严格
  /// 新于 host 已存时间戳才覆盖，避免旧设备滞后上报回退新进度。负位置 clamp 0。
  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs,
  ) async {
    final ({int positionMs, int updatedAtMs}) current =
        await getVideoPosition(id);
    final ({int positionMs, int updatedAtMs}) winner = resolveVideoPositionSync(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
    if (winner.updatedAtMs == current.updatedAtMs &&
        winner.positionMs == current.positionMs) {
      return; // host 已存更新或相等，no-op。
    }
    await _db.setPrefTyped<int>(
        videoRemotePositionPrefKey(id), winner.positionMs);
    await _db.setPrefTyped<int>(
        videoRemotePositionAtPrefKey(id), winner.updatedAtMs);
  }
}

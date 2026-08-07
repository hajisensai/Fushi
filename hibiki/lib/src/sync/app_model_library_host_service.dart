import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show parseSubtitleCues;
import 'package:fushi/src/media/video/video_sidecar.dart'
    show findSidecarSubtitle, isSidecarSubtitleSuffix, pickSidecar;
import 'package:fushi_audio/fushi_audio.dart'
    show AudioCue, readTextWithEncoding;
import 'package:fushi/src/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/collection_sync_engine.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_manager.dart'
    show repackageExtractedEpub, resolveExtractedEpubRoot;
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show extractAudioSegmentViaFfmpeg;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudiobookStorage;
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
class AppModelLibraryHostService
    implements
        FushiLibraryHostService,
        DeletionTombstoneHost,
        VideoDeletionHost,
        InterconnectServiceConfigHost {
  AppModelLibraryHostService({
    required FushiDatabase db,
    required Directory dictionaryResourceRoot,
    required SyncAssetPackageService packages,
    required Future<void> Function() refreshDictionaryCache,
    required Future<void> Function(Future<void> Function() body) runExclusive,
    Future<void> Function(File epubFile)? importBookFromFile,
    Future<void> Function(EpubBookRow row)? cleanupBookOnDisk,
    Future<void> Function(VideoBookRow row)? cleanupVideoOnDisk,
    List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
    Directory? localAudioStagingDir,
    Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
    Directory? audioDatabaseRoot,
    Future<void> Function(String displayName)? removeLocalAudioEntry,
    String videoSubtitleLangCode = 'ja',
    Directory? uploadedVideoRoot,
    Future<String?> Function(
            {required String videoPath, required String bookUid})?
        extractVideoCover,
  })  : _db = db,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _packages = packages,
        _refreshDictionaryCache = refreshDictionaryCache,
        _runExclusive = runExclusive,
        _importBookFromFile = importBookFromFile,
        _cleanupBookOnDisk = cleanupBookOnDisk,
        _cleanupVideoOnDisk = cleanupVideoOnDisk,
        _localAudioEntries = localAudioEntries,
        _localAudioStagingDir = localAudioStagingDir,
        _onLocalAudioImported = onLocalAudioImported,
        _audioDatabaseRoot = audioDatabaseRoot,
        _removeLocalAudioEntry = removeLocalAudioEntry,
        _videoSubtitleLangCode = videoSubtitleLangCode,
        _uploadedVideoRoot = uploadedVideoRoot,
        _extractVideoCover = extractVideoCover;

  final FushiDatabase _db;
  final Directory _dictionaryResourceRoot;
  final SyncAssetPackageService _packages;
  final Future<void> Function() _refreshDictionaryCache;
  final Future<void> Function(Future<void> Function() body) _runExclusive;

  @override
  Future<InterconnectServiceConfigSnapshot>
      getInterconnectServiceConfig() async {
    return InterconnectServiceConfigSnapshot.fromPreferences(
      await _db.getAllPrefs(),
    );
  }

  /// 书籍导入回调（可选；null 时 importBook 抛 [UnsupportedError]）。
  /// 生产传 `(f) => EpubImporter.importFromPath(db: db, filePath: f.path, fileName: p.basename(f.path))`。
  final Future<void> Function(File epubFile)? _importBookFromFile;

  /// 书籍磁盘清理回调（可选；null 时只执行 DB 删除，跳过 AudiobookStorage/SrtBook 清理）。
  /// 生产传 ReaderHibikiSource 实例的磁盘清理部分。
  final Future<void> Function(EpubBookRow row)? _cleanupBookOnDisk;

  /// 视频磁盘清理回调（可选；null 时只执行 DB 删除 + 上传副本目录回收）。
  /// 生产传 `VideoBookRepository.reclaimDeletedVideoBookAssets` 的等价闭包——它按
  /// 「仍在 app 资产目录内 + 无其它条目引用」回收封面 / 字幕缓存，**不碰原始视频文件**。
  final Future<void> Function(VideoBookRow row)? _cleanupVideoOnDisk;

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
  /// 生产传 JapaneseLanguage.instance.languageCode（P4 接线任务完成后注入真实值）。
  final String _videoSubtitleLangCode;

  /// client→host 上传视频的落盘根目录（可选；null 时 [importVideo] 抛 [UnsupportedError]）。
  /// 生产传 `<documents>/remote_videos`（[AppPaths.remoteVideosDirectory] 同目录，与
  /// client 下载远端视频落点一致）。
  final Directory? _uploadedVideoRoot;

  /// 上传视频后的封面抽取回调（可选、best-effort；null 时上传的视频无封面占位）。
  /// 生产传 `extractVideoCover`（桌面 ffmpeg 抽帧；移动端无 ffmpeg 返 null 留空占位）。
  final Future<String?> Function(
      {required String videoPath, required String bookUid})? _extractVideoCover;

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

  /// bookKey → 标签名列表 的一趟映射（TODO-1165，避免逐书 N+1 查询）。
  Future<Map<String, List<String>>> _tagNamesByBookKey() async {
    final Map<int, String> nameById = <int, String>{
      for (final BookTagRow t in await _db.getAllTags()) t.id: t.name,
    };
    final Map<String, List<String>> result = <String, List<String>>{};
    for (final BookTagMappingRow m in await _db.getAllBookTagMappings()) {
      final String? name = nameById[m.tagId];
      if (name == null) continue;
      (result[m.bookKey] ??= <String>[]).add(name);
    }
    return result;
  }

  /// `'<mediaType>|<entryKey>'` → 该条目的**主合集归属**（多端库联合视图 §2.3
  /// 任务5.1）的一趟映射。归属跟随 [FushiDatabase.getPrimaryCollectionIdByEntry] 的
  /// 「最小 collectionId」折叠语义：一条目属多合集时只带它折进的那一张，与库网格
  /// 折叠 / UI 占位卡归行一致。孤儿引用（合集已删）跳过 = 无归属（散卡）。每个被引用
  /// 合集只 [getCollectionItems] 一次，避免逐条目 N+1。
  Future<Map<String, RemoteCollectionMembership>>
      _primaryCollectionMembership() async {
    final Map<String, int> primaryByEntry =
        await _db.getPrimaryCollectionIdByEntry();
    if (primaryByEntry.isEmpty) {
      return const <String, RemoteCollectionMembership>{};
    }
    final Map<int, MediaCollectionRow> collectionsById =
        <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        c.id: c,
    };
    final Map<String, RemoteCollectionMembership> out =
        <String, RemoteCollectionMembership>{};
    // 只遍历真正承载某条目主归属的合集（按 id 去重），逐合集取一次成员行。
    for (final int cid in primaryByEntry.values.toSet()) {
      final MediaCollectionRow? col = collectionsById[cid];
      if (col == null) continue; // 孤儿引用：归属合集已删 → 该条目退化散卡。
      for (final MediaCollectionItemRow item
          in await _db.getCollectionItems(cid)) {
        final String key = '${item.mediaType}|${item.entryKey}';
        // 仅记录以本合集为主归属的成员（该条目也可能在别的更大 id 合集里）。
        if (primaryByEntry[key] != cid) continue;
        out[key] = RemoteCollectionMembership(
          collectionName: col.name,
          collectionType: col.collectionType,
          sortIndex: item.sortIndex,
        );
      }
    }
    return out;
  }

  /// videoBookUid → 标签名列表 的一趟映射（TODO-1165）。
  Future<Map<String, List<String>>> _tagNamesByVideoUid() async {
    final Map<int, String> nameById = <int, String>{
      for (final BookTagRow t in await _db.getAllTags()) t.id: t.name,
    };
    final Map<String, List<String>> result = <String, List<String>>{};
    for (final VideoBookTagMappingRow m
        in await _db.getAllVideoBookTagMappings()) {
      final String? name = nameById[m.tagId];
      if (name == null) continue;
      (result[m.bookUid] ??= <String>[]).add(name);
    }
    return result;
  }

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
      return RemoteBookInfo(
        title: r.title,
        bookKey: r.bookKey,
        hasContent: resolveExtractedEpubRoot(r.extractDir) != null,
        hasEmbeddedCover: coverPath != null,
        coverPath: coverPath,
        hasAudiobook: audiobookKeys.contains(r.bookKey),
        tags: tagsByBookKey[r.bookKey] ?? const <String>[],
        tagsAddedAt: tagAddedAtByKey[r.bookKey] ?? const <String, int>{},
        tagTombstones: tagTombByKey[r.bookKey] ?? const <String, int>{},
        // 合集成员键：epub 条目 mediaType='epub'、entryKey=bookKey（§2.3 任务5.1）。
        // srt-backed 有声书兜底：该书以 srt|uid 入合集时，epub|bookKey 会 miss，
        // 回退查 srt|uid（BUG-812）。散卡（两键都无）= null。
        collection: membership[MediaKind.epub.compositeKey(r.bookKey)] ??
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

  static final RegExp _hoshiBookKeyPattern = RegExp(r'^hoshi://book/(.+)$');

  /// 批查全库书籍阅读进度「bookKey → (percent 0..100, 最近阅读毫秒戳)」。
  ///
  /// percent 与本地首页仪表盘「继续」完全同算：`MediaItems.position/duration`
  /// （书的 MediaItem.mediaIdentifier = `hoshi://book/<bookKey>`）；时刻取
  /// `reader_positions.updatedAt`。两趟全表读，无逐书查询。
  Future<Map<String, ({int percent, int updatedAtMs})>>
      _bookProgressByKey() async {
    final Map<String, int> updatedAtByKey = <String, int>{
      for (final ReaderPositionRow r in await _db.getAllReaderPositions())
        r.bookKey: r.updatedAt,
    };
    final Map<String, ({int percent, int updatedAtMs})> out =
        <String, ({int percent, int updatedAtMs})>{};
    for (final MediaItemRow m in await _db.getAllMediaItems()) {
      final RegExpMatch? match =
          _hoshiBookKeyPattern.firstMatch(m.mediaIdentifier);
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

  /// host 最近 [limit] 条活动事件（新首页 Activity 面板互联数据源）。
  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
      {int limit = 100}) async {
    final List<ActivityEventRow> rows =
        await _db.getRecentActivityEvents(limit: limit);
    return <RemoteActivityEvent>[
      for (final ActivityEventRow r in rows)
        RemoteActivityEvent(
          eventType: r.eventType,
          mediaType: r.mediaType,
          title: r.title,
          dateKey: r.dateKey,
          timestampMs: r.timestampMs,
          mediaKey: r.mediaKey,
          durationMs: r.durationMs,
          charsDelta: r.charsDelta,
        ),
    ];
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
      // TODO-1195 part B：用户删书记墓碑，避免旧备份合并导入时复活。
      await _db.deleteEpubBook(row.bookKey, tombstone: true);

      // extractDir 磁盘目录：DB 删除后再清理（与 reader_hibiki_source 同顺序）。
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
    final ReaderPositionRow? row = await _db.getReaderPosition(bookKey);
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
    if (await _db.getEpubBook(bookKey) == null) return;
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
        bookKey: Value(bookKey),
        sectionIndex: Value(winner.sectionIndex),
        normCharOffset: Value(winner.normCharOffset),
        charOffset: Value(winner.charOffset),
        updatedAt: Value(winner.updatedAtMs),
      ));
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

  /// 既有 Audiobooks 行又有 SrtBooks 行的 bookKey 集合——即真正可经 live-sync
  /// 导出的有声书（[exportAudiobook] 要求两表齐备，缺一即抛 StateError → 404）。
  ///
  /// [listBooks] 的 `hasAudiobook` 徽章、[listAudiobooks] 清单、orchestrator
  /// sweep 三处判据全部走此单一派生逻辑，确保徽章/清单/导出契约完全同源（TODO-778）。
  Future<Set<String>> _srtBackedAudiobookKeys() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    final Set<String> keys = <String>{};
    for (final AudiobookRow r in rows) {
      if (await _db.getSrtBookByBookKey(r.bookKey) != null) {
        keys.add(r.bookKey);
      }
    }
    return keys;
  }

  /// host 当前可导出的有声书清单。
  ///
  /// 两类：
  /// - **srt-backed**（既有 Audiobooks 又有 SrtBooks 行）：身份键 = bookKey（不变）。
  /// - **纯 SRT（standalone）有声书**（SrtBooks 行 bookKey 为空、无 Audiobooks 行）：
  ///   身份键 = uid。旧枚举只遍历 Audiobooks 表，完全遗漏这类书 → 无法跨设备下载。
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    final List<RemoteAudiobookInfo> result = <RemoteAudiobookInfo>[];
    final Set<String> emittedUids = <String>{};
    for (final AudiobookRow r in rows) {
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(r.bookKey);
      if (srt == null) continue;
      result.add(RemoteAudiobookInfo(
        bookKey: r.bookKey,
        uid: srt.uid,
        title: srt.title,
      ));
      emittedUids.add(srt.uid);
    }
    // 纯 SRT（standalone）有声书：bookKey 为空、不落 Audiobooks 行，身份 = uid。
    final List<SrtBookRow> srtRows = await _db.getAllSrtBooks();
    for (final SrtBookRow srt in srtRows) {
      if (srt.bookKey.isNotEmpty) continue; // srt-backed 已在上面枚举
      if (!emittedUids.add(srt.uid)) continue; // 去重（防重复 uid）
      result.add(RemoteAudiobookInfo(
        bookKey: '',
        uid: srt.uid,
        title: srt.title,
      ));
    }
    return result;
  }

  /// 即时把身份键为 [identity] 的有声书打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  ///
  /// [identity] 解析：先按 bookKey 查 Audiobooks（srt-backed），命中即打含 audiobook
  /// 段的包；否则按 uid 查 SrtBooks（纯 SRT standalone），命中即打无 audiobook 段的
  /// 纯 SRT 包。两者都查不到抛 [StateError]。含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<File> exportAudiobook(String identity) async {
    _assertSafeName(identity);

    // srt-backed：identity = bookKey，Audiobooks 行 + SrtBooks 行齐备。
    final AudiobookRow? ab = await _db.getAudiobookByBookKey(identity);
    if (ab != null) {
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(identity);
      if (srt == null) {
        throw StateError('srtBook not found for bookKey: $identity');
      }
      return _packAudiobook(
        identity: identity,
        srtBookUid: srt.uid,
        bookKey: identity,
      );
    }

    // 纯 SRT（standalone）：identity = uid，无 Audiobooks 行，bookKey 空。
    final SrtBookRow? srtStandalone = await _db.getSrtBookByUid(identity);
    if (srtStandalone != null) {
      return _packAudiobook(
        identity: identity,
        srtBookUid: identity,
        bookKey: null, // 无 Audiobooks 行 → 打纯 SRT 包
      );
    }

    throw StateError('audiobook not found for identity: $identity');
  }

  /// 打包成 `<identity>.hibikiaudio` 临时文件（srt-backed 传 [bookKey]；纯 SRT 传
  /// null，包管线据此省略 audiobook 段、cue 走 uid 命名空间）。
  Future<File> _packAudiobook({
    required String identity,
    required String srtBookUid,
    required String? bookKey,
  }) async {
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_audiobook_export');
    final File out = File(p.join(tmpDir.path, '$identity.hibikiaudio'));
    await _packages.exportAudioDatabasePackage(
      srtBookUid: srtBookUid,
      outputFile: out,
      bookKey: bookKey,
    );
    return out;
  }

  /// 廉价判断 host 库是否存在 bookKey 为 [bookKey] 的有声书（BUG-471a）：仅一次
  /// `Audiobooks` 行查询，不触发 [exportAudiobook] 的整包打包 zip I/O。与
  /// [putAudiobookPosition] 自身用的存在性闸门同一查询。
  @override
  Future<bool> audiobookExists(String identity) async {
    _assertSafeName(identity);
    if (await _db.getAudiobookByBookKey(identity) != null) return true;
    // 纯 SRT standalone：无 Audiobooks 行，按 uid 查 SrtBooks。
    return await _db.getSrtBookByUid(identity) != null;
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
      if (ab != null) {
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

        await _deleteAudioRootIfPersisted(audioRoot);
        return;
      }

      // 纯 SRT standalone：identity = uid，无 Audiobooks 行。按 uid 删 SrtBooks 行
      // （级联 uid 命名空间的 audioCues）+ 其持久音频目录。
      final SrtBookRow? srt = await _db.getSrtBookByUid(bookKey);
      if (srt == null) return; // 幂等：都不存在则静默跳过
      final String? audioRoot = srt.audioRoot;
      await _db.deleteSrtBookByUid(srt.uid);
      await _deleteAudioRootIfPersisted(audioRoot);
    });
  }

  /// 删除 [audioRoot] 磁盘目录，但仅当它在 app 内部持久根（<appDoc>/audiobooks）下
  /// —— 绝不递归删用户「引用导入」的原始外部目录（TODO-935 ①A）。
  Future<void> _deleteAudioRootIfPersisted(String? audioRoot) async {
    if (audioRoot == null || audioRoot.isEmpty) return;
    final String persistRoot = await AudiobookStorage.audiobooksRootDir();
    final bool referenced = AudiobookStorage.isReferencedPath(
      filePath: audioRoot,
      persistRoot: persistRoot,
    );
    if (!referenced) {
      final Directory dir = Directory(audioRoot);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  /// 读 host 端有声书 [bookKey] 的播放断点（BUG-471）。真相源是
  /// `audiobook_pos_<bookKey>` + `audiobook_pos_at_<bookKey>` prefs（host 本机播放
  /// 与远端 resume 路径统一写此键空间，见 [AudiobookRepository.updatePositionMs]）。
  ///
  /// 向后兼容：旧数据只写位置不写时间戳，缺时间戳时记 0，被任何带时间戳的对端进度
  /// 在 [resolvePositionLww] 中盖过——既能读出旧本机播放位置，又不让无时间戳
  /// 旧值盖过更新的对端进度。
  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async {
    final int pos =
        await _db.getPrefTyped<int>(audiobookPositionPrefKey(bookKey), 0);
    final int at =
        await _db.getPrefTyped<int>(audiobookPositionAtPrefKey(bookKey), 0);
    return (positionMs: pos, updatedAtMs: at);
  }

  /// 把 client 上报的有声书 [bookKey] 断点写入 host（BUG-471）。
  ///
  /// 存在性闸门：host 无该 bookKey 的 Audiobooks 行 → no-op，不写孤儿
  /// `audiobook_pos_` pref（与视频 [putVideoPosition]「视频不存在不写脏」、书
  /// [putBookProgress]「书不存在不写孤儿行」同语义）。
  ///
  /// 冲突解决「取较新时间戳」（[resolvePositionLww]）：仅当 [updatedAtMs]
  /// 严格新于 host 已存时间戳才覆盖。负位置 clamp 0。
  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    // host 库不存在该有声书 → no-op（防任意 client 上报任意 key 写脏 prefs）。
    // srt-backed 按 bookKey 查 Audiobooks；纯 SRT standalone 按 uid 查 SrtBooks。
    // 进度 pref key = audiobook_pos_<identity>：standalone 的 identity=uid 恰为
    // SrtBook 进度键，故写穿即写到正确命名空间。
    if (await _db.getAudiobookByBookKey(bookKey) == null &&
        await _db.getSrtBookByUid(bookKey) == null) {
      return;
    }
    final ({int positionMs, int updatedAtMs}) current =
        await getAudiobookPosition(bookKey);
    final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
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
        audiobookPositionPrefKey(bookKey), winner.positionMs);
    await _db.setPrefTyped<int>(
        audiobookPositionAtPrefKey(bookKey), winner.updatedAtMs);
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
      final int? ta = a.importedAt;
      final int? tb = b.importedAt;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    final Map<String, List<String>> tagsByVideoUid =
        await _tagNamesByVideoUid();
    final Map<String, RemoteCollectionMembership> membership =
        await _primaryCollectionMembership();
    // 批量预取：位置 prefs / 标签 LWW 时钟 / 移除墓碑各一趟查询，sidecar 同目录只扫
    // 一次。旧实现逐行 2~3 次 prefs 读 + 1 次行重查 + 2 次标签查询 + 1 次全目录
    // listSync——500 行清单一次 ≈ 2500 次 DB 往返 + 500 次目录扫描，且封面端点每张
    // 封面重跑整份清单时按 N² 放大（见 [videoCoverPath]）。
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    final Map<String, Map<String, int>> tagAddedAtByUid =
        await _db.allVideoTagAddedAtByName();
    final Map<String, Map<String, int>> tagTombByUid =
        await _db.allTagTombstonesByName(MediaKind.video);
    final Map<String, List<String>?> sidecarDirCache =
        <String, List<String>?>{};
    final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[];
    for (final VideoBookRow row in rows) {
      videos.add(_videoInfoFromRow(
        row,
        tags: tagsByVideoUid[row.bookUid] ?? const <String>[],
        // 合集成员键：video 条目 mediaType='video'、entryKey=bookUid（§2.3 任务5.1）。
        collection: membership[MediaKind.video.compositeKey(row.bookUid)],
        prefs: allPrefs,
        tagsAddedAt: tagAddedAtByUid[row.bookUid] ?? const <String, int>{},
        tagTombstones: tagTombByUid[row.bookUid] ?? const <String, int>{},
        sidecarDirCache: sidecarDirCache,
      ));
    }
    return videos;
  }

  /// 按 [id] 单查视频封面磁盘路径（封面端点专用，一次 DB 单行查询 + stat；绝不
  /// materialize 整份 [listVideos]——旧封面路径每张封面重跑全量清单是 O(N²) 主犯）。
  @override
  Future<String?> videoCoverPath(String id) async {
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    return _existingFilePath(row.coverPath);
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

  /// 列出 [dir] 下的文件名（仅文件，不含子目录）；目录不存在/读取失败返回 null。
  /// [listVideos] 用它配合每次调用内的目录缓存，同目录 500 个视频只扫一次。
  static List<String>? _listDirFileNames(String dir) {
    final Directory directory = Directory(dir);
    try {
      if (!directory.existsSync()) return null;
      return directory
          .listSync(followLinks: false)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
    } on FileSystemException {
      return null;
    }
  }

  /// 构建单条 [RemoteVideoInfo]（内部辅助，纯同步：所有 DB 数据均由 [listVideos]
  /// 批量预取后经参数注入，仅保留文件 stat 与目录缓存内的 sidecar 匹配）。
  RemoteVideoInfo _videoInfoFromRow(
    VideoBookRow row, {
    required Map<String, String> prefs,
    required Map<String, int> tagsAddedAt,
    required Map<String, int> tagTombstones,
    required Map<String, List<String>?> sidecarDirCache,
    List<String> tags = const <String>[],
    RemoteCollectionMembership? collection,
  }) {
    final String videoPath = row.videoPath;
    int? sizeBytes;
    bool hasSubtitle = false;
    String? subtitleFileName;

    if (videoPath.isNotEmpty) {
      final File f = File(videoPath);
      if (f.existsSync()) {
        try {
          sizeBytes = f.lengthSync();
        } catch (_) {
          // stat 失败：保守返回 null
        }
        // 检查外挂字幕 sidecar（廉价：目录 listing 每目录只扫一次 + 纯字符串匹配）。
        final String dir = p.dirname(videoPath);
        final List<String>? dirFiles =
            sidecarDirCache.putIfAbsent(dir, () => _listDirFileNames(dir));
        final String? picked = dirFiles == null
            ? null
            : pickSidecar(
                p.basenameWithoutExtension(videoPath),
                dirFiles,
                langCode: _videoSubtitleLangCode,
              );
        if (picked != null) {
          hasSubtitle = true;
          subtitleFileName = picked;
        }
        // BUG-814：列表端点**不做**内嵌字幕轨 ffmpeg 探测。旧实现在此逐视频串行
        // spawn `ffmpeg -i`（每项超时基线 60s、大文件到 1200s、无缓存、每次 GET 全量
        // 重跑），大库（如 511 个视频）轻易超过 client 的 15s listTimeout → 远端视频
        // 判空 → 手机整页空。内嵌轨是**播放时**才需要的信息，已由 `/streamurl` 端点
        // (`hibiki_sync_server.dart` `_embeddedSubtitleTracksForRequest`) 在拉流时按需
        // 探测并下发（client 唯一消费者 video_hibiki_page 读的是 streamurl 响应，列表
        // 的 embeddedSubtitleTracks 零消费）。故此处保持 embeddedSubtitleTracks 为空、
        // hasSubtitle 只反映廉价的外挂 sidecar——列表变纯 DB/stat 读，与 listBooks 对称、
        // 毫秒返回。
      }
    }

    final String? coverPath = _existingFilePath(row.coverPath);
    // TODO-653: 把 host 端记录的播放断点带进清单条目，供 client 跨设备恢复。
    // 语义与 [getVideoPosition]\(id, episodeIndex: 0\) 完全一致：prefs 断点（本机/
    // 远端播放统一键）与旧 `VideoBooks.lastPositionMs`（时间戳 0）取较新——只是行
    // 已在手、prefs 已批量预取，不再逐行发查询。
    final ({int positionMs, int updatedAtMs}) progress = resolvePositionLww(
      localPositionMs: PrefCodec.decode<int>(
          prefs[videoRemotePositionPrefKey(row.bookUid)] ?? '', 0),
      localUpdatedAtMs: PrefCodec.decode<int>(
          prefs[videoRemotePositionAtPrefKey(row.bookUid)] ?? '', 0),
      remotePositionMs: row.lastPositionMs,
      remoteUpdatedAtMs: 0,
    );
    // TODO-885: 解析 playlistJson → 远端剧集（只 index+title，绝不带 host path）。
    final List<RemoteVideoEpisode> episodes = _episodesFromRow(row);
    final int currentEpisode = episodes.length > 1
        ? row.currentEpisode.clamp(0, episodes.length - 1)
        : 0;
    return RemoteVideoInfo(
      id: row.bookUid,
      title: row.title,
      sizeBytes: sizeBytes,
      hasSubtitle: hasSubtitle,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: const <RemoteVideoEmbeddedSubtitleTrack>[],
      // durationMs: 暂为 null，DB 无此列（后续接线任务填充）
      hasCover: coverPath != null,
      coverPath: coverPath,
      positionMs: progress.positionMs,
      positionUpdatedAtMs: progress.updatedAtMs,
      // BUG-996：把 host 的字幕时序偏移下发，供远端播放跟随（设备无关的纯时序）。
      delayMs: row.delayMs,
      episodes: episodes,
      currentEpisode: currentEpisode,
      tags: tags,
      // tags 稳健档：带上标签 LWW 时钟 + 移除墓碑，供 client mergeRemoteVideoTags 传播
      // host 侧删除/改名、防复活（旧 client 忽略、按 tags 名单只增）。
      tagsAddedAt: tagsAddedAt,
      tagTombstones: tagTombstones,
      collection: collection,
    );
  }

  /// 把 [row] 的 `playlistJson` 解析成远端剧集列表（TODO-885）。坏 JSON / 单视频
  /// （≤1 集）返回空列表 = 单视频语义（向后兼容）。**只取 index+title**，host 端
  /// 文件 path 留在 host（client 用 episodeIndex 反查），绝不进 [RemoteVideoEpisode]。
  List<RemoteVideoEpisode> _episodesFromRow(VideoBookRow row) {
    final List<PlaylistEntry> entries = _parsePlaylistEntries(row.playlistJson);
    if (entries.length <= 1) return const <RemoteVideoEpisode>[];
    return <RemoteVideoEpisode>[
      for (int i = 0; i < entries.length; i++)
        RemoteVideoEpisode(index: i, title: entries[i].title),
    ];
  }

  /// 纯解析 `playlistJson` 为 [PlaylistEntry] 列表（坏 JSON 返回空）。host 端按集反查
  /// 文件 path 用（[_resolveEpisodeVideoPath]）。
  List<PlaylistEntry> _parsePlaylistEntries(String? playlistJson) {
    if (playlistJson == null || playlistJson.isEmpty) {
      return const <PlaylistEntry>[];
    }
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return const <PlaylistEntry>[];
      return <PlaylistEntry>[
        for (final dynamic e in decoded)
          if (e is Map) PlaylistEntry.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <PlaylistEntry>[];
    }
  }

  /// 按 (bookUid=[id], [episodeIndex]) 从 host DB 反查该集真实视频文件路径（TODO-885）。
  ///
  /// **DB-only 安全契约**：path 永远来自 host 自己 `playlistJson` 解析，绝不接受外部
  /// 传入。[episodeIndex]<=0 或非播放列表时回退 `videoPath`（当前选中集 / 单视频）。
  /// 越界 [episodeIndex] 返回 null（安全拒绝）。
  Future<String?> _resolveEpisodeVideoPath(String id, int episodeIndex) async {
    if (episodeIndex < 0) return null; // 非法下标安全拒绝。
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    // 当前集 / 单视频（episodeIndex==0）：用 row.videoPath，等价旧行为。
    if (episodeIndex == 0) {
      return row.videoPath.isEmpty ? null : row.videoPath;
    }
    // 播放列表按集：DB 解析 playlistJson，越界安全拒绝。
    final List<PlaylistEntry> entries = _parsePlaylistEntries(row.playlistJson);
    if (episodeIndex >= entries.length) return null;
    final String path = entries[episodeIndex].path;
    return path.isEmpty ? null : path;
  }

  /// 按 [id]（即 `VideoBooks.bookUid`）反查真实视频文件。
  ///
  /// **只查 DB**，不接受外部文件路径。文件不存在或 id 未知时返回 null。
  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async {
    final String? path = await _resolveEpisodeVideoPath(id, episodeIndex);
    if (path == null || path.isEmpty) return null;
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
    int episodeIndex = 0,
  }) async {
    final String? videoPath = await _resolveEpisodeVideoPath(id, episodeIndex);
    if (videoPath == null || videoPath.isEmpty) return null;
    final String effectiveLangCode =
        langCode.isEmpty ? _videoSubtitleLangCode : langCode;
    final String? subPath =
        findSidecarSubtitle(videoPath, langCode: effectiveLangCode);
    if (subPath == null) return null;
    final File f = File(subPath);
    return f.existsSync() ? f : null;
  }

  /// BUG-1004：host 端本地裁 mining 句子音频（见抽象声明）。用 [resolveVideoFile] 反查真实
  /// 本地文件后调 [extractAudioSegmentViaFfmpeg]（本地路径、不经网络/TLS——绕开 client
  /// ffmpeg 抓 host 自签 https/token 流的整类失败）。裁到独立临时目录，产物返回给调用方，
  /// 调用方读完删该目录；失败清理临时目录并返回 null。
  @override
  Future<File?> clipVideoAudio(
    String id, {
    required int startMs,
    required int endMs,
    int episodeIndex = 0,
    int? audioStreamIndex,
    int? audioStreamCount,
    int audioChannels = 1,
    String audioBitrate = '64k',
  }) async {
    if (endMs <= startMs) return null;
    final File? file = await resolveVideoFile(id, episodeIndex: episodeIndex);
    if (file == null) return null;
    final Directory tmp =
        Directory.systemTemp.createTempSync('hibiki_clip_audio');
    final String out = p.join(tmp.path, 'clip.aac');
    final String? result = await extractAudioSegmentViaFfmpeg(
      inputPath: file.path,
      startMs: startMs,
      endMs: endMs,
      outputPath: out,
      audioStreamIndex: audioStreamIndex,
      audioStreamCount: audioStreamCount,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
    );
    if (result == null) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // best-effort：临时目录清理失败不影响返回 null（裁切已失败）。
      }
      return null;
    }
    return File(result);
  }

  /// 读 host 端 [id] 视频的播放断点（TODO-653 / TODO-816 断点②）。
  ///
  /// 真相源是 `video_remote_position_<bookUid>` + `video_remote_position_at_<bookUid>`
  /// prefs（host 本机播放与远端 resume 路径统一写此键空间，见 video_hibiki_page
  /// `_persistPosition` / `_persistRemotePosition`）。
  ///
  /// 向后兼容：TODO-816 之前 host 本机播放只写 `VideoBooks.lastPositionMs`、不写 prefs，
  /// 那部分旧进度在 prefs 里缺失。故 prefs 无记录时回退查 `VideoBooks.lastPositionMs`
  /// （旧数据无独立时间戳记 0），与 prefs 经 [resolvePositionLww] 取较新——既能读
  /// 出旧本机播放进度（client 跨设备恢复），又不让无时间戳的旧值盖过更新的 prefs 进度。
  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    final int prefsPos = await _db.getPrefTyped<int>(
        videoRemotePositionEpisodePrefKey(id, episodeIndex), 0);
    final int prefsAt = await _db.getPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, episodeIndex), 0);
    // 旧 host 本机播放只写 VideoBooks.lastPositionMs（整书一个值，无按集语义）；只在
    // episodeIndex<=0（当前集 / 单视频）回退它，避免给某集错配整书的旧进度。
    final VideoBookRow? row =
        episodeIndex <= 0 ? await _db.getVideoBookByBookUid(id) : null;
    final int rowPos = row?.lastPositionMs ?? 0;
    // BUG-996：lastPositionMs 列无时间戳，此前硬编码 remoteUpdatedAtMs:0，使 host 的真
    // 进度在跨设备 LWW 里恒输给任何带 now 戳的本地断点（client 一旦碰过就再也拉不回
    // host 的桌面新进度）。用 importedAt 作「进度至少和导入一样旧」的可辩护下界戳——
    // client 真更近才看过仍会赢（语义可接受），但 client 无有效断点时 host 能续上。
    final int rowAt = rowPos > 0 ? (row?.importedAt ?? 0) : 0;
    return resolvePositionLww(
      localPositionMs: prefsPos,
      localUpdatedAtMs: prefsAt,
      remotePositionMs: rowPos,
      remoteUpdatedAtMs: rowAt,
    );
  }

  /// 把 client 上报的 [id] 视频断点写入 host（TODO-653）。
  ///
  /// 冲突解决「取较新时间戳」（[resolvePositionLww]）：仅当 [updatedAtMs] 严格
  /// 新于 host 已存时间戳才覆盖，避免旧设备滞后上报回退新进度。负位置 clamp 0。
  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    final ({int positionMs, int updatedAtMs}) current =
        await getVideoPosition(id, episodeIndex: episodeIndex);
    final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
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
        videoRemotePositionEpisodePrefKey(id, episodeIndex), winner.positionMs);
    await _db.setPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, episodeIndex),
        winner.updatedAtMs);
  }

  /// 廉价判断 host 库是否已存在 bookUid 为 [id] 的视频（一次 DB 查询）。
  @override
  Future<bool> videoExists(String id) async {
    _assertSafeVideoId(id);
    return (await _db.getVideoBookByBookUid(id)) != null;
  }

  /// 从 host 视频库删除 bookUid 为 [id] 的视频（[VideoDeletionHost]）。
  ///
  /// 与 host 用户在自己视频库长按删除同语义（镜像 `VideoBookRepository.deleteVideoBook`
  /// + `reclaimDeletedVideoBookAssets`）：DB 行 + 字幕 cue + 合集引用 + 删除墓碑，磁盘侧
  /// **只回收 app 自己拥有的字节**。用户自己导入的原始视频文件绝不删除。
  @override
  Future<void> deleteVideo(String id) async {
    _assertSafeVideoId(id);
    await _runExclusive(() async {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
      if (row == null) return; // 幂等：不存在则静默跳过

      // DB 事务：删 VideoBooks 行 + 本视频的 audio_cues（标签映射经 FK cascade）。
      await _db.deleteVideoBook(id);
      // 统一合集：删条目时清其全部合集引用（逻辑外键无 DB cascade），镜像本地
      // 删除路径，避免留孤儿成员 / 合集卡数量虚高。
      await _db.removeEntryFromAllCollections(MediaKind.video, id);
      // 记删除墓碑：host 的其它已配对设备下次同步会拉到并逐条确认删除，使
      // 「从所有设备删除」在 client→host→其它 client 链路上闭合。best-effort。
      try {
        await _db.writeSyncDeletionTombstone(
          SyncTombstoneKind.video.dbValue,
          id,
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (_) {
        // best-effort：记账失败不影响视频已删。
      }

      // 磁盘回收，两条都只碰「能证明是 app 自己写进来的」字节：
      // ① client 上传副本目录（本 host 自己按 uid 建的，见 importVideo）。
      await _deleteUploadedVideoCopy(row);
      // ② 封面 / 字幕缓存交注入回调（与 deleteBook 的 cleanupBookOnDisk 同构，生产接
      //    VideoBookRepository.reclaimDeletedVideoBookAssets，其内部有「仍在 app 资产
      //    目录内 + 无其它条目引用」双重判据）。
      try {
        await _cleanupVideoOnDisk?.call(row);
      } catch (_) {
        // best-effort：磁盘回收失败不影响 DB 已删。
      }
    });
  }

  /// 删除 client 上传副本目录——当且仅当该行的 `videoPath` 确实落在本 host 的
  /// `<uploadedVideoRoot>/<safeUid>/` 之内。
  ///
  /// host 用户自己导入的原片不在这个目录下，所以这条 [p.isWithin] 判据就是
  /// 「这些字节是 app 自己搬进来的」的证明；判据不成立时一个字节都不动。
  Future<void> _deleteUploadedVideoCopy(VideoBookRow row) async {
    final Directory? root = _uploadedVideoRoot;
    if (root == null) return;
    final Directory owned =
        Directory(p.join(root.path, _sanitizeVideoIdForPath(row.bookUid)));
    if (!owned.existsSync()) return;
    if (!p.isWithin(owned.path, row.videoPath)) return;
    try {
      await owned.delete(recursive: true);
    } catch (_) {
      // best-effort：目录被占用等失败不影响 DB 已删。
    }
  }

  /// 接收 client 上传的单文件视频并注册进 host 视频库（client→host live push）。
  ///
  /// 落盘目录按 [id] 确定（`<uploadedVideoRoot>/<safeUid>/`），故重复上传同一视频
  /// 覆盖同一副本、不留孤儿；`upsertVideoBook` 幂等按 bookUid 覆盖同一行。封面 best-effort
  /// 抽取，与建行解耦（绝不挡上传落库）。
  @override
  Future<void> importVideo(
    File videoFile, {
    required String id,
    required String title,
    String? originalFileName,
  }) async {
    _assertSafeVideoId(id);
    final Directory? root = _uploadedVideoRoot;
    if (root == null) {
      throw UnsupportedError(
        'importVideo requires uploadedVideoRoot to be provided',
      );
    }
    await _runExclusive(() async {
      final String safeUid = _sanitizeVideoIdForPath(id);
      final Directory destDir = Directory(p.join(root.path, safeUid));
      destDir.createSync(recursive: true);
      final File dest = File(
          p.join(destDir.path, _uploadedVideoFileName(originalFileName, id)));
      await _moveFileInto(videoFile, dest);
      await _db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(id),
        title: Value(title),
        videoPath: Value(dest.path),
        // 无外挂字幕上传：回退内嵌默认轨（与 client 下载无字幕分支一致）。
        embeddedSubtitleTrack: const Value<int?>(0),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
    });
    // 封面 best-effort，与建行解耦：抽帧走 ffmpeg 慢，失败留空占位（移动端无 ffmpeg
    // 返 null），绝不让封面失败使整个上传报错。
    final Future<String?> Function(
        {required String videoPath,
        required String bookUid})? extractor = _extractVideoCover;
    if (extractor != null) {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
      if (row != null) {
        try {
          final String? coverPath =
              await extractor(videoPath: row.videoPath, bookUid: id);
          if (coverPath != null && coverPath.isNotEmpty) {
            await _db.updateVideoBookCover(id, coverPath);
          }
        } catch (_) {
          // best-effort：封面失败不影响上传成功。
        }
      }
    }
  }

  /// 接收 client 上传的视频外挂字幕并落到视频同目录（BUG-964，client→host live push）。
  ///
  /// 落盘名 = `<host 视频文件 stem><suffix>`，与 [resolveVideoSubtitle] 的同 stem
  /// 匹配规则天然一致；[suffix] 经 [isSidecarSubtitleSuffix] 白名单校验（拒路径
  /// 分隔符/穿越）。落位后按 host 学习语言重解析首选 sidecar（多字幕推送顺序无关、
  /// 结果收敛），镜像 client 下载路径（home_video_page `_registerDownloadedVideo`）
  /// 的行语义：`subtitleSource`/`subtitleFormat` 指向首选 sidecar、
  /// `embeddedSubtitleTrack=null`（播放走外挂）、解析 cue 落库（坏字幕 best-effort
  /// 跳过，不挡文件落位——host 仍能把字节原样转发给其它 client）。
  @override
  Future<void> importVideoSubtitle(
    File subtitleFile, {
    required String id,
    required String suffix,
  }) async {
    _assertSafeVideoId(id);
    if (!isSidecarSubtitleSuffix(suffix)) {
      throw ArgumentError.value(suffix, 'suffix', 'unsafe subtitle suffix');
    }
    await _runExclusive(() async {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
      if (row == null) throw StateError('unknown video: $id');
      final String videoPath = row.videoPath;
      final String lower = videoPath.toLowerCase();
      if (videoPath.isEmpty ||
          lower.startsWith('http://') ||
          lower.startsWith('https://')) {
        throw StateError('video has no local file: $id');
      }
      final File dest = File(p.join(p.dirname(videoPath),
          '${p.basenameWithoutExtension(videoPath)}$suffix'));
      await _moveFileInto(subtitleFile, dest);
      final String? preferred =
          findSidecarSubtitle(videoPath, langCode: _videoSubtitleLangCode);
      if (preferred == null) return; // 防御：刚落位的 dest 本身就是候选。
      final String ext =
          p.extension(preferred).replaceFirst('.', '').toLowerCase();
      List<AudioCue> cues = const <AudioCue>[];
      try {
        cues = parseSubtitleCues(
          content: await readTextWithEncoding(File(preferred)),
          format: ext,
          bookUid: id,
        );
      } catch (_) {
        // best-effort：解析失败不挡字幕文件落位。
      }
      await _db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(id),
        title: Value(row.title),
        videoPath: Value(row.videoPath),
        subtitleSource: Value<String?>(preferred),
        subtitleFormat: Value<String?>(ext),
        embeddedSubtitleTrack: const Value<int?>(null),
      ));
      if (cues.isNotEmpty) {
        await _db.replaceCuesForBook(
            id, cues.map(AudioCue.toCompanion).toList());
      }
    });
  }

  /// 校验视频 id 不含路径穿越字符（`..` / `\`）。id 允许 `/`（bookUid 形如
  /// `video/xxx`），落盘前经 [_sanitizeVideoIdForPath] 压平。
  static void _assertSafeVideoId(String id) {
    if (id.isEmpty || id.contains('..') || id.contains('\\')) {
      throw ArgumentError.value(id, 'id', 'unsafe video id');
    }
  }

  /// 把视频 id 压成单层安全目录名（`/` → `_`，其余非白名单字符 → `_`）。
  static String _sanitizeVideoIdForPath(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 上传视频落盘文件名：优先保留上传方原始 basename 的扩展名（media_kit 依赖扩展名
  /// 判容器）；basename 缺失/不安全时回退 `<safeUid>.mp4`。
  static String _uploadedVideoFileName(String? originalFileName, String id) {
    if (originalFileName != null && originalFileName.isNotEmpty) {
      final String base = p.basename(originalFileName);
      final String safe = base.replaceAll(RegExp(r'[/\\]'), '_');
      if (safe.isNotEmpty &&
          !safe.contains('..') &&
          p.extension(safe).isNotEmpty) {
        return safe;
      }
    }
    return '${_sanitizeVideoIdForPath(id)}.mp4';
  }

  /// 把 [src] 搬进 [dest]（同卷 rename 最快；跨卷 rename 失败回退 copy + delete）。
  static Future<void> _moveFileInto(File src, File dest) async {
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      await src.copy(dest.path);
      try {
        await src.delete();
      } catch (_) {
        // best-effort：源临时文件删除失败不影响落库（上层临时目录整体清理）。
      }
    }
  }

  // ── 聚合（统计 + 收藏，TODO-1056 phase C）────────────────────────────────────

  /// 读 host 端当前聚合快照。直接复用云后端 phase B 的
  /// [AggregateSyncService.materializeLocalSnapshot]（同一 DB 读取逻辑），保证互联
  /// 与云通道 materialize 结果字节等价、无第二套实现。
  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async {
    return AggregateSyncService(_db).materializeLocalSnapshot();
  }

  /// 把 client 上报的聚合快照折叠进 host DB。用
  /// [AggregateSyncService.foldIntoLocal]（先 materialize host 自己 → MAX / 并集
  /// 合并 incoming → apply），保证 host 侧也满足 never-shrinks：client 上报的某字段
  /// 即便小于 host 当前值（并发 / GET 后 host 又涨），MAX 折叠让 host 值不被缩小；
  /// 幂等（重复 apply 同一快照不变）；删除不跨端传播。经 [_runExclusive] 与其它库
  /// 变动串行，避免与 host 本机写统计/收藏竞态。
  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {
    await _runExclusive(
      () => AggregateSyncService(_db).foldIntoLocal(snapshot),
    );
  }

  // ── 合集清单（多端库联合视图 §2.3 任务5.2）──────────────────────────────────

  /// 读 host 合集全量快照清单。直接复用云后端同一 [loadLocalCollectionManifest]（同一
  /// DB 读取逻辑），保证互联与云通道 materialize 结果字节等价、无第二套实现。
  @override
  Future<CollectionManifest> getCollectionManifest() =>
      loadLocalCollectionManifest(_db);

  /// 把 client 上报的合集清单并入 host DB 并返回合并后清单。
  ///
  /// 与云后端 orchestrator [SyncOrchestrator.syncCollections] 的核心完全同构，仅
  /// 通道不同：`CollectionSyncEngine.merge`（host 自身 `sync_collections_baseline_ms`
  /// 因果基线）→ [applyCollectionLocalChanges] 把本地变更集落 host DB → 推进 host
  /// 基线 → 返回合并后清单（client 端再拿它重跑引擎收敛，双端同一并集）。
  ///
  /// 基线的角色：区分「未见过的移出/删除墓碑」（新闻 → 生效）与「本端已裁决过、
  /// 成员/合集仍在即代表之后重加/重建」（旧闻 → 活胜）。host 每次合并成功后推进基线，
  /// 使已应用的墓碑成为「旧闻」，日后本端或对端重加时不被旧墓碑再删（收敛正确性依赖
  /// 此推进，见 collection_sync_engine 注释）。
  ///
  /// 经 [_runExclusive] 与其它库变动串行：读清单→合并→落库→推基线整体互斥，
  /// 避免与 host 本机合集编辑竞态。重放同一清单幂等（应用端按目标态调和）。
  @override
  Future<CollectionManifest> mergeCollectionManifest(
    CollectionManifest incoming,
  ) async {
    late CollectionManifest merged;
    await _runExclusive(() async {
      final CollectionManifest local = await loadLocalCollectionManifest(_db);
      final SyncRepository repo = SyncRepository(_db);
      final int baseline = await repo.getCollectionsSyncBaselineMs();
      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: local,
        remote: incoming,
        lastSyncedAtMs: baseline,
      );
      await applyCollectionLocalChanges(_db, outcome.changes);
      await repo
          .setCollectionsSyncBaselineMs(DateTime.now().millisecondsSinceEpoch);
      merged = outcome.merged;
    });
    return merged;
  }

  @override
  Future<List<({String mediaType, String itemKey, int deletedAt})>>
      listDeletionTombstones() async {
    final List<SyncDeletionTombstoneRow> rows =
        await _db.getSyncDeletionTombstones();
    return <({String mediaType, String itemKey, int deletedAt})>[
      for (final SyncDeletionTombstoneRow r in rows)
        (mediaType: r.mediaType, itemKey: r.itemKey, deletedAt: r.deletedAt),
    ];
  }
}

import 'dart:io';

import 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_manager.dart' show repackageExtractedEpub;
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
        _audioDatabaseRoot = audioDatabaseRoot;

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
  /// [RemoteBookInfo.hasContent] 为 true 当且仅当 extractDir 非空且目录存在。
  @override
  Future<List<RemoteBookInfo>> listBooks() async {
    final List<EpubBookRow> rows = await _db.getAllEpubBooks();
    return <RemoteBookInfo>[
      for (final EpubBookRow r in rows)
        RemoteBookInfo(
          title: r.title,
          hasContent:
              r.extractDir.isNotEmpty && Directory(r.extractDir).existsSync(),
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
    final EpubBookRow? row = rows.cast<EpubBookRow?>().firstWhere(
          (EpubBookRow? r) => r!.title == title,
          orElse: () => null,
        );
    if (row == null) {
      throw StateError('book not found: $title');
    }
    if (row.extractDir.isEmpty || !Directory(row.extractDir).existsSync()) {
      throw StateError('book has no content: $title');
    }

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_book_export');
    // 文件名用 title 但扩展名用 .epub，保证重导入时 fileName 是合法 epub 名。
    final String safeBasename = '$title.epub';
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
      final EpubBookRow? row = rows.cast<EpubBookRow?>().firstWhere(
            (EpubBookRow? r) => r!.title == title,
            orElse: () => null,
          );
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
  /// 注：本地音频来源的注册信息存于 Preferences（不在 Drift DB），删除应由
  /// 调用方经 LocalAudioManager 处理；此处提供接口占位，实现为 no-op 并记录
  /// 预期行为——T3.4 接线时由 AppModel 覆盖或传入回调。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteLocalAudio(String displayName) async {
    _assertSafeName(displayName);
    // 本地音频注册信息由 LocalAudioManager（Preferences）管理，不在 Drift DB 中，
    // 此基础实现仅做名称安全校验。T3.4 接线时应注入删除回调覆盖此行为。
  }

  // ── 有声书包（T3.1）────────────────────────────────────────────────────────

  /// host 当前有声书清单（从 Audiobooks 表读）。
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    return <RemoteAudiobookInfo>[
      for (final AudiobookRow r in rows)
        RemoteAudiobookInfo(bookKey: r.bookKey),
    ];
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
}

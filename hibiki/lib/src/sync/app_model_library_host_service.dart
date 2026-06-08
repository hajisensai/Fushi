import 'dart:io';

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
/// ## 新增书籍支持（T2.1）构造参数说明
///
/// | 参数 | 用途 | 生产传值 |
/// |---|---|---|
/// | [importBookFromFile] | 把 .epub 导入书库的真实逻辑 | `EpubImporter.importFromPath` |
/// | [cleanupBookOnDisk] | deleteBook 时清理 DB 行以外的磁盘资源（Audiobook persist dir 等） | `ReaderHibikiSource.instance.deleteBook` 磁盘部分 |
///
/// T2 后续接线任务会在 AppModel 初始化时传入真实值。
class AppModelLibraryHostService implements HibikiLibraryHostService {
  AppModelLibraryHostService({
    required HibikiDatabase db,
    required Directory dictionaryResourceRoot,
    required SyncAssetPackageService packages,
    required Future<void> Function() refreshDictionaryCache,
    required Future<void> Function(Future<void> Function() body) runExclusive,
    Future<void> Function(File epubFile)? importBookFromFile,
    Future<void> Function(EpubBookRow row)? cleanupBookOnDisk,
  })  : _db = db,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _packages = packages,
        _refreshDictionaryCache = refreshDictionaryCache,
        _runExclusive = runExclusive,
        _importBookFromFile = importBookFromFile,
        _cleanupBookOnDisk = cleanupBookOnDisk;

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
}

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/epub/pdf_book_layout.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

/// 孤儿书目录里能识别出的书类型（BUG-4701）。
enum OrphanBookKind {
  /// 解压后的 EPUB 树（`META-INF/container.xml`）。
  epub,

  /// 本地漫画（`manga.json` + `images/`）。
  manga,

  /// PDF（`document.pdf`）。
  pdf,
}

/// 孤儿书目录不能重新登记的原因。
enum OrphanBookIssue {
  /// 目录是空的。
  emptyDirectory,

  /// 目录内容不是任何一种已知的书（没有 OPF / manga.json / document.pdf）。
  unrecognizedContent,

  /// 目录名不是有效的 bookKey（不是任何标题经 ッツ 文件名净化后的形态）。
  invalidBookKey,

  /// 旧版（v16 之前）按整数 id 命名的书目录：原 bookKey 已无从还原。
  legacyNumericDirectory,

  /// 导入时同名目录被占用而落到的 `<键>~n` 目录：原 bookKey 已无从还原。
  duplicateSuffixDirectory,

  /// 在线漫画：来源（扩展 / 源 / 作品）只记录在书库行里，目录本身还原不出来。
  onlineManga,

  /// 识别出了类型，但内容读不出来（OPF / manga.json / PDF 损坏）。
  unreadable,
}

/// 一个可以重新登记成书的孤儿目录。
class RecoverableOrphanBook {
  const RecoverableOrphanBook({
    required this.bookKey,
    required this.title,
    required this.directory,
    required this.kind,
    required this.previouslyDeleted,
  });

  /// = 目录名，重新登记后原样作为书库主键。
  final String bookKey;

  /// 由目录名反净化得到的书名（`unsanitizeTtuFilename`）。
  final String title;

  /// 书目录绝对路径（重新登记后的 `extract_dir`）。
  final String directory;

  final OrphanBookKind kind;

  /// 书库里留有这本书的删除墓碑：它是用户删过、但磁盘清理没删掉的书。
  final bool previouslyDeleted;
}

/// 一个不能重新登记的孤儿目录（可删除）。
class UnrecoverableOrphanDirectory {
  const UnrecoverableOrphanDirectory({
    required this.directory,
    required this.issue,
    required this.sizeBytes,
    this.detail,
  });

  final String directory;
  final OrphanBookIssue issue;

  /// 目录占用的字节数（递归、不追 symlink）。
  final int sizeBytes;

  /// [OrphanBookIssue.unreadable] 时的原始错误。
  final String? detail;

  String get name => p.basename(directory);
}

/// 一次扫描的结果。
class OrphanBookScan {
  const OrphanBookScan({
    required this.recoverable,
    required this.unrecoverable,
  });

  final List<RecoverableOrphanBook> recoverable;
  final List<UnrecoverableOrphanDirectory> unrecoverable;

  bool get isEmpty => recoverable.isEmpty && unrecoverable.isEmpty;
}

/// 一次重新登记的结果：成功的 bookKey 与失败的（bookKey → 原因）。
class OrphanBookRestoreResult {
  const OrphanBookRestoreResult({
    required this.restored,
    required this.failures,
  });

  final List<String> restored;
  final Map<String, String> failures;
}

/// 按类型把目录登记成书的入口。生产装配在页面层（`libraryRecoveryRegistrars`，
/// 各导入器的 `register*`）：storage 层不得 import 导入器——`PdfImporter` 的依赖
/// 闭包连到 AppModel（`import_cycle_guard_test`）。测试按需注入。
typedef OrphanBookRegistrar =
    Future<String> Function({
      required FushiDatabase db,
      required String bookKey,
      required String title,
      required String bookDir,
    });

/// 「可恢复的书」：书库根（`fushi_books`）下有目录、书库里却没有对应行的书，
/// 重新登记回书库（BUG-4701）。
///
/// 场景：覆盖导入把整个书库换成了别的库（书库行、进度、统计全没），但书文件树
/// 只有备份里带树时才会被替换，于是本机的书目录原样留在盘上成了孤儿；SRS 卡片
/// 幸存，背面的来源链接按 uid → bookKey 回退找书（`card_source_router.dart`）。
/// 本地书的目录名就是 bookKey（`EpubStorage.bookDirectory`），所以**以目录名为
/// bookKey 重新登记**，卡片来源就重新连上。uid 是导入时新生成的（旧 uid 已随旧库
/// 丢失），阅读进度、书签、统计无法从目录恢复——那些只在覆盖导入前的快照里（见
/// `BackupRestoreService.mergeFromOverwriteSnapshot`）。
///
/// 扫描范围只有书库根 `fushi_books` 的直接子目录：
/// - 有声书目录（`audiobooks/<fnv1a(bookKey)>`）是 bookKey 的单向哈希，还原不出
///   书，且有声书行挂在书上，不单独登记；
/// - 在线漫画的来源身份只在书库行里，目录还原不出来，列为不可恢复（下载根里的
///   在线漫画由下载任务页的「漫画重新入库」负责，那里有侧车记录来源）。
///
/// 元数据一律复用导入器的解析与行构造（`EpubImporter.registerExtractedBook` /
/// `MangaImporter.registerExistingBookDir` / `PdfImporter.registerExistingBookDir`，
/// 由调用方经 [OrphanBookRegistrar] 注入），不另写一套。
class OrphanBookRecovery {
  OrphanBookRecovery({
    required this.database,
    required this.booksRoot,
    required Map<OrphanBookKind, OrphanBookRegistrar> registrars,
  }) : _registrars = registrars;

  final FushiDatabase database;

  /// 书库根绝对路径（`<documents>/fushi_books`）。
  final String booksRoot;

  final Map<OrphanBookKind, OrphanBookRegistrar> _registrars;

  /// 以生产书库根构造。
  static Future<OrphanBookRecovery> forApp(
    FushiDatabase database, {
    required Map<OrphanBookKind, OrphanBookRegistrar> registrars,
  }) async => OrphanBookRecovery(
    database: database,
    booksRoot: await EpubStorage.baseDirectory(),
    registrars: registrars,
  );

  /// 在线漫画书目录名：`<runtime>-<sha256 前 32 位 hex>`
  /// （`OnlineMangaLibraryService.bookKeyFor`，逐字节冻结）。
  static final RegExp _onlineMangaKey = RegExp(
    r'^(mihon|aidoku|interconnect|web)-[0-9a-f]{32}$',
  );

  static final RegExp _numericName = RegExp(r'^\d+$');

  /// `EpubImporter.moveExtractedDirIntoPlace` 在目标目录被占用时落到的 `~n` 后缀。
  static final RegExp _duplicateSuffix = RegExp(r'~\d+$');

  /// 扫描书库根，列出可恢复 / 不可恢复的孤儿目录。点开头的目录（导入暂存
  /// `.tmp-*`、缓存）一律不列。
  ///
  /// 列目录之前先收一遍导入残留（[EpubStorage.sweepImportResidue]，BUG-4841）：
  /// `<书>.bak-<ts>` 不是点开头，不先处置就会被当成一本名叫「xxx.bak-123」的孤儿书
  /// 列出来；而替换到一半被杀时它是那本书唯一的副本——清扫把它改回原名，随后才能
  /// 以正确的 bookKey 列为可找回。本进程正在进行的导入的暂存目录清扫不碰。
  Future<OrphanBookScan> scan() async {
    final Directory root = Directory(booksRoot);
    if (!await root.exists()) {
      return const OrphanBookScan(
        recoverable: <RecoverableOrphanBook>[],
        unrecoverable: <UnrecoverableOrphanDirectory>[],
      );
    }
    final List<EpubBookMeta> books = await database.getEpubBookMetas();
    await EpubStorage.sweepImportResidue(
      booksRoot: booksRoot,
      liveExtractDirs: books.map((EpubBookMeta b) => b.extractDir),
    );
    final Set<String> liveKeys = <String>{
      for (final EpubBookMeta b in books) b.bookKey,
    };
    final List<String> liveDirs = <String>[
      for (final EpubBookMeta b in books)
        if (b.extractDir.isNotEmpty) p.normalize(b.extractDir),
    ];
    final Set<String> tombstoned = (await database.getBookTombstoneKeys())
        .toSet();

    final List<RecoverableOrphanBook> recoverable = <RecoverableOrphanBook>[];
    final List<UnrecoverableOrphanDirectory> unrecoverable =
        <UnrecoverableOrphanDirectory>[];
    final List<Directory> dirs = <Directory>[
      await for (final FileSystemEntity e in root.list(followLinks: false))
        if (e is Directory) e,
    ]..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    for (final Directory dir in dirs) {
      final String name = p.basename(dir.path);
      if (name.startsWith('.')) continue;
      if (liveKeys.contains(name)) continue;
      if (liveDirs.any((String live) => p.equals(live, dir.path))) continue;

      Future<void> reject(OrphanBookIssue issue, {String? detail}) async {
        unrecoverable.add(
          UnrecoverableOrphanDirectory(
            directory: dir.path,
            issue: issue,
            sizeBytes: await _directorySize(dir),
            detail: detail,
          ),
        );
      }

      final OrphanBookKind? kind;
      try {
        kind = await _detectKind(dir, name);
      } on _OnlineMangaDirectory {
        await reject(OrphanBookIssue.onlineManga);
        continue;
      } on _EmptyDirectory {
        await reject(OrphanBookIssue.emptyDirectory);
        continue;
      }
      if (kind == null) {
        await reject(OrphanBookIssue.unrecognizedContent);
        continue;
      }
      final String title = unsanitizeTtuFilename(name);
      if (sanitizeTtuFilename(title) != name) {
        await reject(OrphanBookIssue.invalidBookKey);
        continue;
      }
      // 纯数字 / `~n` 后缀的目录名本身也能是合法 bookKey（书名就叫「1984」）。只有
      // EPUB 能拿自带标题核对：OPF 标题净化后正好等于目录名才认；漫画 / PDF 目录里
      // 没有标题可核对，一律不认。
      final bool numeric = _numericName.hasMatch(name);
      final bool suffixed = _duplicateSuffix.hasMatch(name);
      if (numeric || suffixed) {
        bool confirmed = false;
        if (kind == OrphanBookKind.epub) {
          try {
            confirmed =
                sanitizeTtuFilename(
                  await EpubImporter.readExtractedTitle(dir.path),
                ) ==
                name;
          } catch (e) {
            await reject(OrphanBookIssue.unreadable, detail: '$e');
            continue;
          }
        }
        if (!confirmed) {
          await reject(
            numeric
                ? OrphanBookIssue.legacyNumericDirectory
                : OrphanBookIssue.duplicateSuffixDirectory,
          );
          continue;
        }
      }
      recoverable.add(
        RecoverableOrphanBook(
          bookKey: name,
          title: title,
          directory: dir.path,
          kind: kind,
          previouslyDeleted: tombstoned.contains(name),
        ),
      );
    }
    return OrphanBookScan(
      recoverable: recoverable,
      unrecoverable: unrecoverable,
    );
  }

  /// 按目录内容判类型；在线漫画 / 空目录用私有异常带出。
  Future<OrphanBookKind?> _detectKind(Directory dir, String name) async {
    bool has(String rel) =>
        FileSystemEntity.typeSync(p.join(dir.path, rel), followLinks: false) !=
        FileSystemEntityType.notFound;
    if (has(p.join('META-INF', 'container.xml'))) return OrphanBookKind.epub;
    if (has(MangaStorage.kMangaJsonFileName)) {
      if (_onlineMangaKey.hasMatch(name) || has('chapters')) {
        throw const _OnlineMangaDirectory();
      }
      return OrphanBookKind.manga;
    }
    if (has(PdfBookLayout.pdfFileName)) return OrphanBookKind.pdf;
    if (_onlineMangaKey.hasMatch(name)) throw const _OnlineMangaDirectory();
    if (await dir.list(followLinks: false).isEmpty) {
      throw const _EmptyDirectory();
    }
    return null;
  }

  /// 把 [books] 逐本重新登记（bookKey = 目录名）。单本失败（内容损坏、扫描后
  /// 同键已被别的导入占用…）不中止整批，原因收进结果。
  Future<OrphanBookRestoreResult> restore(
    List<RecoverableOrphanBook> books,
  ) async {
    final List<String> restored = <String>[];
    final Map<String, String> failures = <String, String>{};
    for (final RecoverableOrphanBook book in books) {
      try {
        if (await database.getEpubBook(book.bookKey) != null) {
          throw StateError('bookKey already exists: ${book.bookKey}');
        }
        final OrphanBookRegistrar register = _registrars[book.kind]!;
        restored.add(
          await register(
            db: database,
            bookKey: book.bookKey,
            title: book.title,
            bookDir: book.directory,
          ),
        );
      } catch (e) {
        failures[book.bookKey] = '$e';
      }
    }
    return OrphanBookRestoreResult(restored: restored, failures: failures);
  }

  /// 删除一个孤儿目录（只允许书库根的直接子目录，且不能是任何书的 `extract_dir`）。
  Future<void> deleteDirectory(String directory) async {
    if (!p.equals(p.dirname(directory), booksRoot)) {
      throw ArgumentError.value(directory, 'directory', 'not under books root');
    }
    final String name = p.basename(directory);
    if (await database.getEpubBook(name) != null) {
      throw StateError('directory belongs to a live book: $directory');
    }
    final List<EpubBookMeta> books = await database.getEpubBookMetas();
    if (books.any((EpubBookMeta b) => p.equals(b.extractDir, directory))) {
      throw StateError('directory belongs to a live book: $directory');
    }
    await EpubStorage.deleteBookDir(directory);
  }

  static Future<int> _directorySize(Directory dir) async {
    int total = 0;
    try {
      await for (final FileSystemEntity e in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (e is File) total += await e.length();
      }
    } on FileSystemException {
      // 读不全就报读到的部分：只用于展示。
    }
    return total;
  }
}

class _OnlineMangaDirectory implements Exception {
  const _OnlineMangaDirectory();
}

class _EmptyDirectory implements Exception {
  const _EmptyDirectory();
}

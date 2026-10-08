/// 离线导入命令：`import epub|manga|text|auto` 与 `books backfill-isbn`。
///
/// ```
/// fushi_server import epub  <file.epub|dir…>                       [--json]
/// fushi_server import manga <dir|archive|.mokuro|manga.json…> [--title t] [--json]
/// fushi_server import text  <file.txt…> [--title t] [--author a]  [--json]
/// fushi_server import auto  <path…>                                [--json]
/// fushi_server books backfill-isbn                                 [--json]
/// ```
///
/// 落库形态与服务端库扫描（`library_scanner.dart`）、代下载按域入库
/// （`discovery_import_host.dart`）一致：调的是同一批引擎导入原语，只是**不带
/// `sourceId`**——命令行导入等价于 app 里的手动导入，不属于任何库根，也就不会被
/// 库根对账回收。重复条目一律 `DuplicatePolicy.skip()`（批量后台，不交互）：同名已在库
/// 即跳过并如实报 `skipped`。
///
/// 已知边界（不是本命令能修的）：
/// - PDF：引擎没有纯 Dart 的 PDF 导入（`PdfImporter` 靠 pdfrx 插件栅格化封面），
///   与代下载同口径以 `unsupportedOnThisHost` 报失败，不假装导入了。
/// - `import auto` 对 zip / rar / 7z 小说包沿用代下载执行器的行为：解到**压缩包旁**
///   的同名目录再分类（执行器为下载目录设计，会在输入目录里留下解压产物）。
/// - 7z / rar 需要 7-Zip 命令行（`FUSHI_7ZA` / 可执行文件旁 / PATH），找不到时
///   rar 漫画包报 `archiveToolMissing`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_audio/fushi_audio_core.dart' show AudiobookStorage;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_isbn_backfill.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart' show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/discovery_models.dart' show DiscoveryMediaKind;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart' show listEpubSourceFiles;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart' show kMangaOcrOutDirName, kMangaOcrOutputFileName;
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/discovery_import_host.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const String kImportUsage = '''
import epub  <file.epub|dir…>                          导入 EPUB（目录 = 递归收其中全部 .epub）
import manga <dir|archive|.mokuro|manga.json…> [--title t]
                                                     导入漫画（mokuro 卷 / 纯页图目录 / cbz·zip·cbr·rar·cb7 / 纯图 EPUB）
import text  <file.txt…> [--title t] [--author a]     文本（txt/md/html…）转 EPUB 后入库
import auto  <path…>                                  按扩展名 / 目录内容分域入库（书 / 漫画 / 有声书）
books backfill-isbn                                  给缺 ISBN 的存量 EPUB 回填 ISBN
（以上都支持 --json；重复条目跳过不报错）''';

/// 漫画图包载体（与 `MangaArchiveImporter.importArchive` 能吃的格式一致；`.7z` 不在内：
/// 它只认 ZIP 容器 + 7-Zip 处理的 rar/cbr/cb7）。
const Set<String> _kMangaArchiveExtensions = <String>{'.cbz', '.zip', '.cbr', '.rar', '.cb7'};

/// `import auto` 的分域结果。
enum AutoImportKind {
  /// 书（EPUB / 文本 / PDF / 需要先解压的小说包）→ 执行器 novel 域。
  novel,

  /// 有声书（正文 + 字幕 + 音频）→ 执行器 audiobook 域（对齐落库）。
  audiobook,

  /// 漫画图包（cbz / cbr / cb7 / 图片 zip·rar）→ 执行器 manga 域。
  mangaArchive,

  /// 本地漫画卷（`.mokuro` / `manga.json` / 纯页图目录 / 纯图 EPUB）→ 同 `import manga`。
  mangaLocal,

  /// 认不出。
  unsupported,
}

class AutoImportRoute {
  const AutoImportRoute(this.kind, {this.files = const <String>[], this.reason});

  final AutoImportKind kind;

  /// 目录输入时递归枚举出的文件（交给执行器的 `importPaths`）；单文件输入为空。
  final List<String> files;

  /// [AutoImportKind.unsupported] 的原因。
  final String? reason;
}

String _ext(String path) => p.extension(path).toLowerCase();

bool _isText(String path) {
  final String ext = _ext(path);
  return ext.isNotEmpty && TextToEpub.supportedExtensions.contains(ext.substring(1));
}

bool _isMangaJson(String path) => p.basename(path).toLowerCase() == kMangaOcrOutputFileName;

/// `import auto` 的分域判据（只读文件系统，不落库；单测直接调）。
///
/// 单文件按扩展名；zip / rar / epub 先看包里是不是纯图（`looksLikeImageArchive`，
/// 与漫画导入同一判据）。目录按内容，优先级：有音频 → 有声书；有 `.mokuro` →
/// 漫画卷；有漫画图包 → 漫画；有 EPUB / 文本 / PDF → 书；有页图目录 → 漫画卷；
/// 只剩 zip / rar / 7z → 书（执行器解开再分类）。书优先于页图是因为小说目录里常带
/// 封面图，而漫画目录里很少混正文。
AutoImportRoute routeAutoImport(String path) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.directory) {
    final List<String> files = <String>[
      for (final FileSystemEntity e in Directory(path).listSync(recursive: true, followLinks: false))
        if (e is File && !p.split(p.relative(e.path, from: path)).contains(kMangaOcrOutDirName)) e.path,
    ]..sort();
    if (files.isEmpty) return const AutoImportRoute(AutoImportKind.unsupported, reason: '空目录');
    if (files.any((String f) => AudiobookStorage.audioExtensions.contains(_ext(f)))) {
      return AutoImportRoute(AutoImportKind.audiobook, files: files);
    }
    if (files.any((String f) => _ext(f) == '.mokuro' || _isMangaJson(f))) {
      return const AutoImportRoute(AutoImportKind.mangaLocal);
    }
    if (files.any((String f) => const <String>{'.cbz', '.cbr', '.cb7'}.contains(_ext(f)))) {
      return AutoImportRoute(AutoImportKind.mangaArchive, files: files);
    }
    if (files.any((String f) => _ext(f) == '.epub' || _ext(f) == '.pdf' || _isText(f))) {
      return AutoImportRoute(AutoImportKind.novel, files: files);
    }
    if (!planMangaFoldersInDirectory(Directory(path)).isEmpty) {
      return const AutoImportRoute(AutoImportKind.mangaLocal);
    }
    if (files.any(isDiscoveryArchivePath)) return AutoImportRoute(AutoImportKind.novel, files: files);
    return const AutoImportRoute(AutoImportKind.unsupported, reason: '目录里没有可导入的书 / 漫画 / 有声书');
  }
  final String ext = _ext(path);
  if (ext == '.mokuro' || _isMangaJson(path)) return const AutoImportRoute(AutoImportKind.mangaLocal);
  if (const <String>{'.cbz', '.cbr', '.cb7'}.contains(ext)) return const AutoImportRoute(AutoImportKind.mangaArchive);
  if (ext == '.epub') {
    return MangaArchiveImporter.looksLikeImageArchive(path)
        ? const AutoImportRoute(AutoImportKind.mangaLocal)
        : const AutoImportRoute(AutoImportKind.novel);
  }
  if (ext == '.zip' || ext == '.rar') {
    return MangaArchiveImporter.looksLikeImageArchive(path)
        ? const AutoImportRoute(AutoImportKind.mangaArchive)
        : const AutoImportRoute(AutoImportKind.novel);
  }
  if (ext == '.7z' || ext == '.pdf' || _isText(path)) return const AutoImportRoute(AutoImportKind.novel);
  if (AudiobookStorage.audioExtensions.contains(ext) || kDiscoverySubtitleExtensions.contains(ext)) {
    // 单个音频 / 字幕凑不齐有声书三件套：交给执行器按缺哪样给出稳定原因码。
    return const AutoImportRoute(AutoImportKind.audiobook);
  }
  return AutoImportRoute(AutoImportKind.unsupported, reason: '认不出的文件类型 ${ext.isEmpty ? '(无扩展名)' : ext}');
}

/// 一个输入（或输入展开出的一卷）的导入结果。
class ImportItem {
  ImportItem({required this.path, required this.domain});

  final String path;

  /// `book` / `manga` / `audiobook`；认不出时 `unknown`。
  final String domain;

  /// `imported` / `skipped`（同名已在库）/ `failed`。
  String status = 'failed';
  final List<String> bookKeys = <String>[];
  String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'domain': domain,
    'status': status,
    'bookKeys': bookKeys,
    if (error != null) 'error': error,
  };
}

/// 一次 import 命令的执行器：持有数据库与日志，按域调引擎导入原语。
class _Importer {
  _Importer(this.db, this.log, this.err)
    : _executor = DiscoveryImportExecutor(importers: buildServerDiscoveryImporters(db));

  final FushiDatabase db;
  final ServerLog log;
  final StringSink err;
  final DiscoveryImportExecutor _executor;

  /// 跑一个导入动作，把「返回 key / 返回 null（重复）/ 抛业务异常」统一落进 [item]。
  Future<ImportItem> _run(ImportItem item, Future<List<String>?> Function() action) async {
    err.writeln('导入 ${item.domain}: ${item.path}');
    try {
      final List<String>? keys = await action();
      if (keys == null || keys.isEmpty) {
        item.status = 'skipped';
      } else {
        item
          ..status = 'imported'
          ..bookKeys.addAll(keys);
      }
    } on DuplicateImportCancelledException {
      item.status = 'skipped';
    } on DiscoveryImportBlockedException catch (e) {
      item.error = e.detail == null ? e.blocker.name : '${e.blocker.name}: ${e.detail}';
    } on Exception catch (e, stack) {
      item.error = '$e';
      log.log('cli.import(${item.path})', e, stack);
    }
    return item;
  }

  static List<String>? _one(String? key) => key == null ? null : <String>[key];

  Future<List<ImportItem>> epub(String path) async {
    final List<String> files = FileSystemEntity.isDirectorySync(path)
        ? await listEpubSourceFiles(Directory(path))
        : <String>[path];
    if (files.isEmpty) {
      return <ImportItem>[ImportItem(path: path, domain: 'book')..error = '目录里没有 .epub'];
    }
    return <ImportItem>[
      for (final String file in files)
        await _run(ImportItem(path: file, domain: 'book'), () async => _one(await importDiscoveryEpub(db, file))),
    ];
  }

  Future<ImportItem> text(String path, {String? title, String? author}) =>
      _run(ImportItem(path: path, domain: 'book'), () async {
        if (title == null && author == null) return _one(await importDiscoveryText(db, path));
        // 与 `importDiscoveryText` 同路（TextToEpub → EpubImporter.import），只多了
        // 用户给定的标题 / 作者。
        final String effectiveTitle = title ?? discoveryImportStem(path);
        final Uint8List bytes = await TextToEpub.convert(file: File(path), title: effectiveTitle, author: author);
        return _one(
          await EpubImporter.import(
            db: db,
            bytes: bytes,
            fileName: '$effectiveTitle.epub',
            policy: const DuplicatePolicy.skip(),
          ),
        );
      });

  /// 漫画：目录 = 引擎归组出的每个 `.mokuro` 卷 / 纯页图卷各一行（与库扫描同口径），
  /// 再加目录里的图包与 `manga.json`；单文件按格式分派。[title] 只在恰好一卷时生效。
  Future<List<ImportItem>> manga(String path, {String? title}) async {
    if (!FileSystemEntity.isDirectorySync(path)) {
      return <ImportItem>[await _mangaFile(path, title: title)];
    }
    final MangaFolderPlan plan = planMangaFoldersInDirectory(Directory(path));
    final List<String> extras = <String>[
      for (final FileSystemEntity e in Directory(path).listSync(recursive: true, followLinks: false))
        if (e is File &&
            (_kMangaArchiveExtensions.contains(_ext(e.path)) || _isMangaJson(e.path)) &&
            !p.split(p.relative(e.path, from: path)).contains(kMangaOcrOutDirName))
          e.path,
    ]..sort();
    // `<目录>/manga_ocr_out/manga.json` 是对本目录跑 OCR 的产物：页 url 相对本目录。
    final File ocrOut = File(p.join(path, kMangaOcrOutDirName, kMangaOcrOutputFileName));
    final int volumes =
        plan.mokuroPaths.length + plan.imageFolders.length + extras.length + (ocrOut.existsSync() ? 1 : 0);
    if (volumes == 0) {
      return <ImportItem>[ImportItem(path: path, domain: 'manga')..error = '目录里没有可导入的漫画卷'];
    }
    if (title != null && volumes > 1) {
      err.writeln('目录里有 $volumes 卷，--title 只对单卷生效，已忽略');
    }
    final String? single = volumes == 1 ? title : null;
    final List<ImportItem> items = <ImportItem>[];
    if (ocrOut.existsSync()) {
      // 有 OCR 产物时本目录就是一卷（页图目录 + 文字层），不再把页图目录另导一遍。
      items.add(await _mangaFile(ocrOut.path, title: single ?? p.basename(path)));
      return items;
    }
    for (final String mokuro in plan.mokuroPaths) {
      items.add(await _mangaFile(mokuro, title: single));
    }
    for (final String folder in plan.imageFolders) {
      items.add(
        await _run(
          ImportItem(path: folder, domain: 'manga'),
          () async => _one(
            await MangaImporter.importFromImageFolder(
              db: db,
              imageDirPath: folder,
              title: single ?? p.basename(folder),
              policy: const DuplicatePolicy.skip(),
            ),
          ),
        ),
      );
    }
    for (final String file in extras) {
      items.add(await _mangaFile(file, title: single));
    }
    return items;
  }

  Future<ImportItem> _mangaFile(String path, {String? title}) {
    final ImportItem item = ImportItem(path: path, domain: 'manga');
    final String ext = _ext(path);
    if (ext == '.mokuro') {
      return _run(
        item,
        () async => _one(
          await MangaImporter.importFromMokuroPath(
            db: db,
            mokuroPath: path,
            title: title,
            policy: const DuplicatePolicy.skip(),
          ),
        ),
      );
    }
    if (_isMangaJson(path)) {
      // OCR 产物落在 `<页图目录>/manga_ocr_out/manga.json`，页 url 相对页图目录。
      final Directory parent = File(path).parent;
      final String imageRoot = p.basename(parent.path) == kMangaOcrOutDirName ? parent.parent.path : parent.path;
      return _run(
        item,
        () async => _one(
          await MangaImporter.importFromMangaJson(
            db: db,
            mangaJsonPath: path,
            imageRootPath: imageRoot,
            title: title ?? p.basename(imageRoot),
            policy: const DuplicatePolicy.skip(),
          ),
        ),
      );
    }
    if (_kMangaArchiveExtensions.contains(ext) || ext == '.epub') {
      return _run(
        item,
        () async => _one(
          await MangaArchiveImporter.importArchive(
            db: db,
            archivePath: path,
            title: title ?? discoveryImportStem(path),
            policy: const DuplicatePolicy.skip(),
          ),
        ),
      );
    }
    item.error = '不是漫画卷（只收目录 / .mokuro / manga.json / cbz·zip·cbr·rar·cb7 / 纯图 EPUB）';
    return Future<ImportItem>.value(item);
  }

  Future<List<ImportItem>> auto(String path) async {
    final AutoImportRoute route = routeAutoImport(path);
    switch (route.kind) {
      case AutoImportKind.mangaLocal:
        return manga(path);
      case AutoImportKind.unsupported:
        return <ImportItem>[ImportItem(path: path, domain: 'unknown')..error = route.reason];
      case AutoImportKind.novel:
        return <ImportItem>[await _executorImport(path, DiscoveryMediaKind.novel, 'book', route.files)];
      case AutoImportKind.audiobook:
        return <ImportItem>[await _executorImport(path, DiscoveryMediaKind.audiobook, 'audiobook', route.files)];
      case AutoImportKind.mangaArchive:
        return <ImportItem>[await _executorImport(path, DiscoveryMediaKind.manga, 'manga', route.files)];
    }
  }

  /// 交给代下载同一个执行器（分类 → 需要时解压 → 域原语）。产出多本时 summary 是
  /// 「key / key」拼起来的，原样拆回 bookKey 列表。
  Future<ImportItem> _executorImport(String path, DiscoveryMediaKind kind, String domain, List<String> files) =>
      _run(ImportItem(path: path, domain: domain), () async {
        final DiscoveryImportOutcome outcome = files.isEmpty
            ? await _executor.importFile(kind, File(path))
            : await _executor.importPaths(kind, files);
        if (outcome.importedCount == 0) return null;
        final String? summary = outcome.summary;
        return summary == null ? <String>[] : summary.split(' / ');
      });
}

class ImportCommands extends CliModule {
  const ImportCommands({CommandIo io = const CommandIo()}) : _io = io;

  final CommandIo _io;

  @override
  List<String> get commands => const <String>['import', 'books'];

  @override
  void register(ArgParser parser) {
    final ArgParser import = parser.addCommand('import');
    addJsonFlag(import.addCommand('epub'));
    addJsonFlag(import.addCommand('manga')).addOption('title', help: '卷标题（只对单卷生效）');
    addJsonFlag(import.addCommand('text'))
      ..addOption('title', help: '书名（缺省取文件名）')
      ..addOption('author', help: '作者');
    addJsonFlag(import.addCommand('auto'));
    addJsonFlag(parser.addCommand('books').addCommand('backfill-isbn'));
  }

  @override
  String get usage => kImportUsage;

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final ArgResults? leaf = command.command;
    if (name == 'books') {
      if (leaf == null) return _io.usage('缺少子命令', 'books backfill-isbn [--json]');
      return ctx.withRuntime((ServerRuntime rt) => _backfillIsbn(rt, json: wantsJson(leaf)));
    }
    if (leaf == null) return _io.usage('缺少子命令', 'import epub|manga|text|auto <path…> [--json]');
    return _import(leaf, ctx);
  }

  Future<int> _import(ArgResults leaf, CliContext ctx) async {
    final String sub = leaf.name!;
    final String usageLine = switch (sub) {
      'epub' => 'import epub <file.epub|dir…> [--json]',
      'manga' => 'import manga <dir|archive|.mokuro|manga.json…> [--title t] [--json]',
      'text' => 'import text <file.txt…> [--title t] [--author a] [--json]',
      _ => 'import auto <path…> [--json]',
    };
    if (leaf.rest.isEmpty) return _io.usage('缺少输入路径', usageLine);
    final List<String> paths = <String>[for (final String raw in leaf.rest) p.normalize(p.absolute(raw))];
    final String? title = leaf.options.contains('title') ? leaf['title'] as String? : null;
    final String? author = leaf.options.contains('author') ? leaf['author'] as String? : null;
    if (title != null && paths.length != 1) return _io.usage('--title 只能配一个输入', usageLine);
    final List<String> missing = <String>[
      for (final String path in paths)
        if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) path,
    ];
    if (missing.isNotEmpty) {
      for (final String path in missing) {
        _io.err.writeln('找不到: $path');
      }
      return kExitNoInput;
    }
    if (sub == 'epub') {
      for (final String path in paths) {
        if (!FileSystemEntity.isDirectorySync(path) && _ext(path) != '.epub') {
          return _io.usage('不是 .epub: $path', usageLine);
        }
      }
    }
    if (sub == 'text') {
      for (final String path in paths) {
        if (FileSystemEntity.isDirectorySync(path) || !TextToEpub.isSupported(path)) {
          return _io.usage('不支持的文本格式: $path（支持 ${TextToEpub.supportedExtensions.join(' / ')}）', usageLine);
        }
      }
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      final _Importer importer = _Importer(rt.db, rt.log, _io.err);
      final List<ImportItem> items = <ImportItem>[];
      for (final String path in paths) {
        switch (sub) {
          case 'epub':
            items.addAll(await importer.epub(path));
          case 'manga':
            items.addAll(await importer.manga(path, title: title));
          case 'text':
            items.add(await importer.text(path, title: title, author: author));
          default:
            items.addAll(await importer.auto(path));
        }
      }
      return _report(items, json: wantsJson(leaf));
    });
  }

  int _report(List<ImportItem> items, {required bool json}) {
    int count(String status) => items.where((ImportItem i) => i.status == status).length;
    final int imported = count('imported');
    final int skipped = count('skipped');
    final int failed = count('failed');
    if (json) {
      _io.json(<String, Object?>{
        'imported': imported,
        'skipped': skipped,
        'failed': failed,
        'items': <Map<String, Object?>>[for (final ImportItem i in items) i.toJson()],
      });
    } else {
      for (final ImportItem i in items) {
        switch (i.status) {
          case 'imported':
            _io.out.writeln('imported  ${i.bookKeys.join(', ')}  ← ${i.path}');
          case 'skipped':
            _io.out.writeln('skipped   （同名已在库）${i.path}');
          default:
            _io.out.writeln('failed    ${i.path}: ${i.error}');
        }
      }
      _io.out.writeln('导入完成: +$imported, 跳过 $skipped, 失败 $failed');
    }
    return failed == 0 ? kExitOk : kExitFailure;
  }

  Future<int> _backfillIsbn(ServerRuntime rt, {required bool json}) async {
    final int written = await backfillEpubIsbns(rt.db);
    if (json) {
      _io.json(<String, Object?>{'written': written});
    } else {
      _io.out.writeln('已回填 ISBN: $written 本');
    }
    return kExitOk;
  }
}

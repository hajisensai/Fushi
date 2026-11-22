/// 「一个压缩包里装着一批书」的定性与导入：书架导入框与桌面拖放共用（拍板 83Fe7zQbhv）。
///
/// - **预判**（[looksLikeBookArchive]）：按包里**装的是什么**判，不只看扩展名。`.zip`
///   读中央目录的条目名（不解包，后台 isolate）；`.rar` 经 7-Zip 命令行列目录。`.7z`
///   与分卷第一卷（`book.7z.001` / `book.zip.001`）的条目表可能加密、或第一卷本身不是
///   完整的包，列不出名字；`.rar` 列目录失败（条目表加密、7-Zip 起不来）同理。列不出
///   名字的包**不按扩展名猜**是书还是漫画，交给导入这一步「解开一次、按解出来的内容定性」。
/// - **导入**（[BookArchiveImporter]）：解包走导入链路唯一的解包点 [ArchiveUnpacker]
///   （加密包经口令提供方要口令、分卷自动拼），只解书（[kBookArchiveMemberExtensions]）与
///   页图（[kBookArchivePageImageExtensions]）进书库根下的暂存目录，解开后按内容定性：
///   - 有书（[bookArchiveNamesHaveBooks]）→ 逐本交给与发现页下载同一份的域导入原语
///     （`importDiscoveryEpub` / `importDiscoveryText` / PDF），同名已在库即跳过，暂存用完即删；
///   - 只有页图 → 一卷漫画：解出的目录原样记进 [BookArchiveImportSummary.mangaHandoffs]，
///     由 UI 交给既有的漫画导入（页图目录导入）——不再解第二次；
///   - 都没有 → 如实报「包里没有书」。
///   一包多本的结果收成一份 [BookArchiveImportSummary]，由 UI 一次性展示。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/utils/archive/archive_unpacker.dart';
import 'package:fushi_engine/utils/archive/archive_volumes.dart';

/// 包里算「一本书」的条目扩展名（带点、小写）。
///
/// 刻意比书籍导入框能转的文本类（`TextToEpub.supportedExtensions`）窄：小说合集里常夹着
/// `readme.html`、`info.json`、`.url` 之类的附件，把它们一并转成书只会往书架塞垃圾。
/// 这里只认明确是一本书的三种：EPUB、PDF、TXT。
const Set<String> kBookArchiveMemberExtensions = <String>{
  '.epub',
  '.pdf',
  '.txt',
};

/// 可能装着一批书的压缩包扩展名（带点、小写）。分卷第一卷另由
/// [isFirstSplitArchiveVolume] 认。
const Set<String> kBookArchiveContainerExtensions = <String>{
  '.zip',
  '.7z',
  '.rar',
};

/// 条目名列得出来、能先看名字再定性的压缩包扩展名（带点、小写）。
const Set<String> kBookArchiveNameProbeExtensions = <String>{'.zip', '.rar'};

/// 解包时随书一起解出、用来认「这是一卷漫画」的页图扩展名（带点、小写）。
const Set<String> kBookArchivePageImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.avif',
  '.jxl',
};

String _ext(String path) => p.extension(path).toLowerCase();

/// [path] 是不是可能装着一批书的压缩包（扩展名层面，不开包）。
bool isBookArchiveContainerPath(String path) =>
    kBookArchiveContainerExtensions.contains(_ext(path)) ||
    isFirstSplitArchiveVolume(path);

/// [path] 只能解开后再定性（`.7z` 条目表可能加密；分卷第一卷不是完整的包）。
/// `.rar` 列目录失败时也落到同一条「解开再定性」的路上，见 [looksLikeBookArchive]。
bool isBookArchiveDecidedAfterUnpack(String path) =>
    _ext(path) == '.7z' || isFirstSplitArchiveVolume(path);

/// 包内条目 [entryPath]（相对路径，`/` 或 `\` 分隔）是不是一本书。
///
/// macOS 打包留下的 `__MACOSX/` 目录与 `._name` 资源叉文件不算：它们和真书同扩展名，
/// 却只是几百字节的元数据，导进来是一本打不开的「书」。
bool isBookArchiveMember(String entryPath) {
  final List<String> segments = entryPath.replaceAll('\\', '/').split('/');
  if (segments.contains('__MACOSX')) return false;
  final String base = segments.last;
  if (base.isEmpty || base.startsWith('._')) return false;
  return kBookArchiveMemberExtensions.contains(_ext(base));
}

/// 按条目名判断一个包是不是「一批书」。
///
/// - Yomitan 词典包（`index.json` + `*_bank_*.json`）一票否决：词典页的落点行为不变。
/// - 有 EPUB / PDF → 书。
/// - 只有 TXT 时，TXT 不少于页图才算书：一卷漫画包里随手夹一份 `readme.txt` 很常见，
///   不能因此把几百张页图的漫画当成一本书导；小说合集带一两张封面图则仍是书。
bool bookArchiveNamesHaveBooks(Iterable<String> entryNames) {
  bool hasIndex = false;
  bool hasBank = false;
  int documents = 0;
  int texts = 0;
  int images = 0;
  for (final String raw in entryNames) {
    final String name = raw.replaceAll('\\', '/');
    if (name == 'index.json') hasIndex = true;
    final String base = name.split('/').last;
    if (base.contains('_bank_') && base.endsWith('.json')) hasBank = true;
    if (kBookArchivePageImageExtensions.contains(_ext(base))) {
      images++;
      continue;
    }
    if (!isBookArchiveMember(name)) continue;
    if (_ext(base) == '.txt') {
      texts++;
    } else {
      documents++;
    }
  }
  if (hasIndex && hasBank) return false;
  if (documents > 0) return true;
  return texts > 0 && texts >= images;
}

/// `.zip` 的条目名（只读中央目录与本地头，不解压内容），同步。打不开返回 null。
List<String>? zipEntryNamesSync(String zipPath) {
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final ZipDirectory directory = ZipDirectory.read(input);
    return <String>[
      for (final ZipFileHeader header in directory.fileHeaders)
        if (!header.filename.endsWith('/')) header.filename,
    ];
  } on Object {
    // 坏包 / 不是 zip / 没权限：在定性这一层只是「看不出是一批书」，回落到按扩展名的
    // 既有分类（`.zip` → 词典包），不把整次拖放炸掉。
    return null;
  } finally {
    input?.closeSync();
  }
}

/// [path] 要不要交给「解包后按内容导入」（[BookArchiveImporter]）。永不抛。
///
/// - `true`：列得出名字且装着书；或名字列不出来（`.7z` / 分卷第一卷 / 列目录失败的
///   `.rar`）——这时不按扩展名猜，解开一次再按内容分流（书 → 书库、页图 → 漫画导入）。
/// - `false`：列得出名字、不是书（页图包 / 词典包），或打不开的坏 `.zip`；调用方按
///   既有分类走（漫画包 / 词典包）。
///
/// [unpacker] 只在 `.rar` 列目录时用（7-Zip 命令行）；不给就现建一个。
Future<bool> looksLikeBookArchive(
  String path, {
  ArchiveUnpacker? unpacker,
}) async {
  if (isBookArchiveDecidedAfterUnpack(path)) return true;
  final String ext = _ext(path);
  if (ext == '.zip') {
    final List<String>? names = await Isolate.run<List<String>?>(
      () => zipEntryNamesSync(path),
      debugName: 'book-archive-probe',
    );
    return names != null && bookArchiveNamesHaveBooks(names);
  }
  if (ext == '.rar') {
    final List<String>? names = await (unpacker ?? ArchiveUnpacker())
        .listEntryNamesWithCli(path);
    // 列不出名字（条目表加密 / 7-Zip 起不来）≠ 不是书：交解包后定性。解包失败（缺 7-Zip、
    // 口令取消）由导入汇总如实报原因。
    return names == null || bookArchiveNamesHaveBooks(names);
  }
  return false;
}

/// 一本书的导入原语：返回新书的 bookKey；同名已在库被跳过返回 null；失败抛。
typedef BookArchiveMemberImporter = Future<String?> Function(String filePath);

/// 一本书（包里的一个条目，或同批拖入的一个单文件）的导入结果。
enum BookArchiveItemStatus { imported, skipped, failed }

final class BookArchiveItemResult {
  const BookArchiveItemResult({
    required this.name,
    required this.status,
    this.bookKey,
    this.error,
  });

  /// 展示名（包内相对路径或文件名）。
  final String name;
  final BookArchiveItemStatus status;
  final String? bookKey;

  /// [BookArchiveItemStatus.failed] 时的原因（异常文本）。
  final String? error;
}

/// 一个包整包没解开（口令取消 / 缺 7-Zip / 缺分卷 / 坏包……）。
final class BookArchiveUnpackFailure {
  const BookArchiveUnpackFailure({
    required this.archiveName,
    required this.failure,
  });

  final String archiveName;
  final ArchiveUnpackFailure failure;
}

/// 解开后发现是一卷漫画（只有页图）的包：解出的目录交给既有的漫画导入。
///
/// 目录**所有权随之转交**：[BookArchiveImporter] 不删它，交接方用完（漫画导入框关掉）
/// 必须 [discard]。目录名取包名（去扩展名与分卷号），漫画导入按目录名起书名。
final class BookArchiveMangaHandoff {
  const BookArchiveMangaHandoff({
    required this.archiveName,
    required this.directory,
    required this.stagingRoot,
  });

  /// 包的文件名。
  final String archiveName;

  /// 解出的页图目录（[stagingRoot] 之下、以包名命名）。
  final String directory;

  /// 这次解包的暂存根目录，[discard] 整个删掉。
  final String stagingRoot;

  Future<void> discard() async {
    final Directory root = Directory(stagingRoot);
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

/// 一次批量导入的汇总：UI 只展示这一份。
final class BookArchiveImportSummary {
  const BookArchiveImportSummary({
    required this.items,
    required this.unpackFailures,
    required this.archivesWithoutBooks,
    this.mangaHandoffs = const <BookArchiveMangaHandoff>[],
  });

  final List<BookArchiveItemResult> items;
  final List<BookArchiveUnpackFailure> unpackFailures;

  /// 解开了、但里面既没有书也没有页图的包（文件名）。
  final List<String> archivesWithoutBooks;

  /// 解开后是一卷漫画的包（只有页图）：交给漫画导入，见 [BookArchiveMangaHandoff]。
  final List<BookArchiveMangaHandoff> mangaHandoffs;

  /// 只有漫画要交接、没有任何书的结果或问题要给用户看——UI 直接转交漫画导入，不停在
  /// 一份空汇总上。
  bool get onlyMangaHandoffs =>
      mangaHandoffs.isNotEmpty && items.isEmpty && !hasProblems;

  int _count(BookArchiveItemStatus status) =>
      items.where((BookArchiveItemResult r) => r.status == status).length;

  int get importedCount => _count(BookArchiveItemStatus.imported);
  int get skippedCount => _count(BookArchiveItemStatus.skipped);
  int get failedCount => _count(BookArchiveItemStatus.failed);

  List<BookArchiveItemResult> get failedItems => <BookArchiveItemResult>[
    for (final BookArchiveItemResult r in items)
      if (r.status == BookArchiveItemStatus.failed) r,
  ];

  /// 有没有任何需要用户看一眼的问题。
  bool get hasProblems =>
      failedCount > 0 ||
      unpackFailures.isNotEmpty ||
      archivesWithoutBooks.isNotEmpty;
}

/// 进度阶段。
enum BookArchiveImportStage { unpacking, importing }

final class BookArchiveImportProgress {
  const BookArchiveImportProgress({
    required this.stage,
    required this.name,
    required this.done,
    required this.total,
  });

  final BookArchiveImportStage stage;

  /// 正在解的包名 / 正在导的书名。
  final String name;

  /// 已处理的输入路径数 / 输入路径总数（包与单文件各算一个）。
  final int done;
  final int total;
}

/// 把一批路径（压缩包 + 可能同批拖入的单本书）导成书。
class BookArchiveImporter {
  BookArchiveImporter({
    required BookArchiveMemberImporter importEpub,
    required BookArchiveMemberImporter importText,
    required BookArchiveMemberImporter importPdf,
    required Future<String> Function() createStagingDir,
    ArchiveUnpacker? unpacker,
  }) : _importEpub = importEpub,
       _importText = importText,
       _importPdf = importPdf,
       _createStagingDir = createStagingDir,
       _unpacker = unpacker ?? ArchiveUnpacker();

  final BookArchiveMemberImporter _importEpub;
  final BookArchiveMemberImporter _importText;
  final BookArchiveMemberImporter _importPdf;
  final Future<String> Function() _createStagingDir;
  final ArchiveUnpacker _unpacker;

  Future<BookArchiveImportSummary> importAll(
    List<String> paths, {
    void Function(BookArchiveImportProgress progress)? onProgress,
  }) async {
    final List<BookArchiveItemResult> items = <BookArchiveItemResult>[];
    final List<BookArchiveUnpackFailure> unpackFailures =
        <BookArchiveUnpackFailure>[];
    final List<String> withoutBooks = <String>[];
    final List<BookArchiveMangaHandoff> mangaHandoffs =
        <BookArchiveMangaHandoff>[];
    final int total = paths.length;
    for (int i = 0; i < total; i++) {
      final String path = paths[i];
      final String name = p.basename(path);
      if (!isBookArchiveContainerPath(path)) {
        // 同批拖入的单本书（任何书籍扩展名）：EPUB / PDF 各走各的，其余按文本转。
        onProgress?.call(
          BookArchiveImportProgress(
            stage: BookArchiveImportStage.importing,
            name: name,
            done: i,
            total: total,
          ),
        );
        items.add(await _importOne(path, name));
        continue;
      }
      onProgress?.call(
        BookArchiveImportProgress(
          stage: BookArchiveImportStage.unpacking,
          name: name,
          done: i,
          total: total,
        ),
      );
      final Directory staging = Directory(await _createStagingDir());
      // 解进以包名命名的子目录：解出来若是一卷漫画，这个目录原样交给漫画导入（按目录名
      // 起书名），不用再解一次、也不用改名搬家。
      final String unpackDir = p.join(staging.path, _archiveStem(name));
      bool handedOff = false;
      try {
        try {
          await _unpacker.extract(
            path,
            intoDir: unpackDir,
            includeExtensions: const <String>{
              ...kBookArchiveMemberExtensions,
              ...kBookArchivePageImageExtensions,
            },
          );
        } on ArchiveUnpackException catch (e) {
          unpackFailures.add(
            BookArchiveUnpackFailure(archiveName: name, failure: e.failure),
          );
          continue;
        }
        final Directory unpacked = Directory(unpackDir);
        final List<String> files = <String>[
          if (unpacked.existsSync())
            for (final FileSystemEntity entity in unpacked.listSync(
              recursive: true,
              followLinks: false,
            ))
              if (entity is File) p.relative(entity.path, from: unpackDir),
        ];
        // 按解出来的内容定性（与按条目名的预判同一条规则）：有书导书；只有页图是一卷
        // 漫画；都没有如实报。
        if (!bookArchiveNamesHaveBooks(files)) {
          if (files.any(
            (String f) => kBookArchivePageImageExtensions.contains(_ext(f)),
          )) {
            mangaHandoffs.add(
              BookArchiveMangaHandoff(
                archiveName: name,
                directory: unpackDir,
                stagingRoot: staging.path,
              ),
            );
            handedOff = true;
          } else {
            withoutBooks.add(name);
          }
          continue;
        }
        final List<String> members = <String>[
          for (final String file in files)
            if (isBookArchiveMember(file)) p.join(unpackDir, file),
        ]..sort();
        for (final String member in members) {
          final String memberName = p.join(
            name,
            p.relative(member, from: unpackDir),
          );
          onProgress?.call(
            BookArchiveImportProgress(
              stage: BookArchiveImportStage.importing,
              name: memberName,
              done: i,
              total: total,
            ),
          );
          items.add(await _importOne(member, memberName));
        }
      } finally {
        if (!handedOff && staging.existsSync()) {
          await staging.delete(recursive: true);
        }
      }
    }
    return BookArchiveImportSummary(
      items: items,
      unpackFailures: unpackFailures,
      archivesWithoutBooks: withoutBooks,
      mangaHandoffs: mangaHandoffs,
    );
  }

  /// 包名去掉分卷号与扩展名（`第1巻.7z.001` → `第1巻`），做解包子目录名。
  static String _archiveStem(String archiveName) {
    final String whole =
        splitArchiveVolume(archiveName)?.archivePath ?? archiveName;
    final String stem = p.basenameWithoutExtension(whole).trim();
    return stem.isEmpty ? 'archive' : stem;
  }

  Future<BookArchiveItemResult> _importOne(String path, String name) async {
    final BookArchiveMemberImporter importer = switch (_ext(path)) {
      '.epub' => _importEpub,
      '.pdf' => _importPdf,
      _ => _importText,
    };
    try {
      final String? key = await importer(path);
      return BookArchiveItemResult(
        name: name,
        status: key == null
            ? BookArchiveItemStatus.skipped
            : BookArchiveItemStatus.imported,
        bookKey: key,
      );
    } on Object catch (e) {
      // 一本坏书不拖垮整包：记进汇总（原因原样给用户看），其余照导。接 [Object] 而非
      // [Exception]：生产导入原语对坏书抛的不全是 Exception（`PdfImporter` 对零页 PDF
      // 抛 `StateError`），漏接会让整批中断、批量导入框停在进度态关不掉。
      return BookArchiveItemResult(
        name: name,
        status: BookArchiveItemStatus.failed,
        error: '$e',
      );
    }
  }
}

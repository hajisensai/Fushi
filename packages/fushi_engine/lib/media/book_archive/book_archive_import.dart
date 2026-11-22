/// 「一个压缩包里装着一批书」的定性与导入：书架导入框与桌面拖放共用（拍板 83Fe7zQbhv）。
///
/// - **定性**（[looksLikeBookArchive]）：按包里**装的是什么**判，不只看扩展名。`.zip`
///   读中央目录的条目名（不解包，后台 isolate）；`.rar` 经 7-Zip 命令行列目录；`.7z`
///   与分卷第一卷（`book.7z.001` / `book.zip.001`）的条目表可能加密、或第一卷本身不是
///   完整的包，列不出名字，只能解开后再看——它们不是漫画 / 词典的载体扩展名，在书籍落点
///   上就按「待解开的书包」收下，解开后没有书再如实报「包里没有书」。
/// - **导入**（[BookArchiveImporter]）：解包走导入链路唯一的解包点 [ArchiveUnpacker]
///   （加密包经口令提供方要口令、分卷自动拼），只解 [kBookArchiveMemberExtensions] 这几种
///   条目进书库根下的暂存目录（用完即删），逐本交给与发现页下载同一份的域导入原语
///   （`importDiscoveryEpub` / `importDiscoveryText` / PDF），同名已在库即跳过。一包多本
///   的结果收成一份 [BookArchiveImportSummary]，由 UI 一次性展示。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
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

const Set<String> _kImageExtensions = <String>{
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
    if (_kImageExtensions.contains(_ext(base))) {
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

/// [path] 是不是装着一批书的压缩包（按内容）。永不抛：判不出就是 false。
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
    return names != null && bookArchiveNamesHaveBooks(names);
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

/// 一次批量导入的汇总：UI 只展示这一份。
final class BookArchiveImportSummary {
  const BookArchiveImportSummary({
    required this.items,
    required this.unpackFailures,
    required this.archivesWithoutBooks,
  });

  final List<BookArchiveItemResult> items;
  final List<BookArchiveUnpackFailure> unpackFailures;

  /// 解开了、但里面一本书都没有的包（文件名）。
  final List<String> archivesWithoutBooks;

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
      try {
        try {
          await _unpacker.extract(
            path,
            intoDir: staging.path,
            includeExtensions: kBookArchiveMemberExtensions,
          );
        } on ArchiveUnpackException catch (e) {
          unpackFailures.add(
            BookArchiveUnpackFailure(archiveName: name, failure: e.failure),
          );
          continue;
        }
        final List<String> members = <String>[
          for (final FileSystemEntity entity in staging.listSync(
            recursive: true,
            followLinks: false,
          ))
            if (entity is File &&
                isBookArchiveMember(
                  p.relative(entity.path, from: staging.path),
                ))
              entity.path,
        ]..sort();
        if (members.isEmpty) {
          withoutBooks.add(name);
          continue;
        }
        for (final String member in members) {
          final String memberName = p.join(
            name,
            p.relative(member, from: staging.path),
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
        if (staging.existsSync()) await staging.delete(recursive: true);
      }
    }
    return BookArchiveImportSummary(
      items: items,
      unpackFailures: unpackFailures,
      archivesWithoutBooks: withoutBooks,
    );
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
    } on Exception catch (e) {
      // 一本坏书不拖垮整包：记进汇总，其余照导。
      return BookArchiveItemResult(
        name: name,
        status: BookArchiveItemStatus.failed,
        error: '$e',
      );
    }
  }
}

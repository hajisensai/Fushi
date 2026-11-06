import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/import/manga_pdf_importer.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/mokuro_legacy_html.dart'
    show isLegacyMokuroHtmlVolume, isMokuroLegacyHtmlPath;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show enumerateMangaPages, naturalCompare;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一个目录里「每个文件一卷」的整卷载体文件，按文件名自然序。
///
/// **只看直接子层**，不递归：递归会与页图目录的语义打架——`series/vol1/*.jpg`
/// 那种布局本来就该被 [enumerateMangaPages] 压平成一卷，而不是被这里当成
/// 「vol1 是一卷、series 是一批」。一层是能同时说清两件事的唯一深度。
///
/// 只按扩展名过滤（[kMangaCarrierFileExtensions]），不开包：真定性由
/// [classifyImportCarrier] 在逐卷导入时完成，那时反正要解压。判定阶段开 20 个包
/// 只为把按钮点亮是纯浪费。
///
/// mokuro 0.1 旧版产物的 `<卷名>.html`（同级有 `<卷名>/` 与 `_ocr/<卷名>/`）也是一卷
/// 的 manifest，一并列出；同级已有 `<卷名>.mokuro` 时让位给它（新版 mokuro 加
/// `--legacy_html` 两样都写，同一卷不能导两次）。
List<File> mangaCarrierFilesIn(Directory dir) {
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    // 无权限 / 瞬时 IO：当作「这里没有整卷文件」，让上游落回页图目录那条解释。
    return const <File>[];
  }
  final Set<String> mokuroStems = <String>{
    for (final FileSystemEntity entity in entries)
      if (entity is File && p.extension(entity.path).toLowerCase() == '.mokuro')
        p.withoutExtension(entity.path).toLowerCase(),
  };
  final List<File> files = <File>[
    for (final FileSystemEntity entity in entries)
      if (entity is File &&
          (kMangaCarrierFileExtensions.contains(
                p.extension(entity.path).toLowerCase(),
              ) ||
              (isLegacyMokuroHtmlVolume(entity.path) &&
                  !mokuroStems.contains(
                    p.withoutExtension(entity.path).toLowerCase(),
                  ))))
        entity,
  ];
  files.sort(
    (File a, File b) => naturalCompare(p.basename(a.path), p.basename(b.path)),
  );
  return files;
}

/// [mangaCarrierFilesIn] 里的 mokuro manifest：`.mokuro`，以及 mokuro 0.1 旧版
/// 产物的 `<卷名>.html`（同样只看直接子层）。
///
/// 目录载体判定要单独数它（BUG-2785）：`卷.mokuro` + 同名页图子目录是 mokuro 的
/// 标准产物，`.mokuro` 在场时它比页图更能说明这个目录是什么。旧版产物同理：
/// `卷.html` + `卷/` + `_ocr/卷/` 的目录不认 manifest 的话，页图判据会把它压平成
/// 一卷没字的纯页图，文字层丢掉、读的时候又在设备上跑一遍本地 OCR。
List<File> mangaMokuroFilesIn(Directory dir) => <File>[
  for (final File file in mangaCarrierFilesIn(dir))
    if (p.extension(file.path).toLowerCase() == '.mokuro' ||
        isMokuroLegacyHtmlPath(file.path))
      file,
];

/// 目录里有没有页图。判据与真正执行导入的枚举同源，不另写一套。
bool mangaDirectoryHasPageImages(String path) {
  final Directory dir = Directory(path);
  if (!dir.existsSync()) return false;
  return enumerateMangaPages(dir).isNotEmpty;
}

/// 一卷的导入结局。
enum MangaBatchVolumeStatus {
  /// 成功落库。
  imported,

  /// 库里已有同名条目，按 [DuplicatePolicy.skip] 跳过。
  duplicate,

  /// 扩展名像整卷载体，开包后发现不是漫画（词典 `.zip` / 文字 `.epub`）。
  notManga,

  /// 导入过程出错（包损坏、页缺失、磁盘满……）。
  failed,
}

/// 一卷的导入结局 + 用于报告的最小上下文。
class MangaBatchVolumeResult {
  const MangaBatchVolumeResult({
    required this.path,
    required this.status,
    this.error,
  });

  final String path;
  final MangaBatchVolumeStatus status;
  final Object? error;

  String get name => p.basename(path);
}

/// 整批的导入结局。
class MangaBatchImportReport {
  const MangaBatchImportReport(this.volumes);

  final List<MangaBatchVolumeResult> volumes;

  int get importedCount => _countOf(MangaBatchVolumeStatus.imported);
  int get duplicateCount => _countOf(MangaBatchVolumeStatus.duplicate);
  int get notMangaCount => _countOf(MangaBatchVolumeStatus.notManga);
  int get failedCount => _countOf(MangaBatchVolumeStatus.failed);

  /// 一卷都没导进来。调用方据此把整次导入报成失败而不是「成功 0 本」。
  bool get isEmpty => importedCount == 0;

  int _countOf(MangaBatchVolumeStatus status) =>
      volumes.where((MangaBatchVolumeResult v) => v.status == status).length;
}

/// 把 [path] 目录里的整卷载体文件逐个导成独立的一本漫画（BUG-1649）。
///
/// 关键性质：**一卷失败不中断整批**。用户扔进来 20 卷，第 3 卷的包是坏的，另外
/// 19 卷照样进库——把整批废掉才是更糟的行为。每卷的结局收进
/// [MangaBatchImportReport] 交给调用方一次性汇报。
///
/// 标题逐卷取自文件名（去扩展名），不用对话框里那个单值标题框：一个标题套 20 卷
/// 只会得到 `X`、`X (2)`、`X (3)`……那既丢了卷号也丢了顺序。
///
/// 重复策略固定 [DuplicatePolicy.skip]：批量路径不该弹 20 次询问框（术语表里
/// 批量后台就是 skip），已在库的卷跳过并计数，重跑同一个文件夹因此是幂等的。
///
/// [classify] 是测试缝，生产传 null 即走真实判据（开包）。
Future<MangaBatchImportReport> importMangaBatchFolder({
  required FushiDatabase db,
  required String path,
  void Function(int done, int total)? onVolumeProgress,
  ImportCarrier Function(String path)? classify,
}) => importMangaBatchPaths(
  db: db,
  paths: <String>[
    for (final File file in mangaCarrierFilesIn(Directory(path))) file.path,
  ],
  onVolumeProgress: onVolumeProgress,
  classify: classify ?? _classifyCarrierFile,
);

/// 一组用户**同时选中 / 拖入**的漫画载体逐卷导入：每个路径各成一本。
///
/// 与 [importMangaBatchFolder] 是同一套编排（一卷失败不中断、标题取各自名字、
/// 重复固定 skip、结局收进报告）——那个函数只是「先把目录展开成文件列表」再调这里。
/// 多选拖入此前只导第一个、其余静默丢掉，这里让「拖 N 卷进来」与「选一个装着 N 卷的
/// 文件夹」得到同一种结果。
///
/// 列表里的**目录**按它自己的载体身份处理（[classifyImportCarrier] 的目录分支）：
/// 页图目录 = 一卷；只装一个 `.mokuro` 的目录 = 那一卷 `.mokuro`；装着整卷文件的
/// 目录 = 展开成其中每一卷。[classify] 是测试缝，生产传 null 即走真实文件系统判据。
Future<MangaBatchImportReport> importMangaBatchPaths({
  required FushiDatabase db,
  required List<String> paths,
  void Function(int done, int total)? onVolumeProgress,
  ImportCarrier Function(String path)? classify,
}) async {
  final ImportCarrier Function(String path) resolve =
      classify ?? _classifyCarrierPath;
  final List<(String, ImportCarrier)> volumes = <(String, ImportCarrier)>[];
  final Set<String> seen = <String>{};
  void addVolume(String volumePath, ImportCarrier carrier) {
    if (seen.add(p.normalize(volumePath))) volumes.add((volumePath, carrier));
  }

  for (final String path in paths) {
    final ImportCarrier carrier = resolve(path);
    if (carrier == ImportCarrier.mangaBatchFolder) {
      for (final File file in mangaCarrierFilesIn(Directory(path))) {
        addVolume(file.path, resolve(file.path));
      }
      continue;
    }
    if (carrier == ImportCarrier.mangaMokuro && Directory(path).existsSync()) {
      final List<File> mokuro = mangaMokuroFilesIn(Directory(path));
      if (mokuro.length == 1) {
        addVolume(mokuro.single.path, carrier);
        continue;
      }
    }
    addVolume(path, carrier);
  }

  final List<MangaBatchVolumeResult> results = <MangaBatchVolumeResult>[];
  onVolumeProgress?.call(0, volumes.length);
  for (int index = 0; index < volumes.length; index++) {
    final (String volumePath, ImportCarrier carrier) = volumes[index];
    results.add(
      await _importOneVolume(db: db, volumePath: volumePath, carrier: carrier),
    );
    onVolumeProgress?.call(index + 1, volumes.length);
  }
  return MangaBatchImportReport(results);
}

Future<MangaBatchVolumeResult> _importOneVolume({
  required FushiDatabase db,
  required String volumePath,
  required ImportCarrier carrier,
}) async {
  // 目录卷（页图文件夹）的名字里的点不是扩展名（`第01巻.v2`），不能去掉。
  final String title = carrier == ImportCarrier.mangaFolder
      ? p.basename(volumePath)
      : p.basenameWithoutExtension(volumePath);
  try {
    switch (carrier) {
      case ImportCarrier.mangaFolder:
        await MangaImporter.importFromImageFolder(
          db: db,
          imageDirPath: volumePath,
          title: title,
          policy: const DuplicatePolicy.skip(),
        );
      case ImportCarrier.mangaArchive:
        await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: volumePath,
          title: title,
          policy: const DuplicatePolicy.skip(),
        );
      case ImportCarrier.mangaMokuro:
        await MangaImporter.importFromMokuroPath(
          db: db,
          mokuroPath: volumePath,
          title: title,
          policy: const DuplicatePolicy.skip(),
        );
      case ImportCarrier.pdf:
        // 一卷扫描版漫画常常就是一份 PDF；与单卷路径同一条实现（逐页栅格化）。
        await importMangaFromPdf(
          db: db,
          pdfPath: volumePath,
          fileName: p.basename(volumePath),
          title: title,
          policy: const DuplicatePolicy.skip(),
        );
      case ImportCarrier.mangaBatchFolder:
      case ImportCarrier.epub:
      case ImportCarrier.text:
        // 扩展名对得上但内容不是漫画：词典 `.zip`、文字 `.epub`。不静默吞，
        // 计数后在汇总里如实报出来。（整卷目录在这里不可达——
        // [importMangaBatchPaths] 已把它展开成其中的每一卷。）
        return MangaBatchVolumeResult(
          path: volumePath,
          status: MangaBatchVolumeStatus.notManga,
        );
    }
    return MangaBatchVolumeResult(
      path: volumePath,
      status: MangaBatchVolumeStatus.imported,
    );
  } on DuplicateImportCancelledException {
    return MangaBatchVolumeResult(
      path: volumePath,
      status: MangaBatchVolumeStatus.duplicate,
    );
  } catch (error, stack) {
    // 逐卷失败原因必须在**吞掉它的这一层**落盘。批量路径把每卷异常收进报告、只给
    // 调用方一句「成功 N / 失败 M」的汇总，于是 ImportFlowMixin.runImport 那道
    // ErrorLogService 永远拿不到真正的原因——用户事后翻错误日志是空的（用户报的
    // 「error_log.txt 里翻不到」就是这个洞）。放这里而不是放某一个对话框里，是因为
    // 报告有多个消费方，落日志不该跟着 UI 走。
    ErrorLogService.instance.log(
      'MangaBatchImport.volume',
      '${p.basename(volumePath)}: $error',
      stack,
    );
    return MangaBatchVolumeResult(
      path: volumePath,
      status: MangaBatchVolumeStatus.failed,
      error: error,
    );
  }
}

/// 批量里单个候选**文件**的真定性。目录判据在这里恒为 false / 0——候选集本身
/// 就只有文件（[mangaCarrierFilesIn] 只收 `entity is File`）。
ImportCarrier _classifyCarrierFile(String path) => classifyImportCarrier(
  path,
  isDirectory: (String _) => false,
  isImageArchive: MangaArchiveImporter.looksLikeImageArchive,
  directoryHasPageImages: (String _) => false,
  directoryCarrierFileCount: (String _) => 0,
  directoryMokuroFileCount: (String _) => 0,
);

/// [importMangaBatchPaths] 的生产判据：路径可能是文件也可能是目录（拖入 / 多选），
/// 目录判据与漫画导入框同源（[mangaDirectoryHasPageImages] / [mangaCarrierFilesIn]）。
ImportCarrier _classifyCarrierPath(String path) => classifyImportCarrier(
  path,
  isDirectory: (String pth) => Directory(pth).existsSync(),
  isImageArchive: MangaArchiveImporter.looksLikeImageArchive,
  directoryHasPageImages: mangaDirectoryHasPageImages,
  directoryCarrierFileCount: (String pth) =>
      mangaCarrierFilesIn(Directory(pth)).length,
  directoryMokuroFileCount: (String pth) =>
      mangaMokuroFilesIn(Directory(pth)).length,
);

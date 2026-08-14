import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart'
    show enumerateMangaPages, naturalCompare;

/// 一个目录里「每个文件一卷」的整卷载体文件，按文件名自然序。
///
/// **只看直接子层**，不递归：递归会与页图目录的语义打架——`series/vol1/*.jpg`
/// 那种布局本来就该被 [enumerateMangaPages] 压平成一卷，而不是被这里当成
/// 「vol1 是一卷、series 是一批」。一层是能同时说清两件事的唯一深度。
///
/// 只按扩展名过滤（[kMangaCarrierFileExtensions]），不开包：真定性由
/// [classifyImportCarrier] 在逐卷导入时完成，那时反正要解压。判定阶段开 20 个包
/// 只为把按钮点亮是纯浪费。
List<File> mangaCarrierFilesIn(Directory dir) {
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    // 无权限 / 瞬时 IO：当作「这里没有整卷文件」，让上游落回页图目录那条解释。
    return const <File>[];
  }
  final List<File> files = <File>[
    for (final FileSystemEntity entity in entries)
      if (entity is File &&
          kMangaCarrierFileExtensions
              .contains(p.extension(entity.path).toLowerCase()))
        entity,
  ];
  files.sort((File a, File b) =>
      naturalCompare(p.basename(a.path), p.basename(b.path)));
  return files;
}

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
}) async {
  final List<File> files = mangaCarrierFilesIn(Directory(path));
  final ImportCarrier Function(String path) resolve =
      classify ?? _classifyCarrierFile;

  final List<MangaBatchVolumeResult> results = <MangaBatchVolumeResult>[];
  onVolumeProgress?.call(0, files.length);
  for (int index = 0; index < files.length; index++) {
    final String volumePath = files[index].path;
    results.add(await _importOneVolume(
      db: db,
      volumePath: volumePath,
      carrier: resolve(volumePath),
    ));
    onVolumeProgress?.call(index + 1, files.length);
  }
  return MangaBatchImportReport(results);
}

Future<MangaBatchVolumeResult> _importOneVolume({
  required FushiDatabase db,
  required String volumePath,
  required ImportCarrier carrier,
}) async {
  final String title = p.basenameWithoutExtension(volumePath);
  try {
    switch (carrier) {
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
      case ImportCarrier.mangaFolder:
      case ImportCarrier.mangaBatchFolder:
      case ImportCarrier.pdf:
      case ImportCarrier.epub:
      case ImportCarrier.text:
        // 扩展名对得上但内容不是漫画：词典 `.zip`、文字 `.epub`。不静默吞，
        // 计数后在汇总里如实报出来。（目录形态在这里不可达——候选只有文件。）
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
  } catch (error) {
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
    );

/// 漫画 OCR 模型**手动导入**：把用户自己下好的模型文件搬进模型目录。
///
/// 存在的理由：清单里那 470MB 走 huggingface.co 直连，在部分网络下是「连不上」
/// 而不是「慢」。镜像回退（见 `manga_ocr_model_downloader.dart`）解决大多数情况，
/// 但总有网络连镜像也不通的用户——他们能用别的手段拿到文件，缺的只是一个把文件
/// 交给 app 的入口。
///
/// 三种来源走**同一条判据**，没有为哪种来源单开分支：
/// - 单个/多个文件：按 basename 命中清单
/// - 文件夹：递归展开后同上（顺带收集里面的 zip）
/// - zip 包：只解出清单命中的 entry，其余整包忽略
///
/// 判据只有两条：**basename 在清单里** + **字节数等于清单预期**。长度不符一律
/// 拒绝并把「期望多少、实际多少」回报给用户——半个文件转正后只会在推理时炸成
/// 一堆看不懂的 ORT 错误，那比当场说「这个文件不对」糟糕得多。
///
/// 落盘沿用下载器的原子语义：先写临时名，校验通过再 rename，绝不出现半个模型
/// 被当成就绪档。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';

/// 一个来源被拒绝的原因。
enum MangaOcrModelImportRejectReason {
  /// basename 不在清单里（用户拿错了文件，或改过名）。
  unknownFile,

  /// 命中清单但字节数与预期不符（下载被截断 / 拿到的是另一档）。
  sizeMismatch,

  /// 读不动（权限、坏 zip、来源在导入途中消失）。
  unreadable,
}

/// 一条被拒绝的来源，带足以让用户自查的数据。
class MangaOcrModelImportRejection {
  const MangaOcrModelImportRejection({
    required this.source,
    required this.reason,
    this.actualBytes,
    this.expectedBytes,
    this.detail,
  });

  /// 用户看得懂的来源标识：磁盘文件名，或 `包名.zip → entry 名`。
  final String source;

  final MangaOcrModelImportRejectReason reason;

  /// [MangaOcrModelImportRejectReason.sizeMismatch] 时非空。
  final int? actualBytes;
  final int? expectedBytes;

  /// [MangaOcrModelImportRejectReason.unreadable] 时的原始错误串。
  final String? detail;

  @override
  String toString() => 'MangaOcrModelImportRejection($source, $reason)';
}

/// 一次导入的结果。
class MangaOcrModelImportResult {
  const MangaOcrModelImportResult({
    required this.imported,
    required this.skipped,
    required this.rejected,
    required this.stillMissing,
  });

  /// 本次真正落盘转正的清单文件名。
  final List<String> imported;

  /// 目标已存在且字节数正确，未覆盖。
  final List<String> skipped;

  /// 被拒绝的来源。
  final List<MangaOcrModelImportRejection> rejected;

  /// 导入结束后清单里仍缺的文件名（空 = 模型齐全）。
  final List<String> stillMissing;

  bool get allReady => stillMissing.isEmpty;

  /// 本次是否改变了磁盘状态（决定 UI 要不要刷新模型状态）。
  bool get changed => imported.isNotEmpty;

  /// 完全没认出任何清单文件——用户多半选错了东西，值得单独提示。
  bool get matchedNothing => imported.isEmpty && skipped.isEmpty;
}

/// basename → 清单条目。大小写不敏感：用户可能从别处拿到大小写不同的同一个档，
/// 而清单里的名字本就是唯一标识，没必要为大小写把人挡在门外。
MangaOcrModelFile? matchMangaOcrModelFile(
  String fileName,
  List<MangaOcrModelFile> manifest,
) {
  final String target = p.basename(fileName).toLowerCase();
  for (final MangaOcrModelFile model in manifest) {
    if (model.fileName.toLowerCase() == target) {
      return model;
    }
  }
  return null;
}

/// 模型目录里某个清单文件是否**已经是好档**（存在且字节数等于预期）。
///
/// 与 [isMangaOcrModelFileReady] 的宽松判定（存在且非空）刻意不同：那个用于
/// 「能不能跑」，宽松是为了不把上游漂移后的旧档误判成缺失；这个用于「要不要
/// 覆盖」，必须严格，否则一个被截断的坏档会永远挡着用户导入正确的文件。
bool isMangaOcrModelFileExact(File file, MangaOcrModelFile model) {
  if (!file.existsSync()) {
    return false;
  }
  if (model.expectedBytes <= 0) {
    return file.lengthSync() > 0;
  }
  return file.lengthSync() == model.expectedBytes;
}

/// 手动导入器。[manifest] 可注入（测试用小清单）。
class MangaOcrModelImporter {
  MangaOcrModelImporter({List<MangaOcrModelFile>? manifest})
      : _manifest = manifest ?? kMangaOcrModelManifest;

  final List<MangaOcrModelFile> _manifest;

  /// 把 [sourcePaths]（文件 / 文件夹 / zip 任意混合）里认得出的模型搬进 [targetDir]。
  Future<MangaOcrModelImportResult> import({
    required List<String> sourcePaths,
    required Directory targetDir,
  }) async {
    await targetDir.create(recursive: true);

    final List<String> imported = <String>[];
    final List<String> skipped = <String>[];
    final List<MangaOcrModelImportRejection> rejected =
        <MangaOcrModelImportRejection>[];

    final _ImportSources sources = await _expand(sourcePaths, rejected);

    for (final File file in sources.files) {
      await _importPlainFile(file, targetDir, imported, skipped, rejected);
    }
    for (final File zip in sources.zips) {
      await _importZip(zip, targetDir, imported, skipped, rejected);
    }

    final List<String> stillMissing = <String>[
      for (final MangaOcrModelFile model in _manifest)
        if (!isMangaOcrModelFileReady(
            File(p.join(targetDir.path, model.fileName))))
          model.fileName,
    ];

    return MangaOcrModelImportResult(
      imported: imported,
      skipped: skipped,
      rejected: rejected,
      stillMissing: stillMissing,
    );
  }

  /// 展开用户选中的路径：目录递归、zip 单列、其余当普通文件。
  ///
  /// 递归深度不设限但**只收清单命中的文件和 zip**：用户完全可能顺手选了一个装着
  /// 上万张图的目录，把无关文件收进来只会在后面逐个拒绝、刷出一屏噪音。
  Future<_ImportSources> _expand(
    List<String> sourcePaths,
    List<MangaOcrModelImportRejection> rejected,
  ) async {
    final List<File> files = <File>[];
    final List<File> zips = <File>[];

    void visitFile(File file) {
      if (p.extension(file.path).toLowerCase() == '.zip') {
        zips.add(file);
        return;
      }
      files.add(file);
    }

    for (final String path in sourcePaths) {
      final FileSystemEntityType type = await FileSystemEntity.type(path);
      switch (type) {
        case FileSystemEntityType.file:
          visitFile(File(path));
        case FileSystemEntityType.directory:
          try {
            await for (final FileSystemEntity entity
                in Directory(path).list(recursive: true, followLinks: false)) {
              if (entity is! File) continue;
              final String name = p.basename(entity.path);
              final bool isZip = p.extension(name).toLowerCase() == '.zip';
              if (!isZip && matchMangaOcrModelFile(name, _manifest) == null) {
                continue;
              }
              visitFile(entity);
            }
          } on Object catch (error) {
            rejected.add(MangaOcrModelImportRejection(
              source: p.basename(path),
              reason: MangaOcrModelImportRejectReason.unreadable,
              detail: '$error',
            ));
          }
        default:
          rejected.add(MangaOcrModelImportRejection(
            source: p.basename(path),
            reason: MangaOcrModelImportRejectReason.unreadable,
            detail: 'not a file or directory',
          ));
      }
    }
    return _ImportSources(files: files, zips: zips);
  }

  Future<void> _importPlainFile(
    File file,
    Directory targetDir,
    List<String> imported,
    List<String> skipped,
    List<MangaOcrModelImportRejection> rejected,
  ) async {
    final String name = p.basename(file.path);
    final MangaOcrModelFile? model = matchMangaOcrModelFile(name, _manifest);
    if (model == null) {
      rejected.add(MangaOcrModelImportRejection(
        source: name,
        reason: MangaOcrModelImportRejectReason.unknownFile,
      ));
      return;
    }

    final File target = File(p.join(targetDir.path, model.fileName));
    if (isMangaOcrModelFileExact(target, model)) {
      skipped.add(model.fileName);
      return;
    }

    final int actual;
    try {
      actual = await file.length();
    } on Object catch (error) {
      rejected.add(MangaOcrModelImportRejection(
        source: name,
        reason: MangaOcrModelImportRejectReason.unreadable,
        detail: '$error',
      ));
      return;
    }
    if (model.expectedBytes > 0 && actual != model.expectedBytes) {
      rejected.add(MangaOcrModelImportRejection(
        source: name,
        reason: MangaOcrModelImportRejectReason.sizeMismatch,
        actualBytes: actual,
        expectedBytes: model.expectedBytes,
      ));
      return;
    }

    final File staged = File('${target.path}.import');
    try {
      await file.copy(staged.path);
      await _promote(staged, target);
    } on Object catch (error) {
      _discard(staged);
      rejected.add(MangaOcrModelImportRejection(
        source: name,
        reason: MangaOcrModelImportRejectReason.unreadable,
        detail: '$error',
      ));
      return;
    }
    imported.add(model.fileName);
  }

  Future<void> _importZip(
    File zip,
    Directory targetDir,
    List<String> imported,
    List<String> skipped,
    List<MangaOcrModelImportRejection> rejected,
  ) async {
    final String zipName = p.basename(zip.path);
    final String zipPath = zip.path;
    final List<String> wanted = <String>[
      for (final MangaOcrModelFile m in _manifest) m.fileName,
    ];

    // 只把 zip 相关的重活丢给 isolate——inflate 是 CPU 密集活，留在主 isolate
    // 会把 UI 冻住几十秒。
    final List<_ZipEntry> entries;
    try {
      entries = await Isolate.run(() => _scanZipEntries(zipPath, wanted));
    } on Object catch (error) {
      rejected.add(MangaOcrModelImportRejection(
        source: zipName,
        reason: MangaOcrModelImportRejectReason.unreadable,
        detail: '$error',
      ));
      return;
    }

    if (entries.isEmpty) {
      rejected.add(MangaOcrModelImportRejection(
        source: zipName,
        reason: MangaOcrModelImportRejectReason.unknownFile,
      ));
      return;
    }

    for (final _ZipEntry entry in entries) {
      final MangaOcrModelFile? model =
          matchMangaOcrModelFile(entry.name, _manifest);
      if (model == null) {
        continue;
      }
      final String source = '$zipName -> ${entry.name}';
      final File target = File(p.join(targetDir.path, model.fileName));
      if (isMangaOcrModelFileExact(target, model)) {
        skipped.add(model.fileName);
        continue;
      }
      if (model.expectedBytes > 0 && entry.size != model.expectedBytes) {
        rejected.add(MangaOcrModelImportRejection(
          source: source,
          reason: MangaOcrModelImportRejectReason.sizeMismatch,
          actualBytes: entry.size,
          expectedBytes: model.expectedBytes,
        ));
        continue;
      }

      final File staged = File('${target.path}.import');
      final String stagedPath = staged.path;
      final String entryName = entry.name;
      try {
        await Isolate.run(
            () => _extractZipEntry(zipPath, entryName, stagedPath));
        final int actual = await staged.length();
        if (model.expectedBytes > 0 && actual != model.expectedBytes) {
          // zip 头里的 size 与实际解出的字节数不符：包本身坏了。
          throw StateError(
              'extracted $actual bytes, expected ${model.expectedBytes}');
        }
        await _promote(staged, target);
      } on Object catch (error) {
        _discard(staged);
        rejected.add(MangaOcrModelImportRejection(
          source: source,
          reason: MangaOcrModelImportRejectReason.unreadable,
          detail: '$error',
        ));
        continue;
      }
      imported.add(model.fileName);
    }
  }

  /// 原子转正 + 清掉同名 `.part`：导入完成后那半截下载残留既没用也占几百 MB。
  Future<void> _promote(File staged, File target) async {
    if (target.existsSync()) {
      await target.delete();
    }
    await staged.rename(target.path);
    final File downloadPart = File('${target.path}.part');
    if (downloadPart.existsSync()) {
      try {
        await downloadPart.delete();
      } catch (_) {}
    }
  }

  void _discard(File staged) {
    if (!staged.existsSync()) {
      return;
    }
    try {
      staged.deleteSync();
    } catch (_) {}
  }
}

class _ImportSources {
  const _ImportSources({required this.files, required this.zips});

  final List<File> files;
  final List<File> zips;
}

class _ZipEntry {
  const _ZipEntry({required this.name, required this.size});

  final String name;
  final int size;
}

/// isolate 侧：扫 zip 目录区，挑出 basename 命中清单的 entry。只读头，不解压。
List<_ZipEntry> _scanZipEntries(String zipPath, List<String> wantedNames) {
  final Set<String> wanted =
      wantedNames.map((String n) => n.toLowerCase()).toSet();
  final InputFileStream input = InputFileStream(zipPath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    return <_ZipEntry>[
      for (final ArchiveFile file in archive.files)
        if (file.isFile && wanted.contains(p.basename(file.name).toLowerCase()))
          _ZipEntry(name: file.name, size: file.size),
    ];
  } finally {
    input.closeSync();
  }
}

/// isolate 侧：把一个 entry 流式解到 [destPath]。
///
/// 流式而非 `file.content`：encoder 单档 343MB，整块物化会直接把移动端打爆。
void _extractZipEntry(String zipPath, String entryName, String destPath) {
  final InputFileStream input = InputFileStream(zipPath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    final ArchiveFile file = archive.files.firstWhere(
      (ArchiveFile f) => f.isFile && f.name == entryName,
      orElse: () => throw StateError('zip entry vanished: $entryName'),
    );
    File(destPath).parent.createSync(recursive: true);
    final OutputFileStream output = OutputFileStream(destPath);
    try {
      file.writeContent(output);
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
}

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 漫画互联包（互联完整支持批次：漫画此前在互联里完全不可下载/不可推送）。
///
/// **布局即真相**：包 = 漫画书目录整树 zip（根含 [kMangaPackageMarker] + 页图），
/// 与磁盘布局 `<fushi_books>/<bookKey>/{manga.json, 页图…}` 同构——导入侧解压后
/// 直接走 `MangaImporter.importFromMangaJson` 的既有两遍式校验落库（防穿越 /
/// 缺图校验 / 同名策略 / 回滚全部复用，零第二套导入器）。
///
/// 与 EPUB 包（根含 `META-INF/container.xml`）走**同一个** books 传输端点，以
/// [isMangaPackage] 内容嗅探区分：零新端点。向后兼容：旧 client 看不到漫画条目
/// （清单 `hasContent` 对漫画恒 false，新 additive 字段 `hasMangaContent` 只有新
/// client 消费）；旧 host 收到漫画包推送会走 EPUB 导入失败、如实报错（不静默）。
const String kMangaPackageMarker = 'manga.json';

/// [extractDir] 是漫画书目录（根含 manga.json）时打整树 zip 到 [outputPath]，
/// 返回 true；目录缺失 / 无标记（不是漫画目录）不写文件返回 false——与
/// `repackageExtractedEpub` 的「false = 无可打包内容」语义对称。
Future<bool> repackageMangaBook(String extractDir, String outputPath) async {
  if (extractDir.isEmpty) return false;
  final Directory dir = Directory(extractDir);
  if (!dir.existsSync()) return false;
  if (!File(p.join(dir.path, kMangaPackageMarker)).existsSync()) return false;
  final ZipFileEncoder encoder = ZipFileEncoder();
  encoder.create(outputPath);
  try {
    encoder.addDirectory(dir, includeDirName: false);
  } finally {
    encoder.close();
  }
  return true;
}

/// 嗅探 [zipFile] 是否为漫画包（zip 根有 [kMangaPackageMarker] 条目）。
///
/// 只经 [InputFileStream] 流式读中央目录，不解压任何条目数据（漫画包可达数百
/// MB，绝不整包进内存）。非 zip / 读失败返回 false——调用方按 EPUB 处理，坏包由
/// EpubImporter 的既有失败路径诚实报错。
Future<bool> isMangaPackage(File zipFile) async {
  InputFileStream? input;
  try {
    input = InputFileStream(zipFile.path);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile f in archive.files) {
      if (f.name.replaceAll('\\', '/') == kMangaPackageMarker) return true;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await input?.close();
  }
}

/// 把漫画包 [file] 解压并经 [MangaImporter.importFromMangaJson] 落库（两遍式校验
/// / 同名策略 / 回滚全部复用），返回落地 bookKey。host importBookFromFile 与
/// client 远端下载导入共用本函数（同一嗅探 + 同一落库语义，改一处两端生效）。
/// [title] = 身份标题（bookKey 由它派生）；null 退化包文件名（去扩展名）。
Future<String> importMangaPackageFile({
  required FushiDatabase db,
  required File file,
  String? title,
}) async {
  final Directory unpacked = await extractMangaPackage(file);
  try {
    return await MangaImporter.importFromMangaJson(
      db: db,
      mangaJsonPath: p.join(unpacked.path, kMangaPackageMarker),
      imageRootPath: unpacked.path,
      title: title ?? p.basenameWithoutExtension(file.path),
    );
  } finally {
    try {
      unpacked.deleteSync(recursive: true);
    } catch (_) {
      // best-effort 清理临时解包目录。
    }
  }
}

/// 把漫画包解压到新建临时目录并返回该目录（内容 = manga.json + 页图树）。
///
/// 防路径穿越：条目名含 `..` 段或为绝对路径一律抛 [FormatException]（导入侧
/// `importFromMangaJson` 的 destRel 规划还有第二道穿越校验，双保险）。逐条目
/// 解压（单页图级别的内存峰值），失败清临时目录后 rethrow。调用方用后负责删除
/// 返回的目录。
Future<Directory> extractMangaPackage(File zipFile) async {
  final Directory out =
      await Directory.systemTemp.createTemp('hibiki_manga_pkg');
  InputFileStream? input;
  try {
    input = InputFileStream(zipFile.path);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile f in archive.files) {
      final String name = f.name.replaceAll('\\', '/');
      if (name.isEmpty) continue;
      if (p.isAbsolute(name) || p.posix.split(name).contains('..')) {
        throw FormatException('unsafe zip entry: $name');
      }
      final String destPath = p.join(out.path, name);
      if (!f.isFile) {
        await Directory(destPath).create(recursive: true);
        continue;
      }
      final File dest = File(destPath);
      await dest.parent.create(recursive: true);
      // 单条目 materialize（页图量级，MB 级峰值）；整包从不进内存。
      await dest.writeAsBytes(f.content as List<int>, flush: true);
    }
    return out;
  } catch (_) {
    try {
      out.deleteSync(recursive: true);
    } catch (_) {
      // best-effort 清理。
    }
    rethrow;
  } finally {
    await input?.close();
  }
}

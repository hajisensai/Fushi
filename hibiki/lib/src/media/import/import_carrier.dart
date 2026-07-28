import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/audiobook/text_to_epub.dart';

/// 一个待导入路径的**载体身份**：它到底是哪种东西，因而该交给哪个 importer。
///
/// 此前这个判断只活在 `BookImportDialog._importEpubOnly` 的函数体末尾——用户从
/// 漫画库进来时「这是漫画」本来是已知的，却在入口被丢掉，一路走到导入执行阶段
/// 再靠扩展名 + 真读包嗅回来。载体身份提到入口后，漫画和书籍各自有独立入口与
/// 对话框，`isImageArchive` 那次真实 IO 只在**扩展名确实二义**时才发生。
enum ImportCarrier {
  /// 页图**目录**（一个漫画文件夹）。走 `MangaModule.importImageFolder`。
  mangaFolder,

  /// mokuro v0.2+ 的 `.mokuro` OCR 结果文件（+ 同级图片）。
  /// 走 `MangaModule.importMokuro`。
  mangaMokuro,

  /// 图片压缩包：`.cbz`，或真读包确认装的是页图的 `.zip` / `.epub`。
  /// 走 `MangaModule.importArchive`。
  mangaArchive,

  /// PDF。走 `PdfImporter`（真渲染，不经 TextToEpub 文本转换）。
  pdf,

  /// EPUB。走 `EpubImporter.importFromPath`。
  epub,

  /// 可转成 EPUB 的纯文本类（txt/md/html/…），以及不认识的扩展名。
  /// 走 `TextToEpub.convert` + `EpubImporter.import`。
  text;

  /// 是否属漫画域（三种漫画载体的统称）。书籍侧入口只关心这一个问题。
  bool get isManga =>
      this == ImportCarrier.mangaFolder ||
      this == ImportCarrier.mangaMokuro ||
      this == ImportCarrier.mangaArchive;
}

/// 判定 [path] 的载体身份。
///
/// 文件系统判据由调用方注入（与 `classifyDroppedFiles` 同款设计），本函数自身
/// 不碰 IO，故可在纯 Dart 测试里穷举各分支：
///
/// - [isDirectory]：目录判定。**必须最先问**——目录没有扩展名，而目录名带点时
///   `p.extension` 还会误取出一个假扩展名，落到任何按扩展名分派的分支都会失败。
/// - [isImageArchive]：真读包判定，只在扩展名二义（`.zip` / `.epub`）时才被调用。
///   `.zip` 同时是 Yomitan 词典包扩展名，`.epub` 也可能是扫描版漫画——光看扩展名
///   分不出，必须开包看里面装的是不是页图。
ImportCarrier classifyImportCarrier(
  String path, {
  required bool Function(String path) isDirectory,
  required bool Function(String path) isImageArchive,
}) {
  if (isDirectory(path)) return ImportCarrier.mangaFolder;

  final String ext = p.extension(path).toLowerCase();

  // PDF 必须在下面的文本分支之前早退——否则 PDF 二进制会被当文本转成乱码 EPUB。
  if (ext == '.pdf') return ImportCarrier.pdf;

  // .mokuro 同理：它的 JSON 内容会被文本分支当纯文本吞掉。
  if (ext == '.mokuro') return ImportCarrier.mangaMokuro;

  if (ext == '.cbz') return ImportCarrier.mangaArchive;
  if (_ambiguousArchiveExtensions.contains(ext) && isImageArchive(path)) {
    return ImportCarrier.mangaArchive;
  }

  // 非 epub/zip 的一切（含无扩展名文件）都尝试按文本转 EPUB——保持既有兜底语义。
  if (TextToEpub.isSupported(path) || (ext != '.epub' && ext != '.zip')) {
    return ImportCarrier.text;
  }
  return ImportCarrier.epub;
}

/// 需要真读包才能定性的容器扩展名（带点，小写）。
const Set<String> _ambiguousArchiveExtensions = <String>{'.zip', '.epub'};

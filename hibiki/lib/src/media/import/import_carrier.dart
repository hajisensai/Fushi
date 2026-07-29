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

/// 按路径记住一次载体身份的小盒子。
///
/// 为什么需要它：`.zip` / `.epub` 的定性要 [classifyImportCarrier] **真开包**
/// （`isImageArchive` → 全量同步解压），那是导入对话框里唯一一处重量级同步 IO。
/// 而一次导入里同一个路径会被问到不止一次：选中时的漫画闸门、`_doImport` 的兜底
/// 闸门、以及真正分派时。每问一次就整包解压一次。有声书对齐路径（EPUB+字幕）尤其
/// 亏——它根本不进按载体分派那一步，前面那几次开包纯属白开，而分家之前它一次都不开。
///
/// 载体身份本来就是路径的函数（这正是 [ImportCarrier] 的立意：身份在**选中那一刻**
/// 定死，而不是一路嗅到导入执行阶段），所以按路径记住即可。换路径自动失效——key 变了
/// 就重算，因此不会把上一个文件的判定张冠李戴到下一个文件上。
///
/// **不是**靠跳过判据来省 IO：判据一字未动，词典包一票否决照常生效（见
/// `MangaArchiveImporter.looksLikeImageArchive`）。省掉的只是**重复**问同一个问题。
class ImportCarrierResolver {
  ImportCarrierResolver({
    required this.isDirectory,
    required this.isImageArchive,
  });

  final bool Function(String path) isDirectory;
  final bool Function(String path) isImageArchive;

  String? _cachedPath;
  ImportCarrier? _cachedCarrier;

  /// 判定 [path] 的载体身份；同一个 [path] 连续问只算一次真判定。
  ImportCarrier resolve(String path) {
    final ImportCarrier? cached = _cachedCarrier;
    if (cached != null && _cachedPath == path) return cached;
    final ImportCarrier carrier = classifyImportCarrier(
      path,
      isDirectory: isDirectory,
      isImageArchive: isImageArchive,
    );
    _cachedPath = path;
    _cachedCarrier = carrier;
    return carrier;
  }

  /// 丢弃记忆。路径指向的文件可能在对话框开着时被换掉，需要重新定性时调用。
  void invalidate() {
    _cachedPath = null;
    _cachedCarrier = null;
  }
}

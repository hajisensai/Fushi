/// 「书 ↔ 漫画」互相转化的**可行性判定**（纯函数层）。
///
/// 背景：`EpubBooks` 用 `format` 列区分三种书——`'epub'`（文字书/小说）、`'pdf'`、
/// `'manga'`（漫画 OCR）。三者共用同一个书目录 `<hoshi_books>/<bookKey>/`，`format`
/// 之外的身份（`bookKey` = 合集/标签/进度/统计/Profile 的 entryKey）完全不变。
///
/// **为什么需要转化**：查词能力只挂在 `format='manga'` 上，且不是「识别图像」——
/// 漫画能查词是因为 OCR 产出的文本被渲成一层透明 DOM（`.ocr-box`）叠在页图上，查词
/// 查的是那层真实文本节点。文字书阅读器对图片只有「揭开防剧透模糊 / 放大 / 画廊」，
/// 零 OCR 通道。所以一本扫描版漫画若当成普通 EPUB 导入，**在阅读器里点图永远查不了
/// 词**，除了转化没有别的出路。
///
/// **转化即重建**：不是翻一个字段就完事——`format='manga'` 的阅读器硬要求
/// `extractDir/manga.json` + `images/` 存在（缺了直接 `_loadFailed`），所以转过去
/// 必须真的产出页图与 `manga.json`。反向（漫画 → 书）则要求原始 `.epub`/`.pdf` 仍在
/// 书目录里；从 `.mokuro`/裸图片目录导入的漫画压根没有那个原始文件，只能明确说不支持
/// ——而不是造一本假书糊弄过去。
///
/// 本文件只做**判定**（纯函数，便于单测）；磁盘探测由调用方完成后把事实传进来，
/// 与 `drop_classification.dart` 的 `isDirectory` / `isImageArchive` 注入同一范式。
/// 真正的产物重建在 `book_format_rebuild.dart`。
library;

import 'package:hibiki_core/hibiki_core.dart';

/// 转化目标。
enum BookFormatTarget {
  /// 转成漫画（`format='manga'`）：产出页图 + `manga.json`，之后可跑整卷 OCR 查词。
  manga,

  /// 转回书（`format='epub'`/`'pdf'`）：把 `epubPath` 指回书目录里仍在的原始文件。
  book,
}

/// 不能转化的原因。每一条都要能直接翻译成一句**给用户看的**「为什么不支持」，
/// 而不是笼统一句「不支持」——用户报过「拖进去一点反应都没有」，说明白比拒绝重要。
enum BookConvertBlocker {
  /// 已经是目标格式了，无需转化。
  alreadyTarget,

  /// 文字书（普通 EPUB）没有可用作页图的内容。转成漫画后阅读器只会打开一本空书。
  textOnlyBook,

  /// 这本漫画是从 `.mokuro` / 裸图片目录导入的，书目录里没有可还原的原始
  /// `.epub`/`.pdf`。只能保持漫画身份。
  noOriginalFile,

  /// 记录在案的源文件在磁盘上找不到了（被手工删了 / 外部存储掉盘）。
  sourceMissing,
}

/// 判定结果。[blocker] 为 null 即可转化，[sourcePath] 是重建要读的源文件
/// （转漫画时 = 原 `.epub`/`.pdf`；转回书时 = 要指回去的那个原始文件）。
class BookConvertVerdict {
  const BookConvertVerdict.supported(this.sourcePath) : blocker = null;

  const BookConvertVerdict.blocked(BookConvertBlocker this.blocker)
      : sourcePath = null;

  /// 可转化时非 null：重建所需的源文件**绝对路径**。
  final String? sourcePath;

  /// 不可转化时非 null：具体原因（调用方据此给出说明文案）。
  final BookConvertBlocker? blocker;

  bool get supported => blocker == null;
}

/// 书目录里那份原始文件的既有形态（调用方探测后传入）。
///
/// 三种 format 的 `epubPath` 语义各不相同，故这里只描述**事实**、不描述格式：
/// - EPUB 行：`epubPath` = 原 `.epub` 文件名（导入时拷进书目录，仍在）；
/// - PDF 行：`epubPath` = `hibiki.pdf`（PDF 拷进书目录，仍在）；
/// - 漫画行：`epubPath` = `manga.json`（**不是**原始文件；原始文件可能存在也可能
///   压根没有过——`.mokuro`/裸目录导入的漫画就没有）。
class BookSourceProbe {
  const BookSourceProbe({
    required this.sourceExists,
    required this.sourceIsImageArchive,
    this.recoverableOriginalPath,
  });

  /// `extractDir/epubPath` 指向的文件当前是否存在。
  final bool sourceExists;

  /// 该文件是不是「一包页图」（`MangaArchiveImporter.looksLikeImageArchive`，
  /// 对 `.epub` 有专门的图片型判定分支）。PDF 恒可渲染成页图，不看这一位。
  final bool sourceIsImageArchive;

  /// 漫画行专用：书目录里仍在的原始 `.epub`/`.pdf` 绝对路径（没有则 null）。
  final String? recoverableOriginalPath;
}

/// 判定一本书能否转成漫画。纯函数。
///
/// [format] / [sourceAbsolutePath] 来自 `EpubBooks` 行（后者 =
/// `p.join(extractDir, epubPath)`），[probe] 是调用方的磁盘探测结果。
BookConvertVerdict verdictToManga({
  required BookFormat format,
  required String sourceAbsolutePath,
  required BookSourceProbe probe,
}) {
  if (format == BookFormat.manga) {
    return const BookConvertVerdict.blocked(BookConvertBlocker.alreadyTarget);
  }
  if (!probe.sourceExists) {
    return const BookConvertVerdict.blocked(BookConvertBlocker.sourceMissing);
  }
  // PDF 每一页都能栅格化成页图，恒可转（扫描版 PDF 转过来正是刚需：PDF 阅读器
  // 对无文本层的扫描件明确不做 OCR 兜底，转成漫画才有查词）。
  if (format == BookFormat.pdf) {
    return BookConvertVerdict.supported(sourceAbsolutePath);
  }
  // 普通 EPUB：只有「图片型」（扫描版漫画常见的分发形态）才有页图可用。
  // 文字书转过去只会得到一本空漫画——明确说清楚，别让用户转完才发现。
  if (!probe.sourceIsImageArchive) {
    return const BookConvertVerdict.blocked(BookConvertBlocker.textOnlyBook);
  }
  return BookConvertVerdict.supported(sourceAbsolutePath);
}

/// 判定一本漫画能否转回书。纯函数。
///
/// 「转回」是把 `epubPath` 指回书目录里**仍在的**原始 `.epub`/`.pdf`——那才是真书。
/// 从 `.mokuro`/裸图片目录导入的漫画没有这样的原始文件，不支持（不造假书）。
BookConvertVerdict verdictToBook({
  required BookFormat format,
  required BookSourceProbe probe,
}) {
  if (format != BookFormat.manga) {
    return const BookConvertVerdict.blocked(BookConvertBlocker.alreadyTarget);
  }
  final String? original = probe.recoverableOriginalPath;
  if (original == null || original.isEmpty) {
    return const BookConvertVerdict.blocked(BookConvertBlocker.noOriginalFile);
  }
  return BookConvertVerdict.supported(original);
}

/// [DiscoveryDomainImporters] 里纯 Dart 的那几个域原语：EPUB / 文本 / 漫画图包 /
/// 有声书对齐。app 的生产装配（`discovery_import_production.dart`）与无头服务端
/// （`fushi_server` 的 `ServerDownloadHost`）共用这一份，两边对同一个下载包的
/// 入库结果一致。
///
/// 不在这里的两个域：PDF（`PdfImporter` 靠 pdfrx 插件栅格化封面）与游戏登记
/// （`GalgameRepository` 是 app 的库），它们只在 app 里接线；没有它们的宿主用
/// [unsupportedDiscoveryImporter] 如实挡下。
///
/// 策略全部是 `DuplicatePolicy.skip()`：后台批量入库不弹交互，同名已在库即跳过
/// （返回 null，任务显示 0 条新增）。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart'
    show kAsrSuggestedSimilarityThreshold;
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/media/audiobook/standalone_subtitle_book.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

/// EPUB：`EpubImporter.importFromPath`。
Future<String?> importDiscoveryEpub(FushiDatabase db, String filePath) async {
  try {
    return await EpubImporter.importFromPath(
      db: db,
      filePath: filePath,
      fileName: discoveryImportFileName(filePath),
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 文本：`TextToEpub.convert` → `EpubImporter.import`（与书导入对话框同路）。
Future<String?> importDiscoveryText(FushiDatabase db, String filePath) async {
  final String title = discoveryImportStem(filePath);
  final Uint8List bytes = await TextToEpub.convert(
    file: File(filePath),
    title: title,
  );
  try {
    return await EpubImporter.import(
      db: db,
      bytes: bytes,
      fileName: '$title.epub',
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 漫画图包：`MangaArchiveImporter.importArchive`（自建 staging、7-Zip/内置解码
/// 解包、识别包内 `.mokuro` sidecar、防穿越、失败回滚）。它的默认策略是
/// `.suffix()`（适合用户手动点的导入）；自动入库留副本会让重复下载悄悄堆出
/// 「XXX (2)」「XXX (3)」，所以这里显式 skip。
Future<String?> importDiscoveryMangaArchive(
  FushiDatabase db,
  String archivePath,
) async {
  try {
    return await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: archivePath,
      title: discoveryImportStem(archivePath),
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 有声书：正文（EPUB/文本）先入库拿 bookKey，再 `alignAndPersistAudiobook`
/// （与对话框 `_importEpubWithAlignment` 同路，进度/文案省略）。
Future<String?> importDiscoveryAudiobook({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required AudiobookRepository audiobookRepo,
  required AlignAudiobookPlan plan,
  double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
}) async {
  final String? bookKey = plan.contentPath.toLowerCase().endsWith('.epub')
      ? await importDiscoveryEpub(db, plan.contentPath)
      : await importDiscoveryText(db, plan.contentPath);
  if (bookKey == null) {
    // 同名书已在库：v1 不做「附着到既有书」的自动决策（换音频/换字幕是
    // 有损操作，交互入口是 AudiobookImportDialog）。音频并没有入库，不能
    // 装成「0 条新增」——那会落成一句没头没脑的 import failed（BUG-2775），
    // 以稳定原因码报出去，UI 告诉用户去已有书里手动导入有声书。
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
      discoveryImportFileName(plan.contentPath),
    );
  }
  await alignAndPersistAudiobook(
    db: db,
    repo: srtBookRepo,
    audiobookRepo: audiobookRepo,
    bookKey: bookKey,
    title: discoveryImportStem(plan.contentPath),
    subtitlePath: plan.subtitlePath,
    audioPaths: plan.audioPaths,
    similarityThreshold: similarityThreshold,
  );
  return bookKey;
}

/// 有声书正文入库时会不会撞上库里的同名书（撞上 = [importDiscoveryAudiobook]
/// 抛 `audiobookBookAlreadyInLibrary`）。判据与导入器逐项一致：EPUB 取 OPF
/// `dc:title`、缺了退文件名；文本取文件名；比较键是 `sanitizeTtuFilename`。
///
/// 给自动转录在**入队之前**用：转录要几个小时，转完才发现正文进不了库，任务
/// 只会失败、重试也一样失败。
Future<bool> isDuplicateDiscoveryAudiobookContent(
  FushiDatabase db,
  String contentPath,
) async {
  final String proposed = contentPath.toLowerCase().endsWith('.epub')
      ? (await Isolate.run(() => EpubParser.readTitleSync(contentPath))) ??
          discoveryImportStem(contentPath)
      : discoveryImportStem(contentPath);
  final String key = sanitizeTtuFilename(proposed);
  final List<EpubBookMeta> existing = await db.getEpubBookMetas();
  return existing.any((EpubBookMeta b) => sanitizeTtuFilename(b.title) == key);
}

/// 独立字幕书（字幕 + 音频、无正文）：[importStandaloneSubtitleBook]。
///
/// [title] 缺省取字幕文件名；转录产物的字幕叫 `transcript.srt`，调用方必须给。
/// 同名书已在库 → 跳过（返回 null），与其它域的自动入库同一策略。
Future<String?> importDiscoverySubtitleAudiobook({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required SubtitleAudiobookPlan plan,
  String? title,
}) async {
  try {
    final SrtBook book = await importStandaloneSubtitleBook(
      db: db,
      repo: srtBookRepo,
      title: title ?? discoveryImportStem(plan.subtitlePath),
      subtitlePath: plan.subtitlePath,
      audioPaths: plan.audioPaths,
      policy: const DuplicatePolicy.skip(),
    );
    return book.bookKey.isEmpty ? book.uid : book.bookKey;
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 设备端转录出字幕之后的入库：有正文走对齐（听写有误差，阈值按转录产物
/// 放宽，同书导入对话框选「转录」后的做法），没有就成独立字幕书。
Future<String?> importTranscribedAudiobook({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required AudiobookRepository audiobookRepo,
  required String subtitlePath,
  required List<String> audioPaths,
  String? contentPath,
  required String title,
}) {
  if (contentPath != null) {
    return importDiscoveryAudiobook(
      db: db,
      srtBookRepo: srtBookRepo,
      audiobookRepo: audiobookRepo,
      plan: AlignAudiobookPlan(
        contentPath: contentPath,
        subtitlePath: subtitlePath,
        audioPaths: audioPaths,
      ),
      similarityThreshold: kAsrSuggestedSimilarityThreshold,
    );
  }
  return importDiscoverySubtitleAudiobook(
    db: db,
    srtBookRepo: srtBookRepo,
    plan: SubtitleAudiobookPlan(
      subtitlePath: subtitlePath,
      audioPaths: audioPaths,
    ),
    title: title,
  );
}

/// 只有音频时给书起名：单文件取文件名；多文件取它们**最近公共祖先目录**的名字
/// （种子包的真实形状是「书名/01.mp3…」或多碟「书名/CD1/01.mp3、书名/CD2/…」——
/// 只看第一份文件的目录会把多碟包叫成「CD1」，跨目录退回文件名又会叫成「01」，
/// 两本这样的书就会被同名查重互相挤掉）。末尾的 `[ASIN]`（有声书工具的通行命名，
/// 如 `书名 [B0XXXXXXXX].m4b`）不是书名的一部分，去掉。
String audiobookTitleForAudioPaths(List<String> audioPaths) {
  if (audioPaths.isEmpty) return '';
  List<String> dirSegments(String path) {
    final List<String> parts = path.replaceAll('\\', '/').split('/');
    return parts.sublist(0, parts.length - 1);
  }

  String raw = discoveryImportStem(audioPaths.first);
  if (audioPaths.length > 1) {
    List<String> common = dirSegments(audioPaths.first);
    for (final String path in audioPaths.skip(1)) {
      final List<String> dir = dirSegments(path);
      int n = 0;
      while (n < common.length && n < dir.length && common[n] == dir[n]) {
        n++;
      }
      common = common.sublist(0, n);
    }
    final String ancestor = common.isEmpty ? '' : common.last;
    // 公共祖先是盘符根（`D:`）或文件系统根（空段）时没有书名可言。
    if (ancestor.isNotEmpty && !ancestor.endsWith(':')) raw = ancestor;
  }
  final String title =
      raw.replaceFirst(RegExp(r'\s*\[[A-Z0-9]{10}\]$'), '').trim();
  return title.isEmpty ? raw : title;
}

/// 本宿主接不了的域原语：抛 [DiscoveryImportBlocker.unsupportedOnThisHost]，
/// [what] 进 detail（如 `pdf` / `game`）。任务落成 needsAttention 并带稳定原因码，
/// 而不是假装导入了 0 条。
Never unsupportedDiscoveryImporter(String what, String path) =>
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.unsupportedOnThisHost,
      '$what: ${discoveryImportFileName(path)}',
    );

String discoveryImportFileName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String discoveryImportStem(String path) {
  final String base = discoveryImportFileName(path);
  final int dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

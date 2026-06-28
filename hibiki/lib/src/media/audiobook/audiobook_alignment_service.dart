import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart'
    show writeEpubBackedSrtBook;
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// 非 UI 进度回调（替代对话框的 reportProgress）。[fraction] 0..1，[message]
/// 是给用户看的步骤文案（service 不持有 i18n，文案由调用方喂）。
typedef AudiobookAlignmentProgress = void Function(
  double fraction,
  String message,
);

/// EPUB + 字幕 + 可选音频 -> 有声书 对齐落库的可复用结果。
@immutable
class AudiobookAlignmentResult {
  const AudiobookAlignmentResult({
    required this.health,
    required this.cueCount,
    required this.persistedAudioPaths,
  });

  /// 对齐健康度（matcher 命中率 / notApplicable / failed）。
  final AudiobookHealth health;

  /// 解析并落库的 cue 数。
  final int cueCount;

  /// 落盘后的音频绝对路径（复制导入后位于持久目录；可空）。
  final List<String> persistedAudioPaths;
}

/// 解析步骤的可注入文案集合，使 service 不依赖 i18n（t.*）。各字段对应原
/// 对话框 _importEpubWithAlignment 里 reportProgress 的文案；批量扫描器可
/// 传简短英文或留空字符串（进度文案对落库结果无影响）。
@immutable
class AudiobookAlignmentMessages {
  const AudiobookAlignmentMessages({
    this.readingIdb = '',
    this.parsing = '',
    this.matching = '',
    this.persisting = '',
    this.saving = '',
    this.done = '',
    this.copyingFile,
  });

  final String readingIdb;
  final String parsing;
  final String matching;
  final String persisting;
  final String saving;
  final String done;

  /// 复制某文件时的文案构造器（参数为 basename）；null 时复用 [persisting]。
  final String Function(String name)? copyingFile;

  String _copying(String name) => copyingFile?.call(name) ?? persisting;
}

/// 按字幕扩展名分派解析器（与对话框 _parseCuesWithIndex 逐字节等价）。
Future<List<AudioCue>> parseCuesForFormat(
  File file,
  String bookKey,
  int audioFileIndex,
) {
  final String ext = file.path.split('.').last.toLowerCase();
  switch (ext) {
    case 'lrc':
      return LrcParser.parse(
          lrcFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
    case 'vtt':
      return VttParser.parse(
          vttFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
    case 'ass':
    case 'ssa':
      return AssParser.parse(
          assFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
    default:
      return SrtParser.parse(
          srtFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
  }
}

/// 非 UI 的 EPUB + 字幕 + 可选音频 -> 有声书 对齐落库 service。
///
/// 从 BookImportDialog._importEpubWithAlignment 抽出 EPUB 导入之后的部分
/// （解析章节 -> 解析 cue -> 跑 matcher -> 持久字幕/音频 -> 写 Audiobooks +
/// 配对 SrtBook + cue + health overlay）；对话框只保留 UI 相关的 EPUB 导入、
/// 封面、同名书弹窗，导入完拿到 [bookKey] 后调本函数，行为逐字节等价。
///
/// 入参均为已就位的本地绝对路径（[subtitlePath] 必给；[audioPaths] 可空）。
/// [autoWindow] / [searchWindow] / [similarityThreshold] 与对话框同名字段语义
/// 一致。[onProgress] 替代 reportProgress，[messages] 注入步骤文案；二者皆可
/// 省略（扫描器不需要 UI 进度）。返回 [AudiobookAlignmentResult]。
Future<AudiobookAlignmentResult> alignAndPersistAudiobook({
  required HibikiDatabase db,
  required SrtBookRepository repo,
  required AudiobookRepository audiobookRepo,
  required String bookKey,
  required String title,
  String? author,
  required String subtitlePath,
  List<String> audioPaths = const <String>[],
  bool autoWindow = true,
  int searchWindow = EpubSrtMatcher.defaultSearchWindow,
  double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
  AudiobookAlignmentProgress? onProgress,
  AudiobookAlignmentMessages messages = const AudiobookAlignmentMessages(),
}) async {
  void report(double f, String m) => onProgress?.call(f, m);

  report(0.35, messages.readingIdb);
  List<EpubSection> sections = const <EpubSection>[];
  try {
    final EpubBookRow? bookRow = await db.getEpubBook(bookKey);
    final String extractDir = bookRow?.extractDir ?? '';
    final EpubBook epubBook = EpubParser.parseFromExtracted(extractDir);
    sections = List<EpubSection>.generate(
      epubBook.chapters.length,
      (i) => EpubSection(
        index: i,
        href: epubBook.chapters[i].href,
        text: epubBook.chapterPlainText(i),
      ),
    );
  } catch (e, stack) {
    ErrorLogService.instance
        .log('AudiobookAlignmentService.parseEpub', e, stack);
    debugPrint('[hibiki-import] parseFromExtracted failed: $e');
  }
  report(0.45, messages.parsing);
  final String ext = subtitlePath.split('.').last.toLowerCase();
  final List<AudioCue> cues = await parseCuesForFormat(
    File(subtitlePath),
    bookKey,
    0,
  );
  AudiobookHealth health;
  final bool runMatcher = SasayakiRematch.supportedFormats.contains(ext);
  if (runMatcher && sections.isNotEmpty && cues.isNotEmpty) {
    report(0.55, messages.matching);
    MatchResult? matchResult;
    int chosenWindow = searchWindow;
    if (autoWindow) {
      final ProbeResult probe = await EpubCueMatcher.probeInIsolate(
        sections: sections,
        cues: cues,
      );
      final MapEntry<int, double>? best = probe.best;
      if (best != null && best.value > 0) {
        chosenWindow = best.key;
        matchResult = probe.bestResult;
      }
    }
    matchResult ??= await EpubCueMatcher.matchInIsolate(
      sections: sections,
      cues: cues,
      searchWindow: chosenWindow,
      similarityThreshold: similarityThreshold,
    );
    SasayakiMatchCodec.applyToCues(cues: cues, result: matchResult);
    final int pct = (matchResult.matchRate * 100).round();
    health = AudiobookHealth.fromRatePct(
      ratePct: pct,
      reason:
          '${matchResult.matchedCues}/${matchResult.totalCues} cues matched '
          '(window=$chosenWindow)',
    );
  } else if (runMatcher) {
    health = sections.isEmpty
        ? AudiobookHealth.failed(reason: 'ttu IDB record had 0 sections')
        : AudiobookHealth.failed(reason: 'parser returned 0 cues');
  } else {
    health = AudiobookHealth.notApplicable(
      reason: '$ext format uses file anchors, no matcher needed',
    );
  }

  report(0.8, messages.persisting);
  final Directory persistDir = await AudiobookStorage.ensurePersistDir(bookKey);
  final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
    File(subtitlePath),
    persistDir,
    onProgress: (int copied, int total) {
      report(0.8, messages._copying(p.basename(subtitlePath)));
    },
  );

  await AudiobookStorage.cleanAudioFiles(persistDir);
  final List<String> persistedAudioPaths = <String>[];
  for (final String src in audioPaths) {
    persistedAudioPaths.add(
      await AudiobookStorage.persistFileWithProgress(
        File(src),
        persistDir,
        onProgress: (int copied, int total) {
          report(0.85, messages._copying(p.basename(src)));
        },
      ),
    );
  }

  report(0.9, messages.saving);
  final Audiobook audiobook = Audiobook()
    ..bookKey = bookKey
    ..alignmentFormat = ext
    ..alignmentPath = persistedSrt;
  if (persistedAudioPaths.isNotEmpty) {
    audiobook.audioPaths = persistedAudioPaths;
  }
  health.packInto(audiobook);

  await audiobookRepo.saveAudiobook(audiobook);
  await writeEpubBackedSrtBook(
    repo: repo,
    bookKey: bookKey,
    title: title,
    author: author,
    srtPath: persistedSrt,
    audioPaths: persistedAudioPaths,
  );
  await audiobookRepo.saveCues(
    bookKey: bookKey,
    cues: cues,
  );
  await audiobookRepo.updateHealthOverlay(
    bookKey: bookKey,
    health: health,
  );
  report(1, messages.done);

  return AudiobookAlignmentResult(
    health: health,
    cueCount: cues.length,
    persistedAudioPaths: persistedAudioPaths,
  );
}

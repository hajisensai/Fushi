import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';
import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

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

/// 从 EPUB 提取目录构建 matcher 用的章节列表。本 service、导入对话框
/// （probe / matcher）与 [SasayakiRematch]（弹窗 probe / 重跑）五个调用点共用；
/// 解析异常由各调用方按自身语义 try/catch，此处不吞。
/// 转录产物的命中 cue 按正文句界重切（见 `CueSentenceResegmenter`）；三个
/// 匹配入口共用这一处，统计打进日志便于真机对照。
CueResegmentResult resegmentCuesBySentence({
  required List<EpubSection> sections,
  required List<AudioCue> cues,
  required MatchResult result,
}) {
  final CueResegmentResult out = const CueSentenceResegmenter().resegment(
    sections: sections,
    cues: cues,
    result: result,
  );
  debugPrint('[fushi-import] resegment: ${out.stats}');
  return out;
}

List<EpubSection> epubSectionsFromExtractDir(String extractDir) {
  final EpubBook epubBook = EpubParser.parseFromExtracted(extractDir);
  return epubSectionsFromBook(epubBook);
}

/// 每章纯文本（与 `chapterPlainText` 逐码元相同）+ ruby 读音旁路（匹配器的
/// 读音轨，见 `EpubSection.rubies`）。
List<EpubSection> epubSectionsFromBook(EpubBook epubBook) {
  return List<EpubSection>.generate(epubBook.chapters.length, (int i) {
    final EpubPlainTextWithRuby chapter = epubBook.chapterPlainTextWithRuby(i);
    return EpubSection(
      index: i,
      href: epubBook.chapters[i].href,
      text: chapter.text,
      rubies: <EpubRubySpan>[
        for (final EpubRubyAnnotation r in chapter.rubies)
          EpubRubySpan(start: r.start, end: r.end, reading: r.reading),
      ],
    );
  });
}

/// 按字幕扩展名分派解析器（原两个导入对话框各持等价副本，已收敛到此单一真相源）。
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
/// [replaceCueTextWithBookText]：字幕是设备端转录产物时置 true，命中 cue 的文本
/// 落库前换成正文原文（见 `replaceMatchedCueTextWithBookText`）。
///
/// 入参均为已就位的本地绝对路径（[subtitlePath] 必给；[audioPaths] 可空）。
/// [autoWindow] / [searchWindow] / [similarityThreshold] 与对话框同名字段语义
/// 一致。[onProgress] 替代 reportProgress，[messages] 注入步骤文案；二者皆可
/// 省略（扫描器不需要 UI 进度）。返回 [AudiobookAlignmentResult]。
Future<AudiobookAlignmentResult> alignAndPersistAudiobook({
  required FushiDatabase db,
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
  bool replaceCueTextWithBookText = false,
}) async {
  void report(double f, String m) => onProgress?.call(f, m);

  report(0.35, messages.readingIdb);
  List<EpubSection> sections = const <EpubSection>[];
  try {
    final EpubBookRow? bookRow = await db.getEpubBook(bookKey);
    final String extractDir = bookRow?.extractDir ?? '';
    sections = epubSectionsFromExtractDir(extractDir);
  } catch (e, stack) {
    ErrorLogService.instance
        .log('AudiobookAlignmentService.parseEpub', e, stack);
    debugPrint('[fushi-import] parseFromExtracted failed: $e');
  }
  report(0.45, messages.parsing);
  final String ext = subtitlePath.split('.').last.toLowerCase();
  List<AudioCue> cues = await parseCuesForFormat(
    File(subtitlePath),
    bookKey,
    0,
  );
  // 转录产物：把 sidecar 里的逐 token 时间挂上（非产物 / 缺失时 false）。
  final bool hasTokenTiming =
      await AsrTranscriptionService.attachCueTokenTiming(
    cues,
    subtitlePath,
  );
  AudiobookHealth health;
  final bool runMatcher = SubtitleRematch.supportedFormats.contains(ext);
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
    if (hasTokenTiming) {
      // 命中 cue 按正文句界重切（词中切开的合并、一条盖两句的拆开），边界时间
      // 取 token 发射时间；cue 列表与匹配结果一起换新。
      final CueResegmentResult resegmented = resegmentCuesBySentence(
        sections: sections,
        cues: cues,
        result: matchResult,
      );
      cues = resegmented.cues;
      matchResult = resegmented.result;
    }
    if (replaceCueTextWithBookText) {
      // ASR 听写文本 → 正文原文：阅读器按 cue 文本在 DOM 里重定位，听写差会让
      // 高亮漂移；换成正文后逐字精确（未命中的保留听写文本）。
      replaceMatchedCueTextWithBookText(
        sections: sections,
        cues: cues,
        result: matchResult,
      );
    }
    SubtitleRematchCodec.applyToCues(cues: cues, result: matchResult);
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

  // 持久目录音频的唯一写入原语（同步成恰好这一组，幂等、不会先删掉自己的源）。
  final List<String> persistedAudioPaths =
      await AudiobookStorage.syncAudioFiles(
    persistDir,
    audioPaths,
    onFile: (String name) => report(0.85, messages._copying(name)),
  );

  report(0.9, messages.saving);
  // 窄写入：一次只说一件事，没有整行入口可以误清别的列（BUG-1678）。
  await audiobookRepo.replaceAlignment(
    bookKey: bookKey,
    format: ext,
    path: persistedSrt,
  );
  if (persistedAudioPaths.isNotEmpty) {
    await audiobookRepo.replaceAudio(
      bookKey: bookKey,
      audioPaths: persistedAudioPaths,
    );
  }
  await audiobookRepo.writeHealth(bookKey: bookKey, health: health);
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

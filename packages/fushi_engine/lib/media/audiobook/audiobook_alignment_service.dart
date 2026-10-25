import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/audiobook/asr_cue_post_host.dart';
import 'package:fushi_engine/media/audiobook/audiobook_text_coverage.dart';
import 'package:fushi_engine/media/audiobook/subtitle_rematch_policy.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:fushi_engine/media/video/video_clip_subtitle.dart'
    show formatSrtTimestamp;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:meta/meta.dart';

/// 非 UI 进度回调（替代对话框的 reportProgress）。[fraction] 0..1，[message]
/// 是给用户看的步骤文案（service 不持有 i18n，文案由调用方喂）。
typedef AudiobookAlignmentProgress =
    void Function(double fraction, String message);

/// 对齐落库走到了哪一步（[alignAndPersistAudiobook] 的 `onStep`）。与
/// [AudiobookAlignmentProgress] 的 fraction 不同，这里**不给数值**：匹配器在 isolate
/// 里一次跑完、中途不报进度，各步的 fraction 只是排版用的固定刻度，UI 要的是
/// 「现在在干什么」——[readingText] .. [finishing] 是「匹配正文」，[persisting] /
/// [saving] 是「入库」。
enum AudiobookAlignmentStep {
  readingText,
  parsingSubtitle,
  matching,
  finishing,
  persisting,
  saving,
  done,
}

/// [AudiobookAlignmentStep] 回调；[detail] 是正在复制的文件名（[persisting] 时）。
typedef AudiobookAlignmentStepCallback =
    void Function(AudiobookAlignmentStep step, {String? detail});

/// 对齐 / 重新导入在**写盘之前**的检查点上发现已被取消。
///
/// 只在提交点之前抛：持久目录同步（会删旧音频）与写库一旦开始就做完，绝不半途
/// 停下留下「库指着已删文件」的残局。抛出时库与持久目录都还没动。
class AudiobookAlignmentCancelled implements Exception {
  const AudiobookAlignmentCancelled();

  @override
  String toString() => 'AudiobookAlignmentCancelled';
}

/// [isCancelled] 为真时抛 [AudiobookAlignmentCancelled]（null 视为永不取消）。
void throwIfAlignmentCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) throw const AudiobookAlignmentCancelled();
}

/// EPUB + 字幕 + 可选音频 -> 有声书 对齐落库的可复用结果。
@immutable
class AudiobookAlignmentResult {
  const AudiobookAlignmentResult({
    required this.health,
    required this.cueCount,
    required this.persistedAudioPaths,
    this.coverage,
  });

  /// 对齐健康度（matcher 命中率 / notApplicable / failed）。
  final AudiobookHealth health;

  /// 解析并落库的 cue 数。
  final int cueCount;

  /// 落盘后的音频绝对路径（复制导入后位于持久目录；可空）。
  final List<String> persistedAudioPaths;

  /// 正文覆盖情况（见 [AudiobookTextCoverage]）；没跑匹配器时 null。
  final AudiobookTextCoverage? coverage;
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
/// 把转录产物旁边的逐 token 时间 sidecar 挂到从同一份 SRT 解析出来的 [cues] 上，
/// 供匹配后按正文句界重切（[finalizeAlignedCues] 第 1 步）。
///
/// 一条都没挂上时返回 false。**四种情况都算没挂**：不是转录产物、sidecar 缺失、
/// sidecar 读不动、**行数与 cue 数不符**。
///
/// 最后那条最重要，也最容易在重构里丢：行数不等时哪怕只挂上前面对得上的几条，
/// 后面全部错位，而下游照样跑完、照样落库、UI 完全正常，只是跳播位置全偏——没有
/// 任何断言会红。**行号错位比没有更糟**，所以宁可一条都不挂。
///
/// 抽包之后 `fushi_asr_core` 只负责「读 sidecar 并回读到的行」（`readCueTokenTimings`），
/// 挂到哪种 cue 类型上是宿主的事，长度校验也就落在这里。
Future<bool> attachAsrCueTokenTiming(
  List<AudioCue> cues,
  String subtitlePath,
) async {
  final List<AsrCueTokenTiming>? rows =
      await AsrTranscriptionService.readCueTokenTimings(
        subtitlePath,
        expectedCount: cues.length,
      );
  if (rows == null) return false;
  if (rows.length != cues.length) return false;
  for (int i = 0; i < cues.length; i++) {
    cues[i].tokenTiming = CueTokenTiming(
      tokens: rows[i].tokens,
      offsetsMs: rows[i].offsetsMs,
    );
  }
  return true;
}

/// 转录产物对齐后另写的一份字幕：命中 cue 已换成正文原文（标点、引号在内）、
/// 已按句界重切。与原始 `transcript.srt` 同目录并存——原始那份不能覆盖，它是
/// `transcript.tokens.jsonl` 的行号基准，也是重匹配的输入。
const String kAsrAlignedTranscriptFileName = 'transcript.aligned.srt';

/// [srtPath] 旁边对齐版字幕的路径（不检查存在）。
String asrAlignedTranscriptPathFor(String srtPath) =>
    p.join(p.dirname(srtPath), kAsrAlignedTranscriptFileName);

/// 对齐版旁边的「非正文语音」：转录到了、却不是书里正文的 cue（念出来的人物介绍
/// 图片页、片头片尾的出版社与朗读者、旁白外的念白），保留听写原文与时间。
const String kAsrSpeechTranscriptFileName = 'transcript.speech.srt';

/// 匹配健康时（命中率不低于此值）对齐版只放命中正文的 cue，其余另写
/// [kAsrSpeechTranscriptFileName]；低于此值多半是配错了书，对齐版退回全量。
const double kAsrAlignedBookOnlyMinMatchRate = 0.5;

/// 「导出 SRT」该拷哪个文件：对齐版存在就是它，否则原始听写稿。第一次导出
/// 发生在「使用字幕」之前（对齐还没跑），拿到的必然是原始稿；这不是 bug。
String preferredTranscriptExportPath(String srtPath) {
  final String aligned = asrAlignedTranscriptPathFor(srtPath);
  return File(aligned).existsSync() ? aligned : srtPath;
}

/// 匹配之后、落库之前的收尾。书导入 service（[alignAndPersistAudiobook]）与
/// 有声书导入对话框原先各持一份逐行相同的三步链，现在只有这一处：
///
/// 1. 有逐 token 时间 → 命中 cue 按正文句界重切（cue 列表与匹配结果一起换新）；
/// 2. 字幕是设备端转录产物 → 命中 cue 的听写文本换成正文原文（阅读器按 cue 文本
///    在 DOM 里重定位，听写差会让高亮漂移；未命中的保留听写），再把句界吸到转录时
///    写下的能量包络的真实停顿上、并回句内短碎片、留跟读显示余量
///    （[postProcessTranscribedCues]，算法在上游 fushi-subtitles）；
/// 3. 匹配结果编进 cue；
/// 4. 转录产物把对齐后的 cue 另写成 [kAsrAlignedTranscriptFileName]，供「导出
///    SRT」优先拷——之前替换后的文本只活在 DB 里，用户导出拿到的永远是没标点的
///    听写稿。写盘失败只记日志：它是导出的便利品，不是落库链路的一部分。
///    对齐版**只放命中正文的 cue**（见 [kAsrAlignedBookOnlyMinMatchRate]）：导出
///    的消费方是 Hoshi 这类按文本单调游标对齐的阅读器，一条未命中的听写短句
///    （人物介绍页念的「趣味」）会被它在 2000 字窗口里匹配到后文、游标一跳过去，
///    其后整本正文全部失配（春物 2 卷整本 Hoshi 口径覆盖 3% → 只放命中 99.7%）。
///    未命中的 cue 写进 [kAsrSpeechTranscriptFileName]，DB 里照旧全部保留。
///
/// 1–2 步（整书重切的打包 / 编辑距离对齐 FFI / 结果组装、换正文、读能量包络与吸附）
/// 整段放在一个后台 isolate 里跑（与匹配器的 `EpubCueMatcher.matchInIsolate` 同一种
/// `Isolate.run`；fushi_compute 在工作 isolate 里按同一套规则自行加载），大书不在 UI
/// isolate 上卡帧。cue 与匹配结果是纯数据，拷过去、算完经 `Isolate.exit` 交回：返回的
/// cue 是新对象，调用方一律用返回值（对话框据此换掉自己持有的列表内容）。两步都不需要
/// （不是转录产物、没有 token 时间）时不派发，原列表原样返回。
Future<({List<AudioCue> cues, MatchResult result})> finalizeAlignedCues({
  required List<EpubSection> sections,
  required List<AudioCue> cues,
  required MatchResult result,
  required String subtitlePath,
  required bool hasTokenTiming,
}) async {
  final bool asrGenerated = AsrTranscriptionService.isAsrGeneratedSubtitlePath(
    subtitlePath,
  );
  if (hasTokenTiming || asrGenerated) {
    final AlignedCueComputation computed =
        await _computeAlignedCuesInBackground(
          AlignedCueRequest(
            sections: sections,
            cues: cues,
            result: result,
            subtitlePath: subtitlePath,
            hasTokenTiming: hasTokenTiming,
            asrGenerated: asrGenerated,
          ),
        );
    debugLastAlignedCueIsolate = computed.isolateName;
    cues = computed.cues;
    result = computed.result;
    final CueResegmentStats? stats = computed.resegmentStats;
    if (stats != null) fushiDebugPrint('[fushi-import] resegment: $stats');
    if (computed.snappedBoundaries != null) {
      fushiDebugPrint(
        '[fushi-import] energy snap: ${computed.snappedBoundaries} '
        'boundaries, ${computed.refinedEdges} edges, '
        '${computed.mergedFragments} fragments merged, '
        '${computed.displayMargins} margin edges',
      );
    }
  }
  SubtitleRematchCodec.applyToCues(cues: cues, result: result);
  if (asrGenerated) {
    try {
      final bool bookOnly =
          result.matches.length == cues.length &&
          result.matchRate >= kAsrAlignedBookOnlyMinMatchRate;
      final List<AudioCue> book = <AudioCue>[];
      final List<AudioCue> speech = <AudioCue>[];
      for (int i = 0; i < cues.length; i++) {
        (!bookOnly || result.matches[i].matched ? book : speech).add(cues[i]);
      }
      await File(
        asrAlignedTranscriptPathFor(subtitlePath),
      ).writeAsString(serializeAudioCuesToSrt(book));
      final File speechFile = File(
        p.join(p.dirname(subtitlePath), kAsrSpeechTranscriptFileName),
      );
      if (speech.isNotEmpty) {
        await speechFile.writeAsString(serializeAudioCuesToSrt(speech));
      } else if (speechFile.existsSync()) {
        await speechFile.delete();
      }
      // 转录弹层再打开时显示「上次匹配」的覆盖情况。
      await writeAsrCoverageSidecar(
        subtitlePath,
        computeAudiobookTextCoverage(sections: sections, result: result),
      );
    } catch (e, stack) {
      engineLog.log('AudiobookAlignmentService.writeAlignedSrt', e, stack);
    }
  }
  return (cues: cues, result: result);
}

/// [AudioCue] 列表 → SRT 文本（序号从 1 起、`HH:MM:SS,mmm`、cue 间空行）。
/// 与 `SrtParser` 的解析契约一致；空文本 cue 跳过（与 `serializeAsrCuesToSrt`
/// 同规则）。
String serializeAudioCuesToSrt(List<AudioCue> cues) {
  final StringBuffer sb = StringBuffer();
  int index = 1;
  for (final AudioCue cue in cues) {
    if (cue.text.isEmpty) continue;
    sb
      ..writeln(index++)
      ..writeln(
        '${formatSrtTimestamp(cue.startMs)} --> '
        '${formatSrtTimestamp(cue.endMs)}',
      )
      ..writeln(cue.text.replaceAll('\n', ' '))
      ..writeln();
  }
  return sb.toString();
}

/// [finalizeAlignedCues] 送进后台 isolate 的输入（全是可跨 isolate 拷贝的纯数据）。
@visibleForTesting
class AlignedCueRequest {
  const AlignedCueRequest({
    required this.sections,
    required this.cues,
    required this.result,
    required this.subtitlePath,
    required this.hasTokenTiming,
    required this.asrGenerated,
  });

  final List<EpubSection> sections;
  final List<AudioCue> cues;
  final MatchResult result;

  /// 转录产物 SRT 路径：能量包络在它的同目录。
  final String subtitlePath;
  final bool hasTokenTiming;
  final bool asrGenerated;
}

/// 后台 isolate 算完交回的结果；日志由调用方 isolate 打（工作 isolate 里没有宿主装配的
/// `fushiDebugPrint`）。
@visibleForTesting
class AlignedCueComputation {
  const AlignedCueComputation({
    required this.cues,
    required this.result,
    required this.isolateName,
    this.resegmentStats,
    this.snappedBoundaries,
    this.refinedEdges,
    this.mergedFragments,
    this.displayMargins,
  });

  final List<AudioCue> cues;
  final MatchResult result;

  /// 实际执行计算的 isolate 的 debugName（测试据此确认计算不在调用方 isolate 上）。
  final String isolateName;

  /// 做了重切时的统计。
  final CueResegmentStats? resegmentStats;

  /// 做了能量吸附时移动的句界数 / 修整的首尾数。
  final int? snappedBoundaries;
  final int? refinedEdges;

  /// 设备端转录产物并回相邻 cue 的句内碎片数（[postProcessTranscribedCues]）。
  final int? mergedFragments;

  /// 跟读显示余量动过的边数（[postProcessTranscribedCues]）。
  final int? displayMargins;
}

/// [finalizeAlignedCues] 的后台 isolate debugName。
@visibleForTesting
const String kAlignedCueIsolateName = 'fushi-aligned-cue-finish';

/// 最近一次 [finalizeAlignedCues] 的重切 / 吸附实际在哪个 isolate 上跑（debugName）；
/// 只给测试观测「计算经后台入口」用。
@visibleForTesting
String? debugLastAlignedCueIsolate;

/// 单独成函数：交给 `Isolate.run` 的闭包只捕获 [request]，不把调用方的其它局部变量
/// 一起拷过 isolate 边界。
Future<AlignedCueComputation> _computeAlignedCuesInBackground(
  AlignedCueRequest request,
) => Isolate.run(
  () => computeAlignedCues(request),
  debugName: kAlignedCueIsolateName,
);

/// [finalizeAlignedCues] 第 1–2 步的计算本体（同步）：生产路径只在后台 isolate 里调它。
/// 测试直接调用以对拍。
@visibleForTesting
AlignedCueComputation computeAlignedCues(AlignedCueRequest request) {
  List<AudioCue> cues = request.cues;
  MatchResult result = request.result;
  CueResegmentStats? stats;
  if (request.hasTokenTiming) {
    // 转录产物的命中 cue 按正文句界重切（见 `CueSentenceResegmenter`）。
    final CueResegmentResult resegmented = const CueSentenceResegmenter()
        .resegment(sections: request.sections, cues: cues, result: result);
    cues = resegmented.cues;
    result = resegmented.result;
    stats = resegmented.stats;
  }
  int? moved;
  int? edges;
  int? fragments;
  int? margins;
  if (request.asrGenerated) {
    replaceMatchedCueTextWithBookText(
      sections: request.sections,
      cues: cues,
      result: result,
    );
    // 后处理（算法在上游 fushi-subtitles，见 asr_cue_post_host.dart）：句界吸到转录时顺手
    // 写下的能量包络的真实停顿上（旧任务没有包络就只做合并）→ 句内短碎片（「何か、」
    // 「おかしい。」）并回一条 → 按语速留跟读余量（快档贴声音，慢 / 正常档前后多留一两百毫秒）。
    final Int8List? energy = readAsrEnergyTimeline(
      Directory(p.dirname(request.subtitlePath)),
    );
    final TranscribedCuePostResult post = postProcessTranscribedCues(
      cues: cues,
      result: result,
      energy: energy,
    );
    cues = post.cues;
    result = post.result;
    moved = post.snappedBoundaries;
    edges = post.refinedEdges;
    fragments = post.mergedFragments;
    margins = post.displayMarginEdges;
  }
  return AlignedCueComputation(
    cues: cues,
    result: result,
    isolateName: Isolate.current.debugName ?? '',
    resegmentStats: stats,
    snappedBoundaries: moved,
    refinedEdges: edges,
    mergedFragments: fragments,
    displayMargins: margins,
  );
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

/// [epubSectionsFromExtractDir] 的后台 isolate 版——生产路径一律走这里。
///
/// 每章都要读文件 + 整个 HTML5 DOM 解析 + 剥 ruby，一本几百章的轻小说是几百 MB
/// 的瞬时 DOM 和数秒的 CPU；匹配器早就放 isolate 了（[EpubCueMatcher.matchInIsolate]），
/// 这一步是整条对齐链上唯一还留在 UI isolate 的重活。[EpubSection] 是纯数据
/// （index / href / text），可直接跨 isolate 传回。
///
/// 已知权衡：`EpubParser` 内部对坏 nav/ncx 的 `ErrorLogService.log` 落在工作
/// isolate 的临时实例上，不进主 isolate 的错误日志（与 `EpubImporter` 的导入
/// isolate 同款）；解析整体失败仍会抛回调用方并由其记日志。
Future<List<EpubSection>> loadEpubSectionsInBackground(String extractDir) =>
    Isolate.run(() => epubSectionsFromExtractDir(extractDir));

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
        lrcFile: file,
        bookKey: bookKey,
        audioFileIndex: audioFileIndex,
      );
    case 'vtt':
      return VttParser.parse(
        vttFile: file,
        bookKey: bookKey,
        audioFileIndex: audioFileIndex,
      );
    case 'ass':
    case 'ssa':
      return AssParser.parse(
        assFile: file,
        bookKey: bookKey,
        audioFileIndex: audioFileIndex,
      );
    default:
      return SrtParser.parse(
        srtFile: file,
        bookKey: bookKey,
        audioFileIndex: audioFileIndex,
      );
  }
}

/// 非 UI 的 EPUB + 字幕 + 可选音频 -> 有声书 对齐落库 service。
///
/// 从 BookImportDialog._importEpubWithAlignment 抽出 EPUB 导入之后的部分
/// （解析章节 -> 解析 cue -> 跑 matcher -> 持久字幕/音频 -> 写 Audiobooks +
/// 配对 SrtBook + cue + health overlay）；对话框只保留 UI 相关的 EPUB 导入、
/// 封面、同名书弹窗，导入完拿到 [bookKey] 后调本函数，行为逐字节等价。
///
/// 字幕是设备端转录产物时（`AsrTranscriptionService.isAsrGeneratedSubtitlePath`，
/// 由 [finalizeAlignedCues] 自行判定），命中 cue 的文本落库前换成正文原文。
///
/// 入参均为已就位的本地绝对路径（[subtitlePath] 必给；[audioPaths] 可空）。
/// [autoWindow] / [searchWindow] / [similarityThreshold] 与对话框同名字段语义
/// 一致。[onProgress] 替代 reportProgress，[messages] 注入步骤文案；二者皆可
/// 省略（扫描器不需要 UI 进度）。返回 [AudiobookAlignmentResult]。
///
/// [isCancelled]：在读章节 / 解析字幕 / 跑 matcher 这几步之间检查，为真时抛
/// [AudiobookAlignmentCancelled]；matcher 本身在 isolate 里跑、不可中断，所以取消
/// 在当前步骤结束后生效。开始持久化（0.8）之后不再检查——那之后是提交阶段。
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
  bool Function()? isCancelled,
  AudiobookAlignmentStepCallback? onStep,
}) async {
  void report(double f, String m) => onProgress?.call(f, m);
  void step(AudiobookAlignmentStep s, {String? detail}) =>
      onStep?.call(s, detail: detail);

  throwIfAlignmentCancelled(isCancelled);
  step(AudiobookAlignmentStep.readingText);
  report(0.35, messages.readingIdb);
  List<EpubSection> sections = const <EpubSection>[];
  try {
    final EpubBookRow? bookRow = await db.getEpubBook(bookKey);
    final String extractDir = bookRow?.extractDir ?? '';
    sections = await loadEpubSectionsInBackground(extractDir);
  } catch (e, stack) {
    engineLog.log('AudiobookAlignmentService.parseEpub', e, stack);
    fushiDebugPrint('[fushi-import] parseFromExtracted failed: $e');
  }
  throwIfAlignmentCancelled(isCancelled);
  step(AudiobookAlignmentStep.parsingSubtitle);
  report(0.45, messages.parsing);
  final String ext = subtitlePath.split('.').last.toLowerCase();
  List<AudioCue> cues = await parseCuesForFormat(
    File(subtitlePath),
    bookKey,
    0,
  );
  // 转录产物：把 sidecar 里的逐 token 时间挂上（非产物 / 缺失时 false）。
  final bool hasTokenTiming = await attachAsrCueTokenTiming(cues, subtitlePath);
  AudiobookHealth health;
  AudiobookTextCoverage? coverage;
  final bool runMatcher = SubtitleRematchPolicy.supportedFormats.contains(ext);
  throwIfAlignmentCancelled(isCancelled);
  if (runMatcher && sections.isNotEmpty && cues.isNotEmpty) {
    step(AudiobookAlignmentStep.matching);
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
    step(AudiobookAlignmentStep.finishing);
    final ({List<AudioCue> cues, MatchResult result}) finalized =
        await finalizeAlignedCues(
          sections: sections,
          cues: cues,
          result: matchResult,
          subtitlePath: subtitlePath,
          hasTokenTiming: hasTokenTiming,
        );
    cues = finalized.cues;
    matchResult = finalized.result;
    try {
      coverage = computeAudiobookTextCoverage(
        sections: sections,
        result: matchResult,
      );
    } catch (e, stack) {
      // 覆盖率只是展示用的读数，算不出来不能挡住落库。
      engineLog.log('AudiobookAlignmentService.coverage', e, stack);
    }
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

  // 最后一个检查点：之后是提交阶段（同步持久目录 + 写库），不再中断。
  throwIfAlignmentCancelled(isCancelled);
  step(AudiobookAlignmentStep.persisting, detail: p.basename(subtitlePath));
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
        onFile: (String name) {
          step(AudiobookAlignmentStep.persisting, detail: name);
          report(0.85, messages._copying(name));
        },
      );

  step(AudiobookAlignmentStep.saving);
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
  await audiobookRepo.saveCues(bookKey: bookKey, cues: cues);
  await audiobookRepo.updateHealthOverlay(bookKey: bookKey, health: health);
  step(AudiobookAlignmentStep.done);
  report(1, messages.done);

  return AudiobookAlignmentResult(
    health: health,
    cueCount: cues.length,
    persistedAudioPaths: persistedAudioPaths,
    coverage: coverage,
  );
}

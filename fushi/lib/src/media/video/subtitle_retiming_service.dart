/// 视频字幕**模型重定时**的装配层。
///
/// 算法住在 `fushi_asr_subtitles`（上游 fushi-subtitles 仓库）：拿一份设备端 ASR
/// 转录当参照，只认「归一化后唯一且单调」的文本锚点，锚点之间按分区域时钟模型推，
/// 推不出来的段原样保留——**正文与顺序一个字都不动**。
///
/// 与既有的三条调轴路径是不同的东西，别混：手动延迟 / 跳到相邻 cue / 波形自动对轴
/// 都只能整体平移一个 `delayMs`，修不了帧率漂移（越往后偏得越多）和分段偏移
/// （片头剪切、版本差异）。重定时逐句给时间，因此产出的是**一份新的字幕档**而不是
/// 一个偏移量。
///
/// 本层只做三件「只有本仓知道」的事：
/// 1. 把播放器的 [AudioCue] 换成算法要的 [SubtitleCue]（[retimingCuesFromAudioCues]）；
/// 2. 把本仓转录产物（SRT + 同序 token 时间 sidecar）包成 [RetimingTranscription]；
/// 3. 把结果写成一个新的外挂字幕档，交给视频页既有的外挂字幕导入路径去应用。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart'
    show AsrCueTokenTiming, AsrTranscriptionService;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

/// [RetimingTranscription] 的本仓实现：一次设备端转录的产物。
///
/// 只带算法真正要的两样——cue 列表与逐 token 发射时间。**不要**换成
/// `AsrTranscribeResult`：那是「任务落了哪些盘」的记录，与对轴无关。
class AsrRetimingTranscription implements RetimingTranscription {
  const AsrRetimingTranscription({
    required this.cues,
    required this.tokenTimings,
  });

  @override
  final List<SubtitleCue> cues;

  @override
  final List<AsrCueTokenTiming>? tokenTimings;

  /// 从转录落盘的 SRT（[AsrTranscribeResult.srtPath]）读一份参照转录。
  ///
  /// 文件不存在、读不动或不是合法 SRT 时返回 null（调用方据此提示失败，不要拿空
  /// 转录去跑对轴——那只会把所有 cue 判成「无锚点」再原样写回，白跑一趟）。
  ///
  /// 逐 token 发射时间是 SRT 旁边的 sidecar，**行数与 cue 数不符时整份丢掉**：
  /// 错位的 token 时间会把锚点钉到别的句子上，比没有更糟（与
  /// `attachAsrCueTokenTiming` 同一条纪律）。丢掉之后算法自动退回按 cue 边界取锚点。
  static Future<AsrRetimingTranscription?> fromTranscriptSrt(
    String srtPath,
  ) async {
    final File file = File(srtPath);
    if (!await file.exists()) return null;
    final List<SubtitleCue> cues;
    try {
      cues = parseRetimingSubtitles(await file.readAsString());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
    final List<AsrCueTokenTiming>? rows =
        await AsrTranscriptionService.readCueTokenTimings(
      srtPath,
      expectedCount: cues.length,
    );
    return AsrRetimingTranscription(
      cues: cues,
      tokenTimings: (rows != null && rows.length == cues.length) ? rows : null,
    );
  }
}

/// [retimingCuesFromAudioCues] 的产物：可送进算法的 cue，加上被剔掉的条数。
class RetimingInputCues {
  const RetimingInputCues({required this.cues, required this.droppedCount});

  /// 按原顺序编号（1-based）的可用 cue。
  final List<SubtitleCue> cues;

  /// 被剔掉的退化 cue 条数（空正文 / 起止时间非递增 / 负起点）。
  final int droppedCount;

  bool get isEmpty => cues.isEmpty;
}

/// **纯函数**：播放器 cue → 重定时输入。
///
/// 剔掉算法层会直接判非法的退化 cue（空正文、`endMs <= startMs`、负起点）——ASS
/// 转来的字幕里零长度 cue 并不罕见，让它们把整趟对轴炸成一个 FormatException 不
/// 合算。剔掉多少条如实回报（[RetimingInputCues.droppedCount]），由调用方告诉用户
/// 「新档比原档少了几句」，**不要**悄悄补一个 1ms 的假时间窗糊过去。
///
/// [SubtitleCue.index] 按剔除后的次序重编（1-based），与算法输出的 SRT 序号一致。
RetimingInputCues retimingCuesFromAudioCues(List<AudioCue> cues) {
  final List<SubtitleCue> out = <SubtitleCue>[];
  int dropped = 0;
  for (final AudioCue cue in cues) {
    if (cue.startMs < 0 ||
        cue.endMs <= cue.startMs ||
        cue.text.trim().isEmpty) {
      dropped++;
      continue;
    }
    out.add(SubtitleCue(
      index: out.length + 1,
      startMs: cue.startMs,
      endMs: cue.endMs,
      text: cue.text,
    ));
  }
  return RetimingInputCues(cues: out, droppedCount: dropped);
}

/// **纯函数**：重定时产物的档名。
///
/// `<原名>.retimed.srt`；[taken] 里已被占用时补 `-2`、`-3`…（重定时可以对同一部
/// 片跑很多次——换语言、换模型、改用另一版原始字幕——每次都该留下自己的档，
/// 覆盖掉上一次的结果等于让用户没法回头比较）。
///
/// [baseName] 可以带扩展名（`ep01.zh.ass`）也可以不带，一律先去掉扩展名。
String retimedSubtitleFileName(String baseName,
    {Set<String> taken = const <String>{}}) {
  final String stem = p.basenameWithoutExtension(baseName).trim();
  // 前导点要剥掉：`basenameWithoutExtension('.srt')` 原样返回 `.srt`（点开头被当成
  // 隐藏文件、不是扩展名），拼出来的 `.srt.retimed.srt` 在类 Unix 上是隐藏档，
  // 用户在文件管理器里根本看不见自己刚生成的字幕。
  final String stripped = stem.replaceFirst(RegExp(r'^\.+'), '');
  final String safe = stripped.isEmpty ? 'subtitle' : stripped;
  String candidate = '$safe.retimed.srt';
  int serial = 2;
  while (taken.contains(candidate)) {
    candidate = '$safe.retimed-$serial.srt';
    serial++;
  }
  return candidate;
}

/// 一次重定时的完整结果：新档路径 + 算法统计 + 输入侧剔除数。
class RetimedSubtitleFile {
  const RetimedSubtitleFile({
    required this.path,
    required this.cueCount,
    required this.droppedInputCues,
    required this.stats,
  });

  /// 落盘的新外挂字幕档（SRT，UTF-8）。
  final String path;

  /// 新档里的 cue 条数。
  final int cueCount;

  /// 输入侧被剔掉的退化 cue 条数（见 [retimingCuesFromAudioCues]）。
  final int droppedInputCues;

  /// 算法统计原样透传（`matchedCues` / `inputCues` / `medianShiftMs` /
  /// `timingMode` / `warnings` …），UI 摘要走 [retimedSubtitleSummary]。
  final Map<String, Object?> stats;

  /// 命中锚点的 cue 条数（算法未给或类型不对时 0）。
  int get matchedCues => _intStat('matchedCues');

  /// 送进算法的 cue 条数。
  int get inputCues => _intStat('inputCues');

  /// 命中 cue 的时间修正量中位数（毫秒，可正可负）。
  int get medianShiftMs => _intStat('medianShiftMs');

  int _intStat(String key) {
    final Object? value = stats[key];
    return value is int ? value : 0;
  }
}

/// **纯函数**：给 UI 用的一行摘要（命中率 + 中位偏移）。
///
/// 不做 i18n 拼装——调用方拿这三个数去填 i18n 模板；这里只负责把「命中率」算成
/// 整数百分比，免得每个调用点各算一遍还算得不一样。
({int matched, int total, int percent, int medianShiftMs})
    retimedSubtitleSummary(
  RetimedSubtitleFile file,
) {
  final int total = file.inputCues;
  final int matched = file.matchedCues;
  final int percent = total <= 0 ? 0 : ((matched * 100) / total).round();
  return (
    matched: matched,
    total: total,
    percent: percent,
    medianShiftMs: file.medianShiftMs,
  );
}

/// 命中率低于此值时**不该**直接把结果当成功用：锚点太少意味着这份转录和这份字幕
/// 很可能不是同一段内容（语言选错、字幕对不上这一集、片源版本不同）。
///
/// 算法本身在没锚点时会老实把 cue 原样写回，所以低命中不会毁字幕；但让用户在
/// 「已经切换到一份几乎没修过的新档」之后自己发现，比当场说清楚要糟。
const double kRetimedSubtitleLowMatchRate = 0.4;

/// 跑一次重定时并把结果写成新的外挂字幕档。
///
/// [subtitleCues] 是**当前正在放的那条字幕轨**的 cue（内嵌轨与外挂档都行——播放器
/// 侧已经把两者都解析成了 [AudioCue]，所以重定时不挑字幕来源）；
/// [transcriptSrtPath] 是设备端转录刚落盘的 SRT；[outputDirectory] 一般是
/// `AppPaths.videoSubtitlesDirectory()`。
///
/// 返回 null 的三种情况：输入 cue 全被剔光、转录读不出来、算法判输入非法。
/// 取消（[cancellation]）会以 [TranscribeCancelled] 抛出，由调用方吞掉。
Future<RetimedSubtitleFile?> retimeVideoSubtitleToFile({
  required List<AudioCue> subtitleCues,
  required String transcriptSrtPath,
  required Directory outputDirectory,
  required String baseName,
  TranscribeCancellation? cancellation,
}) async {
  final RetimingInputCues input = retimingCuesFromAudioCues(subtitleCues);
  if (input.isEmpty) return null;
  final AsrRetimingTranscription? transcription =
      await AsrRetimingTranscription.fromTranscriptSrt(transcriptSrtPath);
  if (transcription == null || transcription.cues.isEmpty) return null;

  final RetimedSubtitles retimed;
  try {
    retimed = await retimeSubtitles(
      input.cues,
      transcription,
      SubtitleFormat.srt,
      cancellation: cancellation,
    );
  } on FormatException {
    return null;
  }

  await outputDirectory.create(recursive: true);
  final Set<String> taken = <String>{
    for (final FileSystemEntity entity in outputDirectory.listSync())
      p.basename(entity.path),
  };
  final String dest = p.join(
    outputDirectory.path,
    retimedSubtitleFileName(baseName, taken: taken),
  );
  await File(dest).writeAsString(retimed.text);
  return RetimedSubtitleFile(
    path: dest,
    cueCount: retimed.cueCount,
    droppedInputCues: input.droppedCount,
    stats: retimed.stats,
  );
}

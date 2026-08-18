/// 「这条字幕真的是这个视频的吗」——下载之后、落盘之前的最后一道判据。
///
/// 此前全仓**没有任何一处**在拿到字幕字节后检查过它的内容：集号匹配靠文件名，
/// 文件名对了就落盘。于是一整类错配无声通过——最典型的是把整季合并的单文件
/// （5 小时）当成某一集（24 分钟）的字幕装上去，播放时字幕从第 3 分钟起就全错位。
///
/// **这道判据能做什么、不能做什么，必须说清楚**：
/// - 能抓：整季合并文件、错媒体（电影字幕装到剧集上）、空文件、解析不出的字节；
/// - **抓不了**：轴偏移（同一集不同压制组，OP 长度差几秒）。那要靠发布组名匹配，
///   拿时长去判只会误伤。别把这个判据当成「字幕对轴校验」用。
///
/// 全部纯函数，不碰磁盘/网络/DB；时长由调用方提供（ffprobe 或刮削 runtime）。
library;

/// 视频时长的来源——决定容差，因为两者精度差一个量级。
enum VideoDurationSource {
  /// ffprobe / `ffmpeg -i` 探到的真实容器时长。精确到秒。
  probed,

  /// 刮削元数据里的播出时长（`VideoMetadataEpisodes.runtimeMinutes` 等）。
  ///
  /// 这是**播出时长**不是文件时长：含广告位、四舍五入到分钟、BD 版还会与 TV 版
  /// 差几分钟。只配当粗筛，容差必须放得比 [probed] 宽得多。
  scrapedRuntime,
}

/// 已知的视频时长 + 它的来源。
class KnownVideoDuration {
  const KnownVideoDuration({required this.durationMs, required this.source});

  const KnownVideoDuration.probed(int durationMs)
      : this(durationMs: durationMs, source: VideoDurationSource.probed);

  const KnownVideoDuration.scrapedRuntime(int durationMs)
      : this(
            durationMs: durationMs, source: VideoDurationSource.scrapedRuntime);

  final int durationMs;
  final VideoDurationSource source;

  /// 允许字幕最后一句超出视频时长的上界。
  ///
  /// 比例 + 绝对量双保险：比例项负责长片（2 小时电影的 15% 是 18 分钟，够宽），
  /// 绝对量负责短片（5 分钟的 PV，15% 只有 45 秒，太紧）。
  int get maxAcceptableLastCueEndMs => switch (source) {
        VideoDurationSource.probed => (durationMs * 1.15).round() +
            const Duration(seconds: 60).inMilliseconds,
        VideoDurationSource.scrapedRuntime => (durationMs * 1.5).round() +
            const Duration(minutes: 2).inMilliseconds,
      };
}

/// 从字幕原文抽出的时间跨度概览。
class SubtitleTimingSummary {
  const SubtitleTimingSummary({
    required this.cueCount,
    required this.firstStartMs,
    required this.lastEndMs,
  });

  /// 一条时间轴都没解析出来。
  static const SubtitleTimingSummary empty = SubtitleTimingSummary(
    cueCount: 0,
    firstStartMs: 0,
    lastEndMs: 0,
  );

  /// 解析出的时间轴条数（不是渲染后的行数）。
  final int cueCount;

  /// 最早一句的开始时刻（毫秒）。
  final int firstStartMs;

  /// 最后一句的结束时刻（毫秒）——判「字幕覆盖到哪」的唯一依据。
  final int lastEndMs;

  bool get isEmpty => cueCount == 0;
}

/// 校验结论。
enum SubtitleTimingVerdict {
  /// 通过（含「视频时长未知、只做了内容自检」）。
  ok,

  /// 字节解析不出任何时间轴：不是字幕、编码坏了、或是被 HTML 错误页顶替。
  unparsable,

  /// 解析出来了但一条 cue 都没有。
  empty,

  /// 最后一句远超视频时长 → **不可能是这个视频的字幕**（整季合并文件 / 错媒体）。
  overrunsVideo,

  /// 覆盖不到视频的一半 → 可疑但**不拒收**：只有 OP/ED 的歌词轨、只标注了字幕
  /// 招牌的 signs 轨都是这个形状，且它们是用户可能真的想要的东西。
  suspiciouslyShort,
}

/// 校验结果：结论 + 可读原因（英文短语，落任务行/日志，与既有 failureReason 同风格）。
class SubtitleTimingCheck {
  const SubtitleTimingCheck(this.verdict, {this.detail});

  final SubtitleTimingVerdict verdict;
  final String? detail;

  /// **有备选候选**时的拒收判据：读不出来的、空的、和视频对不上的，全换下一个。
  ///
  /// 只有当调用方还能试别的候选（下载流水线的 registry 搜索结果）时才用这条。
  bool get rejected => switch (verdict) {
        SubtitleTimingVerdict.ok ||
        SubtitleTimingVerdict.suspiciouslyShort =>
          false,
        SubtitleTimingVerdict.unparsable ||
        SubtitleTimingVerdict.empty ||
        SubtitleTimingVerdict.overrunsVideo =>
          true,
      };

  /// **没有备选候选**时的拒收判据：只认「正面矛盾」。
  ///
  /// 番剧下载的字幕反查按集号锁定了唯一一条字幕，扔掉它就是让用户什么都没有。
  /// 这种位置上，「我读不出这个文件」不足以否决它——本模块的扫描器只认三种时间轴
  /// 写法，而真实世界的字幕文件总有意外形态；真正的解析器（
  /// `parseSubtitleContentAsync`）可能照样能读。只有 [overrunsVideo] 这种
  /// 「字幕比视频长得多」的正面证据才配否决，因为它无法用解析器差异解释。
  bool get contradictsVideo => verdict == SubtitleTimingVerdict.overrunsVideo;
}

/// 字幕最后一句至少要覆盖到视频这个比例，否则记 [SubtitleTimingVerdict.suspiciouslyShort]。
const double kSubtitleMinCoverageRatio = 0.5;

/// 校验 [timing] 与 [video] 是否自洽。[video] 为 null = 时长未知，只做内容自检。
SubtitleTimingCheck checkSubtitleTiming(
  SubtitleTimingSummary timing, {
  KnownVideoDuration? video,
}) {
  if (timing.isEmpty) {
    return const SubtitleTimingCheck(
      SubtitleTimingVerdict.unparsable,
      detail: 'subtitle has no readable timings',
    );
  }
  if (timing.lastEndMs <= 0) {
    return const SubtitleTimingCheck(
      SubtitleTimingVerdict.empty,
      detail: 'subtitle timings are all zero',
    );
  }
  if (video == null || video.durationMs <= 0) {
    return const SubtitleTimingCheck(SubtitleTimingVerdict.ok);
  }
  if (timing.lastEndMs > video.maxAcceptableLastCueEndMs) {
    return SubtitleTimingCheck(
      SubtitleTimingVerdict.overrunsVideo,
      detail: 'subtitle runs to ${_mmss(timing.lastEndMs)} but the video is '
          'only ${_mmss(video.durationMs)} long',
    );
  }
  if (timing.lastEndMs < video.durationMs * kSubtitleMinCoverageRatio) {
    return SubtitleTimingCheck(
      SubtitleTimingVerdict.suspiciouslyShort,
      detail: 'subtitle only covers up to ${_mmss(timing.lastEndMs)} of '
          '${_mmss(video.durationMs)}',
    );
  }
  return const SubtitleTimingCheck(SubtitleTimingVerdict.ok);
}

/// 从字幕原文扫出时间跨度。**只认时间轴，不做真正的解析**。
///
/// 为什么不复用 `parseSubtitleContentAsync`：那条路要 bookUid、要建 cue 行、走
/// isolate，为了拿两个数字把整套 DB 语义拖进来。这里要的只是「最后一句结束在
/// 哪」，一次正则扫描就够，而且是纯函数、能在任何地方单测。
///
/// 覆盖三种真实格式的时间轴写法：
/// - srt：`00:01:02,345 --> 00:01:05,678`
/// - vtt：`00:01:02.345 --> 00:01:05.678`（也允许省略小时的 `01:02.345`）
/// - ass/ssa：`Dialogue: 0,0:01:02.34,0:01:05.67,Default,...`
SubtitleTimingSummary summarizeSubtitleTiming(String content) {
  if (content.trim().isEmpty) return SubtitleTimingSummary.empty;
  int count = 0;
  int? first;
  int last = 0;

  void record(int startMs, int endMs) {
    count++;
    if (first == null || startMs < first!) first = startMs;
    if (endMs > last) last = endMs;
  }

  for (final RegExpMatch match in _arrowTiming.allMatches(content)) {
    final int? start = _parseClock(match.group(1)!);
    final int? end = _parseClock(match.group(2)!);
    if (start == null || end == null) continue;
    record(start, end);
  }
  if (count == 0) {
    for (final RegExpMatch match in _assDialogue.allMatches(content)) {
      final int? start = _parseClock(match.group(1)!);
      final int? end = _parseClock(match.group(2)!);
      if (start == null || end == null) continue;
      record(start, end);
    }
  }
  if (count == 0) return SubtitleTimingSummary.empty;
  return SubtitleTimingSummary(
    cueCount: count,
    firstStartMs: first ?? 0,
    lastEndMs: last,
  );
}

/// srt / vtt 的 `起 --> 止`。小时段可选（vtt 允许 `MM:SS.mmm`）。
final RegExp _arrowTiming = RegExp(
  r'(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3}|[0-5]?\d:[0-5]?\d[.,]\d{1,3})'
  r'\s*-->\s*'
  r'(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3}|[0-5]?\d:[0-5]?\d[.,]\d{1,3})',
);

/// ass/ssa 的 `Dialogue: <layer>,<start>,<end>,...`（首字段是层号，不是时间）。
final RegExp _assDialogue = RegExp(
  r'^\s*Dialogue\s*:[^,]*,\s*'
  r'(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3})\s*,\s*'
  r'(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3})\s*,',
  multiLine: true,
);

/// `[HH:]MM:SS[.,]mmm` → 毫秒。小数位不足 3 位按左对齐补零（ass 的 `.34` = 340ms）。
int? _parseClock(String raw) {
  final List<String> head = raw.split(RegExp(r'[.,]'));
  if (head.length != 2) return null;
  final List<String> parts = head[0].split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final List<int?> nums = parts.map(int.tryParse).toList();
  if (nums.any((int? v) => v == null)) return null;
  final int hours = parts.length == 3 ? nums[0]! : 0;
  final int minutes = parts.length == 3 ? nums[1]! : nums[0]!;
  final int seconds = parts.length == 3 ? nums[2]! : nums[1]!;
  final String fractionRaw = head[1].padRight(3, '0').substring(0, 3);
  final int? fraction = int.tryParse(fractionRaw);
  if (fraction == null) return null;
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction;
}

String _mmss(int ms) {
  final Duration d = Duration(milliseconds: ms);
  final String mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
}

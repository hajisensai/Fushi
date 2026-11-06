import 'dart:convert';

/// libmpv `demuxer-cache-state.seekable-ranges` 里的一段可 seek 缓冲（播放器轴，秒）。
class MpvSeekableRange {
  const MpvSeekableRange({required this.start, required this.end});

  final double start;
  final double end;

  @override
  String toString() => 'MpvSeekableRange($start..$end)';
}

/// 解析 `demuxer-cache-state` 的字符串形态。
///
/// media_kit 只能按字符串读属性（`mpv_get_property_string`）；这个属性是 node map，
/// libmpv 把它序列化成 JSON（实测 mpv 0.41：
/// `{"cache-end":89.98,…,"seekable-ranges":[{"start":15.0,"end":89.98}]}`）。
/// `demuxer-cache-state/seekable-ranges` 之类的子路径读不到（返回 NULL），所以只能整份读。
/// 解析失败 / 没有该字段 → 空列表（= 没有可用缓冲）。
List<MpvSeekableRange> parseMpvSeekableRanges(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return const <MpvSeekableRange>[];
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map) return const <MpvSeekableRange>[];
    final Object? ranges = decoded['seekable-ranges'];
    if (ranges is! List) return const <MpvSeekableRange>[];
    final List<MpvSeekableRange> out = <MpvSeekableRange>[];
    for (final Object? item in ranges) {
      if (item is! Map) continue;
      final Object? start = item['start'];
      final Object? end = item['end'];
      if (start is num && end is num && end > start) {
        out.add(MpvSeekableRange(start: start.toDouble(), end: end.toDouble()));
      }
    }
    return out;
  } on FormatException {
    return const <MpvSeekableRange>[];
  }
}

/// 一次 `dump-cache` 的参数：从 [dumpStart] 落到 [dumpEnd]（播放器轴，秒），文件 0 点
/// 对应播放器轴 [zeroMs]。
class MpvCacheDumpPlan {
  const MpvCacheDumpPlan({
    required this.dumpStart,
    required this.dumpEnd,
    required this.zeroMs,
  });

  final double dumpStart;
  final double dumpEnd;
  final int zeroMs;
}

/// 规划结论：[plan] 非 null = 现在就能落盘；[waitForTail] = 起点已在缓冲里、尾巴还没
/// 下载到（用户在一句中途点了制卡），稍等再问；两者都不是 = 这段不在缓冲里（被挤掉了 /
/// 跳过去了），调用方直接放弃，走远端抽取。
class MpvCacheDumpDecision {
  const MpvCacheDumpDecision.ready(MpvCacheDumpPlan this.plan)
    : waitForTail = false;
  const MpvCacheDumpDecision.waitForTail() : plan = null, waitForTail = true;
  const MpvCacheDumpDecision.unavailable() : plan = null, waitForTail = false;

  final MpvCacheDumpPlan? plan;
  final bool waitForTail;
}

/// 决定怎么把播放器轴 `[startMs, endMs]` 这段从缓冲里落出来。
///
/// **为什么从缓冲段起点开始落，而不是从 [startMs]**：`dump-cache` 从请求起点**之前的
/// 那个视频关键帧**开始写，并把时间戳归零到写出的第一个包——文件 0 点落在哪个关键帧
/// 上，播放器不告诉我们，抽取就对不准。缓冲段的起点本身就是一个关键帧（mpv 只把能 seek
/// 到的位置算进 seekable range），从它开始落，文件 0 点就**等于**它。实测（mpv 0.41，
/// HTTP mkv 与 HLS 各 3 组）误差 ≤ 5 ms；从任意起点落则会偏出一整个 GOP（实测 5 秒）。
/// 代价是文件从段起点一直写到句尾——后向缓冲上限（桌面 64 MiB）以内，本地写盘毫秒级。
///
/// [tailMarginMs]：尾部多落一点。文档写明 dump 的末尾「可能略不完整」，多落半秒让句尾
/// 那几帧 / 几个音频包稳稳在文件里；不足时夹到缓冲末尾。
MpvCacheDumpDecision planMpvCacheDump({
  required List<MpvSeekableRange> ranges,
  required int startMs,
  required int endMs,
  int tailMarginMs = 500,
}) {
  if (endMs <= startMs) return const MpvCacheDumpDecision.unavailable();
  final double start = startMs / 1000.0;
  final double end = endMs / 1000.0;
  for (final MpvSeekableRange range in ranges) {
    if (range.start > start || range.end <= start) continue;
    if (range.end < end) return const MpvCacheDumpDecision.waitForTail();
    final double wanted = (endMs + tailMarginMs) / 1000.0;
    return MpvCacheDumpDecision.ready(
      MpvCacheDumpPlan(
        dumpStart: range.start,
        dumpEnd: wanted < range.end ? wanted : range.end,
        zeroMs: (range.start * 1000).round(),
      ),
    );
  }
  return const MpvCacheDumpDecision.unavailable();
}

/// `dump-cache` 命令的参数。秒数用固定 6 位小数：与 mpv 自己在 `demuxer-cache-state`
/// 里打印的精度一致（起点原样回传，不会被四舍五入到缓冲段之前），也避开 Dart 对大/小
/// 数值输出科学计数法（mpv 的 time 解析不收）。
List<String> mpvDumpCacheCommand(MpvCacheDumpPlan plan, String outputPath) =>
    <String>[
      'dump-cache',
      plan.dumpStart.toStringAsFixed(6),
      plan.dumpEnd.toStringAsFixed(6),
      outputPath,
    ];

/// HLS 往缓冲外 seek 时给 libmpv 的 `hr-seek-demuxer-offset`（秒），见
/// [hrSeekDemuxerOffsetForSeek]。
///
/// 量级取「一个 GOP 的上界」：x264 默认 `keyint=250`，23.976 fps 下关键帧间隔
/// ≈10.4 s，番剧压制普遍不超过它；再留一点余量取 12 s。代价只落在缓冲外的 seek 上
/// （本来就要重新拉分片），多拉一两个分片、多解十来秒的帧（硬解远快于实时）。
const double kHlsOutOfCacheSeekDemuxerOffsetSeconds = 12;

/// 判「目标在缓冲里」时离缓冲段起点留的余量（秒）：缓冲快照是周期采样的（≤1 s
/// 旧），后向缓冲的起点会随裁剪往后挪；贴着起点的目标按「不在缓冲里」处理更稳。
const double kSeekableRangeStartMarginSeconds = 2;

/// 一次 seek 应当下发的 `hr-seek-demuxer-offset`（秒，BUG-3618）。
///
/// 在线源的 HLS 分片常常**不是从关键帧切开**的（分片 4～6 s、GOP 10 s 上下）。往
/// 缓冲外 seek 时，ffmpeg 的 hls demuxer 只能按播放列表时长找到「包含目标的那一片」
/// 从片头读起；片头不是关键帧，解码要等到片内 / 下一片的第一个关键帧，而它可能在
/// 目标**之后**——libmpv 的 hr-seek 只会往后丢帧、不会往回找，于是落点比目标晚最多
/// 一个 GOP。往回跳几秒（上一句 / 固定秒数后退）时这个晚落点常常就在原位置附近，
/// 表现为「往回跳不动」；从前面播过来的段已在 demuxer 缓冲里（缓冲内 seek 按真实
/// 关键帧定位，精确），所以「多往前跳一点播过来就好了」「从头看很少遇到」。
///
/// mpv 为「demuxer 做不到精确 seek」提供的就是 `hr-seek-demuxer-offset`：demuxer
/// 从目标前这么多秒读起，目标之前必有关键帧，hr-seek 再精确解到目标。它对缓冲内的
/// seek 同样生效（会白解一段帧、拖慢句子跳转），所以只在**目标不在缓冲里**时给：
///  - [hlsStream] 为 false（本地文件 / 有索引的 mp4、mkv 直链，demuxer 自己能按索引
///    找到目标前的关键帧）→ 0；
///  - 目标落在某段 [ranges]（`demuxer-cache-state.seekable-ranges`）里、且离段起点
///    不少于 [kSeekableRangeStartMarginSeconds] → 0；
///  - 其余 → [kHlsOutOfCacheSeekDemuxerOffsetSeconds]。
double hrSeekDemuxerOffsetForSeek({
  required bool hlsStream,
  required List<MpvSeekableRange> ranges,
  required double targetSeconds,
}) {
  if (!hlsStream) return 0;
  for (final MpvSeekableRange range in ranges) {
    if (targetSeconds >= range.start + kSeekableRangeStartMarginSeconds &&
        targetSeconds <= range.end) {
      return 0;
    }
  }
  return kHlsOutOfCacheSeekDemuxerOffsetSeconds;
}

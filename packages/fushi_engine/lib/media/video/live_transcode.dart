// 互联远端播放的**按需转码**（弱网可用）。
//
// 背景：互联 host 的 `/api/library/videos/<id>/stream` 一直是「原文件 Range 直传」。
// 在家（局域网）没问题，人在外面用手机网络看一部 8 Mbps 的片子就只能卡着等缓冲。本
// 模块让 host 按对端选的画质档把视频切段转码，用 HLS 下发。
//
// ## 为什么是「自己拼 playlist + MPEG-TS 分段」
//
// 随包的精简 ffmpeg（`tool/ffmpeg-min`）没有编入 `hls` muxer，但 playlist 不过是一段
// 文本，分段一段一个短命 ffmpeg 出 `mpegts` 就够——于是 playlist 由 Dart 生成。
//
// 这条路换来的是**播放器侧零特殊处理**：libmpv 原生吃 HLS，进度条、总时长、seek 全
// 部照常工作。相对的另一条路（一条不可 Range 的渐进流）要在播放器里拦截 seek、伪造
// 时长，还得改 vendored 的 media_kit fork——同样的用户价值，代价差一个数量级。
//
// ## 为什么分段是 MPEG-TS 而不是 fMP4（BUG-2630 第二段）
//
// 首版分段是 fMP4（`mp4` muxer 的 fragmented 模式 + Dart 侧剥 `ftyp/moov`、平移
// `tfdt`）。它在 Windows 随包 libmpv（FFmpeg master 构建）上一切正常，但 Apple /
// Android 随包 libmpv 是 **FFmpeg 6.1.6**：6.1 的 hls demuxer seek 时只把子 AVIO 的
// `pos` 清零并重新喂 init+分段，而 6.1 的 mov demuxer 没有 master 那段
// 「`pb->pos == 0` 就丢弃 fragment index / 样本游标并重新 `mov_switch_root`」，会沿
// seek 前的绝对偏移向前跳、把新数据当 moof 解——`Invalid NAL unit size` → 解码器吐
// 不出帧 → 瞬间 EOF。真机复现：iOS 模拟器 / macOS / Android 只要 seek（含恢复上次
// 位置）就黑屏。hls.c 那次 `pos = 0` 重置本来就是为 mpegts demuxer 设计的（源码注释
// 原话），MPEG-TS 也是 Jellyfin / Emby 给 mpv 客户端的标准分段形态；mpegts muxer 认
// `-output_ts_offset`，段内时间轴直接平移到片中绝对位置，不再需要任何字节层改写。
//
// ## 一段一个进程
//
// 分段之间没有共享状态：请求第 n 段就 `-ss n*6 -to (n+1)*6` 起一个 ffmpeg，转完即退。
// 没有会话表、没有临时文件、没有需要清理的长跑进程，seek 到哪里就转哪里（播放器直接
// 请求那一段），也不会因为用户拖了一下进度条就把前面转好的东西全扔了。代价是段边界
// 处要重新初始化编码器，换来的是整套机制没有可泄漏的状态。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:meta/meta.dart';

/// 一个画质档：高度上限 + 视频码率上限。
///
/// 两个字段都是**上限**而非目标：源本来就比档位小的（480p 的老番）不会被放大，也不会
/// 被硬拉到档位码率——放大只是既费 CPU 又费流量。
@immutable
class VideoTranscodeProfile {
  const VideoTranscodeProfile({
    required this.maxWidth,
    required this.maxBitrate,
  });

  /// 画面宽度上限（像素）。`<= 0` 表示不限。
  ///
  /// 用宽度而不是高度，是为了和 client 侧既有的画质档模型（`MediaServerQualityPreset`
  /// 的 `maxWidth`，Jellyfin/Emby 也是按宽度声明）对齐——两处用不同的轴，迟早有人在
  /// 中间漏掉一次换算。
  final int maxWidth;

  /// 视频码率上限（bps）。`<= 0` 表示不限。
  final int maxBitrate;

  /// query 参数往返（`?maxWidth=1280&maxBitrate=3000000`）。两项都缺/非法 → null
  /// （= 不转码，原文件直传）。
  static VideoTranscodeProfile? fromQuery(Map<String, String> query) {
    final int width = int.tryParse(query['maxWidth'] ?? '') ?? 0;
    final int bitrate = int.tryParse(query['maxBitrate'] ?? '') ?? 0;
    if (width <= 0 && bitrate <= 0) return null;
    return VideoTranscodeProfile(maxWidth: width, maxBitrate: bitrate);
  }

  Map<String, String> toQuery() => <String, String>{
    if (maxWidth > 0) 'maxWidth': '$maxWidth',
    if (maxBitrate > 0) 'maxBitrate': '$maxBitrate',
  };

  @override
  bool operator ==(Object other) =>
      other is VideoTranscodeProfile &&
      other.maxWidth == maxWidth &&
      other.maxBitrate == maxBitrate;

  @override
  int get hashCode => Object.hash(maxWidth, maxBitrate);

  @override
  String toString() =>
      'VideoTranscodeProfile(maxWidth: $maxWidth, maxBitrate: $maxBitrate)';
}

/// 分段时长（秒）。
///
/// 起播要等第一段转完，所以段越长起播越慢；段越短则进程开销与请求数越多。6 秒是 HLS
/// 的常见取值，480p veryfast 在桌面 CPU 上转 6 秒内容通常不到 1 秒。
const int kTranscodeSegmentSeconds = 6;

/// 转码分段端点的路径尾（`/api/library/videos/<id>/hlsseg.ts?token=&n=`）。
///
/// **扩展名是协议的一部分，不是装饰**（BUG-2630）：FFmpeg 6.1.3+ / 7.1.1+ / 8.0（2025
/// 年安全加固回移到维护分支；6.1.0～6.1.2 与 7.0.x / 7.1.0 没有这道门）的 hls demuxer
/// （`extension_picky` 默认开）对 playlist 里每个分段 URL 先查
/// `allowed_segment_extensions` 白名单，扩展名取 **query 之前**的路径尾
/// （`ff_match_url_ext`）；不在名单上就 `Invalid data found`，播放器压根不去取分段。
/// Android / iOS / macOS 随包 libmpv 是 FFmpeg 6.1.6、Windows 随包是 2026-08 的
/// master 构建，都在这道门内（Linux 走系统库，发行版 6.1.1 / 7.0.x 不复现），所以裸
/// `hlsseg?token=` 让随包四端的转码流一开就死。`.ts` 同时在白名单里、又在「探得
/// mpegts 格式时放行」的表里；playlist（`hls.m3u8`）本就带扩展名。
const String kTranscodeSegmentPathSuffix = 'hlsseg.ts';

/// 音频目标码率（bps）：AAC 立体声 128 kbps，够用且在弱网里只占总带宽的零头。
const int kTranscodeAudioBitrate = 128000;

/// 同时在跑的转码进程上限。
///
/// 播放器会预取后面的分段，不设闸门的话一次 seek 就能同时点起七八个 ffmpeg，host 的
/// CPU 被瓜分之后**每一段都变慢**，结果是本来为了不卡而降的画质反而更卡。
const int kMaxConcurrentTranscodes = 3;

/// 纯函数：拼一段转码的 ffmpeg 参数。
///
/// `-ss` / `-to` 都放在 `-i` **之前**：输入 seek 既快又精确，且此时两者都按源的原始
/// 时间轴计。放到输出侧会把跳过的部分也解码一遍，转第 100 段就得先白解码 10 分钟。
///
/// 段首帧必然是 IDR（新进程从这里开始编码），所以 HLS 要求的「分段以关键帧起头」天然
/// 满足，不必再 `-force_key_frames`。
List<String> buildTranscodeSegmentArgs({
  required String inputPath,
  required VideoTranscodeProfile profile,
  required Duration start,
  required Duration end,
  int? audioStreamIndex,
  int audioBitrate = kTranscodeAudioBitrate,
}) {
  return <String>[
    '-hide_banner',
    // ffmpeg 默认会读 stdin 抢键盘；服务端进程里这会让它读到 EOF 直接退出。
    '-nostdin',
    '-loglevel', 'error',
    '-ss', _ffmpegSeconds(start),
    '-to', _ffmpegSeconds(end),
    '-i', inputPath,
    // 视频恒取第一条；音频可由 client 指定（多音轨番剧的日配/中配），越界时 `?` 让
    // ffmpeg 静默跳过而不是硬失败。
    '-map', '0:v:0',
    '-map', audioStreamIndex == null ? '0:a:0?' : '0:a:$audioStreamIndex?',
    // 字幕不进转码流：fMP4 里的内嵌字幕轨既不通用也没法被播放器可靠自绘，client 改走
    // host 的 `/subtitle?embeddedStreamIndex=N` 外挂下发（这正是
    // `streamIsOriginalContainer: false` 要让 client 知道的事）。
    '-sn',
    if (profile.maxWidth > 0) ...<String>[
      '-vf',
      scaleFilterFor(profile.maxWidth),
    ],
    '-c:v', 'libx264',
    // 实时性优先：转得比播放慢就等于没做。与既有导出路径
    // （buildClipVideoEncoderArgs）同款 preset。
    '-preset', 'veryfast',
    if (profile.maxBitrate > 0) ...<String>[
      // 单给 `-b:v` 只是平均码率，一个高动态镜头就能把瞬时码率顶到几倍——弱网上那正是
      // 卡顿的来源。maxrate/bufsize 把它箍成 VBV 受限的近似 CBR。
      '-b:v', '${profile.maxBitrate}',
      '-maxrate', '${profile.maxBitrate}',
      '-bufsize', '${profile.maxBitrate * 2}',
    ] else ...<String>['-crf', '23'],
    '-profile:v', 'high',
    '-pix_fmt', 'yuv420p',
    // 段内不再插关键帧：段首已经是 IDR，段长 6 秒，段内额外的 IDR 只会白占码率。
    '-g', '600',
    '-keyint_min', '600',
    '-sc_threshold', '0',
    // **不能开 B 帧**（BUG-2630 第三段）：`-output_ts_offset` 平移的是 PTS 和 DTS
    // 两者，而有 B 帧时段首关键帧的 `DTS = PTS - 重排延迟`，于是段 n 的首个关键帧
    // 落在 `n*6 - 延迟`；偏偏第 0 段还会被 `avoid_negative_ts`（mpegts muxer 没有
    // `AVFMT_TS_NEGATIVE`，默认 MAKE_NON_NEGATIVE）整体抬成非负。hls demuxer 判
    // seek 落点用的是 **DTS**：`first_timestamp`（第 0 段首包 DTS，被抬成 0）加上
    // playlist 里 `EXTINF` 的累计，凡 DTS 比它小的包全部 `av_packet_unref` 丢掉
    // （`hls.c` 的 `find_timestamp_in_playlist` 与 seek 后的丢包循环）。段 n 唯一
    // 的关键帧比门槛早那个重排延迟 → **整段被丢、落到段 n+1**；目标落在最后一段时
    // 直接 EOF。实测（本仓随包 ffmpeg，854p/1.5 Mbps，6 秒段）重排延迟 83.422 ms，
    // 段 1/2 的关键帧 DTS 5.916578 / 11.916578 对名义位置 6.000000 / 12.000000，
    // seek 7 s 落到 11.94 s、seek 13 s 什么都播不出来；关掉 B 帧后三段关键帧
    // DTS 与 PTS 重合、与名义位置精确相等，落点恢复正常。
    //
    // 这不是「调参绕过」：每段是**独立编码**、起点由 `-output_ts_offset` 钉死在
    // PTS 域，而 HLS 的分段索引是 DTS 域的——两域必须重合，段边界才自洽。代价是
    // 少了 B 帧的压缩收益，但弱网上「seek 能用」比那几个百分点重要得多，何况
    // `-g 600` 本来就是一段一个关键帧。守卫见
    // `fushi/test/media/video/live_transcode_test.dart` 与 `tool/ffmpeg-min/smoke-test.sh`。
    '-bf', '0',
    '-c:a', 'aac',
    '-b:a', '$audioBitrate',
    '-ac', '2',
    // 默认 0.7s 的 muxer 预读窗口会让首包晚到，起播观感差一截。
    '-muxdelay', '0',
    '-muxpreload', '0',
    // 段内时间轴平移到片中绝对位置：`-ss` 输入 seek 后输出从 0 起计，mpegts muxer
    // 认这个偏移（mp4 muxer 的 fragmented 模式不认，首版才要在字节层改 tfdt）。
    // 各段首尾相接后覆盖全片。注意 hls demuxer 判 seek 落点用的是 **DTS** 而不是
    // PTS（见上面 `-bf 0` 处），两者只有在关掉 B 帧后才重合。
    '-output_ts_offset', _ffmpegSeconds(start),
    '-f', 'mpegts',
    'pipe:1',
  ];
}

/// 纯函数：宽度上限对应的 scale 滤镜。
///
/// `min(w,iw)` 保证**只缩不放**；高度位的 `-2` 让它按比例走且落在偶数上（yuv420p 的
/// 硬性要求，奇数边会让 libx264 直接拒绝）。
String scaleFilterFor(int maxWidth) => 'scale=min($maxWidth\\,iw):-2';

/// `-ss` / `-to` 用的秒数文本（毫秒精度，不带指数/尾随噪声）。
String _ffmpegSeconds(Duration d) =>
    (d.inMilliseconds / 1000).toStringAsFixed(3);

/// 纯函数：分段数（最后一段不足 [kTranscodeSegmentSeconds] 也算一段）。
int transcodeSegmentCount(
  int durationMs, {
  int segmentSeconds = kTranscodeSegmentSeconds,
}) {
  if (durationMs <= 0) return 0;
  final int segmentMs = segmentSeconds * 1000;
  return (durationMs + segmentMs - 1) ~/ segmentMs;
}

/// 纯函数：第 [index] 段的时间范围（末段按真实时长收尾，不越过片尾）。
({Duration start, Duration end}) transcodeSegmentRange(
  int index,
  int durationMs, {
  int segmentSeconds = kTranscodeSegmentSeconds,
}) {
  final int segmentMs = segmentSeconds * 1000;
  final int startMs = index * segmentMs;
  final int endMs = ((index + 1) * segmentMs).clamp(0, durationMs);
  return (
    start: Duration(milliseconds: startMs),
    end: Duration(milliseconds: endMs < startMs ? startMs : endMs),
  );
}

/// 纯函数：生成 HLS 媒体 playlist。
///
/// [segmentUri] 把段下标映射成 URI（host 侧带上 token）。分段是自描述的 MPEG-TS，
/// 没有初始化段（`EXT-X-MAP`）。
///
/// `PLAYLIST-TYPE:VOD` + `ENDLIST` 让播放器知道这是完整的点播内容：时长可算、进度条
/// 可拖，而不是当成没有尽头的直播。
String buildTranscodeHlsPlaylist({
  required int durationMs,
  required String Function(int index) segmentUri,
  int segmentSeconds = kTranscodeSegmentSeconds,
}) {
  final int count = transcodeSegmentCount(
    durationMs,
    segmentSeconds: segmentSeconds,
  );
  final StringBuffer buffer = StringBuffer()
    ..writeln('#EXTM3U')
    // TS 分段的 VOD playlist 只用到 version 3 的特性（小数 EXTINF）。
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:$segmentSeconds')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0')
    ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
  for (int i = 0; i < count; i++) {
    final ({Duration start, Duration end}) range = transcodeSegmentRange(
      i,
      durationMs,
      segmentSeconds: segmentSeconds,
    );
    final double seconds =
        (range.end - range.start).inMilliseconds /
        Duration.millisecondsPerSecond;
    buffer
      ..writeln('#EXTINF:${seconds.toStringAsFixed(6)},')
      ..writeln(segmentUri(i));
  }
  buffer.writeln('#EXT-X-ENDLIST');
  return buffer.toString();
}

/// 起转码进程并收完 stdout 的注入点（测试替身在此接管，不真起 ffmpeg）。
typedef TranscodeSegmentRunner = Future<Uint8List> Function(List<String> args);

TranscodeSegmentRunner? _runnerOverride;

@visibleForTesting
void setTranscodeSegmentRunnerForTesting(TranscodeSegmentRunner? runner) {
  _runnerOverride = runner;
  _availabilityOverride = null;
}

bool? _availabilityOverride;

@visibleForTesting
void setTranscodeAvailableForTesting(bool? available) {
  _availabilityOverride = available;
}

/// 本机能不能跑按需转码。
///
/// 判据是「能不能 exec 一个 ffmpeg 子进程」，而不是「有没有 ffmpeg」：移动端装的是
/// 进程内的 ffmpeg-kit（`KitFfmpegBackend`），它只能跑完一条命令再交结果，**没有可
/// 接管的 stdout 管道**；iOS 更是从根上禁子进程。所以 Android / iOS 当 host 时这条
/// 能力位如实报 false，client 据此隐藏画质档、老实直传——而不是让用户选了之后对着一
/// 个永远转不出第一段的黑屏。
///
/// 桌面与无头服务端走 [CliFfmpegBackend]，可执行文件由 [resolveFfmpegExecutable]
/// 解析（显式覆盖 > 随包 > PATH）。
bool transcodeAvailable() {
  final bool? override = _availabilityOverride;
  if (override != null) return override;
  if (_runnerOverride != null) return true;
  // 移动端当 host：判据是「能不能 exec 一个 ffmpeg 子进程」。那边装的是进程内
  // ffmpeg-kit（没有可接管的 stdout 管道），iOS 更是从根上禁子进程。而
  // `_selectBackend()` 本身没有任何平台判断——装配点没装、或在装配前就被缓存过
  // 一次时，移动端照样拿到 CliFfmpegBackend，于是能力位报 true、HLS URL 照发、
  // 每一段都失败。这里兜一条硬的。
  if (Platform.isAndroid || Platform.isIOS) return false;
  return resolveFfmpegBackend() is CliFfmpegBackend;
}

/// 在并发闸门内跑一段任意工作（**仅测试用**）：`_runSegment` 的 runner override 在
/// 取名额**之前**就返回，所以闸门本身（队列交棒、排空回零）在产品路径外没有别的
/// 入口可验。
@visibleForTesting
Future<T> runGuardedTranscodeForTesting<T>(Future<T> Function() body) async {
  await _acquireTranscodeSlot();
  try {
    return await body();
  } finally {
    _releaseTranscodeSlot();
  }
}

int _liveTranscodes = 0;
final List<Completer<void>> _transcodeQueue = <Completer<void>>[];

Future<void> _acquireTranscodeSlot() async {
  if (_liveTranscodes < kMaxConcurrentTranscodes) {
    _liveTranscodes++;
    return;
  }
  final Completer<void> waiter = Completer<void>();
  _transcodeQueue.add(waiter);
  await waiter.future;
}

void _releaseTranscodeSlot() {
  if (_transcodeQueue.isNotEmpty) {
    // 名额直接交棒，不回落计数——否则两个等待者会同时被放行。
    _transcodeQueue.removeAt(0).complete();
    return;
  }
  if (_liveTranscodes > 0) _liveTranscodes--;
}

@visibleForTesting
int get liveTranscodeCount => _liveTranscodes;

/// 转出一段，返回**已经可以直接发给播放器**的 MPEG-TS 分段字节：ffmpeg 的产物
/// 就是最终产物（时间轴已由 `-output_ts_offset` 平移到片中绝对位置，TS 自描述、
/// 没有初始化段），不做任何字节层改写。
Future<Uint8List> transcodeSegment({
  required String inputPath,
  required VideoTranscodeProfile profile,
  required int index,
  required int durationMs,
  int? audioStreamIndex,
  int segmentSeconds = kTranscodeSegmentSeconds,
}) {
  final ({Duration start, Duration end}) range = transcodeSegmentRange(
    index,
    durationMs,
    segmentSeconds: segmentSeconds,
  );
  return _runSegment(
    buildTranscodeSegmentArgs(
      inputPath: inputPath,
      profile: profile,
      start: range.start,
      end: range.end,
      audioStreamIndex: audioStreamIndex,
    ),
  );
}

/// 单段转码的墙钟上界。一段只有 [kTranscodeSegmentSeconds] 秒内容，正常几百毫秒到
/// 几秒；挂死的 ffmpeg（网络盘掉线、解码器卡住）若不设上界会**永久**占住三个并发
/// 名额之一，占满之后这台 host 的转码彻底哑掉且不会自愈——`_transcodeQueue` 里的
/// Completer 永不 complete，后续每个分段请求连同 shelf handler 一起永久挂起。
const Duration kTranscodeSegmentTimeout = Duration(seconds: 90);

/// 跑一次分段转码进程，返回 (退出码, stdout 字节, stderr 摘要)。超时 SIGKILL 并抛
/// [TranscodeFailure]（与既有 [runFfmpegProcess] 的处置同口径）。
Future<({int code, List<int> bytes, String stderr})> _spawnSegment(
  String executable,
  List<String> args,
) async {
  final Process process = await HelperProcessRegistry.instance.start(
    executable,
    args,
  );
  // stdout / stderr 必须同时 drain：任一管道写满 64 KB 都会把 ffmpeg 堵死，表现为
  // 「转码莫名其妙停住」。与既有 runFfmpegProcess 的防死锁处理同因。
  final Future<List<int>> stdoutFuture = process.stdout
      .expand<int>((List<int> c) => c)
      .toList();
  final StringBuffer stderrBuffer = StringBuffer();
  final Future<void> stderrFuture = process.stderr.forEach((List<int> chunk) {
    if (stderrBuffer.length < 4096) {
      stderrBuffer.write(String.fromCharCodes(chunk));
    }
  });
  try {
    final List<int> collected = await stdoutFuture.timeout(
      kTranscodeSegmentTimeout,
    );
    await stderrFuture.timeout(kTranscodeSegmentTimeout);
    final int code = await process.exitCode.timeout(kTranscodeSegmentTimeout);
    return (
      code: code,
      bytes: collected,
      stderr: stderrBuffer.toString().trim(),
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    fushiDebugPrint(
      'transcode segment timed out after ${kTranscodeSegmentTimeout.inSeconds}s: '
      '$executable',
    );
    throw TranscodeFailure(-1, 'segment timed out');
  }
}

/// 随包 ffmpeg 被杀软隔离 / 缺 DLL / 架构不匹配时的判据（BUG-275 / BUG-283 同款）：
/// 非 0 退出且一个字节的视频数据都没产出。这时回退 PATH 上的 ffmpeg 再试一次——
/// 全应用其它路径（`_runCliFfmpeg`）早就这么做了，只有转码这条新路径没有，结果是
/// 「能力位报 true、HLS URL 照发、每一段都 503」。
bool _bundledSegmentUnusable(int code, List<int> bytes) =>
    code != 0 && bytes.isEmpty;

Future<Uint8List> _runSegment(List<String> args) async {
  final TranscodeSegmentRunner? override = _runnerOverride;
  if (override != null) return override(args);

  await _acquireTranscodeSlot();
  try {
    final String executable = resolveFfmpegExecutable();
    ({int code, List<int> bytes, String stderr}) r;
    try {
      r = await _spawnSegment(executable, args);
    } on ProcessException {
      // 随包路径存在于磁盘却起不来（损坏 / 架构不匹配 / 无执行权限）。
      if (executable == 'ffmpeg' || ffmpegExplicitOverride() != null) rethrow;
      fushiDebugPrint('bundled ffmpeg failed to start, retrying PATH ffmpeg');
      r = await _spawnSegment('ffmpeg', args);
    }
    if (_bundledSegmentUnusable(r.code, r.bytes) &&
        executable != 'ffmpeg' &&
        ffmpegExplicitOverride() == null) {
      fushiDebugPrint(
        'bundled ffmpeg produced no output (code=${r.code}); '
        'retrying PATH ffmpeg',
      );
      r = await _spawnSegment('ffmpeg', args);
    }
    if (r.code != 0) {
      fushiDebugPrint('transcode segment exited ${r.code}: ${r.stderr}');
      throw TranscodeFailure(r.code, r.stderr);
    }
    return Uint8List.fromList(r.bytes);
  } finally {
    _releaseTranscodeSlot();
  }
}

/// 转码进程以非 0 退出。带上 ffmpeg 的 stderr，好让 host 日志里能看出是源文件的问题
/// 还是 ffmpeg 自身的问题。
class TranscodeFailure implements Exception {
  TranscodeFailure(this.exitCode, this.stderr);

  final int exitCode;
  final String stderr;

  @override
  String toString() => 'TranscodeFailure(exit $exitCode): $stderr';
}

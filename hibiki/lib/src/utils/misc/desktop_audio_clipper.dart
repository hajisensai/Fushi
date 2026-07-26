import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart'
    show kYoutubeStreamReplayUserAgent;
import 'package:hibiki/src/media/video/video_clip_exporter.dart'
    show resolveAudioMapIndex;
import 'package:http/http.dart' as http;
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:meta/meta.dart';

// resolveFfmpegExecutable 已移到 ffmpeg_backend.dart（执行配置的自然归宿）；
// 从这里 re-export 让既有 importer 与测试仍从本文件解析它。
export 'package:hibiki/src/media/video/ffmpeg_backend.dart'
    show resolveFfmpegExecutable;

typedef FfmpegFailureReporter = void Function(String summary);

/// TODO-1000：ffmpeg 抽取器的 inputPath 可以是本地绝对路径，也可以是可 seek 的 http(s)
/// 流 URL（YouTube 分离流、其它远端直链）。本地路径要用 `File.existsSync()` 早退避免喂
/// ffmpeg 一个不存在的文件；但对 http(s) URL 该守卫会误杀——文件系统里当然没有它。此谓词
/// 让各抽取器只对本地路径做存在性检查，URL 直接放行给 ffmpeg（ffmpeg 自己吃 http 输入）。
bool _isRemoteFfmpegInput(String inputPath) {
  return inputPath.startsWith('http://') || inputPath.startsWith('https://');
}

/// 仅供测试：暴露 [_isRemoteFfmpegInput] 的判定（本地路径 vs http(s) 流 URL）。
@visibleForTesting
bool debugIsRemoteFfmpegInput(String inputPath) =>
    _isRemoteFfmpegInput(inputPath);

/// TODO-1000（BUG-528/522）：http(s) 流输入（YouTube googlevideo 分离流/直链）的 ffmpeg
/// 网络韧性开关，**必须放在 `-i` 之前**（这些是 http 协议的输入选项）。googlevideo 在打开
/// 输入时会间歇性丢连（实测 `Error number -138` opening input——多帧 GIF/音频段读取更易撞上），
/// 加 `-reconnect` 系列让 ffmpeg 自动重连（实测把间歇失败的 GIF 抽取变成稳定 277KB 产出）；
/// `-user_agent` 与 libmpv 侧一致，规避个别流对 UA 的挑剔。本地路径返回空（不加网络开关）。
/// 纯函数，便于单测。
///
/// TODO-1290：制卡句子音频（[extractAudioSegmentViaFfmpeg]）在 googlevideo 流上仍报
/// `ffmpeg exit -138`。根因：`-138` 是 **打开/连接阶段** 的 TCP/TLS 网络错误
/// （Windows/mingw errno 138 = ETIMEDOUT，即连接超时），而 `-reconnect` /
/// `-reconnect_streamed` 只在「流传输中断 / EOF」时重连，**不覆盖 connect 阶段的网络错误**
/// ——所以短音频段（每次都新开一条 googlevideo 连接、更常在 open 阶段撞上超时）依旧硬失败。
/// 补 `-reconnect_on_network_error 1`：ffmpeg http 协议在 connect 阶段的 TCP/TLS 错误上
/// 自动重连（配合已有的 `-reconnect_delay_max 5` 退避预算），正好命中 `-138` 这一类。
/// 该选项 ffmpeg ≥4.3 即有，捆绑的 n7.1.5 已带；网络支持早在 ffmpeg-min recipe 编入
/// （`--enable-network` + http/https/tcp/tls），**无需重编二进制**。remote-only、对本地
/// 输入零影响。
List<String> buildFfmpegRemoteInputArgs(String inputPath,
    {String? tlsPinSha256}) {
  if (!_isRemoteFfmpegInput(inputPath)) return const <String>[];
  final String? pin = tlsPinSha256?.trim();
  return <String>[
    // BUG-891：远端自签 Hibiki 主机（自编 ffmpeg-kit `--enable-gnutls` + tls pin 补丁，
    // 见 third_party/ffmpeg_kit_flutter/patches/）——把 host 的 TOFU 钉扎指纹下发给
    // ffmpeg 的 TLS 层，握手后按证书 SHA-256 钉扎接受自签，非无条件放行。空 = 公网源
    // （YouTube 等有效证书）不钉扎，走 ffmpeg 默认。必须在 `-i` 前（TLS 输入选项）。
    if (pin != null && pin.isNotEmpty) ...<String>['-tls_pin_sha256', pin],
    // TODO-1365（BUG-669）：`-user_agent` 与 libmpv 侧回放 UA 同源（[kYoutubeStreamReplayUserAgent]
    // ＝youtube_explode 铸流 UA），规避 googlevideo svpuc 对残缺 UA 的 tarpit 超时。含常量故非 const。
    '-user_agent',
    kYoutubeStreamReplayUserAgent,
    '-reconnect',
    '1',
    '-reconnect_streamed',
    '1',
    // TODO-1290：connect 阶段 TCP/TLS 错误（含 -138 / ETIMEDOUT）也自动重连——
    // `-reconnect` 系列只管流中断/EOF，短音频段的失败几乎全在 open 阶段。
    '-reconnect_on_network_error',
    '1',
    '-reconnect_delay_max',
    '5',
  ];
}

/// TODO-1314（B5，借鉴 yt-dlp 分片 range 下载）：把 googlevideo 流 URL 追加/覆盖
/// `range=<start>-<end>` **查询参数**，构造一个 byte 区间请求 URL。纯函数，便于单测。
///
/// 根因：googlevideo 对 **audio-only DASH** 流施加 SABR/限速——不带 `range=` 的整段 GET
/// 会被限到涓流甚至首个请求即超时（[extractAudioSegmentViaFfmpeg] 的 ffmpeg HTTP `-ss`
/// seek 正撞上它 → 120s 超时 → 无句子音频，即 TODO-1301 用 muxed 绕行的技术债）。yt-dlp 对
/// 这类流走 `range=` 分片顺序下载，每个分片是 full-speed 服务、不触发限速。此处按 yt-dlp
/// 语义追加**查询参数**（而非 HTTP `Range` header——googlevideo 认查询参数那一路才不限速）。
String buildGoogleVideoRangeUrl(String baseUrl, int start, int end) {
  final Uri uri = Uri.parse(baseUrl);
  final Map<String, String> q = Map<String, String>.from(uri.queryParameters);
  q['range'] = '$start-$end';
  return uri.replace(queryParameters: q).toString();
}

/// TODO-1314（B5）：把远端 **audio-only DASH** 流（googlevideo 分离音频轨）用 yt-dlp 式
/// `range=` 分片顺序下载**整段物化到本地临时文件** [outputPath]，返回本地路径（成功）或
/// null（失败 / 空流 / 非 http 输入）。**best-effort**，绝不抛。
///
/// 为什么必须整段物化而非只下 `[startMs,endMs)` 对应字节窗：audio-only DASH 流（webm/opus、
/// m4a/aac）是带容器头/索引的**封装流**，中段裸字节切片不是合法容器（无 moov/Cues），ffmpeg
/// 解不出 → 只能物化完整流再本地 seek。制卡音频流通常几 MB（几分钟片段），一次性下载可接受；
/// [maxBytes] 兜底避免超长视频跑飞。物化后 ffmpeg 对**本地文件** `-ss` 是即时的（无网络 seek
/// stall），故这条路径根治 audio-only 不可 seek、去掉对 muxed 的硬依赖。
///
/// 分片语义：从 byte 0 起每次请求 `range=start-(start+chunkBytes-1)`，googlevideo 对查询参数
/// range 返回该窗口（HTTP 200，非 206）。返回体短于窗口 = 到流末尾（break）；HTTP 416 = 上一
/// 片恰好是流末尾（EOF，break）；首片非 2xx / 网络异常 → 删半成品返回 null，让调用方回退
/// （不建无音频卡，绝不喂 ffmpeg 半截流）。[httpClient] 仅供测试注入。
Future<String?> materializeRemoteAudioViaRangeDownload({
  required String audioUrl,
  required String outputPath,
  http.Client? httpClient,
  int chunkBytes = 4 * 1024 * 1024,
  int maxBytes = 128 * 1024 * 1024,
  FfmpegFailureReporter? onFailure,
}) async {
  if (!_isRemoteFfmpegInput(audioUrl)) return null;
  final http.Client client = httpClient ?? http.Client();
  final File output = File(outputPath);
  try {
    await output.parent.create(recursive: true);
  } catch (_) {}
  final IOSink sink = output.openWrite();
  bool closed = false;
  Future<void> closeSink() async {
    if (closed) return;
    closed = true;
    try {
      await sink.flush();
    } catch (_) {}
    try {
      await sink.close();
    } catch (_) {}
  }

  void deletePartial() {
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
  }

  try {
    int start = 0;
    int total = 0;
    while (start < maxBytes) {
      final int end = start + chunkBytes - 1;
      final http.Response res = await client.get(
        Uri.parse(buildGoogleVideoRangeUrl(audioUrl, start, end)),
        // TODO-1365（BUG-669）：range 下载 UA 与铸流 UA 一致，见 [kYoutubeStreamReplayUserAgent]。
        headers: <String, String>{'User-Agent': kYoutubeStreamReplayUserAgent},
      );
      // 416（range 越界）= 上一片恰好取到流末尾：正常 EOF，用已下载数据收尾。
      if (res.statusCode == 416) break;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await closeSink();
        deletePartial();
        _reportFfmpegEarlyReturn(
          'materializeRemoteAudioViaRangeDownload',
          'range chunk HTTP ${res.statusCode} at byte $start; url=$audioUrl',
          onFailure,
        );
        return null;
      }
      final int n = res.bodyBytes.length;
      if (n == 0) break; // EOF
      sink.add(res.bodyBytes);
      total += n;
      start += n;
      if (n < chunkBytes) break; // 短读 = 流末尾
    }
    await closeSink();
    if (total <= 0 || !output.existsSync() || output.lengthSync() <= 0) {
      deletePartial();
      return null;
    }
    return outputPath;
  } catch (e, stack) {
    await closeSink();
    deletePartial();
    _reportFfmpegUnexpectedException(
      'materializeRemoteAudioViaRangeDownload',
      e,
      stack,
      onFailure,
    );
    return null;
  } finally {
    if (httpClient == null) client.close();
  }
}

/// TODO-1650 制卡媒体清晰度档位（音频 / GIF 封面 / 截图封面的编码参数集）。
///
/// 由两个用户可调的清晰度滑块组装（各是独立有序档位，替代旧的单一「压缩」开关）：
/// - **图片/GIF 清晰度**（`AppModel.miningImageQuality`，4 档 0..3）：只管截图分辨率/
///   JPEG 质量 + GIF 帧率/宽度。见 [imageTiers]。满档 [imageTierMax]=**最高**（截图不缩、
///   原图直通；GIF 走封顶档，非源分辨率/源帧率——BUG-1039），最省档 0 更小更省流。
///   默认档 [defaultImageTier]=1 与旧「压缩档」逐字节一致——零行为破坏。
/// - **音频质量**（`AppModel.miningAudioQuality`，3 档 0..2）：只管句子/cue 音频声道 +
///   比特率。见 [audioTiers]。默认档 [defaultAudioTier]=0 = 旧压缩档（单声道 64k）。
///
/// 不可变值对象（纯数据，可单测、可在隔离中构造）。各底层纯函数（[buildFfmpegClipArgs]
/// / [buildFfmpegClipGifArgs] / [downsampleCardScreenshot]）仍接收原始可选参数，本类只是
/// 调用点选档时的参数捆绑，不让纯函数读全局偏好。最高档用 [screenshotMaxLongEdge] == 0
/// 表示「不缩放」（截图原图直通），由底层纯函数解读；**GIF 侧没有 0 哨兵档**（BUG-1039，
/// 见 [imageTiers]），任何档位的 [gifFps]/[gifWidth] 都是有限值。
class MiningMediaCompression {
  const MiningMediaCompression({
    required this.audioChannels,
    required this.audioBitrate,
    required this.gifFps,
    required this.gifWidth,
    required this.screenshotMaxLongEdge,
    required this.screenshotQuality,
  });

  /// 音频下混声道数（`-ac`）。
  final int audioChannels;

  /// 音频比特率（`-b:a`，如 `'64k'`）。
  final String audioBitrate;

  /// cue 封面 GIF 帧率（`fps=`）。**0 = 源帧率**（不加 fps 滤镜）。BUG-1039 后已无档位
  /// 产出 0——GIF 侧全档有限值；纯函数仍支持 0 供直接调用方使用。
  final int gifFps;

  /// cue 封面 GIF 宽度（`scale=W:-2`）。**0 = 源分辨率**（不加 scale 滤镜）。同上，
  /// BUG-1039 后已无档位产出 0。
  final int gifWidth;

  /// 帧截图封面降采样长边（px）。**0 = 不缩放**（最高档，原图字节直通）。
  final int screenshotMaxLongEdge;

  /// 帧截图封面重编码 JPEG 质量（0–100）。最高档不重编码，此值不生效。
  final int screenshotQuality;

  /// 图片/GIF 清晰度有序档位（索引 0..[imageTierMax]）：低→高。
  /// 档 1 = 旧「压缩档」（1000px/q90/GIF 480px·8fps），逐字节保持现状。
  /// 档 2 = 旧「高保真档」（2000px/q95/GIF 720px·12fps）。
  /// 档 3 = **最高**（UI 文案 `mining_image_quality_max`）：**截图**不缩、原图直通
  /// （`maxLongEdge` 用 0 哨兵）；**GIF** 走 [gifMaxTierFps]/[gifMaxTierWidth] 的封顶档。
  /// BUG-1039 前这一档叫「原片」，但它对 GIF 已不再是源分辨率/源帧率——只有截图仍是
  /// 原图，故改名为「最高」：只承诺是滑块顶格，不承诺具体保真度。
  ///
  /// BUG-1039：这一档过去对 GIF 也用 0 哨兵（源分辨率 + 源帧率），这是把「截图」的
  /// 语义错套到「动图」上——截图原图直通只是几 MB 的一张 JPEG，而 GIF 是 8-bit 调色板
  /// 逐帧 LZW、**无帧间压缩**，「源分辨率+源帧率」必然线性爆炸。1080p 源、**4 秒**字幕
  /// 区间实测：标准档(480/8) 1.5 秒 / 1.5 MB，原片档(0/0) **48.9 秒 / 54 MB**；cue 上限
  /// 10 秒时约 135 MB、还会撞 [extractClipGifViaFfmpeg] 的 120 秒超时。这条链路后面是
  /// base64 + jsonEncode + POST 给 AnkiConnect，Anki 在自己主线程解析这坨 JSON → 直接
  /// 无响应；落到卡片里每次复习都要解 54 MB GIF、AnkiWeb 也同步不上去。也就是说「GIF
  /// 原片」不是一个更高的质量档，而是一个**在任何口径下都不可用**的配置。故档 3 对 GIF
  /// 给出真实可用的封顶值（仍显著高于高清档：960px·12fps ≈ 高清档 1.8 倍像素，实测同一
  /// 4 秒区间 6 秒 / 7.7 MB），截图侧的原图直通语义完全不动。
  static const List<({int gifFps, int gifWidth, int maxLongEdge, int quality})>
      imageTiers = [
    (gifFps: 6, gifWidth: 360, maxLongEdge: 720, quality: 80), // 0 省流
    (gifFps: 8, gifWidth: 480, maxLongEdge: 1000, quality: 90), // 1 标准（默认=旧压缩档）
    (gifFps: 12, gifWidth: 720, maxLongEdge: 2000, quality: 95), // 2 高清（=旧高保真档）
    (
      gifFps: gifMaxTierFps,
      gifWidth: gifMaxTierWidth,
      maxLongEdge: 0,
      quality: 100
    ), // 3 最高（截图原图直通；GIF 封顶，BUG-1039）
  ];

  /// BUG-1039：最高档 GIF 的封顶帧率 / 宽度。GIF 无帧间压缩，不存在可用的「源分辨率+
  /// 源帧率」档；这两个值是「仍明显优于高清档、且体积与耗时可控」的实测折中。
  static const int gifMaxTierFps = 12;
  static const int gifMaxTierWidth = 960;

  /// 音频质量有序档位（索引 0..2）：低→高。
  /// 档 0 = 旧压缩档（单声道 64k），档 1 = 旧高保真档（立体声 128k），档 2 = 最高（立体声
  /// 192k）。BUG-1039 前档 2 叫「原片」，但 192k AAC 是有损重编码、并非原片，故一并改名。
  static const List<({int channels, String bitrate})> audioTiers = [
    (channels: 1, bitrate: '64k'), // 0 标准（默认=旧压缩档）
    (channels: 2, bitrate: '128k'), // 1 高音质（=旧高保真档）
    (channels: 2, bitrate: '192k'), // 2 最高
  ];

  static const int imageTierCount = 4;
  static const int audioTierCount = 3;

  /// 默认图片档（= 旧压缩档，保持现状）。
  static const int defaultImageTier = 1;

  /// 默认音频档（= 旧压缩档，单声道 64k）。
  static const int defaultAudioTier = 0;

  /// 满档索引（最高档，供 UI / 调用点判定「滑块顶格」语义）。
  static const int imageTierMax = imageTierCount - 1;

  static int _clampImageTier(int tier) =>
      tier < 0 ? 0 : (tier >= imageTierCount ? imageTierCount - 1 : tier);

  static int _clampAudioTier(int tier) =>
      tier < 0 ? 0 : (tier >= audioTierCount ? audioTierCount - 1 : tier);

  /// 具名预设：默认档组合（图片标准档 1 + 音频标准档 0），逐字节 = TODO-646 现状。
  /// 供不读用户偏好的调用点/测试当默认媒体档用（与 `resolve(imageTier:1, audioTier:0)` 等价）。
  static const MiningMediaCompression compressed = MiningMediaCompression(
    audioChannels: 1,
    audioBitrate: '64k',
    gifFps: 8,
    gifWidth: 480,
    screenshotMaxLongEdge: 1000,
    screenshotQuality: 90,
  );

  /// 具名预设：高保真档组合（图片高清档 2 + 音频高音质档 1），= 旧「关闭压缩」。
  static const MiningMediaCompression highFidelity = MiningMediaCompression(
    audioChannels: 2,
    audioBitrate: '128k',
    gifFps: 12,
    gifWidth: 720,
    screenshotMaxLongEdge: 2000,
    screenshotQuality: 95,
  );

  /// 据图片/GIF 清晰度档 [imageTier] + 音频质量档 [audioTier] 组装媒体档（越界自动夹取）。
  static MiningMediaCompression resolve({
    required int imageTier,
    required int audioTier,
  }) {
    final ({int gifFps, int gifWidth, int maxLongEdge, int quality}) img =
        imageTiers[_clampImageTier(imageTier)];
    final ({int channels, String bitrate}) aud =
        audioTiers[_clampAudioTier(audioTier)];
    return MiningMediaCompression(
      audioChannels: aud.channels,
      audioBitrate: aud.bitrate,
      gifFps: img.gifFps,
      gifWidth: img.gifWidth,
      screenshotMaxLongEdge: img.maxLongEdge,
      screenshotQuality: img.quality,
    );
  }
}

void _reportFfmpegFailure(
  String source,
  FfmpegRunResult result,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = result.failureSummary;
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, summary, StackTrace.current);
}

void _reportFfmpegProcessException(
  String source,
  ProcessException exception,
  StackTrace stack,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = describeFfmpegProcessException(exception);
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, summary, stack);
}

/// TODO-1005 / BUG-472：「ffmpeg 还没跑」的早返回（零长/错位区间、输入缺失）统一上报：
/// 同时进 ErrorLogService（in-app 日志页）+ 回调 onFailure（供传 reporter 的制卡路径
/// 向用户解释）。不改变返回值，仅补可诊断日志。
void _reportFfmpegEarlyReturn(
  String source,
  String summary,
  FfmpegFailureReporter? onFailure,
) {
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, summary, StackTrace.current);
}

void _reportFfmpegUnexpectedException(
  String source,
  Object error,
  StackTrace stack,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = error.toString();
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, error, stack);
}

/// Desktop (Windows/Linux/macOS) audio-clip extraction via ffmpeg.
///
/// On Android the sentence-audio clip used for Anki mining is cut by the native
/// `TtsChannelHandler` (MediaExtractor + AacAdtsCueAudioRewriter). There is no
/// native handler off Android, so desktop builds fall back to ffmpeg here.
///
/// ffmpeg is resolved from the `HIBIKI_FFMPEG` env var (absolute path), else
/// `ffmpeg` on PATH. If ffmpeg is absent the call returns null — the same
/// no-audio outcome as before, never a crash.

/// Builds the ffmpeg argument list to cut `[startMs, endMs)` out of [inputPath]
/// and re-encode it to AAC at [outputPath]. Pure (no IO) so it is unit-testable.
///
/// `-ss`/`-t` precede `-i` for fast input seeking (a multi-hour audiobook is not
/// decoded from 0); audio seeking is frame-accurate enough for sentence clips.
///
/// [audioStreamIndex] selects which audio stream to cut (ffmpeg `-map
/// 0:a:<idx>`, 0-based ordinal among the input's audio streams). null/negative
/// leaves ffmpeg's default audio-stream selection (the first / default track) —
/// used for audiobook clips (single audio) and when the user has not switched
/// the video's audio track. A multi-audio video (e.g. JP + EN dub) passes the
/// currently-selected track's ordinal so the clip matches what the user hears.
List<String> buildFfmpegClipArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  // TODO-757 压缩开关：默认压缩档（单声道 64k，= TODO-646 现状）。关闭压缩时调用
  // 点传立体声 128k（高保真档）。默认值保持现状，纯函数不读全局偏好。
  int audioChannels = 1,
  String audioBitrate = '64k',
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) {
  final double startSeconds = startMs / 1000.0;
  final double durationSeconds = (endMs - startMs) / 1000.0;
  final int? explicitAudio = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  return <String>[
    '-y',
    ...buildFfmpegRemoteInputArgs(inputPath, tlsPinSha256: tlsPinSha256),
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    '-vn',
    if (explicitAudio != null) ...<String>[
      '-map',
      // 尾随 '?'：越界音轨映射降级回退默认轨而非硬失败（BUG-345）。
      '0:a:$explicitAudio?',
    ],
    '-c:a',
    'aac',
    // TODO-646 近无损压缩 + TODO-757 压缩开关：句子音频是人声短片段，压缩档单声道
    // 64k AAC 听感接近透明、比默认（立体声 ~128k）省一半以上体积。`-ac` 下混声道、
    // `-b:a` 钉比特率，由 [audioChannels]/[audioBitrate] 决定（压缩档 1/64k=现状，
    // 高保真档 2/128k）。桌面句子音频与视频 cue 音频共用本函数，两条链路同时受益；
    // Android 原生 AacAdtsCueAudioRewriter 是无损 re-mux（跟源、不重编码），不经此
    // 路径、不受压缩开关影响。
    '-ac',
    '$audioChannels',
    '-b:a',
    audioBitrate,
    outputPath,
  ];
}

/// Builds the ffmpeg argument list to extract the embedded cover art of
/// [inputPath] into [outputPath] (re-encoded to the output extension, e.g. jpg).
List<String> buildFfmpegCoverArgs({
  required String inputPath,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-an',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Extracts the embedded cover art of [audioPath] into [outputPath] via ffmpeg.
/// Returns [outputPath] if a cover was written, else null (no cover / no ffmpeg
/// / error). Does not treat a non-zero ffmpeg exit as fatal — a file with no
/// cover stream simply produces no output.
Future<String?> extractEmbeddedCoverViaFfmpeg({
  required String audioPath,
  required String outputPath,
}) async {
  if (!File(audioPath).existsSync()) return null;
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegCoverArgs(inputPath: audioPath, outputPath: outputPath),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == null) {
      // Timed out / killed: drop any partial output.
      if (output.existsSync()) {
        try {
          output.deleteSync();
        } catch (_) {}
      }
      return null;
    }
    // ffmpeg exits non-zero when there is no cover stream; rely on the output.
    if (output.existsSync() && output.lengthSync() > 0) return outputPath;
    return null;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedCoverViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedCoverViaFfmpeg', e, stack);
    return null;
  }
}

/// TODO-1045 M4B 元数据：从音频容器 tag 读到的标题/作者/专辑。不可变值对象（纯数据，
/// 可单测、可在隔离中构造）。任一字段为 null 表示该 tag 缺失/空。
class AudioMetadata {
  const AudioMetadata({this.title, this.author, this.album});

  /// 容器 `title` tag（M4B 的 `©nam` 由 ffprobe 归一为 `title`）。
  final String? title;

  /// 容器 `artist` tag（M4B 的 `©ART` → `artist`）。有声书作者/朗读者。
  final String? author;

  /// 容器 `album` tag（M4B 的 `©alb` → `album`）。系列名，暂不回填但一并解析备用。
  final String? album;

  /// 三个字段全空（无任何可用 tag）。
  bool get isEmpty => title == null && author == null && album == null;
}

/// Builds the ffprobe argument list that prints [inputPath] 的 `format.tags` 为
/// JSON（镜像 [buildFfmpegCoverArgs] 的纯函数风格，无 IO，可单测）。
///
/// `-v quiet` 压掉 banner/进度，`-print_format json -show_format` 让 ffprobe 只把
/// 容器级信息（含 `format.tags`）以合法 JSON 写 stdout。M4B 的 iTunes 原子
/// （`©nam`/`©ART`/`©alb`）由 ffprobe 归一成 `title`/`artist`/`album` 键。
List<String> buildFfprobeFormatTagsArgs({required String inputPath}) {
  return <String>[
    '-v',
    'quiet',
    '-print_format',
    'json',
    '-show_format',
    inputPath,
  ];
}

/// **纯函数**：从 ffprobe `-show_format -print_format json` 的 stdout 解析出
/// [AudioMetadata]。读 `format.tags` 下的 title/artist/album，**键名大小写不敏感**
/// （不同容器写 `TITLE`/`title`/`Title`）。空白值归一成 null。解析失败 / 非预期结构
/// 返回全空 [AudioMetadata]（绝不抛，调用方据此回退文件名兜底）。
AudioMetadata parseAudioMetadataFromFfprobeJson(String probeStdout) {
  final String trimmed = probeStdout.trim();
  if (trimmed.isEmpty) return const AudioMetadata();
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const AudioMetadata();
  }
  if (decoded is! Map) return const AudioMetadata();
  final Object? format = decoded['format'];
  if (format is! Map) return const AudioMetadata();
  final Object? tags = format['tags'];
  if (tags is! Map) return const AudioMetadata();

  // 大小写不敏感取键：把所有 tag 键小写化后查。首个非空值胜出。
  final Map<String, String> lower = <String, String>{};
  tags.forEach((Object? k, Object? v) {
    if (k is String && v != null) {
      final String key = k.toLowerCase();
      final String value = v.toString().trim();
      if (value.isNotEmpty && !lower.containsKey(key)) {
        lower[key] = value;
      }
    }
  });
  return AudioMetadata(
    title: lower['title'],
    author: lower['artist'],
    album: lower['album'],
  );
}

/// Extracts the container-level [AudioMetadata] (title/artist/album tags) of
/// [inputPath] via ffprobe. Returns null when the input is missing, ffprobe is
/// unavailable (mobile CLI absent — the Kit backend handles mobile), the probe
/// times out, or no usable tags were found — the same graceful degradation as
/// [extractEmbeddedCoverViaFfmpeg]，调用方回退文件名兜底，绝不崩。
Future<AudioMetadata?> extractAudioMetadataViaFfprobe({
  required String inputPath,
}) async {
  if (!File(inputPath).existsSync()) return null;
  try {
    final FfmpegRunResult result = await resolveFfmpegBackend().runProbe(
      buildFfprobeFormatTagsArgs(inputPath: inputPath),
      const Duration(seconds: 15),
    );
    if (result.returnCode == null) return null; // timed out / killed
    final AudioMetadata meta = parseAudioMetadataFromFfprobeJson(result.output);
    return meta.isEmpty ? null : meta;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractAudioMetadataViaFfprobe', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractAudioMetadataViaFfprobe', e, stack);
    return null;
  }
}

/// Builds the ffmpeg argument list to grab a single frame from [inputPath] at
/// [atSeconds] (input seek, fast) and write it to [outputPath] (the output
/// extension, e.g. `.jpg`, picks the encoder). Pure (no IO) so it is
/// unit-testable.
///
/// `-ss <atSeconds>` precedes `-i` for fast input seeking (a multi-GB episode is
/// not decoded from 0). [atSeconds] is clamped to >= 0 so a tiny/short video
/// never seeks negative; seeking past the end yields no frame (the extractor
/// then reports null). A non-zero default (e.g. 10s) avoids a black intro frame.
List<String> buildFfmpegFrameArgs({
  required String inputPath,
  required String outputPath,
  double atSeconds = 0.0,
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) {
  final double seek = atSeconds < 0 ? 0.0 : atSeconds;
  return <String>[
    '-y',
    ...buildFfmpegRemoteInputArgs(inputPath, tlsPinSha256: tlsPinSha256),
    '-ss',
    seek.toStringAsFixed(3),
    '-i',
    inputPath,
    '-an',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Grabs a single video frame from [inputPath] at [atSeconds] into [outputPath]
/// via ffmpeg (used as the shelf cover thumbnail). Returns [outputPath] on
/// success, or null if the input is missing, ffmpeg is not installed, or no
/// frame was written (e.g. seek past the end).
///
/// Mirrors [extractEmbeddedCoverViaFfmpeg]: bounded timeout, drops partial
/// output on timeout / failure, never throws for the caller (no ffmpeg on
/// mobile simply means no thumbnail, not a crash).
Future<String?> extractVideoFrameViaFfmpeg({
  required String inputPath,
  required String outputPath,
  double atSeconds = 10.0,
  FfmpegFailureReporter? onFailure,
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) async {
  if (!_isRemoteFfmpegInput(inputPath) && !File(inputPath).existsSync()) {
    return null;
  }
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegFrameArgs(
        inputPath: inputPath,
        outputPath: outputPath,
        atSeconds: atSeconds,
        tlsPinSha256: tlsPinSha256,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractVideoFrameViaFfmpeg', result, onFailure);
    return null;
  } on ProcessException catch (e, stack) {
    _reportFfmpegProcessException(
      'extractVideoFrameViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  } catch (e, stack) {
    _reportFfmpegUnexpectedException(
      'extractVideoFrameViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  }
}

/// 视频制卡用：把 `[startMs, endMs)` 这段 cue 时间窗导出成**循环动图 GIF**
/// （用户要的「cue 时间段的动图」而非单帧截图）。纯函数（无 IO），可单测。
///
/// 单次 ffmpeg 调用内做两遍调色板（`palettegen`/`paletteuse`）以避免低质抖动：
/// `fps=[fps],scale=[width]:-2:lanczos,split → palettegen → paletteuse`。
/// `-2` 让高度按宽度等比且取偶（gif 编码要求偶数维度）。`-ss`/`-t` 置于 `-i` 前做
/// 快速输入定位（多 GB 剧集不从 0 解码）。时长 clamp 到 `(0, maxDurationMs]`：cue 太长
/// 时只取前段，避免 gif 体积/耗时爆炸；endMs<=startMs 时调用方应已拦截。
List<String> buildFfmpegClipGifArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  // TODO-646 近无损压缩 + TODO-757 压缩开关：压缩档 cue 封面动图 480px/8fps
  // （TODO-1145 从 320 拉高）；高保真档 720px/12fps（与 app 内视频制卡共用档位）。
  // 默认值保持压缩档（现状），由调用点据压缩开关传值，纯函数不读全局偏好。仍走
  // palettegen/paletteuse 双遍避免抖动。
  int fps = 8,
  int width = 320,
  int maxDurationMs = 10000,
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) {
  final double startSeconds = (startMs < 0 ? 0 : startMs) / 1000.0;
  final int rawDur = endMs - startMs;
  final int clampedDur =
      rawDur > maxDurationMs ? maxDurationMs : (rawDur < 1 ? 1 : rawDur);
  final double durationSeconds = clampedDur / 1000.0;
  // [fps]<=0 / [width]<=0 表示「源帧率 / 源分辨率」（BUG-1039 后无档位再传 0，仅供直接调用方）：
  // 对应滤镜前缀整段省略（不降帧、不缩放），仅保留 palettegen/paletteuse 双遍避免抖动。
  final StringBuffer pre = StringBuffer();
  if (fps > 0) pre.write('fps=$fps,');
  if (width > 0) pre.write('scale=$width:-2:flags=lanczos,');
  final String filter =
      '${pre}split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse';
  return <String>[
    '-y',
    ...buildFfmpegRemoteInputArgs(inputPath, tlsPinSha256: tlsPinSha256),
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    '-an',
    '-filter_complex',
    filter,
    '-loop',
    '0',
    outputPath,
  ];
}

/// 把 [inputPath] 的 `[startMs, endMs)` 段导出成循环 GIF 到 [outputPath]（见
/// [buildFfmpegClipGifArgs]）。成功返回 [outputPath]，否则 null（范围非法 / 输入缺失 /
/// ffmpeg 不存在（移动端无 CLI ffmpeg）/ 编码无输出）——调用方据此回退单帧截图。
///
/// 镜像 [extractAudioSegmentViaFfmpeg]：有界超时、失败/超时清理半成品、对调用方不抛。
Future<String?> extractClipGifViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
  // TODO-757 压缩开关：默认压缩档（480px/8fps，TODO-1145 拉高）；关闭压缩时调用点
  // 传高保真档（720px/12fps，与 app 内视频制卡共用档位）。
  int fps = 8,
  int width = 320,
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) async {
  if (endMs <= startMs) return null;
  if (!_isRemoteFfmpegInput(inputPath) && !File(inputPath).existsSync()) {
    return null;
  }

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegClipGifArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
        fps: fps,
        width: width,
        tlsPinSha256: tlsPinSha256,
      ),
      const Duration(seconds: 120),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractClipGifViaFfmpeg', result, onFailure);
    return null;
  } on ProcessException catch (e, stack) {
    // 移动端无 CLI ffmpeg：优雅回退（调用方改用单帧截图）。
    _reportFfmpegProcessException(
      'extractClipGifViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  } catch (e, stack) {
    _reportFfmpegUnexpectedException(
      'extractClipGifViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  }
}

/// Builds the ffmpeg argument list to demux the [streamIndex]-th subtitle track
/// of [inputPath] into [outputPath]. Pure (no IO) so it is unit-testable.
///
/// `0:s:$streamIndex` selects the Nth subtitle stream of the (only) input;
/// ffmpeg infers the output subtitle format from [outputPath]'s extension
/// (e.g. `.ass` → ASS), so an embedded ASS track round-trips losslessly.
List<String> buildFfmpegSubtitleArgs({
  required String inputPath,
  required int streamIndex,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-map',
    '0:s:$streamIndex',
    outputPath,
  ];
}

/// Demuxes the [streamIndex]-th embedded subtitle track of [inputPath] into
/// [outputPath] via ffmpeg. Returns [outputPath] on success, or null if the
/// input is missing, the stream index is out of range, ffmpeg is not installed,
/// or no subtitle text was written.
///
/// Mirrors [extractAudioSegmentViaFfmpeg]: bounded timeout, drops partial
/// output on timeout / failure, never throws for the caller (a video with no
/// subtitle track is a no-op fallback, not a crash).
Future<String?> extractEmbeddedSubtitleViaFfmpeg({
  required String inputPath,
  required int streamIndex,
  required String outputPath,
}) async {
  if (!File(inputPath).existsSync()) return null;

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    // 30s bounds a hung demux; subtitle demuxing is text-only (no re-encode of
    // the multi-GB video), so even a long episode finishes in well under this.
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegSubtitleArgs(
        inputPath: inputPath,
        streamIndex: streamIndex,
        outputPath: outputPath,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractEmbeddedSubtitleViaFfmpeg', result, null);
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg not installed / not on PATH — graceful no-subtitle fallback.
    ErrorLogService.instance.log('extractEmbeddedSubtitleViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitleViaFfmpeg', e, stack);
    return null;
  }
}

/// Builds the ffmpeg argument list to demux MANY embedded subtitle tracks of
/// [inputPath] in a **single pass** — one `-i`, then `-map 0:s:i out_i` repeated.
/// Pure (no IO) so it is unit-testable.
///
/// [outputs] maps each subtitle relative stream index (`-map 0:s:N`) to its
/// output path; the path extension drives ffmpeg's output muxer (`.srt`→SubRip,
/// `.ass`→ASS…). Maps are emitted in ascending stream-index order for
/// deterministic args. The whole point: an interleaved multi-GB container is
/// read **once** for every track at once (the read dominates wall-clock), so
/// extracting 8 tracks costs the same as extracting one — switching among tracks
/// no longer re-reads the file each time (BUG-104).
List<String> buildFfmpegMultiSubtitleArgs({
  required String inputPath,
  required Map<int, String> outputs,
}) {
  final List<String> args = <String>['-y', '-i', inputPath];
  final List<int> indices = outputs.keys.toList()..sort();
  for (final int idx in indices) {
    args.addAll(<String>['-map', '0:s:$idx', outputs[idx]!]);
  }
  return args;
}

/// Demuxes ALL requested embedded subtitle tracks of [inputPath] in one ffmpeg
/// pass (see [buildFfmpegMultiSubtitleArgs]). Returns the subset of [outputs]
/// actually written (file exists and non-empty); a partially-failed batch (one
/// corrupt track) still yields the tracks that succeeded rather than dropping
/// everything. When the single pass produces fewer tracks than requested — the
/// worst case being an output-open `AVERROR(EINVAL)` (exit -22) that a single
/// un-encodable track triggers, aborting the batch before ANY track is written —
/// each still-missing track is re-demuxed on its own so one poison track only
/// loses itself instead of poisoning every good track in the container.
///
/// [timeout] bounds a hung demux. Unlike single-clip encodes, the read time of a
/// big interleaved container grows with its size, so callers pass a size-scaled
/// timeout (see `subtitleExtractTimeoutForBytes`). Never throws for the caller:
/// missing input / absent ffmpeg / error all yield an empty map (no-subtitle
/// fallback, not a crash).
/// Suffix of the negative-cache sentinel written next to an embedded-subtitle
/// output when a track is rejected DEFINITIVELY (ffmpeg ran and returned a
/// non-zero, non-timeout exit — a codec the bundled build can't decode). Lets
/// callers skip re-reading the whole container for that track on later passes.
/// Deliberately NOT written on timeouts (`returnCode == null`), which are
/// transient (IO contention on a huge interleaved container, BUG-104) and must
/// stay retryable. Lives beside the cache file, whose directory is keyed by the
/// video's size+mtime, so replacing the file in place re-attempts extraction.
/// BUG-863.
const String kUnsupportedEmbeddedSubtitleSentinelSuffix = '.unsupported';

/// Returns the subset of [outputs] that ffmpeg actually wrote (file exists and
/// is non-empty), deleting empty stubs left behind by a failed/aborted run.
Map<int, String> _collectWrittenSubtitles(Map<int, String> outputs) {
  final Map<int, String> written = <int, String>{};
  outputs.forEach((int idx, String out) {
    final File f = File(out);
    if (f.existsSync() && f.lengthSync() > 0) {
      written[idx] = out;
    } else if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  });
  return written;
}

Future<Map<int, String>> extractEmbeddedSubtitlesViaFfmpeg({
  required String inputPath,
  required Map<int, String> outputs,
  Duration timeout = const Duration(seconds: 180),
}) async {
  if (outputs.isEmpty) return const <int, String>{};
  if (!File(inputPath).existsSync()) return const <int, String>{};
  try {
    for (final String out in outputs.values) {
      File(out).parent.createSync(recursive: true);
    }
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegMultiSubtitleArgs(inputPath: inputPath, outputs: outputs),
      timeout,
    );
    // Filter by what actually landed, dropping empty stubs.
    final Map<int, String> written = _collectWrittenSubtitles(outputs);

    // BUG-863: the single-pass batch is all-or-nothing at *output-binding* time.
    // ffmpeg wires up EVERY `-map … out` before decoding a single packet, so one
    // track it can't process — a text codec the bundled `--disable-everything`
    // min-ffmpeg lacks a decoder for (ttml / eia_608·CEA-708 / dvb_teletext /
    // hdmv_text / sami …, all of which `subtitleFormatForCodec` fail-opens to
    // `.srt`) — aborts the whole command with AVERROR(EINVAL) ("Error opening
    // output files: Invalid argument", exit -22) BEFORE any file is written. The
    // good subrip/ass tracks in the same batch are lost too → the user sees NO
    // embedded subtitles at all. When the batch didn't yield every requested
    // track, retry the missing ones ONE AT A TIME: a bad track then fails in
    // isolation (fast, at binding — no full container read) while every good
    // track still lands. The batch stays the fast path for the common all-good
    // case; this only runs on failure.
    // Gated on a non-null batch returnCode: a timed-out batch (returnCode ==
    // null) means the demux itself is too slow (IO contention, BUG-104), so
    // per-track retries would just multiply that one timeout into N. The
    // poison-track case this fallback targets always returns a real exit code
    // (-22), fast — so the guard costs nothing there.
    if (result.returnCode != null && written.length < outputs.length) {
      for (final MapEntry<int, String> entry in outputs.entries) {
        if (written.containsKey(entry.key)) continue;
        final FfmpegRunResult single = await _runFfmpeg(
          buildFfmpegSubtitleArgs(
            inputPath: inputPath,
            streamIndex: entry.key,
            outputPath: entry.value,
          ),
          timeout,
        );
        final File f = File(entry.value);
        if (single.returnCode == 0 && f.existsSync() && f.lengthSync() > 0) {
          written[entry.key] = entry.value;
          continue;
        }
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
        // Definitive rejection (ran, non-zero, non-timeout → the codec is
        // undecodable by this build): negatively cache so future passes skip
        // this track instead of re-reading the container and re-logging. A
        // timeout (returnCode null) is transient and stays retryable.
        final int? rc = single.returnCode;
        if (rc != null && rc != 0) {
          try {
            File('${entry.value}$kUnsupportedEmbeddedSubtitleSentinelSuffix')
                .writeAsStringSync('');
          } catch (_) {}
        }
      }
    }

    // Only a genuinely empty result (every track un-extractable) is worth an
    // error log; a partial batch rescued by the per-track fallback is a success.
    if (written.isEmpty) {
      _reportFfmpegFailure(
        'extractEmbeddedSubtitlesViaFfmpeg',
        result,
        null,
      );
    }
    return written;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitlesViaFfmpeg', e, stack);
    return const <int, String>{};
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitlesViaFfmpeg', e, stack);
    return const <int, String>{};
  }
}

/// Runs ffmpeg with [args] via the active [FfmpegBackend] and returns the exit
/// code (null on timeout). Behaviour is unchanged from the historical inline
/// `Process.start` path — [CliFfmpegBackend] replicates it; the mobile
/// [KitFfmpegBackend] (self-built ffmpeg-kit) slots in transparently. Throws
/// [ProcessException] when ffmpeg is unavailable — callers handle that.
Future<FfmpegRunResult> _runFfmpeg(List<String> args, Duration timeout) async {
  final FfmpegRunResult result =
      await resolveFfmpegBackend().run(args, timeout);
  return result;
}

/// Cuts `[startMs, endMs)` out of [inputPath] into [outputPath] using ffmpeg.
/// Returns [outputPath] on success, or null if the range is invalid, the input
/// is missing, ffmpeg is not installed, or the cut produced no output.
Future<String?> extractAudioSegmentViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegFailureReporter? onFailure,
  // TODO-757 压缩开关：默认压缩档（单声道 64k，= 现状）；关闭压缩时调用点传立体声
  // 128k（高保真档）。
  int audioChannels = 1,
  String audioBitrate = '64k',
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
}) async {
  // TODO-1005 / BUG-472：这两条「ffmpeg 还没跑」的早返回历来静默 return null——
  // 有声书片段导出 / 句子音频 TTS / 视频制卡 只看到「失败但日志空白」，无从诊断。
  // 改为同时打 ErrorLogService（in-app 日志页可查）+ 回调 onFailure（让传 reporter
  // 的制卡路径也能向用户解释），再 return null（返回值/行为不变）。
  if (endMs <= startMs) {
    _reportFfmpegEarlyReturn(
      'extractAudioSegmentViaFfmpeg',
      'non-positive range (endMs=$endMs <= startMs=$startMs); '
          'inputPath=$inputPath',
      onFailure,
    );
    return null;
  }
  if (!_isRemoteFfmpegInput(inputPath) && !File(inputPath).existsSync()) {
    _reportFfmpegEarlyReturn(
      'extractAudioSegmentViaFfmpeg',
      'input audio file does not exist: $inputPath '
          '(startMs=$startMs, endMs=$endMs)',
      onFailure,
    );
    return null;
  }

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    // 120s bounds a hung encode; even a several-minute clip re-encodes to AAC
    // far faster than real time, so this never truncates a legitimate clip.
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegClipArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        audioChannels: audioChannels,
        audioBitrate: audioBitrate,
        tlsPinSha256: tlsPinSha256,
      ),
      const Duration(seconds: 120),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractAudioSegmentViaFfmpeg', result, onFailure);
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg not installed / not on PATH — graceful no-audio fallback.
    _reportFfmpegProcessException(
      'extractAudioSegmentViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  } catch (e, stack) {
    _reportFfmpegUnexpectedException(
      'extractAudioSegmentViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  }
}

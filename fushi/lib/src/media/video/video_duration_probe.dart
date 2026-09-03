/// 一次 ffprobe 探出一个本地视频文件的**全部容器事实**：时长、容器码率、视频流规格
/// （分辨率 / 编码 / 色深 / 帧率 / 色彩标签）、以及每一条音轨与字幕轨。
///
/// 起初这里只探两件事（时长 + 音轨语言），都是给字幕自动获取链路用的：
/// - **时长**给「这条字幕真的是这个视频的吗」校验用（`subtitle/subtitle_timing_check.dart`）。
///   `VideoBooks` 没有 duration 列，播放器时长又只在 controller 打开后才有，下载
///   流水线拿不到，只能现探。
/// - **音轨语言**给「默认下视频语言的字幕」用。
///
/// 后来库页卡片与作品详情页要展示技术规格（清晰度 / HDR / 编码 / 音轨），而这些事实
/// **与上面两件出自同一次 ffprobe**——多问几个 `-show_entries` 字段是免费的，再起一次
/// 进程不是。所以这里扩成完整探测，[VideoProbeFacts] 相应长大；老调用点只读
/// [VideoProbeFacts.durationMs] / [VideoProbeFacts.audioLanguages]，语义逐字未变。
///
/// （文件名仍是 `video_duration_probe`，已窄于实际职责；改名是纯机械改动，留给独立提交，
/// 不混进功能改动里。）
///
/// 走既有 [FfmpegBackend.runProbe]，所以桌面（ffprobe 进程）与移动端
/// （ffmpeg-kit 进程内）同一条路径，不新增平台分支。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, immutable, visibleForTesting;

import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/video_dynamic_range.dart';

/// ffprobe 探测的超时。只读 header，不解码，几十毫秒级；给足 20s 覆盖冷缓存
/// 与机械盘。**超时按失败处理并返回空结果**——校验拿不到时长时会退化成「只做内容
/// 自检」，绝不因为探测失败就拒收字幕。
const Duration kVideoDurationProbeTimeout = Duration(seconds: 20);

/// 探测器请求的字段集版本。
///
/// 落库缓存拿它当失效判据之一：字段集扩了（比如以后加 side_data 里的 Dolby Vision），
/// 旧行即便文件没变也必须重探，否则新字段永远是空的。**改动下面的 `-show_entries`
/// 就必须 +1**。
///
/// v3：加 `attached_pic` disposition——此前拿第一条 video 流当视频轨，内嵌封面图会把
/// 4K 片子标成「480p · MJPEG」；已缓存的错行靠这次 +1 自动重探。
const int kVideoProbeFieldSetVersion = 3;

/// 一次 ffprobe 的产出。每个字段各自可空：探到什么算什么，绝不因为一半缺失就把
/// 另一半也丢掉。
@immutable
class VideoProbeFacts {
  const VideoProbeFacts({
    this.durationMs,
    this.fileSizeBytes,
    this.containerBitrate,
    this.video,
    this.audioTracks = const <AudioTrackFacts>[],
    this.subtitleTracks = const <SubtitleTrackFacts>[],
  });

  static const VideoProbeFacts empty = VideoProbeFacts();

  /// 容器时长（毫秒）；探不到为 null。
  final int? durationMs;

  /// 容器文件大小（字节，`format.size`）；探不到为 null。
  final int? fileSizeBytes;

  /// 整个容器的平均码率（bit/s，`format.bit_rate`）。
  ///
  /// **视频流自己的码率经常没有**（实测：mkv 的视频/音频流都不给 `bit_rate`，只有 mp4
  /// 给），所以展示码率时通常只能用这个容器级的值。
  final int? containerBitrate;

  /// 第一条视频流的规格；纯音频文件或探测失败为 null。
  final VideoStreamFacts? video;

  /// 全部音轨，**按流顺序**（第一条通常是主音轨）。
  final List<AudioTrackFacts> audioTracks;

  /// 全部字幕轨（内封），按流顺序。
  final List<SubtitleTrackFacts> subtitleTracks;

  /// 音轨自报的语言标签，**按流顺序**。未标注的流不入列。
  ///
  /// 从 [audioTracks] 派生而不是单独存一份——同一事实存两处早晚会不一致。语义与扩展
  /// 前逐字相同：原样返回不归一（归一是 `subtitle_language_preference.dart` 的职责），
  /// 且 `und` 不入列。
  List<String> get audioLanguages {
    final List<String> out = <String>[];
    for (final AudioTrackFacts track in audioTracks) {
      final String? language = track.language;
      if (language == null) continue;
      out.add(language);
    }
    return List<String>.unmodifiable(out);
  }

  /// 主音轨语言（第一条带 language tag 的音轨）；没有返回 null。
  String? get primaryAudioLanguage =>
      audioLanguages.isEmpty ? null : audioLanguages.first;

  /// 是否什么都没探到（用于判断要不要落库）。
  bool get isEmpty =>
      durationMs == null &&
      video == null &&
      audioTracks.isEmpty &&
      subtitleTracks.isEmpty;
}

/// 视频流规格。
@immutable
class VideoStreamFacts {
  const VideoStreamFacts({
    this.codec,
    this.width,
    this.height,
    this.pixelFormat,
    this.bitDepth,
    this.frameRateMilli,
    this.bitrate,
    this.colorPrimaries,
    this.colorTransfer,
    this.colorSpace,
  });

  /// ffprobe `codec_name`，如 `h264` / `hevc` / `av1`。
  final String? codec;

  final int? width;
  final int? height;

  /// 如 `yuv420p10le`。色深主要从它推（见 [bitDepth]）。
  final String? pixelFormat;

  /// 每分量位深。
  ///
  /// **不能只信 `bits_per_raw_sample`**：实测 10-bit HEVC 流根本不给这个字段，而
  /// 8-bit H.264 给。所以优先从 [pixelFormat] 的 `p10le` / `p12le` 后缀推，推不出
  /// 再退回 `bits_per_raw_sample`。
  final int? bitDepth;

  /// 帧率 ×1000（23.976fps → 23976）。
  ///
  /// 用整数存是因为 ffprobe 给的是 `"2997/125"` 这样的**精确分数**，转 double 再比较
  /// 会引入浮点误差；×1000 的整数足够区分 23.976 / 24 / 25 / 29.97 / 30 / 60。
  final int? frameRateMilli;

  /// 视频流码率（bit/s）。**mkv 通常没有**，见 [VideoProbeFacts.containerBitrate]。
  final int? bitrate;

  final String? colorPrimaries;
  final String? colorTransfer;
  final String? colorSpace;

  /// 归一后的动态范围。判据收口在 `video_dynamic_range.dart`，与播放器侧同一份。
  VideoDynamicRange get dynamicRange => dynamicRangeFromFfprobe(
        colorPrimaries: colorPrimaries,
        colorTransfer: colorTransfer,
      );

  /// 帧率（fps），[frameRateMilli] 为空时返回 null。
  double? get frameRate =>
      frameRateMilli == null ? null : frameRateMilli! / 1000.0;

  /// 清晰度短标：`4K` / `1080p` / `720p` …
  ///
  /// 按**长边**分档，不按高度：2.35:1 的电影片源高度只有 800~872，按高度会被误判成
  /// 720p；竖屏视频则反过来。长边同时覆盖这两种情况，不需要为横竖屏各写一个分支。
  /// 阈值取得比标准分辨率低一档，是为了容纳裁边后的非标准尺寸（1920×804 仍是 1080p）。
  String? get resolutionLabel {
    final int? w = width;
    final int? h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    final int longEdge = math.max(w, h);
    if (longEdge >= 3800) return '4K';
    if (longEdge >= 2500) return '1440p';
    if (longEdge >= 1800) return '1080p';
    if (longEdge >= 1200) return '720p';
    if (longEdge >= 940) return '576p';
    if (longEdge >= 600) return '480p';
    return '${longEdge}p';
  }

  /// 编码显示名：`hevc` → `HEVC`、`h264` → `H.264`。
  String? get codecLabel => _videoCodecLabel(codec);
}

/// 一条音轨。
@immutable
class AudioTrackFacts {
  const AudioTrackFacts({
    required this.index,
    this.codec,
    this.channels,
    this.channelLayout,
    this.sampleRate,
    this.bitrate,
    this.language,
    this.title,
    this.isDefault = false,
    this.isForced = false,
    this.isCommentary = false,
  });

  /// ffprobe `index`（容器内的全局流序号，不是「第几条音轨」）。
  final int index;

  /// `codec_name`，如 `aac` / `flac` / `eac3` / `truehd`。
  final String? codec;

  final int? channels;

  /// `channel_layout`，如 `stereo` / `5.1`。
  final String? channelLayout;

  final int? sampleRate;
  final int? bitrate;

  /// 自报语言；`und` 与未标注一律为 null（放行 `und` 会让下游把「未知」当成一个真语言
  /// 去匹配，永远匹配不上，还挡住后面真有标注的音轨）。
  final String? language;

  final String? title;
  final bool isDefault;
  final bool isForced;

  /// `disposition.comment`：导演评论等副音轨。
  final bool isCommentary;

  /// 编码显示名：`eac3` → `E-AC-3`。
  String? get codecLabel => _audioCodecLabel(codec);

  /// 落库用。键名短且稳定——这串 JSON 会存进 `video_file_specs.audio_tracks_json`，
  /// 改键名等于让所有已缓存的行解不出来（届时靠 `kVideoProbeFieldSetVersion` 兜底重探）。
  Map<String, Object?> toJson() => <String, Object?>{
        'i': index,
        if (codec != null) 'c': codec,
        if (channels != null) 'ch': channels,
        if (channelLayout != null) 'cl': channelLayout,
        if (sampleRate != null) 'sr': sampleRate,
        if (bitrate != null) 'br': bitrate,
        if (language != null) 'l': language,
        if (title != null) 't': title,
        if (isDefault) 'd': 1,
        if (isForced) 'f': 1,
        if (isCommentary) 'm': 1,
      };

  static AudioTrackFacts fromJson(Map<String, Object?> json) => AudioTrackFacts(
        index: _intFrom(json['i']) ?? 0,
        codec: _stringFrom(json['c']),
        channels: _intFrom(json['ch']),
        channelLayout: _stringFrom(json['cl']),
        sampleRate: _intFrom(json['sr']),
        bitrate: _intFrom(json['br']),
        language: _stringFrom(json['l']),
        title: _stringFrom(json['t']),
        isDefault: _intFrom(json['d']) == 1,
        isForced: _intFrom(json['f']) == 1,
        isCommentary: _intFrom(json['m']) == 1,
      );

  /// 声道显示名：`5.1` / `2.0`（`stereo` 与 `mono` 归一成数字写法，与 `5.1` 同形）。
  String? get channelLabel {
    final String? layout = channelLayout?.trim().toLowerCase();
    if (layout != null && layout.isNotEmpty) {
      switch (layout) {
        case 'stereo':
          return '2.0';
        case 'mono':
          return '1.0';
        default:
          // `5.1(side)` 这类带括号后缀的，取括号前的主体。
          final int paren = layout.indexOf('(');
          return paren > 0 ? layout.substring(0, paren) : layout;
      }
    }
    final int? c = channels;
    if (c == null || c <= 0) return null;
    return switch (c) {
      1 => '1.0',
      2 => '2.0',
      6 => '5.1',
      8 => '7.1',
      _ => '$c.0',
    };
  }
}

/// 一条内封字幕轨。
@immutable
class SubtitleTrackFacts {
  const SubtitleTrackFacts({
    required this.index,
    this.codec,
    this.language,
    this.title,
    this.isDefault = false,
    this.isForced = false,
  });

  final int index;

  /// `codec_name`，如 `subrip` / `ass` / `hdmv_pgs_subtitle`。
  final String? codec;

  final String? language;
  final String? title;
  final bool isDefault;
  final bool isForced;

  /// 字幕格式显示名：`subrip` → `SRT`、`hdmv_pgs_subtitle` → `PGS`。
  String? get codecLabel => _subtitleCodecLabel(codec);

  /// 落库用，键名约定同 [AudioTrackFacts.toJson]。
  Map<String, Object?> toJson() => <String, Object?>{
        'i': index,
        if (codec != null) 'c': codec,
        if (language != null) 'l': language,
        if (title != null) 't': title,
        if (isDefault) 'd': 1,
        if (isForced) 'f': 1,
      };

  static SubtitleTrackFacts fromJson(Map<String, Object?> json) =>
      SubtitleTrackFacts(
        index: _intFrom(json['i']) ?? 0,
        codec: _stringFrom(json['c']),
        language: _stringFrom(json['l']),
        title: _stringFrom(json['t']),
        isDefault: _intFrom(json['d']) == 1,
        isForced: _intFrom(json['f']) == 1,
      );
}

/// 把一串轨道编码成落库的 JSON 文本。
String encodeTrackListJson(List<Map<String, Object?>> tracks) =>
    jsonEncode(tracks);

/// 解码落库的轨道 JSON 文本。**任何格式异常都退化成空列表**——规格是装饰性信息，
/// 一条坏缓存不该让作品详情页整页打不开。
List<T> decodeTrackListJson<T>(
  String? json,
  T Function(Map<String, Object?>) fromJson,
) {
  if (json == null || json.trim().isEmpty) return <T>[];
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List) return <T>[];
    final List<T> out = <T>[];
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      out.add(fromJson(item));
    }
    return List<T>.unmodifiable(out);
  } catch (_) {
    return <T>[];
  }
}

/// 一次 ffprobe 拿到 [path] 的全部容器事实。任何失败返回 [VideoProbeFacts.empty]。
Future<VideoProbeFacts> probeVideoFacts(
  String path, {
  @visibleForTesting FfmpegBackend? backend,
}) async {
  try {
    final FfmpegRunResult result =
        await (backend ?? resolveFfmpegBackend()).runProbe(
      <String>[
        '-v',
        'quiet',
        '-print_format',
        'json',
        '-show_entries',
        kVideoProbeShowEntries,
        path,
      ],
      kVideoDurationProbeTimeout,
    );
    if (result.returnCode != 0) return VideoProbeFacts.empty;
    return parseFfprobeFacts(result.output);
  } catch (e) {
    // 缺 ffprobe 是**正常降级**（用户没装 / 没捆绑），不是错误路径。
    debugPrint('[VideoDurationProbe] probe failed for "$path": $e');
    return VideoProbeFacts.empty;
  }
}

/// `-show_entries` 的字段集。
///
/// 三段各有各的语法，**不能合并**（实测踩过：把 `disposition` 写进 `stream=` 段里
/// 不会有任何输出，必须单独用 `stream_disposition=`）：
/// - `format=` 容器级
/// - `stream=` 流的固有属性
/// - `stream_disposition=` 流的 default/forced/comment 标志
/// - `stream_tags=` 流的元数据 tag
///
/// 改这里必须同步 +1 [kVideoProbeFieldSetVersion]，否则已落库的旧行不会重探。
const String kVideoProbeShowEntries = 'format=duration,size,bit_rate:'
    'stream=index,codec_type,codec_name,width,height,pix_fmt,'
    'color_primaries,color_transfer,color_space,bits_per_raw_sample,'
    'r_frame_rate,bit_rate,channels,channel_layout,sample_rate:'
    'stream_disposition=default,forced,comment,attached_pic:'
    'stream_tags=language,title';

/// 只要时长的窄入口（老调用点保持原样）。
Future<int?> probeVideoDurationMs(
  String path, {
  @visibleForTesting FfmpegBackend? backend,
}) async =>
    (await probeVideoFacts(path, backend: backend)).durationMs;

/// 解析 ffprobe `-print_format json` 的 stdout。纯函数，便于单测。
///
/// 容错到底：ffprobe 对无时长容器给 `"N/A"` 或干脆不给 `duration`；`streams` 可能
/// 整个缺失；单个 stream 可能没有 `tags` / `disposition`；**未标注的色彩字段整个键都
/// 不出现**。任何一处不合预期都只让那一项为空，**不让整次探测作废**。
VideoProbeFacts parseFfprobeFacts(String stdout) {
  final String trimmed = stdout.trim();
  if (trimmed.isEmpty) return VideoProbeFacts.empty;
  try {
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return VideoProbeFacts.empty;
    final Object? format = decoded['format'];
    final Object? streams = decoded['streams'];
    return VideoProbeFacts(
      durationMs: _durationMsFrom(format),
      fileSizeBytes: _intFrom(_mapOrNull(format)?['size']),
      containerBitrate: _intFrom(_mapOrNull(format)?['bit_rate']),
      video: _videoFrom(streams),
      audioTracks: _audioTracksFrom(streams),
      subtitleTracks: _subtitleTracksFrom(streams),
    );
  } catch (_) {
    return VideoProbeFacts.empty;
  }
}

/// 兼容老调用点/老测试：只取时长。
int? parseFfprobeDurationMs(String stdout) =>
    parseFfprobeFacts(stdout).durationMs;

int? _durationMsFrom(Object? format) {
  final Map<String, dynamic>? map = _mapOrNull(format);
  if (map == null) return null;
  final Object? duration = map['duration'];
  final double? seconds = switch (duration) {
    final num value => value.toDouble(),
    final String value => double.tryParse(value),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return (seconds * 1000).round();
}

VideoStreamFacts? _videoFrom(Object? streams) {
  for (final Map<String, dynamic> stream in _streamsOfType(streams, 'video')) {
    // 内嵌封面图在 ffprobe 眼里也是一条 video 流，codec 是 mjpeg/png、尺寸是海报
    // 尺寸。它若排在真正的视频轨前面，卡片就会把一个 4K 片子标成「600x900 · MJPEG」。
    // **必须跳过**，不能拿第一条 video 流了事。
    //
    // 实测（ffprobe n7.1.5）：`attached_pic` 是 **mp4/mov** 的机制，封面流上为 1、
    // 真视频轨为 0。**mkv 设不上这个 disposition**（Matroska 走 Attachments，封面
    // 根本不作为 stream 出现），所以 mkv 不需要也无法靠这个判据——那边天然没有这个
    // 问题，别因为 mkv 测不出来就以为判据没用。
    final Map<String, dynamic>? disposition = _mapOrNull(stream['disposition']);
    if (_flagFrom(disposition, 'attached_pic')) continue;
    final String? pixelFormat = _stringFrom(stream['pix_fmt']);
    return VideoStreamFacts(
      codec: _stringFrom(stream['codec_name']),
      width: _intFrom(stream['width']),
      height: _intFrom(stream['height']),
      pixelFormat: pixelFormat,
      bitDepth: bitDepthFromPixelFormat(pixelFormat) ??
          _intFrom(stream['bits_per_raw_sample']),
      frameRateMilli: frameRateMilliFromFraction(
        _stringFrom(stream['r_frame_rate']),
      ),
      bitrate: _intFrom(stream['bit_rate']),
      colorPrimaries: _stringFrom(stream['color_primaries']),
      colorTransfer: _stringFrom(stream['color_transfer']),
      colorSpace: _stringFrom(stream['color_space']),
    );
  }
  return null;
}

List<AudioTrackFacts> _audioTracksFrom(Object? streams) {
  final List<AudioTrackFacts> out = <AudioTrackFacts>[];
  for (final Map<String, dynamic> stream in _streamsOfType(streams, 'audio')) {
    final Map<String, dynamic>? disposition = _mapOrNull(stream['disposition']);
    out.add(AudioTrackFacts(
      index: _intFrom(stream['index']) ?? out.length,
      codec: _stringFrom(stream['codec_name']),
      channels: _intFrom(stream['channels']),
      channelLayout: _stringFrom(stream['channel_layout']),
      sampleRate: _intFrom(stream['sample_rate']),
      bitrate: _intFrom(stream['bit_rate']),
      language: _languageFrom(stream),
      title: _tagFrom(stream, 'title'),
      isDefault: _flagFrom(disposition, 'default'),
      isForced: _flagFrom(disposition, 'forced'),
      isCommentary: _flagFrom(disposition, 'comment'),
    ));
  }
  return List<AudioTrackFacts>.unmodifiable(out);
}

List<SubtitleTrackFacts> _subtitleTracksFrom(Object? streams) {
  final List<SubtitleTrackFacts> out = <SubtitleTrackFacts>[];
  for (final Map<String, dynamic> stream
      in _streamsOfType(streams, 'subtitle')) {
    final Map<String, dynamic>? disposition = _mapOrNull(stream['disposition']);
    out.add(SubtitleTrackFacts(
      index: _intFrom(stream['index']) ?? out.length,
      codec: _stringFrom(stream['codec_name']),
      language: _languageFrom(stream),
      title: _tagFrom(stream, 'title'),
      isDefault: _flagFrom(disposition, 'default'),
      isForced: _flagFrom(disposition, 'forced'),
    ));
  }
  return List<SubtitleTrackFacts>.unmodifiable(out);
}

Iterable<Map<String, dynamic>> _streamsOfType(Object? streams, String type) sync* {
  if (streams is! List) return;
  for (final Object? stream in streams) {
    if (stream is! Map<String, dynamic>) continue;
    if (stream['codec_type'] != type) continue;
    yield stream;
  }
}

/// `und` 是 ffmpeg 对「未标注」的显式写法，等同于没有。
String? _languageFrom(Map<String, dynamic> stream) {
  final String? language = _tagFrom(stream, 'language');
  if (language == null) return null;
  return language.toLowerCase() == 'und' ? null : language;
}

String? _tagFrom(Map<String, dynamic> stream, String key) {
  final Map<String, dynamic>? tags = _mapOrNull(stream['tags']);
  if (tags == null) return null;
  return _stringFrom(tags[key]);
}

/// ffprobe 的 disposition 值是 0/1 整数。
bool _flagFrom(Map<String, dynamic>? disposition, String key) =>
    _intFrom(disposition?[key]) == 1;

/// 从 `yuv420p10le` 这样的 pix_fmt 推每分量位深；**推不出返回 null**。
///
/// 规则是「`p` 后紧跟的数字」：`yuv420p10le` → 10、`yuv444p12le` → 12、`p010le` → 10。
/// `yuv420p` 这类以 `p` 结尾、无后缀数字的平面格式 → 8（未标位深的都是 8-bit）。
///
/// 但**不以 `p` 收尾的格式（`rgb48le`、`xyz12le`、`nv20`…）一律返回 null**，好让调用
/// 方回退到 ffprobe 的 `bits_per_raw_sample`。此前这里无条件兜底成 8，等于把那些格式
/// 的真实位深（16 / 12）永久盖成 8，而回退值明明就在同一条 JSON 里。
@visibleForTesting
int? bitDepthFromPixelFormat(String? pixelFormat) {
  final String? value = _stringFrom(pixelFormat)?.toLowerCase();
  if (value == null) return null;
  final RegExpMatch? match = RegExp(r'p(\d+)').firstMatch(value);
  if (match != null) {
    final int? depth = int.tryParse(match.group(1)!);
    if (depth != null && depth > 0) return depth;
  }
  // 平面格式以 `p` 结尾（yuv420p / gbrp / yuvj444p）= 8-bit。
  if (value.endsWith('p')) return 8;
  return null;
}

/// 解析 ffprobe 的分数帧率 `"2997/125"` → 23976（fps×1000）。
///
/// `"0/0"` 是 ffprobe 对「这条流没有帧率」的写法（音轨/字幕轨全是它），返回 null。
@visibleForTesting
int? frameRateMilliFromFraction(String? fraction) {
  final String? value = _stringFrom(fraction);
  if (value == null) return null;
  final List<String> parts = value.split('/');
  if (parts.length != 2) {
    final double? plain = double.tryParse(value);
    if (plain == null || !plain.isFinite || plain <= 0) return null;
    return (plain * 1000).round();
  }
  final double? numerator = double.tryParse(parts[0]);
  final double? denominator = double.tryParse(parts[1]);
  if (numerator == null || denominator == null) return null;
  if (denominator == 0 || numerator <= 0) return null;
  final double fps = numerator / denominator;
  if (!fps.isFinite || fps <= 0) return null;
  return (fps * 1000).round();
}

String? _videoCodecLabel(String? codec) {
  final String? value = _stringFrom(codec)?.toLowerCase();
  if (value == null) return null;
  return switch (value) {
    'h264' || 'avc' || 'avc1' => 'H.264',
    'hevc' || 'h265' => 'HEVC',
    'av1' => 'AV1',
    'vp9' => 'VP9',
    'vp8' => 'VP8',
    'mpeg4' => 'MPEG-4',
    'mpeg2video' => 'MPEG-2',
    'vc1' => 'VC-1',
    _ => value.toUpperCase(),
  };
}

String? _audioCodecLabel(String? codec) {
  final String? value = _stringFrom(codec)?.toLowerCase();
  if (value == null) return null;
  return switch (value) {
    'aac' => 'AAC',
    'ac3' => 'AC-3',
    'eac3' => 'E-AC-3',
    'truehd' => 'TrueHD',
    'dts' => 'DTS',
    'flac' => 'FLAC',
    'opus' => 'Opus',
    'vorbis' => 'Vorbis',
    'mp3' => 'MP3',
    'pcm_s16le' || 'pcm_s24le' || 'pcm_s32le' => 'PCM',
    _ => value.toUpperCase(),
  };
}

String? _subtitleCodecLabel(String? codec) {
  final String? value = _stringFrom(codec)?.toLowerCase();
  if (value == null) return null;
  return switch (value) {
    'subrip' => 'SRT',
    'ass' || 'ssa' => 'ASS',
    'webvtt' => 'WebVTT',
    'mov_text' => 'MP4TT',
    'hdmv_pgs_subtitle' => 'PGS',
    'dvd_subtitle' => 'VobSub',
    'dvb_subtitle' => 'DVB',
    _ => value.toUpperCase(),
  };
}

Map<String, dynamic>? _mapOrNull(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// ffprobe 的数值字段有的给 int、有的给字符串（`"5443344"`），两种都要认。
int? _intFrom(Object? value) => switch (value) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v.trim()),
      _ => null,
    };

/// 空串按「没有」处理——与 ffprobe「未标注就整个省略键」同义。
String? _stringFrom(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

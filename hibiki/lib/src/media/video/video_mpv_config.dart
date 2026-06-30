import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 视频播放的 mpv 配置（全局偏好），成体系覆盖解码/画质/画面几何/色彩均衡/音频/播放，
/// 外加原始 mpv.conf 逃生口。
///
/// 经 media_kit 底层 libmpv 的 `setProperty` 应用——与着色器同一边界
/// （见 [applyShadersToPlayer]）。**仅桌面 libmpv 实测可用**；非 libmpv 后端 / 不可
/// 运行时设置的属性（如 `vo`、`profile`）静默 no-op，[rawConf] 是高级逃生口
/// （写得进就生效，写不进就忽略，不报错不黑屏）。
///
/// **不含**：字幕轨/字幕大小/字幕延迟（已由字幕源菜单 + 字幕外观 + A/V 延迟覆盖）、
/// Anime4k（着色器对话框）、SVP/RIFE 帧插值（需外部工具链，非纯 libmpv 属性）。
@immutable
class VideoMpvConfig {
  static const int _schemaVersion = 2;

  const VideoMpvConfig({
    required this.hwdec,
    required this.highQuality,
    required this.deband,
    required this.dither,
    required this.interpolation,
    required this.deinterlace,
    required this.sigmoidUpscaling,
    required this.correctDownscaling,
    required this.videoRotate,
    required this.videoZoom,
    required this.aspectOverride,
    required this.panscan,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.gamma,
    required this.hue,
    required this.audioDelayMs,
    required this.audioPitchCorrection,
    required this.audioChannels,
    required this.normalizeDownmix,
    required this.loopFile,
    required this.rawConf,
  });

  /// 默认配置启用保守的内置高画质缩放；硬件解码默认交给 mpv 安全自动探测。
  static const VideoMpvConfig defaults = VideoMpvConfig(
    hwdec: 'auto-safe',
    highQuality: true,
    deband: false,
    dither: false,
    interpolation: false,
    deinterlace: false,
    sigmoidUpscaling: true,
    correctDownscaling: false,
    videoRotate: 0,
    videoZoom: 0,
    aspectOverride: '-1',
    panscan: 0,
    brightness: 0,
    contrast: 0,
    saturation: 0,
    gamma: 0,
    hue: 0,
    audioDelayMs: 0,
    audioPitchCorrection: true,
    audioChannels: 'auto-safe',
    normalizeDownmix: false,
    loopFile: false,
    rawConf: '',
  );

  /// 硬件解码：`no` | `auto-safe` | `auto-copy`。
  final String hwdec;

  /// 高画质渲染：on → 高质量 scale 链（ewa_lanczossharp 等）；off → bilinear（mpv 默认）。
  final bool highQuality;

  /// 去色带 deband。
  final bool deband;

  /// 抖动：on → `dither-depth=auto`。
  final bool dither;

  /// 运动插帧（平滑流畅度）：on → interpolation + video-sync=display-resample + tscale。
  final bool interpolation;

  /// 去隔行 deinterlace（隔行片源用）。
  final bool deinterlace;

  /// S 形曲线上采样（减少振铃；mpv 默认 yes）。
  final bool sigmoidUpscaling;

  /// 线性光降采样（更准的缩小；mpv 默认 no）。
  final bool correctDownscaling;

  /// 画面旋转（度）：0/90/180/270。
  final int videoRotate;

  /// 画面缩放（log2，-2..2，0=原始）。
  final double videoZoom;

  /// 画面比例覆盖：`-1`(原始) | `16:9` | `4:3` | `2.35:1` | `1:1`。
  final String aspectOverride;

  /// 平移裁切 panscan（0..1，0=完整画面，1=填满裁切黑边）。
  final double panscan;

  /// 色彩均衡（-100..100，0=默认）。
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;
  final int hue;

  /// 音频延迟（毫秒，正=音频滞后）→ `audio-delay` 秒。与字幕 A/V 延迟（_delayMs，
  /// 调字幕 cue 时序）正交：本项移真实音频轨。
  final int audioDelayMs;

  /// 音频变速保持音高（mpv 默认 yes）。
  final bool audioPitchCorrection;

  /// 声道布局：`auto-safe` | `stereo`（5.1 下混双声道）| `mono`。
  final String audioChannels;

  /// 下混时做响度归一化（mpv 默认 no）。
  final bool normalizeDownmix;

  /// 单文件循环。
  final bool loopFile;

  /// 原始 mpv.conf 文本（每行 `key=value` 或裸 flag）；优先级高于上面结构化项。
  final String rawConf;

  VideoMpvConfig copyWith({
    String? hwdec,
    bool? highQuality,
    bool? deband,
    bool? dither,
    bool? interpolation,
    bool? deinterlace,
    bool? sigmoidUpscaling,
    bool? correctDownscaling,
    int? videoRotate,
    double? videoZoom,
    String? aspectOverride,
    double? panscan,
    int? brightness,
    int? contrast,
    int? saturation,
    int? gamma,
    int? hue,
    int? audioDelayMs,
    bool? audioPitchCorrection,
    String? audioChannels,
    bool? normalizeDownmix,
    bool? loopFile,
    String? rawConf,
  }) =>
      VideoMpvConfig(
        hwdec: hwdec ?? this.hwdec,
        highQuality: highQuality ?? this.highQuality,
        deband: deband ?? this.deband,
        dither: dither ?? this.dither,
        interpolation: interpolation ?? this.interpolation,
        deinterlace: deinterlace ?? this.deinterlace,
        sigmoidUpscaling: sigmoidUpscaling ?? this.sigmoidUpscaling,
        correctDownscaling: correctDownscaling ?? this.correctDownscaling,
        videoRotate: videoRotate ?? this.videoRotate,
        videoZoom: videoZoom ?? this.videoZoom,
        aspectOverride: aspectOverride ?? this.aspectOverride,
        panscan: panscan ?? this.panscan,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        gamma: gamma ?? this.gamma,
        hue: hue ?? this.hue,
        audioDelayMs: audioDelayMs ?? this.audioDelayMs,
        audioPitchCorrection: audioPitchCorrection ?? this.audioPitchCorrection,
        audioChannels: audioChannels ?? this.audioChannels,
        normalizeDownmix: normalizeDownmix ?? this.normalizeDownmix,
        loopFile: loopFile ?? this.loopFile,
        rawConf: rawConf ?? this.rawConf,
      );

  static String encode(VideoMpvConfig c) => jsonEncode(<String, dynamic>{
        '_v': _schemaVersion,
        'hwdec': c.hwdec,
        'highQuality': c.highQuality,
        'deband': c.deband,
        'dither': c.dither,
        'interpolation': c.interpolation,
        'deinterlace': c.deinterlace,
        'sigmoidUpscaling': c.sigmoidUpscaling,
        'correctDownscaling': c.correctDownscaling,
        'videoRotate': c.videoRotate,
        'videoZoom': c.videoZoom,
        'aspectOverride': c.aspectOverride,
        'panscan': c.panscan,
        'brightness': c.brightness,
        'contrast': c.contrast,
        'saturation': c.saturation,
        'gamma': c.gamma,
        'hue': c.hue,
        'audioDelayMs': c.audioDelayMs,
        'audioPitchCorrection': c.audioPitchCorrection,
        'audioChannels': c.audioChannels,
        'normalizeDownmix': c.normalizeDownmix,
        'loopFile': c.loopFile,
        'rawConf': c.rawConf,
      });

  static VideoMpvConfig decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      final int version = d['_v'] is num ? (d['_v'] as num).toInt() : 1;
      int clampInt(Object? v, int fb, int lo, int hi) =>
          (v is num ? v.toInt() : fb).clamp(lo, hi);
      const Set<int> rotates = <int>{0, 90, 180, 270};
      const Set<String> hwdecs = <String>{'no', 'auto-safe', 'auto-copy'};
      const Set<String> channels = <String>{'auto-safe', 'stereo', 'mono'};
      final int rot =
          d['videoRotate'] is num ? (d['videoRotate'] as num).toInt() : 0;
      final String hw =
          d['hwdec'] is String ? d['hwdec'] as String : defaults.hwdec;
      String decodedHwdec = hwdecs.contains(hw) ? hw : defaults.hwdec;
      if (version < _schemaVersion && decodedHwdec == 'no') {
        decodedHwdec = defaults.hwdec;
      }
      final String ch = d['audioChannels'] is String
          ? d['audioChannels'] as String
          : 'auto-safe';
      return VideoMpvConfig(
        hwdec: decodedHwdec,
        highQuality: d['highQuality'] is bool
            ? d['highQuality'] as bool
            : defaults.highQuality,
        deband: d['deband'] == true,
        dither: d['dither'] == true,
        interpolation: d['interpolation'] == true,
        deinterlace: d['deinterlace'] == true,
        sigmoidUpscaling: d['sigmoidUpscaling'] != false, // 默认 true
        correctDownscaling: d['correctDownscaling'] == true,
        videoRotate: rotates.contains(rot) ? rot : 0,
        videoZoom:
            (d['videoZoom'] is num ? (d['videoZoom'] as num).toDouble() : 0.0)
                .clamp(-2.0, 2.0),
        aspectOverride: d['aspectOverride'] is String
            ? d['aspectOverride'] as String
            : '-1',
        panscan: (d['panscan'] is num ? (d['panscan'] as num).toDouble() : 0.0)
            .clamp(0.0, 1.0),
        brightness: clampInt(d['brightness'], 0, -100, 100),
        contrast: clampInt(d['contrast'], 0, -100, 100),
        saturation: clampInt(d['saturation'], 0, -100, 100),
        gamma: clampInt(d['gamma'], 0, -100, 100),
        hue: clampInt(d['hue'], 0, -100, 100),
        audioDelayMs: clampInt(d['audioDelayMs'], 0, -60000, 60000),
        audioPitchCorrection: d['audioPitchCorrection'] != false, // 默认 true
        audioChannels: channels.contains(ch) ? ch : 'auto-safe',
        normalizeDownmix: d['normalizeDownmix'] == true,
        loopFile: d['loopFile'] == true,
        rawConf: d['rawConf'] is String ? d['rawConf'] as String : '',
      );
    } catch (_) {
      return defaults;
    }
  }
}

/// 解析 mpv.conf 风格文本为 `属性名→值` map。纯函数。
///
/// 规则：忽略空行与 `#` 注释行；`key=value` 去首尾空白并剥外层引号；裸 `key`（无 `=`）
/// 当作 `key=yes`（mpv flag 语义）。重复 key 后者覆盖。
Map<String, String> parseMpvConf(String text) {
  final Map<String, String> out = <String, String>{};
  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int eq = line.indexOf('=');
    if (eq < 0) {
      out[line] = 'yes';
      continue;
    }
    final String key = line.substring(0, eq).trim();
    if (key.isEmpty) continue;
    String value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

/// 把 [config] 构建成要 setProperty 的 `属性名→值` map。纯函数。
///
/// **全量 emit**（含中性默认值）：保证设置面板关掉某项时能在运行时复位回 mpv 默认，
/// 而非残留。默认配置下所有值等于 mpv 默认 → 视觉等价于「什么都没设」。raw 最后合并、
/// 同 key 覆盖结构化项。
/// 把 [hwdec] 偏好按平台解析成「实际下发给 libmpv 的 `hwdec` 值」。纯函数。
///
/// **根治 realme 8 / Android 11「视频闪烁 + 无画面」（BUG-470）。** media_kit 在 Android
/// 用的是**纹理渲染**路径——`AndroidVideoController` 强制 `vo=gpu` + `gpu-context=android`
/// + `opengl-es=yes`（见 media_kit_video `android_video_controller/real.dart`），libmpv 把
/// 解码帧画进 GL 纹理交给 Flutter 合成，**不存在**给硬件解码器直渲的 Android Surface /
/// native_window。
///
/// 而 libmpv 的 `auto-safe`（与裸 `auto`）在 Android 上会选 **surface-直渲** 的
/// `mediacodec` 硬解：它需要一个 `native_window` 把帧直接渲染上去。texture 路径没有这个
/// surface → HEVC 等走 `mediacodec` 时报 `hevc_mediacodec: Both surface and native_window
/// are NULL`，解码出不了帧 → 画面闪烁 / 全黑。
///
/// 与 texture/gpu 渲染**匹配**的硬解是 **copy 变体**（`mediacodec-copy`）：硬件解码后把帧
/// **拷回内存**再上传 GL 纹理，不需要任何 surface/native_window。`auto-copy` 即「自动挑一个
/// copy-back 硬解」，正好消除 surface-null。
///
/// 故 Android 上把会落到 surface-直渲的 `auto-safe` / `auto` 一律改写成 `auto-copy`；
/// `no`（软解）与 `auto-copy`（已是 copy）原样透传。这是**对齐 media_kit 的纹理渲染模型**
/// 的根因修复，对**所有** Android 设备一致（都走同一 texture 渲染器），不是给 realme 8
/// 打特例；非 Android（桌面 / iOS）原样透传，零行为变化。
///
/// [isAndroid] 默认取 `Platform.isAndroid`，注入仅为单测。
String resolveAndroidHwdec(String hwdec, {bool? isAndroid}) {
  final bool android = isAndroid ?? Platform.isAndroid;
  if (!android) return hwdec;
  // Android 纹理渲染下，surface-直渲的 auto-safe/auto 会 surface-null，统一改 copy 变体。
  if (hwdec == 'auto-safe' || hwdec == 'auto') return 'auto-copy';
  return hwdec; // no（软解）/ auto-copy（已 copy）/ 其它显式值透传。
}

Map<String, String> buildMpvProperties(VideoMpvConfig config,
    {bool? isAndroid}) {
  final Map<String, String> out = <String, String>{};
  // 解码：Android 纹理渲染下把 surface-直渲的 auto-safe 改写成 copy 变体（BUG-470）。
  out['hwdec'] = resolveAndroidHwdec(config.hwdec, isAndroid: isAndroid);
  // 画质：scale 链（on=高质量 / off=mpv 默认 bilinear，便于运行时复位）
  if (config.highQuality) {
    out['scale'] = 'ewa_lanczossharp';
    out['cscale'] = 'ewa_lanczossharp';
    out['dscale'] = 'mitchell';
    out['scale-antiring'] = '0.7';
    out['cscale-antiring'] = '0.7';
  } else {
    out['scale'] = 'bilinear';
    out['cscale'] = 'bilinear';
    out['dscale'] = 'bilinear';
    out['scale-antiring'] = '0';
    out['cscale-antiring'] = '0';
  }
  out['deband'] = config.deband ? 'yes' : 'no';
  out['dither-depth'] = config.dither ? 'auto' : 'no';
  if (config.interpolation) {
    out['interpolation'] = 'yes';
    out['video-sync'] = 'display-resample';
    out['tscale'] = 'oversample';
  } else {
    out['interpolation'] = 'no';
    out['video-sync'] = 'audio';
  }
  out['deinterlace'] = config.deinterlace ? 'yes' : 'no';
  out['sigmoid-upscaling'] = config.sigmoidUpscaling ? 'yes' : 'no';
  out['correct-downscaling'] = config.correctDownscaling ? 'yes' : 'no';
  // 画面几何
  out['video-rotate'] = config.videoRotate.toString();
  out['video-zoom'] = config.videoZoom.toString();
  out['video-aspect-override'] = config.aspectOverride;
  out['panscan'] = config.panscan.toString();
  // 色彩均衡
  out['brightness'] = config.brightness.toString();
  out['contrast'] = config.contrast.toString();
  out['saturation'] = config.saturation.toString();
  out['gamma'] = config.gamma.toString();
  out['hue'] = config.hue.toString();
  // 音频
  out['audio-delay'] = (config.audioDelayMs / 1000).toString(); // 秒
  out['audio-pitch-correction'] = config.audioPitchCorrection ? 'yes' : 'no';
  out['audio-channels'] = config.audioChannels;
  out['audio-normalize-downmix'] = config.normalizeDownmix ? 'yes' : 'no';
  // 播放
  out['loop-file'] = config.loopFile ? 'inf' : 'no';
  // 原始 mpv.conf：最后合并，同 key 覆盖结构化项
  out.addAll(parseMpvConf(config.rawConf));
  return out;
}

/// 把 [config] 应用到 media_kit [player]（仅 libmpv 后端/桌面生效）。
///
/// best-effort：`player.platform` 非 libmpv（无 setProperty）或某属性不被接受时
/// 单条静默吞掉，不影响其余属性与播放。与 [applyShadersToPlayer] 同范式。
Future<void> applyMpvConfigToPlayer(
    Player player, VideoMpvConfig config) async {
  final dynamic native = player.platform;
  if (native == null) return;
  final Map<String, String> props = buildMpvProperties(config);
  for (final MapEntry<String, String> e in props.entries) {
    try {
      await native.setProperty(e.key, e.value);
    } catch (_) {
      // 非 libmpv / 该属性不支持运行时设置：跳过这条，继续下一条。
    }
  }
}

/// 判断 [uri] 是否为 http(s) 网络流（远端直传）。本地 `file://` / 裸路径返回 false。
///
/// 远端视频经 host 直传，URI 是 [HibikiSyncServer] 签发的 `http://…/stream?token=…`；
/// 本地播放是 `File(path).uri`（`file://…`）。仅网络流才需要网络缓存调优，本地文件
/// 注入这些属性既无收益又可能浪费内存（见 [buildNetworkCacheProperties]）。纯函数。
bool isNetworkStreamUri(String uri) {
  final Uri? parsed = Uri.tryParse(uri);
  if (parsed == null) return false;
  final String scheme = parsed.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// 构建**网络流**专用的 libmpv 缓存/预读属性 map（`属性名→值`）。纯函数。
///
/// 仅用于远端 http(s) 直传（局域网 host → 客户端）；缓解 WiFi 抖动导致的卡顿重缓冲。
/// **不做转码/降码率**——只调 libmpv 的网络缓冲行为，保守取值避免爆内存。
///
/// media_kit 创建 player 时已设 `network-timeout=5` / `cache=yes` /
/// `demuxer-max-bytes=32MiB`（见 media_kit `native/player/real.dart` 的初始化块）。
/// 这些默认值对局域网 WiFi 流偏紧：
///
/// - `network-timeout=30`：默认 5s 太激进——WiFi 短暂抖动超过 5s 就会撕掉 HTTP 连接
///   触发整段重连。放宽到 30s，让瞬时停顿靠缓存撑过去而非断流。
/// - `cache=yes`：显式确认开启流缓存（media_kit 默认已开，远端流再确认一次）。
/// - `demuxer-max-bytes=128MiB`：缓存的**真实约束**。mpv 文档明确「cache 开启时实际
///   预读量受 demuxer-max-bytes 限制」；默认 32MiB 在 ~40Mbps REMUX 下只够约 6s，
///   抖动一下就空。提到 128MiB（~40Mbps 约 25s / 典型 15Mbps 约 68s）给足缓冲。
///   只一段视频会话用一份缓冲，dispose 即释放，128MiB 桌面/现代移动端可接受。
/// - `demuxer-max-back-bytes=64MiB`：向后缓冲（往回 seek 不重新拉流），取前向一半。
/// - `cache-secs=30`：目标预读 30s（受上面字节上限封顶）。mpv 文档：cache 开启时
///   cache-secs 覆盖 demuxer-readahead-secs，故网络流用 cache-secs 控预读时长（而非
///   demuxer-readahead-secs——后者在 cache 开启时「基本被忽略」）。
///
/// 所有属性均为 libmpv 运行时可设属性（经 `mpv_set_property_string`），由
/// [applyNetworkCachePropertiesToPlayer] 在 `player.open` 后逐条 best-effort 注入。
Map<String, String> buildNetworkCacheProperties() {
  return <String, String>{
    'cache': 'yes',
    'cache-secs': '30',
    'demuxer-max-bytes': '${128 * 1024 * 1024}', // 128 MiB
    'demuxer-max-back-bytes': '${64 * 1024 * 1024}', // 64 MiB
    'network-timeout': '30',
  };
}

/// 仅对**网络流** [sourceUri]（http/https）把 [buildNetworkCacheProperties] 注入
/// media_kit [player]（仅 libmpv 后端/桌面生效）。本地文件 [sourceUri] 直接 no-op。
///
/// best-effort：与 [applyMpvConfigToPlayer] 同范式，单条属性失败静默吞掉。
Future<void> applyNetworkCachePropertiesToPlayer(
    Player player, String sourceUri) async {
  if (!isNetworkStreamUri(sourceUri)) return;
  final dynamic native = player.platform;
  if (native == null) return;
  final Map<String, String> props = buildNetworkCacheProperties();
  for (final MapEntry<String, String> e in props.entries) {
    try {
      await native.setProperty(e.key, e.value);
    } catch (_) {
      // 非 libmpv / 该属性不支持运行时设置：跳过这条，继续下一条。
    }
  }
}

/// 构建「彻底关闭 libmpv 内置字幕渲染 + 禁止自动重选字幕轨」的属性 map。纯函数。
///
/// 根治 TODO-080/092 的双层竞态根因（BUG-190）：[VideoPlayerController.load] 只调一次
/// `setSubtitleTrack(SubtitleTrack.no())` 不够——libmpv 字幕轨列表是 `player.open` 后
/// **异步**解析就绪的，而 mpv 默认 `sub-auto=exact` 会在轨就绪后**自动重新选中**内嵌
/// 字幕轨，覆盖掉先前的 `no()`。被重选的轨经 `sub-visibility=yes` 渲染成画面像素字幕，
/// 与 media_kit 的内置 `SubtitleView`（也监听 `player.state.subtitle`）一起叠在 Hibiki
/// 可点 [VideoSubtitleOverlay] 之上 → 字幕透明随机、点字幕穿透落空、横竖屏残留黑底。
///
/// 字幕在 Hibiki 一律走可点 overlay（外挂 sidecar 解析成 cue、内嵌文本轨经
/// `_loadEmbeddedSubtitleIfNeeded` 抽取成 cue），libmpv 不该自己渲染任何字幕：
/// - `sub-auto=no`：禁止 libmpv 自动加载/选择字幕轨——根治「轨就绪后被自动重选」竞态。
/// - `sub-visibility=no`：即便某轨仍被选中（含图形 PGS 轨的画面渲染），也不渲染画面字幕。
///
/// **例外**：图形内封字幕（PGS/DVD 等位图，[selectEmbeddedGraphicTrack]）必须靠 libmpv
/// 画面渲染（无文本可查词，BUG-122 兜底），那条路径会自行把 `sub-visibility` 打开，
/// 故这里的默认抑制不影响它（见 [buildGraphicSubtitleVisibilityProperties]）。
Map<String, String> buildSubtitleSuppressionProperties() {
  return <String, String>{
    'sub-auto': 'no',
    'sub-visibility': 'no',
  };
}

/// 图形内封字幕（PGS 等）走 libmpv 画面渲染时，重新打开画面字幕可见性。纯函数。
///
/// 与 [buildSubtitleSuppressionProperties] 配对：默认全程 `sub-visibility=no`（字幕走
/// 可点 overlay），仅当用户选了**没有文本 cue 的图形轨**（[selectEmbeddedGraphicTrack]）
/// 时才把可见性打开，让 libmpv 把位图字幕画到画面上。`sub-auto` 仍保持 `no`——轨由代码
/// 显式 `setSubtitleTrack` 选定，不交给 mpv 自动选。
Map<String, String> buildGraphicSubtitleVisibilityProperties() {
  return <String, String>{
    'sub-visibility': 'yes',
  };
}

/// 副字幕（TODO-857 视频双字幕 Path A）走 libmpv `secondary-sid` 自渲染。纯函数。
///
/// 与主字幕完全独立：主字幕走可点 overlay（[VideoPlayerController] 的 cue 流，可
/// 查词），副字幕只交给 libmpv 画到画面上（**不进 Dart cue 流，不可查词**）。
/// [libmpvTrackId] 是 libmpv 内部 track id（不是 ffmpeg streamIndex），由
/// [VideoPlayerController.selectSecondarySubtitleTrack] 经 `tracks.subtitle` 去
/// auto/no 取第 N 条的 `.id` 解析得到。`secondary-sub-visibility=yes` 显式打开副字幕
/// 可见性——与主字幕的 `sub-visibility`（BUG-190 抑制为 no）正交，互不影响。
Map<String, String> buildSecondarySubtitleProperties(String libmpvTrackId) {
  return <String, String>{
    'secondary-sid': libmpvTrackId,
    'secondary-sub-visibility': 'yes',
  };
}

/// 关闭副字幕：把 libmpv `secondary-sid` 设回 `no` 并关副字幕可见性。纯函数。
/// 只动 `secondary-*`，绝不碰主字幕 `sid` / `sub-visibility`。
Map<String, String> buildSecondarySubtitleClearProperties() {
  return <String, String>{
    'secondary-sid': 'no',
    'secondary-sub-visibility': 'no',
  };
}

/// 构建图形字幕调轴用的 libmpv `sub-delay` 属性 map（`属性名→值`）。纯函数。
///
/// 文本字幕走可点 overlay（cue 同步），其偏移由 [effectiveSubtitlePositionMs] 在
/// Dart 侧完成，**不**经 libmpv；但图形内封字幕（PGS/DVD 等位图，
/// [VideoPlayerController.selectEmbeddedGraphicTrack]）由 libmpv 画面渲染，Dart 的
/// cue 偏移对它无效——必须把延迟下发到 libmpv 的 `sub-delay`（BUG-301）。
///
/// 单位换算：`_delayMs` 与 mpv `sub-delay` 语义同向（正＝字幕延后），故
/// `sub-delay = delayMs / 1000`（秒），不翻符号。
///
/// **不进 [VideoMpvConfig]/[buildMpvProperties]**：`sub-delay` 是每视频的字幕调轴
/// 状态（per-video），不是 mpv 全局画质/音频偏好；与 `audio-delay`（真实音频轨移位，
/// 属全局配置）正交。与 [buildGraphicSubtitleVisibilityProperties] 同范式，可单测。
Map<String, String> buildSubtitleDelayProperty(int delayMs) {
  return <String, String>{
    'sub-delay': (delayMs / 1000).toString(),
  };
}

/// 把 [props]（字幕抑制/可见性属性）逐条 best-effort 注入 media_kit [player]。
///
/// 与 [applyMpvConfigToPlayer] / [applyNetworkCachePropertiesToPlayer] 同范式：经
/// `player.platform`（NativePlayer）的 `setProperty`，仅 libmpv 后端生效；非 libmpv /
/// 不支持属性单条静默吞掉，不影响播放。
Future<void> applySubtitleMpvPropertiesToPlayer(
    Player player, Map<String, String> props) async {
  final dynamic native = player.platform;
  if (native == null) return;
  for (final MapEntry<String, String> e in props.entries) {
    try {
      await native.setProperty(e.key, e.value);
    } catch (_) {
      // 非 libmpv / 该属性不支持运行时设置：跳过这条，继续下一条。
    }
  }
}

/// 构建防盗链 header 注入用的 libmpv `http-header-fields` 属性 map（TODO-850 阶段①）。
/// 纯函数。
///
/// libmpv 的 `http-header-fields` 是 `Field: value` 列表属性，给网络流请求附加自定义
/// HTTP 头（典型用于带 Referer / User-Agent 的防盗链直链）。media_kit 经
/// `mpv_set_property_string` 逐条设属性，列表项以逗号分隔——故把每个 `key: value`
/// 拼成 `Key: Value` 并用逗号连接。[headers] 为空时返回空 map（调用方据此不下发，
/// 普通流 / 本地文件零影响）。
///
/// **不进 [VideoMpvConfig]/[buildMpvProperties]**：header 是每条流的会话级防盗链
/// 凭据（per-stream，阶段①只在 session 内有效、不落 DB），不是全局画质/音频偏好；
/// 与字幕调轴 `sub-delay`（[buildSubtitleDelayProperty]）同范式独立可测。
Map<String, String> buildHttpHeaderFieldsProperty(Map<String, String> headers) {
  if (headers.isEmpty) return const <String, String>{};
  final List<String> fields = <String>[
    for (final MapEntry<String, String> e in headers.entries)
      if (e.key.trim().isNotEmpty) '${e.key.trim()}: ${e.value.trim()}',
  ];
  if (fields.isEmpty) return const <String, String>{};
  return <String, String>{'http-header-fields': fields.join(',')};
}

/// 仅当 [headers] 非空时，把 [buildHttpHeaderFieldsProperty] 注入 media_kit [player]
/// （仅 libmpv 后端/桌面生效）。空 header 直接 no-op（普通流/本地文件零影响）。
///
/// best-effort：与 [applyMpvConfigToPlayer] / [applyNetworkCachePropertiesToPlayer]
/// 同范式，单条属性失败静默吞掉。
Future<void> applyHttpHeaderFieldsToPlayer(
    Player player, Map<String, String> headers) async {
  final Map<String, String> props = buildHttpHeaderFieldsProperty(headers);
  if (props.isEmpty) return;
  final dynamic native = player.platform;
  if (native == null) return;
  for (final MapEntry<String, String> e in props.entries) {
    try {
      await native.setProperty(e.key, e.value);
    } catch (_) {
      // 非 libmpv / 该属性不支持运行时设置：跳过这条，继续下一条。
    }
  }
}

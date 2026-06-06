import 'dart:convert';

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

  /// 每字段取 mpv 自身默认：默认配置下全量 setProperty 与历史行为视觉等价。
  static const VideoMpvConfig defaults = VideoMpvConfig(
    hwdec: 'no',
    highQuality: false,
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
      int clampInt(Object? v, int fb, int lo, int hi) =>
          (v is num ? v.toInt() : fb).clamp(lo, hi);
      const Set<int> rotates = <int>{0, 90, 180, 270};
      const Set<String> hwdecs = <String>{'no', 'auto-safe', 'auto-copy'};
      const Set<String> channels = <String>{'auto-safe', 'stereo', 'mono'};
      final int rot =
          d['videoRotate'] is num ? (d['videoRotate'] as num).toInt() : 0;
      final String hw = d['hwdec'] is String ? d['hwdec'] as String : 'no';
      final String ch = d['audioChannels'] is String
          ? d['audioChannels'] as String
          : 'auto-safe';
      return VideoMpvConfig(
        hwdec: hwdecs.contains(hw) ? hw : 'no',
        highQuality: d['highQuality'] == true,
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
Map<String, String> buildMpvProperties(VideoMpvConfig config) {
  final Map<String, String> out = <String, String>{};
  // 解码
  out['hwdec'] = config.hwdec;
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

/// 全屏歌词动画（「歌词动画样式」）的共享契约：样式枚举、每帧输入、配色、可调参数与注册项。
///
/// 思路借鉴 folia-major 的 visualizer（`src/components/visualizer/definition.ts`）：一个宿主
/// 画背景 / 字幕 / 退出，样式只管把歌词画成动画；每个样式一个目录
/// （`modes/<样式>/`），在 `lyric_visualizer_registry.dart` 登记。样式只读这里的契约，不
/// 自己再扫歌词、不自己读偏好。
///
/// 纯观赏：全屏动画里不点词查词（用户 2026-11-22 拍板），点一下退出回原布局。
library;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 播放位置读口（只读、无副作用）。框架契约自带这一个最小接口，不从 app 组件层引入时钟类型：
/// 否则契约文件会连带导入整个 app（含注册表与全部样式），任何一个样式编不过，所有样式的单测都零执行。
abstract interface class LyricVisualizerClock {
  /// 当前播放位置（逐帧连续）。
  Duration get position;

  /// 整首时长；未知为 [Duration.zero]。
  Duration get duration;
}

/// 样式清单。[prefValue] 是落库值（冻结）；与 folia 的模式 id 一致，便于对照源码。
enum LyricVisualizerMode {
  /// 流光（folia classic / Luminous）：逐词发光。
  luminous('classic'),

  /// 心象（folia cadenza / Mindscape）。
  mindscape('cadenza'),

  /// 浮名（folia fume）。
  fume('fume'),

  /// 云阶（folia partita）。
  partita('partita'),

  /// 群唱（folia cappella）：聊天气泡式。
  cappella('cappella'),

  /// 回环（folia claddagh）：环形歌词。
  claddagh('claddagh'),

  /// 莫奈（folia monet）。
  monet('monet'),

  /// 镜台（folia diorama）：3D 纵深。
  diorama('diorama'),

  /// 时计（folia pendolo）。
  pendolo('pendolo'),

  /// 商籁（folia sonnet）。
  sonnet('sonnet'),

  /// 凝彩（folia tempera）。
  tempera('tempera'),

  /// 绘光（folia lumiere）。
  lumiere('lumiere'),

  /// 雾笺（folia nebbia）。
  nebbia('nebbia'),

  /// 隐喻（folia metaphor）。
  metaphor('metaphor'),

  /// 花火（folia hanabi）。
  hanabi('hanabi'),

  /// 町景（folia machi）。
  machi('machi'),

  /// 倾诉（folia tilt）。
  tilt('tilt'),

  /// 静止（folia still）：静止低占用，不画共享背景。
  still('still');

  const LyricVisualizerMode(this.prefValue);

  /// 落库值（冻结）。
  final String prefValue;

  /// 出厂默认。
  static const LyricVisualizerMode defaultMode = luminous;

  /// 未知 / 缺省值回落 [defaultMode]。
  static LyricVisualizerMode fromPref(String? value) {
    for (final LyricVisualizerMode m in values) {
      if (m.prefValue == value) return m;
    }
    return defaultMode;
  }
}

/// 样式用的配色（取自封面主题；folia 里是 AI / 封面生成的 Theme）。
@immutable
class LyricVisualizerPalette {
  const LyricVisualizerPalette({
    required this.background,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.text,
    required this.dimText,
    required this.brightness,
  });

  /// 从封面配色推出来。
  factory LyricVisualizerPalette.fromScheme(ColorScheme s) =>
      LyricVisualizerPalette(
        background: s.surface,
        primary: s.primary,
        secondary: s.secondary,
        accent: s.tertiary,
        text: s.onSurface,
        dimText: s.onSurface.withValues(alpha: 0.45),
        brightness: s.brightness,
      );

  final Color background;
  final Color primary;
  final Color secondary;
  final Color accent;

  /// 正在唱 / 已唱的字色。
  final Color text;

  /// 未唱 / 非当前行的字色。
  final Color dimText;
  final Brightness brightness;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerPalette &&
      other.background == background &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.accent == accent &&
      other.text == text &&
      other.dimText == dimText &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(
    background,
    primary,
    secondary,
    accent,
    text,
    dimText,
    brightness,
  );
}

// ---------------------------------------------------------------------------
// 可调参数（folia 每个样式的 tuning.ts）
// ---------------------------------------------------------------------------

/// 一项可调参数的声明。样式在注册项里列出，宿主据此画通用的参数面板并落库；样式用
/// [LyricVisualizerTuning] 读取当前值。[key] 落库（冻结）。
sealed class LyricVisualizerTuningSpec {
  const LyricVisualizerTuningSpec({required this.key, required this.label});

  final String key;

  /// 显示名（i18n getter，面板构建时才取，跟随语言切换）。
  final String Function() label;

  Object get defaultValue;

  /// 把落库值规整成合法值（类型不对 / 越界回落默认）。
  Object normalize(Object? raw);
}

/// 连续数值（滑杆）。
class LyricVisualizerSliderSpec extends LyricVisualizerTuningSpec {
  const LyricVisualizerSliderSpec({
    required super.key,
    required super.label,
    required this.min,
    required this.max,
    required this.initial,
    this.divisions,
    this.format,
  });

  final double min;
  final double max;
  final double initial;
  final int? divisions;

  /// 读数格式（缺省两位小数）。
  final String Function(double value)? format;

  @override
  Object get defaultValue => initial;

  @override
  Object normalize(Object? raw) {
    if (raw is! num || raw.isNaN) return initial;
    return raw.toDouble().clamp(min, max);
  }
}

/// 开关。
class LyricVisualizerToggleSpec extends LyricVisualizerTuningSpec {
  const LyricVisualizerToggleSpec({
    required super.key,
    required super.label,
    required this.initial,
  });

  final bool initial;

  @override
  Object get defaultValue => initial;

  @override
  Object normalize(Object? raw) => raw is bool ? raw : initial;
}

/// 单选（几个值里选一个）。
class LyricVisualizerChoiceSpec extends LyricVisualizerTuningSpec {
  const LyricVisualizerChoiceSpec({
    required super.key,
    required super.label,
    required this.options,
    required this.initial,
  });

  /// 值 → 显示名。
  final List<(String, String Function())> options;
  final String initial;

  @override
  Object get defaultValue => initial;

  @override
  Object normalize(Object? raw) {
    for (final (String v, _) in options) {
      if (v == raw) return v;
    }
    return initial;
  }
}

/// 某个样式当前生效的参数（落库值按声明规整过，缺的取默认）。
@immutable
class LyricVisualizerTuning {
  LyricVisualizerTuning(
    List<LyricVisualizerTuningSpec> specs,
    Map<String, Object?> stored,
  ) : _values = <String, Object>{
        for (final LyricVisualizerTuningSpec s in specs)
          s.key: s.normalize(stored[s.key]),
      };

  /// 全默认。
  LyricVisualizerTuning.defaults(List<LyricVisualizerTuningSpec> specs)
    : this(specs, const <String, Object?>{});

  final Map<String, Object> _values;

  double number(String key, double fallback) {
    final Object? v = _values[key];
    return v is double ? v : fallback;
  }

  bool flag(String key, bool fallback) {
    final Object? v = _values[key];
    return v is bool ? v : fallback;
  }

  String choice(String key, String fallback) {
    final Object? v = _values[key];
    return v is String ? v : fallback;
  }

  Map<String, Object> toMap() => Map<String, Object>.unmodifiable(_values);

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerTuning && mapEquals(other._values, _values);

  @override
  int get hashCode => Object.hashAllUnordered(
    _values.entries.map(
      (MapEntry<String, Object> e) => Object.hash(e.key, e.value),
    ),
  );
}

// ---------------------------------------------------------------------------
// 每帧输入
// ---------------------------------------------------------------------------

/// 宿主交给样式的全部输入（folia 的 `VisualizerSharedProps`）。时间不在这里：样式用
/// [LyricVisualizerFrame]（`lyric_visualizer_frame.dart`）逐帧读 [clock]。
@immutable
class LyricVisualizerContext {
  const LyricVisualizerContext({
    required this.timeline,
    required this.runtime,
    required this.clock,
    required this.offsetMs,
    required this.playing,
    required this.palette,
    required this.tuning,
    required this.seed,
    required this.motion,
    this.fontScale = 1,
    this.coverPath,
    this.title,
    this.artist,
    this.album,
    this.onSeek,
  });

  final LyricTimeline timeline;

  /// 预先算好的行 / 字时间线（按 [timeline] 缓存，样式不要自己再扫）。
  final LyricVisualizerRuntime runtime;

  /// 插值播放时钟（每帧连续）。
  final LyricVisualizerClock clock;

  /// 整首偏移：显示时间 = 播放位置 + [offsetMs]。
  final int offsetMs;
  final bool playing;
  final LyricVisualizerPalette palette;
  final LyricVisualizerTuning tuning;

  /// 本首稳定的随机种子（同一首每次布局一致）。
  final int seed;

  /// false = 减弱动态效果 / 墨水屏：样式只画静态帧（不跑粒子 / 漂移），文字照常换行。
  final bool motion;

  /// 歌词字号倍数。
  final double fontScale;
  final String? coverPath;
  final String? title;
  final String? artist;
  final String? album;

  /// 跳到某个播放位置（毫秒，音频时间）。只有声明 `seeksOnLineTap` 的样式会用。
  final ValueChanged<int>? onSeek;

  /// 当前帧的歌词显示时间（毫秒）。
  int displayTimeMs() => clock.position.inMilliseconds + offsetMs;
}

/// 样式的注册项（folia `VisualizerRegistryEntry`）。
@immutable
class LyricVisualizerEntry {
  const LyricVisualizerEntry({
    required this.mode,
    required this.label,
    required this.icon,
    required this.builder,
    this.description,
    this.tunings = const <LyricVisualizerTuningSpec>[],
    this.sharedBackdrop = true,
    this.sharedSubtitle = true,
  });

  final LyricVisualizerMode mode;
  final String Function() label;

  /// 一句话介绍（选择面板里显示）。
  final String Function()? description;
  final IconData icon;

  /// 画样式本体。宿主已经铺好背景（[sharedBackdrop] 为 true 时）；返回的 widget 填满约束。
  final Widget Function(LyricVisualizerContext context) builder;
  final List<LyricVisualizerTuningSpec> tunings;

  /// true = 宿主在样式下面画歌词页的流体背景；false = 样式自己画全部背景（Still、Diorama…）。
  final bool sharedBackdrop;

  /// true = 宿主在底部画共享的译文 / 下一句字幕；样式自己排译文时填 false。
  final bool sharedSubtitle;
}

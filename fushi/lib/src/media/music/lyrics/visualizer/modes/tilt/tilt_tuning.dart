/// 倾诉（folia `tilt/tuning.ts` + `types.ts` 的 `TiltTuning`）的可调参数：键名、默认值与
/// 范围照 folia，落库键冻结。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 落库键（冻结，与 folia 字段名一致）。
abstract final class TiltTuningKeys {
  static const String splitProbability = 'splitProbability';
  static const String tiltStyleProbability = 'tiltStyleProbability';
  static const String colorScheme = 'colorScheme';
}

/// 配色方案（folia `TiltColorScheme`）：正体行与斜体行各用主色还是强调色。
enum TiltColorScheme {
  /// 双色 1：正体主色、斜体强调色。
  dual('default'),

  /// 双色 2：正体强调色、斜体主色。
  swap('swap'),

  /// 单色 1：全用强调色。
  accentAll('accentAll'),

  /// 单色 2：全用主色。
  primaryAll('primaryAll');

  const TiltColorScheme(this.value);

  /// 落库值（冻结）。
  final String value;

  static TiltColorScheme of(String raw) {
    for (final TiltColorScheme s in values) {
      if (s.value == raw) return s;
    }
    return dual;
  }
}

/// 生效的参数（两个概率已夹在 0–1）。
@immutable
class TiltTuning {
  const TiltTuning({
    this.splitProbability = 0.75,
    this.tiltStyleProbability = 0.35,
    this.colorScheme = TiltColorScheme.dual,
  });

  factory TiltTuning.of(LyricVisualizerTuning tuning) => TiltTuning(
    splitProbability: tuning
        .number(TiltTuningKeys.splitProbability, 0.75)
        .clamp(0.0, 1.0),
    tiltStyleProbability: tuning
        .number(TiltTuningKeys.tiltStyleProbability, 0.35)
        .clamp(0.0, 1.0),
    colorScheme: TiltColorScheme.of(
      tuning.choice(TiltTuningKeys.colorScheme, TiltColorScheme.dual.value),
    ),
  );

  /// 分行概率：越大越容易把一句拆成多行。
  final double splitProbability;

  /// 斜体强调概率：每一行被选成斜体候选的概率。
  final double tiltStyleProbability;
  final TiltColorScheme colorScheme;

  @override
  bool operator ==(Object other) =>
      other is TiltTuning &&
      other.splitProbability == splitProbability &&
      other.tiltStyleProbability == tiltStyleProbability &&
      other.colorScheme == colorScheme;

  @override
  int get hashCode =>
      Object.hash(splitProbability, tiltStyleProbability, colorScheme);
}

/// 正体行 / 斜体行的字色。
@immutable
class TiltColors {
  const TiltColors({required this.normal, required this.tilt});

  final Color normal;
  final Color tilt;
}

/// folia `getColors`。folia 主题色对应：primaryColor（前景字色）→ [LyricVisualizerPalette.text]，
/// accentColor → [LyricVisualizerPalette.primary]。
TiltColors resolveTiltColors(
  TiltColorScheme scheme,
  LyricVisualizerPalette palette,
) {
  final Color primary = palette.text;
  final Color accent = palette.primary;
  return switch (scheme) {
    TiltColorScheme.swap => TiltColors(normal: accent, tilt: primary),
    TiltColorScheme.accentAll => TiltColors(normal: accent, tilt: accent),
    TiltColorScheme.primaryAll => TiltColors(normal: primary, tilt: primary),
    TiltColorScheme.dual => TiltColors(normal: primary, tilt: accent),
  };
}

String _percent(double v) => '${(v * 100).round()}%';

/// 参数声明（面板顺序照 folia `TiltSettingsPanel`：配色、分行概率、斜体强调概率）。
final List<LyricVisualizerTuningSpec> tiltTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerChoiceSpec(
        key: TiltTuningKeys.colorScheme,
        label: () => t.music_visualizer_tilt_color_scheme,
        initial: TiltColorScheme.dual.value,
        options: <(String, String Function())>[
          (
            TiltColorScheme.dual.value,
            () => t.music_visualizer_tilt_color_scheme_default,
          ),
          (
            TiltColorScheme.swap.value,
            () => t.music_visualizer_tilt_color_scheme_swap,
          ),
          (
            TiltColorScheme.accentAll.value,
            () => t.music_visualizer_tilt_color_scheme_accent_all,
          ),
          (
            TiltColorScheme.primaryAll.value,
            () => t.music_visualizer_tilt_color_scheme_primary_all,
          ),
        ],
      ),
      LyricVisualizerSliderSpec(
        key: TiltTuningKeys.splitProbability,
        label: () => t.music_visualizer_tilt_split_probability,
        min: 0,
        max: 1,
        initial: 0.75,
        divisions: 20,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: TiltTuningKeys.tiltStyleProbability,
        label: () => t.music_visualizer_tilt_style_probability,
        min: 0,
        max: 1,
        initial: 0.35,
        divisions: 20,
        format: _percent,
      ),
    ];

/// 雾笺的可调参数（folia `nebbia/types.ts` + `tuning.ts`）：默认值、范围、落库键，以及把
/// [LyricVisualizerTuning] 读成一份完整的 [NebbiaSettings]。
///
/// folia 里多选的几组（出现方式、消失方式、构图、窗外显示）：出现 / 消失照 folia 播放页快捷按钮的
/// 预设做成单选；构图、窗外显示每项一个开关。分辨率 / 抗锯齿（`render`）由宿主统一管，不在这里。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 出现方式：手指书写、慢慢显现、哈气后书写。
enum NebbiaAppear { write, fade, breath }

/// 消失方式：慢慢起雾、两根手指搓掉。
enum NebbiaFade { fog, fingers }

/// 窗外：雨夜街景、水族箱、共用背景（雾变半透明，透出宿主的背景）。
enum NebbiaBehind { night, aquarium, backdrop }

/// 前面玻璃上的水：雨窗、凝露、融雪。
enum NebbiaGlass { rain, dew, snow }

/// 窗外的雨：斜着、竖直、不下。
enum NebbiaRain { slant, straight, off }

/// 一句的构图（nebbia_compositions.dart）。
const List<String> kNebbiaLayouts = <String>[
  'ribbon',
  'lines2',
  'lines3',
  'cross',
  'pillar',
  'header',
  'badge',
  'columns',
  'orbit',
];

/// 窗外可单独关掉的几样。
const List<String> kNebbiaScenery = <String>[
  'spot',
  'buildings',
  'lights',
  'cars',
  'road',
];

/// 水族箱最多几只水母。
const int kNebbiaMaxJellies = 24;

/// 原型里写死的参数（folia `nebbiaConstants.ts` 的 NEBBIA_FIXED）。
abstract final class NebbiaFixed {
  static const double edge = 0.6;
  static const double beads = 0.35;
  static const double drip = 0.25;
  static const double fieldDrops = 0.5;
  static const double endBead = 1;
  static const double endBeadMin = 48;
  static const double beadHold = 4;
  static const double breathSpread = 1.2;
  static const double breathHold = 1;
  static const double breathFade = 8;
  static const double breathThick = 0.7;
  static const double bumpRate = 1;
  static const double bumpFall = 0.5;
}

/// 一个滑杆的声明：落库键、范围、默认、显示名。
class _Num {
  const _Num(this.key, this.min, this.max, this.initial, this.label);
  final String key;
  final double min;
  final double max;
  final double initial;
  final String Function() label;
}

final List<_Num> _numbers = <_Num>[
  _Num('jitter', 0, 1.5, 0.6, () => t.music_visualizer_nebbia_jitter),
  _Num('warp', 0, 1.5, 0.6, () => t.music_visualizer_nebbia_warp),
  _Num('mist', 0.2, 1, 0.75, () => t.music_visualizer_nebbia_mist),
  _Num('hold', 0, 6, 1.2, () => t.music_visualizer_nebbia_hold),
  _Num('refog', 0.5, 12, 4, () => t.music_visualizer_nebbia_refog),
  _Num(
    'strokeWidth',
    0.04,
    0.16,
    0.09,
    () => t.music_visualizer_nebbia_stroke_width,
  ),
  _Num('writeSpeed', 0.4, 2.5, 1, () => t.music_visualizer_nebbia_write_speed),
  _Num('doodle', 0, 1, 0.3, () => t.music_visualizer_nebbia_doodle),
  _Num('busSpeed', 0, 3, 1, () => t.music_visualizer_nebbia_bus_speed),
  _Num('neon', 0, 2, 1, () => t.music_visualizer_nebbia_neon),
  _Num('spot', 0, 2, 0.5, () => t.music_visualizer_nebbia_spot),
  _Num('spotX', 0, 1, 0.8, () => t.music_visualizer_nebbia_spot_x),
  _Num('rainHit', 0, 3, 1, () => t.music_visualizer_nebbia_rain_hit),
  _Num('rainBig', 0, 2, 1, () => t.music_visualizer_nebbia_rain_big),
  _Num('bump', 0, 2.5, 1, () => t.music_visualizer_nebbia_bump),
  _Num(
    'jellies',
    0,
    kNebbiaMaxJellies.toDouble(),
    16,
    () => t.music_visualizer_nebbia_jellies,
  ),
  _Num('jellySize', 0.5, 1.8, 1, () => t.music_visualizer_nebbia_jelly_size),
  _Num('bubbles', 0, 1, 0.6, () => t.music_visualizer_nebbia_bubbles),
  _Num('dew', 0, 1.5, 1, () => t.music_visualizer_nebbia_dew),
  _Num('dewSize', 0.5, 2, 1, () => t.music_visualizer_nebbia_dew_size),
  _Num('dewGlint', 0, 2, 1, () => t.music_visualizer_nebbia_dew_glint),
  _Num('snow', 0, 3, 1, () => t.music_visualizer_nebbia_snow),
  _Num('snowSize', 0.5, 2, 1, () => t.music_visualizer_nebbia_snow_size),
  _Num('snowMelt', 0.25, 3, 1, () => t.music_visualizer_nebbia_snow_melt),
  // folia 智能动感模式「疏雨轻车」的颠簸份额：有鼓击分析时车跟鼓点颠（0 = 照旧随机颠）。
  _Num('drumBump', 0, 2, 1, () => t.music_visualizer_nebbia_drum_bump),
  // folia「舞潮踏拍」：水族箱里水母收缩、水草摆动、聚光放大跟拍（0 = 不跟拍）。
  _Num('aquaBeat', 0, 2, 1, () => t.music_visualizer_nebbia_aqua_beat),
];

String Function() _layoutLabel(String name) => switch (name) {
  'ribbon' => () => t.music_visualizer_nebbia_layout_ribbon,
  'lines2' => () => t.music_visualizer_nebbia_layout_lines2,
  'lines3' => () => t.music_visualizer_nebbia_layout_lines3,
  'cross' => () => t.music_visualizer_nebbia_layout_cross,
  'pillar' => () => t.music_visualizer_nebbia_layout_pillar,
  'header' => () => t.music_visualizer_nebbia_layout_header,
  'badge' => () => t.music_visualizer_nebbia_layout_badge,
  'columns' => () => t.music_visualizer_nebbia_layout_columns,
  _ => () => t.music_visualizer_nebbia_layout_orbit,
};

String Function() _sceneryLabel(String name) => switch (name) {
  'spot' => () => t.music_visualizer_nebbia_scenery_spot,
  'buildings' => () => t.music_visualizer_nebbia_scenery_buildings,
  'lights' => () => t.music_visualizer_nebbia_scenery_lights,
  'cars' => () => t.music_visualizer_nebbia_scenery_cars,
  _ => () => t.music_visualizer_nebbia_scenery_road,
};

/// 注册项里的参数声明（顺序 = 面板顺序：写字 → 窗外 → 玻璃）。
final List<LyricVisualizerTuningSpec> nebbiaTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerChoiceSpec(
        key: 'appear',
        label: () => t.music_visualizer_nebbia_appear,
        initial: 'auto',
        options: <(String, String Function())>[
          ('auto', () => t.music_visualizer_nebbia_appear_auto),
          ('write', () => t.music_visualizer_nebbia_appear_write),
          ('fade', () => t.music_visualizer_nebbia_appear_fade),
          ('breath', () => t.music_visualizer_nebbia_appear_breath),
        ],
      ),
      LyricVisualizerChoiceSpec(
        key: 'fade',
        label: () => t.music_visualizer_nebbia_fade,
        initial: 'fog',
        options: <(String, String Function())>[
          ('fog', () => t.music_visualizer_nebbia_fade_fog),
          ('fingers', () => t.music_visualizer_nebbia_fade_fingers),
          ('mix', () => t.music_visualizer_nebbia_fade_mix),
        ],
      ),
      for (final _Num n in _numbers.sublist(0, 8))
        LyricVisualizerSliderSpec(
          key: n.key,
          label: n.label,
          min: n.min,
          max: n.max,
          initial: n.initial,
        ),
      LyricVisualizerToggleSpec(
        key: 'credits',
        label: () => t.music_visualizer_nebbia_credits,
        initial: true,
      ),
      for (final String l in kNebbiaLayouts)
        LyricVisualizerToggleSpec(
          key: 'layout_$l',
          label: _layoutLabel(l),
          initial: true,
        ),
      LyricVisualizerChoiceSpec(
        key: 'behind',
        label: () => t.music_visualizer_nebbia_behind,
        initial: 'night',
        options: <(String, String Function())>[
          ('night', () => t.music_visualizer_nebbia_behind_night),
          ('aquarium', () => t.music_visualizer_nebbia_behind_aquarium),
          ('backdrop', () => t.music_visualizer_nebbia_behind_backdrop),
        ],
      ),
      for (final String s in kNebbiaScenery)
        LyricVisualizerToggleSpec(
          key: 'scenery_$s',
          label: _sceneryLabel(s),
          initial: true,
        ),
      LyricVisualizerChoiceSpec(
        key: 'rain',
        label: () => t.music_visualizer_nebbia_rain,
        initial: 'slant',
        options: <(String, String Function())>[
          ('slant', () => t.music_visualizer_nebbia_rain_slant),
          ('straight', () => t.music_visualizer_nebbia_rain_straight),
          ('off', () => t.music_visualizer_nebbia_rain_off),
        ],
      ),
      for (final _Num n in _numbers.sublist(8, 18))
        LyricVisualizerSliderSpec(
          key: n.key,
          label: n.label,
          min: n.min,
          max: n.max,
          initial: n.initial,
          divisions: n.key == 'jellies' ? kNebbiaMaxJellies : null,
          format: n.key == 'jellies'
              ? (double v) => v.round().toString()
              : null,
        ),
      LyricVisualizerChoiceSpec(
        key: 'glass',
        label: () => t.music_visualizer_nebbia_glass,
        initial: 'rain',
        options: <(String, String Function())>[
          ('rain', () => t.music_visualizer_nebbia_glass_rain),
          ('dew', () => t.music_visualizer_nebbia_glass_dew),
          ('snow', () => t.music_visualizer_nebbia_glass_snow),
        ],
      ),
      for (final _Num n in _numbers.sublist(18))
        LyricVisualizerSliderSpec(
          key: n.key,
          label: n.label,
          min: n.min,
          max: n.max,
          initial: n.initial,
        ),
    ];

T _enumOf<T extends Enum>(List<T> values, String name, T fallback) {
  for (final T v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// 一份完整、合法的雾笺参数（运行时只读它）。
class NebbiaSettings {
  NebbiaSettings({
    required this.appear,
    required this.fade,
    required this.layouts,
    required this.behind,
    required this.glass,
    required this.scenery,
    required this.rain,
    required this.credits,
    required this.numbers,
  });

  /// 全默认。
  factory NebbiaSettings.defaults() =>
      NebbiaSettings.from(LyricVisualizerTuning.defaults(nebbiaTuningSpecs));

  factory NebbiaSettings.from(LyricVisualizerTuning tuning) {
    final List<NebbiaAppear> appear = switch (tuning.choice('appear', 'auto')) {
      'write' => <NebbiaAppear>[NebbiaAppear.write],
      'fade' => <NebbiaAppear>[NebbiaAppear.fade],
      'breath' => <NebbiaAppear>[NebbiaAppear.fade, NebbiaAppear.breath],
      _ => <NebbiaAppear>[NebbiaAppear.write, NebbiaAppear.fade],
    };
    final List<NebbiaFade> fade = switch (tuning.choice('fade', 'fog')) {
      'fingers' => <NebbiaFade>[NebbiaFade.fingers],
      'mix' => <NebbiaFade>[NebbiaFade.fog, NebbiaFade.fingers],
      _ => <NebbiaFade>[NebbiaFade.fog],
    };
    final List<String> layouts = <String>[
      for (final String l in kNebbiaLayouts)
        if (tuning.flag('layout_$l', true)) l,
    ];
    return NebbiaSettings(
      appear: appear,
      fade: fade,
      // 构图至少一种：全关时按默认全开（folia subsetOf 的兜底）。
      layouts: layouts.isEmpty ? kNebbiaLayouts : layouts,
      behind: _enumOf(
        NebbiaBehind.values,
        tuning.choice('behind', 'night'),
        NebbiaBehind.night,
      ),
      glass: _enumOf(
        NebbiaGlass.values,
        tuning.choice('glass', 'rain'),
        NebbiaGlass.rain,
      ),
      scenery: <String>{
        for (final String s in kNebbiaScenery)
          if (tuning.flag('scenery_$s', true)) s,
      },
      rain: _enumOf(
        NebbiaRain.values,
        tuning.choice('rain', 'slant'),
        NebbiaRain.slant,
      ),
      credits: tuning.flag('credits', true),
      numbers: <String, double>{
        for (final _Num n in _numbers) n.key: tuning.number(n.key, n.initial),
      },
    );
  }

  final List<NebbiaAppear> appear;
  final List<NebbiaFade> fade;
  final List<String> layouts;
  final NebbiaBehind behind;
  final NebbiaGlass glass;
  final Set<String> scenery;
  final NebbiaRain rain;
  final bool credits;
  final Map<String, double> numbers;

  double _n(String key) => numbers[key]!;

  double get jitter => _n('jitter');
  double get warp => _n('warp');
  double get mist => _n('mist');
  double get hold => _n('hold');
  double get refog => _n('refog');
  double get strokeWidth => _n('strokeWidth');
  double get writeSpeed => _n('writeSpeed');
  double get doodle => _n('doodle');
  double get busSpeed => _n('busSpeed');
  double get neon => _n('neon');
  double get spot => _n('spot');
  double get spotX => _n('spotX');
  double get rainHit => _n('rainHit');
  double get rainBig => _n('rainBig');
  double get bump => _n('bump');
  int get jellies => _n('jellies').round();
  double get jellySize => _n('jellySize');
  double get bubbles => _n('bubbles');
  double get dew => _n('dew');
  double get dewSize => _n('dewSize');
  double get dewGlint => _n('dewGlint');
  double get snow => _n('snow');
  double get snowSize => _n('snowSize');
  double get snowMelt => _n('snowMelt');
  double get drumBump => _n('drumBump');
  double get aquaBeat => _n('aquaBeat');

  bool sceneryOn(String part) => scenery.contains(part);

  /// 场景（字的位置、书写节奏）要不要按新参数重排：只看影响排版的那几项。
  String get layoutKey => <Object>[
    appear,
    fade,
    layouts,
    credits,
    jitter,
    warp,
    hold,
    refog,
    writeSpeed,
    doodle,
  ].join('|');
}

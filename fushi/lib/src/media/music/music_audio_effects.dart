/// 音效（音乐方案 §1「EQ / 卷积放到 P5，且开启即退出 bit-perfect」）：图示均衡 + 预设 +
/// 前级、低音 / 高音搁架、声道平衡 / 立体声宽度 / 单声道 / 左右互换、防削波限幅器。
///
/// **做法**：整条链是一个带标签的 lavfi 滤镜挂在 mpv 的 `af` 上（`@fushi-fx:`），全部用
/// 统一 FFmpeg（9.0.1，五端同一份配方、全量滤镜）的基础滤镜，双精度运算：
///  1. `aformat=sample_fmts=dblp`（有声道效果时再加 `channel_layouts=stereo`，多声道源下混
///     成立体声）——之后每一级都在 double 上算，中间不会因整数格式削波；
///  2. `pan`：平衡 / 宽度 / 单声道 / 互换合成**一个** 2×2 矩阵（[musicChannelMatrix]），
///     宽度用中 / 侧分解：`L' = (1+w)/2·L + (1−w)/2·R`，w=0 即单声道、1 原样、2 加宽一倍；
///  3. `volume`：前级 + 自动余量（见下）；
///  4. `bass` / `treble`：RBJ 低 / 高搁架（Q=0.5），转折频率可选；
///  5. 10 段倍频程峰值 `equalizer`（ISO 266 中心 31 Hz … 16 kHz，每段 1 octave），
///     `precision=f64`；
///  6. `alimiter`（限幅器开、且链路可能把满幅推过 0 dBFS 时才挂）。
///
/// **不削波**：线性部分（搁架 + 均衡 + 声道矩阵）的最大提升量由 [musicAudioEffectsPeakGainDb]
/// 按 FFmpeg 同一套 biquad 公式在细频率网格、多个采样率上数值算出（相邻两段同时提升时实际
/// 峰值高于单段设定值，旧版只取单段最大值会低估）。限幅器关：前级只能往下压，`volume` =
/// 前级 − max(0, 前级 + 峰值)，任何正弦都不会过 0 dBFS；限幅器开：前级按设定值，峰值交给
/// `alimiter`（天花板 −0.1 dBFS，`level=0` 不做自动电平）——响度保住、过冲被软压。
///
/// **与 bit-perfect 共存**：总开关关、或开着但每一项都中性时根本不挂滤镜——`af` 为空，样本
/// 原样到达设备（真 libmpv 用例 music_audio_effects_real_test 逐样本比对）。单开限幅器不算
/// 生效：没有任何提升时它无事可做，不为它退出 bit-perfect。**与交叉淡入共存**：交叉淡入用
/// 逐文件 `file-local-options/af`，它会整体替换全局 `af`，所以装交叉淡入滤镜时把音效一起拼进
/// 同一条链（[musicComposeAf]），否则淡入淡出的那几首会悄悄丢掉音效。
///
/// **卷积（FIR / 房间校正）没做**：`afir` 要把脉冲响应文件作为第二路输入接进滤镜图，mpv 的
/// `af=lavfi=[…]` 包装只给单进单出的图，要么改 mpv 的滤镜包装、要么在图里用 `amovie` 读 IR
/// （后者在打开文件之外再开一个解复用器，失败形态不可见）——都不是「插一个滤镜」量级的事，
/// 也拿不出可信的质量验收（需要真实房间 / 耳机的测量数据），按设计「不达质量就不上线开关」处理。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 各段中心频率（Hz，ISO 266 倍频程）。
const List<int> kMusicEqualizerBandsHz = <int>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// 每段增益的范围（dB）。
const double kMusicEqualizerMaxGainDb = 12;

/// 前级范围（dB）。
const double kMusicEffectsMaxPreampDb = 12;

/// 低音 / 高音增益范围（dB）。
const double kMusicToneMaxGainDb = 12;

/// 低音搁架可选转折频率（Hz）；默认 [kMusicBassDefaultHz]（「100 Hz 以下」）。
const List<int> kMusicBassFrequenciesHz = <int>[60, 80, 100, 150, 200, 300];
const int kMusicBassDefaultHz = 100;

/// 高音搁架可选转折频率（Hz）；默认 [kMusicTrebleDefaultHz]（「8 kHz 以上」）。
const List<int> kMusicTrebleFrequenciesHz = <int>[
  3000,
  4000,
  6000,
  8000,
  10000,
  12000,
];
const int kMusicTrebleDefaultHz = 8000;

/// 立体声宽度上限（1 = 原样，0 = 单声道）。
const double kMusicStereoWidthMax = 2;

/// 限幅器天花板（dBFS）。
const double kMusicLimiterCeilingDb = -0.1;

/// 滤镜标签（信号路径面板据此认出本模块的音效链）。
const String kMusicEffectsLabel = 'fushi-fx';

/// 算峰值提升量时覆盖的采样率：biquad 的双线性变换在高频处随采样率翘曲，取常见几档的最大值。
const List<int> _kPeakSampleRates = <int>[44100, 48000, 96000];

/// 内置均衡预设。增益表与 [kMusicEqualizerBandsHz] 一一对应（dB，0.5 dB 档，与滑块同档）。
/// [custom] 没有增益表：手动拖任何一段即落到它。声明顺序即预设 chip 的显示顺序。
enum MusicEqPreset {
  custom(null),
  flat(<double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  pop(<double>[-1, -0.5, 0, 2, 3.5, 3.5, 2, 0.5, -0.5, -1]),
  rock(<double>[4.5, 3.5, 2.5, 1, -1, -1.5, 0, 2, 3, 3.5]),
  classical(<double>[0, 0, 0, 0, 0, 0, -1.5, -2.5, -3, -4]),
  jazz(<double>[3, 2, 1, 2, -1.5, -1.5, 0, 1.5, 2.5, 3]),
  vocal(<double>[-2, -2, -1, 1, 3, 3.5, 3, 1.5, 0, -1]),
  electronic(<double>[4.5, 4, 1, 0, -2, 1.5, 1, 1.5, 3.5, 4.5]),
  bassBoost(<double>[6, 5, 4, 2, 0.5, 0, 0, 0, 0, 0]),
  trebleBoost(<double>[0, 0, 0, 0, 0, 0.5, 2, 4, 5, 6]),
  headphones(<double>[2, 3.5, 2, -1, -1, 0.5, 1.5, 3, 4, 4.5]),
  smallSpeakers(<double>[-5, -3, 2, 3, 2, 0, 0.5, 2, 2, 1]);

  const MusicEqPreset(this.gainsDb);

  /// null = [custom]。
  final List<double>? gainsDb;

  /// 偏好里的值（枚举名）。
  String get wire => name;

  static MusicEqPreset? fromWire(String raw) {
    for (final MusicEqPreset p in values) {
      if (p.name == raw) return p;
    }
    return null;
  }

  /// 增益表与 [gains] 逐段相同（±0.05 dB）。
  bool matches(List<double> gains) {
    final List<double>? own = gainsDb;
    if (own == null || own.length != gains.length) return false;
    for (int i = 0; i < own.length; i++) {
      if ((own[i] - gains[i]).abs() >= 0.05) return false;
    }
    return true;
  }

  /// 存着的预设 + 当前增益 → 该显示哪个预设：存的预设与增益对得上就是它；存的是自定义
  /// 就是自定义（哪怕恰好拖回了某个预设的形状）；没存过（老用户只有增益）按增益认，
  /// 认不出即自定义。
  static MusicEqPreset resolve(String stored, List<double> gains) {
    final MusicEqPreset? s = fromWire(stored);
    if (s == custom) return custom;
    if (s != null && s.matches(gains)) return s;
    for (final MusicEqPreset p in values) {
      if (p.matches(gains)) return p;
    }
    return custom;
  }
}

@immutable
class MusicAudioEffects {
  const MusicAudioEffects({
    this.enabled = false,
    this.gainsDb = const <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.preampDb = 0,
    this.bassDb = 0,
    this.bassHz = kMusicBassDefaultHz,
    this.trebleDb = 0,
    this.trebleHz = kMusicTrebleDefaultHz,
    this.balance = 0,
    this.width = 1,
    this.mono = false,
    this.swapChannels = false,
    this.limiter = false,
  });

  /// 总开关（偏好 `music_eq_enabled`，键名沿用）。
  final bool enabled;

  /// 与 [kMusicEqualizerBandsHz] 一一对应（dB）。
  final List<double> gainsDb;

  /// 前级（dB）。
  final double preampDb;

  /// 低音 / 高音搁架增益（dB）与转折频率（Hz）。
  final double bassDb;
  final int bassHz;
  final double trebleDb;
  final int trebleHz;

  /// 声道平衡：−1 = 只剩左、0 = 居中、1 = 只剩右（只衰减另一侧，不提升）。
  final double balance;

  /// 立体声宽度：0 = 单声道、1 = 原样、[kMusicStereoWidthMax] = 侧声道加倍。
  final double width;

  /// 单声道下混（优先于 [width]）。
  final bool mono;

  /// 左右声道互换。
  final bool swapChannels;

  /// 防削波限幅器。
  final bool limiter;

  static bool _zero(double v) => v.abs() < 0.05;

  /// 每段都是 0 dB。
  bool get isFlat => gainsDb.every(_zero);

  /// 有声道类效果（需要立体声 + `pan` 矩阵）。
  bool get hasChannelEffects =>
      mono ||
      swapChannels ||
      balance.abs() >= 0.005 ||
      (width - 1).abs() >= 0.005;

  /// 每一项都中性（不改样本）。限幅器不算：没有提升时它无事可做。
  bool get isNeutral =>
      isFlat &&
      _zero(preampDb) &&
      _zero(bassDb) &&
      _zero(trebleDb) &&
      !hasChannelEffects;

  /// 真正作用于信号（开着且不中性）。
  bool get isActive => enabled && !isNeutral;

  /// 偏好里的逗号分隔串 → 增益表；坏值 / 段数不对一律回平直（不让一个坏值把整条链打坏）。
  static List<double> parseGains(String raw) {
    final List<String> parts = raw.split(',');
    if (parts.length != kMusicEqualizerBandsHz.length) {
      return List<double>.filled(kMusicEqualizerBandsHz.length, 0);
    }
    final List<double> out = <double>[];
    for (final String p in parts) {
      final double? v = double.tryParse(p.trim());
      if (v == null || v.isNaN) {
        return List<double>.filled(kMusicEqualizerBandsHz.length, 0);
      }
      out.add(v.clamp(-kMusicEqualizerMaxGainDb, kMusicEqualizerMaxGainDb));
    }
    return out;
  }

  static String encodeGains(List<double> gains) =>
      <String>[for (final double g in gains) g.toStringAsFixed(1)].join(',');

  MusicAudioEffects copyWith({
    bool? enabled,
    List<double>? gainsDb,
    double? preampDb,
    double? bassDb,
    int? bassHz,
    double? trebleDb,
    int? trebleHz,
    double? balance,
    double? width,
    bool? mono,
    bool? swapChannels,
    bool? limiter,
  }) => MusicAudioEffects(
    enabled: enabled ?? this.enabled,
    gainsDb: gainsDb ?? this.gainsDb,
    preampDb: preampDb ?? this.preampDb,
    bassDb: bassDb ?? this.bassDb,
    bassHz: bassHz ?? this.bassHz,
    trebleDb: trebleDb ?? this.trebleDb,
    trebleHz: trebleHz ?? this.trebleHz,
    balance: balance ?? this.balance,
    width: width ?? this.width,
    mono: mono ?? this.mono,
    swapChannels: swapChannels ?? this.swapChannels,
    limiter: limiter ?? this.limiter,
  );

  @override
  bool operator ==(Object other) =>
      other is MusicAudioEffects &&
      other.enabled == enabled &&
      listEquals(other.gainsDb, gainsDb) &&
      other.preampDb == preampDb &&
      other.bassDb == bassDb &&
      other.bassHz == bassHz &&
      other.trebleDb == trebleDb &&
      other.trebleHz == trebleHz &&
      other.balance == balance &&
      other.width == width &&
      other.mono == mono &&
      other.swapChannels == swapChannels &&
      other.limiter == limiter;

  @override
  int get hashCode => Object.hash(
    enabled,
    Object.hashAll(gainsDb),
    preampDb,
    bassDb,
    bassHz,
    trebleDb,
    trebleHz,
    balance,
    width,
    mono,
    swapChannels,
    limiter,
  );
}

/// 一节 biquad（归一化前的 RBJ 系数）。
class _Biquad {
  const _Biquad(this.b0, this.b1, this.b2, this.a0, this.a1, this.a2);

  final double b0, b1, b2, a0, a1, a2;

  /// 角频率 [w]（rad/样本）处的幅度（线性）。
  double magnitude(double w) {
    double mag(double c0, double c1, double c2) {
      final double re = c0 + c1 * math.cos(w) + c2 * math.cos(2 * w);
      final double im = -(c1 * math.sin(w) + c2 * math.sin(2 * w));
      return math.sqrt(re * re + im * im);
    }

    return mag(b0, b1, b2) / mag(a0, a1, a2);
  }
}

/// FFmpeg `equalizer`（t=o:w=1）同一套公式。
_Biquad _peaking(double hz, double gainDb, int sampleRate) {
  final double w0 = 2 * math.pi * hz / sampleRate;
  final double a = math.pow(10, gainDb / 40).toDouble();
  final double s = math.sin(w0);
  final double x = math.log(2) / 2 * 1 * w0 / s;
  final double alpha = s * (math.exp(x) - math.exp(-x)) / 2;
  final double c = math.cos(w0);
  return _Biquad(
    1 + alpha * a,
    -2 * c,
    1 - alpha * a,
    1 + alpha / a,
    -2 * c,
    1 - alpha / a,
  );
}

/// FFmpeg `bass` / `treble`（t=q:w=0.5）同一套 RBJ 搁架公式。
_Biquad _shelf(double hz, double gainDb, int sampleRate, {required bool low}) {
  final double w0 = 2 * math.pi * hz / sampleRate;
  final double a = math.pow(10, gainDb / 40).toDouble();
  final double alpha = math.sin(w0) / (2 * 0.5);
  final double c = math.cos(w0);
  final double k = 2 * math.sqrt(a) * alpha;
  if (low) {
    return _Biquad(
      a * ((a + 1) - (a - 1) * c + k),
      2 * a * ((a - 1) - (a + 1) * c),
      a * ((a + 1) - (a - 1) * c - k),
      (a + 1) + (a - 1) * c + k,
      -2 * ((a - 1) + (a + 1) * c),
      (a + 1) + (a - 1) * c - k,
    );
  }
  return _Biquad(
    a * ((a + 1) + (a - 1) * c + k),
    -2 * a * ((a - 1) + (a + 1) * c),
    a * ((a + 1) + (a - 1) * c - k),
    (a + 1) - (a - 1) * c + k,
    2 * ((a - 1) - (a + 1) * c),
    (a + 1) - (a - 1) * c - k,
  );
}

List<_Biquad> _filters(MusicAudioEffects s, int sampleRate) => <_Biquad>[
  if (!MusicAudioEffects._zero(s.bassDb))
    _shelf(s.bassHz.toDouble(), s.bassDb, sampleRate, low: true),
  if (!MusicAudioEffects._zero(s.trebleDb))
    _shelf(s.trebleHz.toDouble(), s.trebleDb, sampleRate, low: false),
  for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
    if (!MusicAudioEffects._zero(s.gainsDb[i]))
      _peaking(kMusicEqualizerBandsHz[i].toDouble(), s.gainsDb[i], sampleRate),
];

double _responseDb(List<_Biquad> filters, double hz, int sampleRate) {
  final double w = 2 * math.pi * hz / sampleRate;
  double lin = 1;
  for (final _Biquad f in filters) {
    lin *= f.magnitude(w);
  }
  return 20 * math.log(lin) / math.ln10;
}

/// 纯函数：搁架 + 均衡在 [hz] 处的幅度响应（dB；不含前级、余量与声道矩阵）。频响曲线用。
double musicAudioEffectsResponseDb(
  MusicAudioEffects s,
  double hz, {
  int sampleRate = 48000,
}) => _responseDb(_filters(s, sampleRate), hz, sampleRate);

/// 纯函数：对数均匀的频率网格（含各段中心），[minHz] … [maxHz]。
List<double> musicAudioEffectsFrequencyGrid({
  double minHz = 20,
  double maxHz = 20000,
  int pointsPerOctave = 24,
}) {
  final Set<double> out = <double>{
    for (final int hz in kMusicEqualizerBandsHz)
      if (hz >= minHz && hz <= maxHz) hz.toDouble(),
  };
  final double octaves = math.log(maxHz / minHz) / math.ln2;
  final int n = (octaves * pointsPerOctave).ceil();
  for (int i = 0; i <= n; i++) {
    out.add(
      math.min(maxHz, minHz * math.pow(2, i / pointsPerOctave).toDouble()),
    );
  }
  return out.toList()..sort();
}

/// 纯函数：声道矩阵 `[[LL, LR], [RL, RR]]`（输出 = 矩阵 · 输入）：宽度 / 单声道 → 互换 →
/// 平衡。
List<List<double>> musicChannelMatrix(MusicAudioEffects s) {
  final double w = s.mono ? 0 : s.width.clamp(0, kMusicStereoWidthMax);
  final double a = (1 + w) / 2;
  final double b = (1 - w) / 2;
  List<List<double>> m = <List<double>>[
    <double>[a, b],
    <double>[b, a],
  ];
  if (s.swapChannels) m = <List<double>>[m[1], m[0]];
  final double bal = s.balance.clamp(-1, 1);
  final double gl = bal > 0 ? 1 - bal : 1;
  final double gr = bal < 0 ? 1 + bal : 1;
  return <List<double>>[
    <double>[m[0][0] * gl, m[0][1] * gl],
    <double>[m[1][0] * gr, m[1][1] * gr],
  ];
}

/// 纯函数：线性部分（声道矩阵 + 搁架 + 均衡）可能的最大提升量（dB，≥ 0 才有削波风险）。
/// 均衡 / 搁架取细网格上、多个采样率下的最大幅度响应；矩阵取行绝对值和（同相满幅信号
/// 的最坏情况）。
double musicAudioEffectsPeakGainDb(MusicAudioEffects s) {
  double tone = 0;
  for (final int sr in _kPeakSampleRates) {
    final List<_Biquad> f = _filters(s, sr);
    if (f.isEmpty) break;
    // 下到 1 Hz：低音搁架的满增益在直流附近才到，次声内容照样会被推高。
    for (final double hz in musicAudioEffectsFrequencyGrid(
      minHz: 1,
      maxHz: sr * 0.49,
      pointsPerOctave: 24,
    )) {
      tone = math.max(tone, _responseDb(f, hz, sr));
    }
  }
  double rows = 0;
  if (s.hasChannelEffects) {
    for (final List<double> r in musicChannelMatrix(s)) {
      rows = math.max(rows, r[0].abs() + r[1].abs());
    }
  } else {
    rows = 1;
  }
  return tone + (rows <= 0 ? 0 : 20 * math.log(rows) / math.ln10);
}

/// 纯函数：限幅器关时自动让出的余量（dB，≥ 0）。
double musicAudioEffectsAutoHeadroomDb(MusicAudioEffects s) {
  if (s.limiter || !s.isActive) return 0;
  return math.max(0, s.preampDb + musicAudioEffectsPeakGainDb(s));
}

String _db(double v) => v.toStringAsFixed(2);

String _coef(double v) => v.toStringAsFixed(6);

String _panRow(String out, List<double> row) {
  final String second = row[1] < 0
      ? '-${_coef(-row[1])}*c1'
      : '+${_coef(row[1])}*c1';
  return '$out=${_coef(row[0])}*c0$second';
}

/// 纯函数：音效设置 → mpv `af` 里的一项（带标签的 lavfi 链）；不作用于信号时为 null
/// （不挂任何滤镜，bit-perfect 不受影响）。
String? musicAudioEffectsAf(MusicAudioEffects s) {
  if (!s.isActive) return null;
  final double peak = musicAudioEffectsPeakGainDb(s);
  final double volumeDb = s.limiter
      ? s.preampDb
      : s.preampDb - math.max(0, s.preampDb + peak);
  final bool channels = s.hasChannelEffects;
  final List<List<double>> m = musicChannelMatrix(s);
  final List<String> chain = <String>[
    channels
        ? 'aformat=sample_fmts=dblp:channel_layouts=stereo'
        : 'aformat=sample_fmts=dblp',
    if (channels) 'pan=stereo|${_panRow('c0', m[0])}|${_panRow('c1', m[1])}',
    if (volumeDb.abs() >= 0.005)
      'volume=volume=${_db(volumeDb)}dB:precision=double',
    if (!MusicAudioEffects._zero(s.bassDb))
      'bass=g=${_db(s.bassDb)}:f=${s.bassHz}:t=q:w=0.5:precision=f64',
    if (!MusicAudioEffects._zero(s.trebleDb))
      'treble=g=${_db(s.trebleDb)}:f=${s.trebleHz}:t=q:w=0.5:precision=f64',
    for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
      if (!MusicAudioEffects._zero(s.gainsDb[i]))
        'equalizer=f=${kMusicEqualizerBandsHz[i]}:t=o:w=1:'
            'g=${_db(s.gainsDb[i])}:precision=f64',
    // 只在链路可能把满幅推过 0 dBFS 时挂（没有提升时它只会白白引入几毫秒前瞻延迟）。
    if (s.limiter && volumeDb + peak > 0.005)
      'alimiter=limit=${_coef(math.pow(10, kMusicLimiterCeilingDb / 20).toDouble())}'
          ':attack=5:release=50:level=0',
  ];
  return '@$kMusicEffectsLabel:lavfi=[${chain.join(',')}]';
}

/// 纯函数：把多段 `af` 项拼成一条（空项跳过）；全空返回空串。
String musicComposeAf(Iterable<String?> parts) => <String>[
  for (final String? p in parts)
    if (p != null && p.trim().isNotEmpty) p,
].join(',');

/// 纯函数：从 mpv `af` 里去掉本模块的音效链（信号路径面板单独标「音效」）。
String musicStripAudioEffectsFilters(String af) {
  final List<String> parts = <String>[];
  int depth = 0;
  final StringBuffer cur = StringBuffer();
  for (final int c in af.codeUnits) {
    final String ch = String.fromCharCode(c);
    if (ch == '[') depth++;
    if (ch == ']') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty) parts.add(cur.toString());
  return parts
      .where(
        (String p) =>
            p.trim().isNotEmpty &&
            !p.trim().startsWith('@$kMusicEffectsLabel:'),
      )
      .join(',');
}

/// 纯函数：`af` 里有没有本模块的音效链。
bool musicAfHasAudioEffects(String af) => af.contains('@$kMusicEffectsLabel:');

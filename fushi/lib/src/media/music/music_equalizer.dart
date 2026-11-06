/// 图示均衡器（音乐方案 §1「EQ / 卷积放到 P5，且开启即退出 bit-perfect」）。
///
/// **做法**：10 段倍频程峰值滤波（ISO 266 中心频率 31 Hz … 16 kHz，每段 1 octave 带宽），
/// 用统一 FFmpeg 的 `equalizer`（RBJ biquad）滤镜、`precision=f64` 双精度运算，前面一级
/// `volume` 自动让出余量（= 最大提升量，任何一段都不会把满幅信号推过 0 dBFS）。整条链作为
/// 一个带标签的 lavfi 滤镜挂在 mpv 的 `af` 上（`@fushi-eq:`），信号路径面板据此单独标
/// 「均衡器」，并判非 bit-perfect。
///
/// **与 bit-perfect 共存**：均衡器关、或开着但每段都是 0 dB 时根本不挂滤镜——`af` 为空，
/// 样本原样到达设备（真 libmpv 用例逐样本比对）。**与交叉淡入共存**：交叉淡入用逐文件
/// `file-local-options/af`，它会整体替换全局 `af`，所以装交叉淡入滤镜时把均衡器一起拼进同一
/// 条链（[musicComposeAf]），否则淡入淡出的那几首会悄悄丢掉均衡。
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

/// 滤镜标签（信号路径面板据此认出本模块的均衡器）。
const String kMusicEqualizerLabel = 'fushi-eq';

@immutable
class MusicEqualizerSettings {
  const MusicEqualizerSettings({
    this.enabled = false,
    this.gainsDb = const <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  });

  final bool enabled;

  /// 与 [kMusicEqualizerBandsHz] 一一对应（dB）。
  final List<double> gainsDb;

  /// 每段都是 0 dB（不改样本）。
  bool get isFlat => gainsDb.every((double g) => g.abs() < 0.05);

  /// 真正作用于信号（开着且不平）。
  bool get isActive => enabled && !isFlat;

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

  @override
  bool operator ==(Object other) =>
      other is MusicEqualizerSettings &&
      other.enabled == enabled &&
      listEquals(other.gainsDb, gainsDb);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(gainsDb));
}

String _db(double v) => v.toStringAsFixed(2);

/// 纯函数：均衡器设置 → mpv `af` 里的一项（带标签的 lavfi 链）；不作用于信号时为 null
/// （不挂任何滤镜，bit-perfect 不受影响）。
String? musicEqualizerAf(MusicEqualizerSettings s) {
  if (!s.isActive) return null;
  final double boost = s.gainsDb.fold<double>(0, math.max);
  final List<String> chain = <String>[
    // 余量：最大提升量。biquad 峰值滤波的增益不会超过它在中心频率上的设定值。
    if (boost > 0) 'volume=volume=${_db(-boost)}dB:precision=double',
    for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
      if (s.gainsDb[i].abs() >= 0.05)
        'equalizer=f=${kMusicEqualizerBandsHz[i]}:t=o:w=1:'
            'g=${_db(s.gainsDb[i])}:precision=f64',
  ];
  return '@$kMusicEqualizerLabel:lavfi=[${chain.join(',')}]';
}

/// 纯函数：把多段 `af` 项拼成一条（空项跳过）；全空返回空串。
String musicComposeAf(Iterable<String?> parts) => <String>[
  for (final String? p in parts)
    if (p != null && p.trim().isNotEmpty) p,
].join(',');

/// 纯函数：从 mpv `af` 里去掉本模块的均衡器（信号路径面板单独标「均衡器」）。
String musicStripEqualizerFilters(String af) {
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
            !p.trim().startsWith('@$kMusicEqualizerLabel:'),
      )
      .join(',');
}

/// 纯函数：`af` 里有没有本模块的均衡器。
bool musicAfHasEqualizer(String af) => af.contains('@$kMusicEqualizerLabel:');

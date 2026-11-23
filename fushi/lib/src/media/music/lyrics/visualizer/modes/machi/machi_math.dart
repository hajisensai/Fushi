/// 町景共用的小工具：三维向量、稳定哈希、插值与颜色运算（纯 Dart，可单测）。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// 三维点 / 方向（米；y 向上，+z 朝前，+x 朝右，与 folia 的 three.js 场景一致）。
class MachiV3 {
  const MachiV3(this.x, this.y, this.z);

  static const MachiV3 zero = MachiV3(0, 0, 0);
  static const MachiV3 up = MachiV3(0, 1, 0);
  static const MachiV3 down = MachiV3(0, -1, 0);

  final double x;
  final double y;
  final double z;

  MachiV3 operator +(MachiV3 o) => MachiV3(x + o.x, y + o.y, z + o.z);
  MachiV3 operator -(MachiV3 o) => MachiV3(x - o.x, y - o.y, z - o.z);
  MachiV3 operator *(double k) => MachiV3(x * k, y * k, z * k);
  MachiV3 operator -() => MachiV3(-x, -y, -z);

  double dot(MachiV3 o) => x * o.x + y * o.y + z * o.z;

  MachiV3 cross(MachiV3 o) =>
      MachiV3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  MachiV3 normalized() {
    final double l = length;
    return l < 1e-9 ? this : this * (1 / l);
  }

  MachiV3 withY(double ny) => MachiV3(x, ny, z);

  @override
  bool operator ==(Object other) =>
      other is MachiV3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'MachiV3($x, $y, $z)';
}

/// 水平面上方位角 [azimuth]（弧度，从 +z 转向 +x）的单位方向。
MachiV3 machiAzimuthDir(double azimuth) =>
    MachiV3(math.sin(azimuth), 0, math.cos(azimuth));

const double machiDeg = math.pi / 180;

double machiClamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double machiLerp(double a, double b, double t) => a + (b - a) * t;

double machiSmoothstep(double e0, double e1, double x) {
  final double t = machiClamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
}

/// 字符串 → 32 位哈希（FNV-1a；folia `hashVisualizerSeed` 的同类）。
int machiHashString(String s) {
  int h = 0x811C9DC5;
  for (final int u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// (key, index, salt) → [0, 1) 的稳定哈希（folia `visualizerHash01`）。
double machiHash01(int key, int index, int salt) {
  int h =
      (key ^
          ((index * 0x9E3779B1) & 0xFFFFFFFF) ^
          ((salt * 0x85EBCA77) & 0xFFFFFFFF)) &
      0xFFFFFFFF;
  h = ((h ^ (h >> 16)) * 0x7FEB352D) & 0xFFFFFFFF;
  h = ((h ^ (h >> 15)) * 0x846CA68B) & 0xFFFFFFFF;
  h = (h ^ (h >> 16)) & 0xFFFFFFFF;
  return h / 4294967296.0;
}

// ---------------------------------------------------------------------------
// 颜色
// ---------------------------------------------------------------------------

Color machiHex(int rgb) => Color(0xFF000000 | rgb);

Color machiMix(Color a, Color b, double t) {
  final double k = machiClamp(t, 0, 1);
  return Color.from(
    alpha: a.a + (b.a - a.a) * k,
    red: a.r + (b.r - a.r) * k,
    green: a.g + (b.g - a.g) * k,
    blue: a.b + (b.b - a.b) * k,
  );
}

/// 按通道乘（[k] 可大于 1，结果夹到 0..1）。
Color machiScale(Color c, double k) => Color.from(
  alpha: c.a,
  red: machiClamp(c.r * k, 0, 1),
  green: machiClamp(c.g * k, 0, 1),
  blue: machiClamp(c.b * k, 0, 1),
);

/// 按光照的 RGB 倍数乘。
Color machiModulate(Color c, double r, double g, double b) => Color.from(
  alpha: c.a,
  red: machiClamp(c.r * r, 0, 1),
  green: machiClamp(c.g * g, 0, 1),
  blue: machiClamp(c.b * b, 0, 1),
);

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double machiLuminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double machiContrast(Color a, Color b) {
  final double la = machiLuminance(a);
  final double lb = machiLuminance(b);
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// HSL（h 0..360，s / l 0..1）。
class MachiHsl {
  const MachiHsl(this.h, this.s, this.l);

  factory MachiHsl.of(Color c) {
    final double r = c.r;
    final double g = c.g;
    final double b = c.b;
    final double mx = math.max(r, math.max(g, b));
    final double mn = math.min(r, math.min(g, b));
    final double l = (mx + mn) / 2;
    if ((mx - mn).abs() < 1e-9) return MachiHsl(0, 0, l);
    final double d = mx - mn;
    final double s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    double h;
    if (mx == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    return MachiHsl(h * 60, s, l);
  }

  final double h;
  final double s;
  final double l;

  MachiHsl copyWith({double? h, double? s, double? l}) =>
      MachiHsl(h ?? this.h, s ?? this.s, l ?? this.l);

  Color toColor() {
    final double hh = ((h % 360) + 360) % 360 / 360;
    if (s <= 0) return Color.from(alpha: 1, red: l, green: l, blue: l);
    final double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final double p = 2 * l - q;
    double hue(double t) {
      double tt = t;
      if (tt < 0) tt += 1;
      if (tt > 1) tt -= 1;
      if (tt < 1 / 6) return p + (q - p) * 6 * tt;
      if (tt < 1 / 2) return q;
      if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
      return p;
    }

    return Color.from(
      alpha: 1,
      red: hue(hh + 1 / 3),
      green: hue(hh),
      blue: hue(hh - 1 / 3),
    );
  }
}

/// 色相差（0..180）。
double machiHueDistance(double a, double b) {
  final double d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

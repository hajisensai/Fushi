/// 吉祥物 logo 跟随主题强调色的纯函数层（无 Flutter 依赖，可进 isolate）。
///
/// logo 原图（`assets/meta/`）的配色就是从 M3 基线紫取的：薰衣草底、长春花色耳尖 /
/// 腮红 / 鳍、深紫墨线，全部落在 HCT 色相 ≈ 250°–320° 一带；另有白身体、桃色嘴巴。
/// 换强调色时只把「logo 自己的那一族色相」整体旋转到当前 primary 的色相，**保留每个
/// 像素的明度（tone）与原有彩度层次**，白 / 灰等中性色与嘴巴的桃色不动——于是明暗
/// 结构、描边与阴影一概不变，只有色调跟着主题走。
///
/// 基线紫下 [LogoAccentTint.isIdentity] 成立，调用方直接用原图（像素级一致）。
library;

import 'dart:typed_data';

import 'package:material_color_utilities/material_color_utilities.dart';

/// logo 原配色对应的强调色：M3 基线紫种子（`ThemeNotifier.themePresets['m3-baseline']`）。
const int kLogoReferenceAccentArgb = 0xFF6750A4;

/// logo 自身配色族的色相中心（HCT 度）：耳尖 278°、底色 288°、阴影 301°、墨线 321°、
/// 鳍高光 249°。
const double kLogoAccentHueCenter = 290;

/// 距 [kLogoAccentHueCenter] 这么近的像素整份跟随色相旋转。
const double kLogoAccentHueFullWidth = 75;

/// 超过这个距离的像素完全不动（嘴巴的桃色在 45° 左右，距中心 115°）；
/// 两者之间线性过渡，避免抗锯齿边出现色相断层。
const double kLogoAccentHueFadeWidth = 105;

/// RGB 三通道极差不超过它的像素视为中性色（白身体、灰阶抗锯齿），原样保留。
///
/// 不用 HCT 彩度判：CAM16 下纯白 / 纯灰也有 2–3 的彩度和一个随机色相，按彩度判会把
/// 白身体一起染色。
const int kLogoNeutralRgbSpread = 3;

/// primary 彩度达到它即认为是「有颜色的强调色」，logo 保留原彩度；
/// 现有彩色预设里最低的是深色红 primary（≈29），都在线上。
const double kLogoFullAccentChroma = 24;

/// primary 彩度不超过它视为无彩度（CAM16 下纯灰约 2–3）：logo 褪成灰阶。
/// 两者之间（中性灰预设 ≈12）线性褪色。
const double kLogoAchromaticAccentChroma = 4;

/// 色相旋转量与彩度缩放：logo 换色的全部参数。
///
/// 两个量都做了量化（色相取整度、彩度缩放取 0.05 步长），作为图片缓存 key 时
/// 同一主题不会因浮点抖动生成多份解码结果。
class LogoAccentTint {
  const LogoAccentTint._(this.hueShift, this.chromaScale);

  /// 恒等变换（基线紫）。
  static const LogoAccentTint identity = LogoAccentTint._(0, 1);

  /// 由当前主题的 primary（ARGB）推出换色参数：色相差相对基线紫，彩度缩放按
  /// primary 彩度相对 [kLogoFullAccentChroma]。
  factory LogoAccentTint.fromAccent(int accentArgb) {
    final Hct accent = Hct.fromInt(accentArgb);
    final double chromaScale = _quantizeScale(
      ((accent.chroma - kLogoAchromaticAccentChroma) /
              (kLogoFullAccentChroma - kLogoAchromaticAccentChroma))
          .clamp(0.0, 1.0),
    );
    // 无彩度强调色的色相没有意义（HCT 给灰色一个随机色相）：只褪色、不转色相。
    final double shift = chromaScale == 0
        ? 0
        : _normalizeShift(accent.hue - _referenceHue).roundToDouble();
    if (shift == 0 && chromaScale == 1) return identity;
    return LogoAccentTint._(shift, chromaScale);
  }

  /// 色相旋转量（度，-180..180）。
  final double hueShift;

  /// 彩度缩放（0..1）。
  final double chromaScale;

  bool get isIdentity => hueShift == 0 && chromaScale == 1;

  static final double _referenceHue = Hct.fromInt(kLogoReferenceAccentArgb).hue;

  static double _normalizeShift(double shift) {
    double s = shift % 360;
    if (s > 180) s -= 360;
    if (s <= -180) s += 360;
    return s;
  }

  static double _quantizeScale(double scale) => (scale * 20).round() / 20;

  @override
  bool operator ==(Object other) =>
      other is LogoAccentTint &&
      other.hueShift == hueShift &&
      other.chromaScale == chromaScale;

  @override
  int get hashCode => Object.hash(hueShift, chromaScale);

  @override
  String toString() =>
      'LogoAccentTint(hueShift: $hueShift, chromaScale: $chromaScale)';
}

/// 像素色相距 logo 配色族中心的权重：1 = 整份跟随，0 = 不动。
double logoAccentHueWeight(double hue) {
  final double d = (hue - kLogoAccentHueCenter).abs() % 360;
  final double distance = d > 180 ? 360 - d : d;
  if (distance <= kLogoAccentHueFullWidth) return 1;
  if (distance >= kLogoAccentHueFadeWidth) return 0;
  return (kLogoAccentHueFadeWidth - distance) /
      (kLogoAccentHueFadeWidth - kLogoAccentHueFullWidth);
}

/// 对单个不透明颜色（ARGB，alpha 原样带回）做 logo 换色。
int tintLogoArgb(int argb, LogoAccentTint tint) {
  if (tint.isIdentity) return argb;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;
  final int spread =
      (r > g ? (r > b ? r : b) : (g > b ? g : b)) -
      (r < g ? (r < b ? r : b) : (g < b ? g : b));
  if (spread <= kLogoNeutralRgbSpread) return argb;
  final Hct hct = Hct.fromInt(argb | 0xFF000000);
  final double weight = logoAccentHueWeight(hct.hue);
  if (weight == 0) return argb;
  final double hue = (hct.hue + tint.hueShift * weight) % 360;
  final double chroma = hct.chroma * (1 - weight + weight * tint.chromaScale);
  final int rgb = Hct.from(hue, chroma, hct.tone).toInt() & 0x00FFFFFF;
  return (argb & 0xFF000000) | rgb;
}

/// 对非预乘 RGBA8888 像素（`ImageByteFormat.rawStraightRgba`）逐像素换色，返回新缓冲；
/// 透明度不变。同色像素只算一次 HCT（logo 只有几千种颜色）。
Uint8List tintLogoRgba(Uint8List rgba, LogoAccentTint tint) {
  final Uint8List out = Uint8List.fromList(rgba);
  if (tint.isIdentity) return out;
  final Map<int, int> memo = <int, int>{};
  for (int i = 0; i + 3 < out.length; i += 4) {
    if (out[i + 3] == 0) continue;
    final int rgb = (out[i] << 16) | (out[i + 1] << 8) | out[i + 2];
    final int mapped = memo.putIfAbsent(
      rgb,
      () => tintLogoArgb(0xFF000000 | rgb, tint) & 0x00FFFFFF,
    );
    if (mapped == rgb) continue;
    out[i] = (mapped >> 16) & 0xFF;
    out[i + 1] = (mapped >> 8) & 0xFF;
    out[i + 2] = mapped & 0xFF;
  }
  return out;
}

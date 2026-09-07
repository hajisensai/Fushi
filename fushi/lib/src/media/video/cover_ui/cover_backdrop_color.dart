/// 「模糊垫底」在封面自带透明区时缺的那一层底色。
///
/// 为什么需要它：垫底手法是「同图放大 + 高斯模糊」，这条路默认图片是**不透明**的
/// 照片 / 海报。galgame 封面链末端却是 exe 内嵌图标（`extractLargestIconPng` 从 PE
/// 资源解出的 PNG）——角色立绘四周整片透明。透明的图模糊之后还是透明，垫底层等于
/// 什么都没画，卡片只剩死灰一片。
///
/// 修法不是给透明图另开一条分支，而是把垫底补全：**先铺一层由图片自身算出的底色**。
/// 图片不透明时这层被模糊图完全盖住（零观感变化），透明时它就是背景——色相取自
/// 立绘本身，因此天然与前景协调。
///
/// 采样时机挂在宽高比探测的同一个 [ui.Image] 上（`CoverAspectProbe`），不额外解码。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 参与主色统计的最低 alpha：低于此值算「背景空白」，不计入色相，也不计入
/// [CoverBackdropSeed.opaqueRatio]。取 32/255≈12.5%，抗 PNG 边缘羽化。
const int kBackdropSampleMinAlpha = 32;

/// 采样点数量目标。按总像素开方定步长，图再大也只取这么多点——主色是统计量，
/// 多采不会更准，只会更慢。
const int kBackdropSampleTargetPoints = 2048;

/// 「几乎不透明」阈值：不透明像素占比高于此值就不需要底色了（模糊垫底本来就能
/// 铺满），返回 null 省掉一层 widget。
const double kBackdropOpaqueSkipRatio = 0.995;

/// 一次主色采样的结果。
class CoverBackdropSeed {
  const CoverBackdropSeed({required this.color, required this.opaqueRatio});

  /// 非透明像素按 alpha 加权的平均色（未经明暗调制，见 [harmonizeBackdrop]）。
  final Color color;

  /// 非透明像素占采样点的比例，1.0 = 整图不透明。
  final double opaqueRatio;
}

/// 从已解码的 [image] 取主色种子；整图几乎不透明（或全透明 / 读像素失败）时返回
/// null，表示「不需要底色」。
///
/// 调用方负责 [image] 的生命周期——本函数只读，不 dispose。
Future<CoverBackdropSeed?> sampleCoverBackdropSeed(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final Uint8List bytes = data.buffer.asUint8List();
  final int pixelCount = image.width * image.height;
  if (pixelCount <= 0) return null;
  // 按总像素开方定步长：面积越大跳得越远，采样点数恒在目标量级。
  final int step = _sampleStep(pixelCount);

  int sampled = 0;
  int opaque = 0;
  // alpha 加权累加：半透明的羽化边缘不该和实心区域等权拉偏主色。
  double weight = 0;
  double r = 0;
  double g = 0;
  double b = 0;
  for (int i = 0; i < pixelCount; i += step) {
    final int o = i * 4;
    if (o + 3 >= bytes.length) break;
    sampled++;
    final int a = bytes[o + 3];
    if (a < kBackdropSampleMinAlpha) continue;
    opaque++;
    final double w = a / 255.0;
    weight += w;
    r += bytes[o] * w;
    g += bytes[o + 1] * w;
    b += bytes[o + 2] * w;
  }
  if (sampled == 0 || weight <= 0) return null;
  final double opaqueRatio = opaque / sampled;
  if (opaqueRatio >= kBackdropOpaqueSkipRatio) return null;
  return CoverBackdropSeed(
    color: Color.fromARGB(
      0xFF,
      (r / weight).round().clamp(0, 255),
      (g / weight).round().clamp(0, 255),
      (b / weight).round().clamp(0, 255),
    ),
    opaqueRatio: opaqueRatio,
  );
}

int _sampleStep(int pixelCount) {
  if (pixelCount <= kBackdropSampleTargetPoints) return 1;
  final int step = (pixelCount / kBackdropSampleTargetPoints).floor();
  return step < 1 ? 1 : step;
}

/// 主色种子 → 真正铺上去的背景色。
///
/// 立绘主色常常很艳（发色 / 服装的高饱和粉紫），原样铺满整张卡会喧宾夺主，还会
/// 在一排卡片里互相打架。所以只留**色相**，饱和度收进上限、亮度按主题钉死：
/// 卡片背景该是安静的有色底，不是色块。
Color harmonizeBackdrop(Color seed, Brightness brightness) {
  final HSLColor hsl = HSLColor.fromColor(seed);
  return hsl
      .withSaturation(hsl.saturation.clamp(0.0, kBackdropMaxSaturation))
      .withLightness(brightness == Brightness.dark
          ? kBackdropDarkLightness
          : kBackdropLightLightness)
      .toColor();
}

/// 饱和度上限（只留色相倾向，不铺色块）。
const double kBackdropMaxSaturation = 0.42;

/// 暗色主题下的背景亮度。
const double kBackdropDarkLightness = 0.22;

/// 亮色主题下的背景亮度。
const double kBackdropLightLightness = 0.87;

/// 背景渐变的上下亮度偏移：纯平色显得像色块，给一点点纵向明暗就有了体积感。
const double kBackdropGradientLightnessDelta = 0.06;

/// 把背景色摊成纵向渐变（上略亮、下略暗）。
Gradient coverBackdropGradient(Color base) {
  final HSLColor hsl = HSLColor.fromColor(base);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      hsl
          .withLightness((hsl.lightness + kBackdropGradientLightnessDelta)
              .clamp(0.0, 1.0))
          .toColor(),
      hsl
          .withLightness((hsl.lightness - kBackdropGradientLightnessDelta)
              .clamp(0.0, 1.0))
          .toColor(),
    ],
  );
}

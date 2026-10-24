// 歌词页外壳的背景（与有声书无关，从 `media/audiobook/lyrics_player/` 原样抽出）。
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// 饱和度 × 不透明度合成一个颜色矩阵（Rec.709 亮度权重，与 Core Image 同口径）。
/// 把 opacity 折进 alpha 行，省掉一层 Opacity 的 saveLayer。
List<double> _saturationMatrix(double saturation, double opacity) {
  const double lr = 0.2126;
  const double lg = 0.7152;
  const double lb = 0.0722;
  final double inv = 1 - saturation;
  return <double>[
    lr * inv + saturation, lg * inv, lb * inv, 0, 0, //
    lr * inv, lg * inv + saturation, lb * inv, 0, 0, //
    lr * inv, lg * inv, lb * inv + saturation, 0, 0, //
    0, 0, 0, opacity, 0, //
  ];
}

/// Apple Music 式模糊封面底（Niratan `lyricsBackground`）：黑底 + 两层强模糊
/// 高饱和封面 + 自上而下压暗渐变。
class LyricsShellAppleBackground extends StatelessWidget {
  const LyricsShellAppleBackground({
    super.key,
    required this.cover,
    required this.accent,
  });

  final ImageProvider? cover;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? source = cover;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double w = constraints.maxWidth;
          final double h = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              const ColoredBox(color: Colors.black),
              if (source != null) ...<Widget>[
                // 封面糊到看不出细节，解码成 160px 宽足够，省内存也省模糊开销。
                Positioned(
                  left: -w * 0.125,
                  top: -h * 0.125,
                  width: w * 1.25,
                  height: h * 1.25,
                  // 第一层铺满且溢出视口：clamp 让模糊边缘延伸原色，不会在视口
                  // 边缘晕出一圈黑（窄屏溢出量只有 ~24px，decal 会露底）。
                  child: _BlurredCover(
                    image: source,
                    sigma: 36,
                    saturation: 1.6,
                    opacity: 0.6,
                    tileMode: TileMode.clamp,
                  ),
                ),
                Positioned(
                  left: w * 0.05 + w * 0.24,
                  top: h * 0.05 + h * 0.2,
                  width: w * 0.9,
                  height: h * 0.9,
                  // 第二层是偏移的旋转色斑：decal 让它的边缘自然淡出，无硬边。
                  child: Transform.rotate(
                    angle: math.pi,
                    child: _BlurredCover(
                      image: source,
                      sigma: 48,
                      saturation: 1.5,
                      opacity: 0.38,
                      tileMode: TileMode.decal,
                    ),
                  ),
                ),
              ] else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Color.lerp(const Color(0xFF1C1C1E), accent, 0.38)!,
                        const Color(0xFF111114),
                        Colors.black,
                      ],
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.black.withValues(alpha: 0.2),
                      Colors.black.withValues(alpha: 0.46),
                      Colors.black.withValues(alpha: 0.74),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BlurredCover extends StatelessWidget {
  const _BlurredCover({
    required this.image,
    required this.sigma,
    required this.saturation,
    required this.opacity,
    required this.tileMode,
  });

  final ImageProvider image;
  final double sigma;
  final double saturation;
  final double opacity;
  final TileMode tileMode;

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_saturationMatrix(saturation, opacity)),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: tileMode,
        ),
        child: Image(
          image: ResizeImage.resizeIfNeeded(160, null, image),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (BuildContext context, Object error, StackTrace? st) =>
              const SizedBox.shrink(),
        ),
      ),
    );
  }
}

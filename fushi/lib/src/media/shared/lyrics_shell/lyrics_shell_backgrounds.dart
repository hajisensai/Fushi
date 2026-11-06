// 歌词页外壳的背景（与有声书无关，从 `media/audiobook/lyrics_player/` 抽出）。
import 'dart:math' as math;
import 'dart:ui' as ui;
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
///
/// 两层模糊（sigma 36 / 48，整屏）**只在输入变化时离屏算一次**，之后作为静态图
/// 合成：Impeller 没有栅格缓存，若用 `ImageFiltered` 层，覆盖层每出一帧（进度条、
/// 换句动画、按钮动效）这两层都会整屏重新模糊。快照的输入 = 封面帧 × 画布尺寸 ×
/// DPR；配色只影响无封面时的渐变与压暗层，那两层是廉价的普通绘制、照常走 widget。
class LyricsShellAppleBackground extends StatefulWidget {
  const LyricsShellAppleBackground({
    super.key,
    required this.cover,
    required this.accent,
  });

  final ImageProvider? cover;
  final Color accent;

  /// 测试钩子：背景每离屏渲染一张模糊快照就回调一次（参数是本次产出的图，
  /// 归背景 State 所有，测试只读不释放）。
  @visibleForTesting
  static ValueChanged<ui.Image>? debugOnBlurredBackgroundRendered;

  @override
  State<LyricsShellAppleBackground> createState() =>
      _LyricsShellAppleBackgroundState();
}

/// 模糊快照的缓存键：封面帧序号 × 画布逻辑尺寸 × DPR。
typedef _BlurKey = ({int coverRevision, Size size, double devicePixelRatio});

class _LyricsShellAppleBackgroundState
    extends State<LyricsShellAppleBackground> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onCoverFrame,
    onError: _onCoverError,
  );

  /// 当前封面帧（本 State 持有的克隆，换帧 / 卸载时释放）。封面换了但新图还没
  /// 解码完时保留旧帧（等价于原 `Image(gaplessPlayback: true)`）。
  ImageInfo? _coverFrame;
  int _coverRevision = 0;

  /// 离屏模糊快照（本 State 持有，键变化 / 卸载时释放）。
  ui.Image? _blurred;
  _BlurKey? _blurredKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveCover();
  }

  @override
  void didUpdateWidget(LyricsShellAppleBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cover != oldWidget.cover) _resolveCover();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _stream = null;
    _coverFrame?.dispose();
    _coverFrame = null;
    _disposeBlurred();
    super.dispose();
  }

  void _resolveCover() {
    final ImageProvider? cover = widget.cover;
    if (cover == null) {
      _stream?.removeListener(_listener);
      _stream = null;
      _coverFrame?.dispose();
      _coverFrame = null;
      _disposeBlurred();
      return;
    }
    // 封面糊到看不出细节，解码成 160px 宽足够，省内存也省模糊开销。
    final ImageStream stream = ResizeImage.resizeIfNeeded(
      160,
      null,
      cover,
    ).resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _stream?.removeListener(_listener);
    _stream = stream;
    stream.addListener(_listener);
  }

  void _onCoverFrame(ImageInfo info, bool synchronousCall) {
    if (_coverFrame?.isCloneOf(info) ?? false) {
      info.dispose();
      return;
    }
    setState(() {
      _coverFrame?.dispose();
      _coverFrame = info;
      _coverRevision++;
    });
  }

  void _onCoverError(Object error, StackTrace? stackTrace) {
    // 与原 `Image(errorBuilder: SizedBox.shrink)` 一致：解码失败 = 只剩黑底。
    setState(() {
      _coverFrame?.dispose();
      _coverFrame = null;
      _coverRevision++;
      _disposeBlurred();
    });
  }

  void _disposeBlurred() {
    _blurred?.dispose();
    _blurred = null;
    _blurredKey = null;
  }

  /// 取（必要时重算）当前输入对应的模糊快照；输入不变时直接复用。
  ui.Image? _blurredFor(ImageInfo frame, Size size, double devicePixelRatio) {
    if (size.isEmpty || !size.isFinite || devicePixelRatio <= 0) return null;
    final _BlurKey key = (
      coverRevision: _coverRevision,
      size: size,
      devicePixelRatio: devicePixelRatio,
    );
    if (_blurred != null && _blurredKey == key) return _blurred;
    final ui.Image next = _renderBlurredCover(frame, size, devicePixelRatio);
    _disposeBlurred();
    _blurred = next;
    _blurredKey = key;
    LyricsShellAppleBackground.debugOnBlurredBackgroundRendered?.call(next);
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final ImageInfo? frame = widget.cover == null ? null : _coverFrame;
          final ui.Image? blurred = frame == null
              ? null
              : _blurredFor(frame, size, devicePixelRatio);
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              const ColoredBox(color: Colors.black),
              if (widget.cover != null) ...<Widget>[
                if (blurred != null)
                  RawImage(
                    key: const ValueKey<String>('lyrics_apple_blurred_cover'),
                    image: blurred,
                    width: size.width,
                    height: size.height,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.low,
                  ),
              ] else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Color.lerp(
                          const Color(0xFF1C1C1E),
                          widget.accent,
                          0.38,
                        )!,
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

/// 把黑底 + 两层模糊封面一次性画进一张物理像素尺寸的离屏图。
///
/// 几何、滤镜顺序与原先的 widget 树逐层对应：`ColorFiltered(ImageFiltered(
/// Image(fit: cover)))`；画布先按 DPR 缩放，模糊 sigma 与原 `ImageFiltered`
/// 一样在逻辑坐标里生效。
ui.Image _renderBlurredCover(
  ImageInfo frame,
  Size size,
  double devicePixelRatio,
) {
  final double w = size.width;
  final double h = size.height;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder)..scale(devicePixelRatio);
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
  // 第一层铺满且溢出视口：clamp 让模糊边缘延伸原色，不会在视口边缘晕出一圈黑
  // （窄屏溢出量只有 ~24px，decal 会露底）。
  _paintBlurredCoverLayer(
    canvas,
    frame,
    rect: Rect.fromLTWH(-w * 0.125, -h * 0.125, w * 1.25, h * 1.25),
    rotated: false,
    sigma: 36,
    saturation: 1.6,
    opacity: 0.6,
    tileMode: TileMode.clamp,
  );
  // 第二层是偏移的旋转色斑：decal 让它的边缘自然淡出，无硬边。
  _paintBlurredCoverLayer(
    canvas,
    frame,
    rect: Rect.fromLTWH(
      w * 0.05 + w * 0.24,
      h * 0.05 + h * 0.2,
      w * 0.9,
      h * 0.9,
    ),
    rotated: true,
    sigma: 48,
    saturation: 1.5,
    opacity: 0.38,
    tileMode: TileMode.decal,
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return picture.toImageSync(
      math.max(1, (w * devicePixelRatio).round()),
      math.max(1, (h * devicePixelRatio).round()),
    );
  } finally {
    picture.dispose();
  }
}

void _paintBlurredCoverLayer(
  Canvas canvas,
  ImageInfo frame, {
  required Rect rect,
  required bool rotated,
  required double sigma,
  required double saturation,
  required double opacity,
  required TileMode tileMode,
}) {
  canvas.save();
  if (rotated) {
    // 原 `Transform.rotate(angle: pi)`：绕盒子中心转半圈。
    final Offset c = rect.center;
    canvas
      ..translate(c.dx, c.dy)
      ..rotate(math.pi)
      ..translate(-c.dx, -c.dy);
  }
  canvas.saveLayer(
    null,
    Paint()
      ..colorFilter = ColorFilter.matrix(
        _saturationMatrix(saturation, opacity),
      ),
  );
  // 模糊层的输入边界 = 子节点（铺满盒子的封面）的绘制边界，与 ImageFilterLayer
  // 一致：clamp / decal 都以盒子边缘为界。
  canvas.saveLayer(
    rect,
    Paint()
      ..imageFilter = ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: tileMode,
      ),
  );
  paintImage(
    canvas: canvas,
    rect: rect,
    image: frame.image,
    scale: frame.scale,
    debugImageLabel: frame.debugLabel,
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
  );
  canvas
    ..restore()
    ..restore()
    ..restore();
}

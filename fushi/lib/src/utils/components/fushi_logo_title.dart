import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

// =============================================================================
// 作品艺术字（刮削 logo）的尺寸规则——全站一份（2026-11-20 用户：「艺术字的宽度
// 不要全部都全占满，真的很丑。要稍微适应一下」）。
//
// 此前 logo 只限高度：横长的 logo（3:1 以上）会把文字列撑满、顶到卡片边，方形 /
// 竖长的反而显得很小。改成按「视觉面积」统一：目标面积随档位上限走
// （A = [kFushiLogoAreaFactor] × 上限²），宽 = √(A × 宽高比)，再夹在文字列的
// [kFushiLogoMinWidthFraction]…[kFushiLogoMaxWidthFraction] 之间，最后高度不超过
// 档位上限（超了按上限等比缩回）。色块（[FushiCoverBlock]）、继续观看剧照主卡
// 等所有画 logo 的地方都走 [FushiLogoTitle]，不各写一份。
// =============================================================================

/// 目标面积系数：A = 系数 × 档位高度上限²。取值使 2.5:1 的 logo 在拼贴首块
/// 文字列里约占 54%（设计稿 #2 的示意）。
const double kFushiLogoAreaFactor = 1.8;

/// logo 宽度下限（占文字列宽的比例）：方形 logo 不至于缩成一个小角标。
const double kFushiLogoMinWidthFraction = 0.38;

/// logo 宽度上限（占文字列宽的比例）：横长 logo 不撑满整行。
const double kFushiLogoMaxWidthFraction = 0.62;

/// 按「视觉面积」规则算 logo 的显示尺寸。[aspect] = 宽 / 高；[columnWidth] =
/// logo 所在文字列宽（无界时不做宽度夹取）；[maxHeight] = 档位高度上限（已与
/// 可用高度取小）。返回的尺寸恒满足：宽 ≤ 列宽 × 62%、高 ≤ [maxHeight]，且保持
/// [aspect]。
Size fushiLogoBoxSize({
  required double aspect,
  required double columnWidth,
  required double maxHeight,
}) {
  if (!(aspect > 0) || !(maxHeight > 0)) return Size.zero;
  final double area = kFushiLogoAreaFactor * maxHeight * maxHeight;
  double width = math.sqrt(area * aspect);
  if (columnWidth.isFinite && columnWidth > 0) {
    width = width.clamp(
      columnWidth * kFushiLogoMinWidthFraction,
      columnWidth * kFushiLogoMaxWidthFraction,
    );
  }
  double height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }
  return Size(width, height);
}

/// 标题位的 logo：先读出图的宽高比，按 [fushiLogoBoxSize] 定尺寸，起始侧底部
/// 对齐。解码前按 [maxHeight] 高占位（不让布局在图到达时跳动太多），解码失败
/// 画 [fallback]（标题文字）。语义标签是 [title]。
class FushiLogoTitle extends StatefulWidget {
  const FushiLogoTitle({
    required this.logo,
    required this.title,
    required this.maxHeight,
    required this.fallback,
    super.key,
  });

  final ImageProvider logo;
  final String title;

  /// 档位高度上限（实际还会与可用高度取小）。
  final double maxHeight;

  /// 解码失败时的替身（通常是标题文字）。
  final Widget fallback;

  @override
  State<FushiLogoTitle> createState() => _FushiLogoTitleState();
}

class _FushiLogoTitleState extends State<FushiLogoTitle> {
  late final FushiImageAspectProbe _probe = FushiImageAspectProbe(_onChanged);

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _probe.track(widget.logo, createLocalImageConfiguration(context));
  }

  @override
  void didUpdateWidget(FushiLogoTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _probe.track(widget.logo, createLocalImageConfiguration(context));
  }

  @override
  void dispose() {
    _probe.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_probe.failed) return ExcludeSemantics(child: widget.fallback);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxHeight = constraints.maxHeight.isFinite
            ? math.min(widget.maxHeight, constraints.maxHeight)
            : widget.maxHeight;
        final double columnWidth = constraints.maxWidth;
        final double? aspect = _probe.aspect;
        final Size box = aspect == null
            ? Size(
                columnWidth.isFinite
                    ? columnWidth * kFushiLogoMinWidthFraction
                    : maxHeight,
                maxHeight,
              )
            : fushiLogoBoxSize(
                aspect: aspect,
                columnWidth: columnWidth,
                maxHeight: maxHeight,
              );
        return Semantics(
          label: widget.title,
          image: true,
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            widthFactor: 1,
            heightFactor: 1,
            child: SizedBox.fromSize(
              size: box,
              child: aspect == null
                  ? null
                  : Image(
                      image: widget.logo,
                      fit: BoxFit.contain,
                      alignment: AlignmentDirectional.bottomStart,
                      excludeFromSemantics: true,
                      gaplessPlayback: true,
                      errorBuilder:
                          (BuildContext _, Object __, StackTrace? ___) =>
                              const SizedBox.shrink(),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// 一张图的固有宽高比探针（解出前 / 取不到图源 / 解码失败 = null；解码失败
/// 另记 [failed]）。
///
/// 缓存命中时监听器在 `addListener` 里同步回调：此刻正处在
/// `didChangeDependencies` / `didUpdateWidget`（随后必 build），直接赋值；异步解出
/// 才经 [onChanged] 让宿主重建。
class FushiImageAspectProbe {
  FushiImageAspectProbe(this.onChanged);

  final VoidCallback onChanged;

  ImageProvider? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 宽 / 高。
  double? aspect;

  /// 当前图源解码失败。
  bool failed = false;

  /// 换成追踪 [image]（同一图源不重解）。
  void track(ImageProvider? image, ImageConfiguration config) {
    if (image == _image) return;
    stop();
    _image = image;
    aspect = null;
    failed = false;
    if (image == null) return;
    bool synchronous = true;
    final ImageStream stream = image.resolve(config);
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        final int w = info.image.width;
        final int h = info.image.height;
        info.dispose();
        if (_image != image) return;
        final double? resolved = w > 0 && h > 0 ? w / h : null;
        stop();
        if (resolved == aspect) return;
        aspect = resolved;
        if (!synchronous) onChanged();
      },
      onError: (Object _, StackTrace? __) {
        if (_image != image) return;
        stop();
        failed = true;
        if (!synchronous) onChanged();
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
    synchronous = false;
  }

  /// 停止监听（保留已解出的 [aspect]）。
  void stop() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }
}

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

// =============================================================================
// 作品艺术字（刮削 logo）的标题槽——全站一份。
//
// 2026-11-21 用户：「logo 长宽高大小一样主要是，而且标题文字的占位大小也不一样」
// （设计稿：左右对照的实图稿，用户拍板「按右边改」）。此前按「视觉面积」给每个
// logo 单算一个框（宽在文字列 38%～62% 浮动、高 ≤ 档位上限），横长 / 偏方 / 无
// logo 三种情况标题区宽高各不相同，一排卡的标题上沿高低错开。现在每个尺寸档
// 只有一个固定槽：宽 = 文字列 × [kFushiLogoSlotWidthFraction]、高 = 档位高度；
// logo 等比缩进槽里贴起始侧底部，没有 logo 时标题文字（最多两行）也占同一个槽
// （[FushiTitleSlot]）。色块（[FushiCoverBlock]）、继续观看剧照主卡等所有画
// logo 的地方都走 [FushiLogoTitle]，不各写一份。
// =============================================================================

/// 标题槽宽度占文字列宽的比例。
const double kFushiLogoSlotWidthFraction = 0.7;

/// 标题槽尺寸：宽 = [columnWidth] × [kFushiLogoSlotWidthFraction]（列宽无界时
/// 按 3:1 取 [height] 的三倍），高 = [height]。与 logo 的宽高比无关。
Size fushiLogoSlotSize({required double columnWidth, required double height}) {
  if (!(height > 0)) return Size.zero;
  final double width = columnWidth.isFinite && columnWidth > 0
      ? columnWidth * kFushiLogoSlotWidthFraction
      : height * 3;
  return Size(width, height);
}

/// 无 logo 时的标题文字槽：高 = [height]（与可用高度取小）、宽占满文字列，文字
/// 贴起始侧底部、最多 [maxLines] 行（还会按槽高能放下的行数收紧）。与同档
/// [FushiLogoTitle] 的槽同高，一排卡里有 logo 与没 logo 的标题区一样大。
class FushiTitleSlot extends StatelessWidget {
  const FushiTitleSlot({
    required this.title,
    required this.style,
    required this.height,
    this.maxLines = 2,
    super.key,
  });

  final String title;
  final TextStyle style;

  /// 槽高（通常就是同档 logo 的槽高）。
  final double height;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double slot = constraints.maxHeight.isFinite
            ? math.min(height, constraints.maxHeight)
            : height;
        final double lineHeight =
            scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.15);
        final int lines = (slot / lineHeight).floor().clamp(1, maxLines);
        return SizedBox(
          height: slot,
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Text(
              title,
              maxLines: lines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        );
      },
    );
  }
}

/// 标题位的 logo：恒占一个 [fushiLogoSlotSize] 固定槽（解码前后、横长竖长都
/// 一样大，布局不跳），图等比缩进槽里贴起始侧底部；解码失败画 [fallback]（标题
/// 文字）。语义标签是 [title]。
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

  /// 槽高（档位高度，实际还会与可用高度取小）。
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
        final Size box = fushiLogoSlotSize(
          columnWidth: constraints.maxWidth,
          height: maxHeight,
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
              child: _probe.aspect == null
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

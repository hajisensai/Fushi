import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 视频库主网格 2:3 海报封面（Kazumi 式，用户拍板 2026-07-24 统一竖版）。
///
/// 外层由调用方给定 2:3 区域（`AspectRatio(aspectRatio: 2 / 3)`），本组件按图片
/// 固有宽高比选择填充手法，**不出黑边、不变形，也不搞「有海报竖版、无海报横版」
/// 的混排特例**：
///
/// * 竖图（宽高比 ≤ [portraitAspectThreshold]，真海报 2:3≈0.67）→ 直接
///   `BoxFit.cover` 铺满；
/// * 横图（现状导入抽帧的 16:9 截帧）→ 同图两层：底层 `cover` 放大 + 高斯模糊 +
///   半透明压暗垫底，前景 `contain` 居中完整显示；
/// * 尺寸未知（首帧解码前）先按 `cover` 渲染，[ImageStream] 拿到尺寸后再切换，
///   避免先占位后闪换；
/// * 加载/解码失败 → [errorBuilder]（通常是调用方的占位封面）。
///
/// 宽高比判定不异步 decode 整图：前景 [Image] 与尺寸探测共用同一个
/// [ImageProvider]（同一 [ImageStream]），零额外解码成本。
class PortraitCoverImage extends StatefulWidget {
  const PortraitCoverImage({
    super.key,
    required this.image,
    this.imageKey,
    this.errorBuilder,
  });

  /// 已解析好的图片源。本地文件请自带解码上限（如 `resizedFileImage`），远端用
  /// `RemoteCoverImage`——本组件不关心来源，垫底/前景共享同一 provider 的解码缓存。
  final ImageProvider image;

  /// 前景 [Image] 的 key（widget 测试按此定位，沿用旧封面 key 习惯）。
  final Key? imageKey;

  /// 加载/解码失败时的替代内容（通常是调用方的无封面占位）。
  final WidgetBuilder? errorBuilder;

  /// 竖图判定阈值：宽高比 ≤ 此值直接 cover（海报 2:3≈0.67，留裕量收到 0.85）。
  static const double portraitAspectThreshold = 0.85;

  /// 横图垫底的模糊强度（sigma，任务定 12~16 取中）。
  static const double backdropBlurSigma = 14;

  @override
  State<PortraitCoverImage> createState() => _PortraitCoverImageState();
}

class _PortraitCoverImageState extends State<PortraitCoverImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 图片固有宽高比（宽 / 高）；null = 首帧前尺寸未知。
  double? _aspect;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(PortraitCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _aspect = null;
      _failed = false;
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _detachListener();
    super.dispose();
  }

  void _detachListener() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolveImage() {
    final ImageStream newStream =
        widget.image.resolve(createLocalImageConfiguration(context));
    if (newStream.key == _stream?.key) return;
    _detachListener();
    final ImageStreamListener listener =
        ImageStreamListener(_onImage, onError: _onError);
    _stream = newStream;
    _listener = listener;
    newStream.addListener(listener);
  }

  void _onImage(ImageInfo info, bool syncCall) {
    final double aspect = info.image.width / info.image.height;
    info.dispose();
    if (!mounted || _aspect == aspect) return;
    setState(() {
      _aspect = aspect;
      _failed = false;
    });
  }

  void _onError(Object exception, StackTrace? stackTrace) {
    if (!mounted || _failed) return;
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
    }
    final double? aspect = _aspect;
    final bool landscape =
        aspect != null && aspect > PortraitCoverImage.portraitAspectThreshold;
    final Widget foreground = Image(
      key: widget.imageKey,
      image: widget.image,
      // 竖图 / 首帧前：cover 铺满；已知横图：contain 完整居中浮于模糊垫底上。
      fit: landscape ? BoxFit.contain : BoxFit.cover,
      errorBuilder: widget.errorBuilder == null
          ? null
          : (BuildContext context, Object error, StackTrace? stackTrace) =>
              widget.errorBuilder!(context),
    );
    if (!landscape) return foreground;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 垫底：同图放大模糊（blur 溢出由外层 ClipRect 收口）。
          ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: PortraitCoverImage.backdropBlurSigma,
              sigmaY: PortraitCoverImage.backdropBlurSigma,
            ),
            child: Image(
              image: widget.image,
              fit: BoxFit.cover,
              // 垫底解码失败不接管整卡（前景/流监听兜底），静默留空。
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          // 半透明压暗垫底，突出前景。
          const ColoredBox(color: Color(0x59000000)),
          foreground,
        ],
      ),
    );
  }
}

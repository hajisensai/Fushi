import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 宽幅（约 2.7:1）封面槽的填充组件 —— [PortraitCoverImage] 的镜像。
///
/// 竖版槽装横图由 `PortraitCoverImage` 负责；本组件负责相反的一侧：**横幅槽装竖
/// 图**。合集详情页 hero 就是这样一个槽：它跨整屏宽、高 400~600，比例约 2.7:1，
/// 而它的图源只有一个 `MediaCollections.coverPath` 列——既可能是导入抽帧的 16:9
/// 横图，也可能是刮削写入的 2:3 竖版海报（BUG-1298）。一个列服务两种朝向，所以
/// 朝向判定必须落在渲染层。
///
/// * 横图（宽高比 ≥ [landscapeAspectThreshold]，抽帧 16:9≈1.78）→ 直接
///   `BoxFit.cover` 铺满，[overlays] 压在其上。**与本组件引入前逐像素相同。**
/// * 竖图（刮削海报 2:3≈0.71）→ 同图两层：底层 `cover` 放大 + 高斯模糊 + 半透明
///   压暗垫底，前景 `contain` 完整显示、按 [foregroundAlignment] 靠边避让 hero
///   文字。直接 `cover` 一张 2:3 海报进 2.7:1 槽要放大 4.5 倍、只剩中间 26% 的
///   高度带（人脸糊满屏、头顶被切），正是 BUG-1298 的现象。
/// * 尺寸未知（首帧解码前）先按 `cover` 渲染，[ImageStream] 拿到尺寸后再切换，
///   避免先占位后闪换（与 `PortraitCoverImage` 同一策略）。
/// * 加载/解码失败 → [errorBuilder]。
///
/// [overlays] 是压在封面之上、**清晰前景之下**的遮罩层（hero 那两层可读性渐变）。
/// 层序是本组件的存在理由之一：渐变要盖住模糊垫底（否则文字压在花花绿绿的背景上
/// 不可读），但**不能**盖住清晰海报（hero 底部渐变浓到 0xE8，海报下半截会被压成
/// 一片黑）。调用方自己拼 Stack 做不到这个层序，除非把朝向判定抄一遍。
///
/// 宽高比判定不异步 decode 整图：前景 [Image] 与尺寸探测共用同一个 [ImageProvider]
/// （同一 [ImageStream]），零额外解码成本。
class LandscapeCoverImage extends StatefulWidget {
  const LandscapeCoverImage({
    super.key,
    required this.image,
    this.imageKey,
    this.overlays = const <Widget>[],
    this.foregroundAlignment = AlignmentDirectional.centerEnd,
    this.foregroundPadding = EdgeInsets.zero,
    this.errorBuilder,
  });

  /// 已解析好的图片源。本地文件请自带解码上限（如 `resizedFileImage`）——垫底与
  /// 前景共享同一 provider 的解码缓存。
  final ImageProvider image;

  /// 主 [Image] 的 key（widget 测试按此定位）。
  final Key? imageKey;

  /// 压在封面之上、清晰前景之下的遮罩层（自下而上）。
  final List<Widget> overlays;

  /// 竖图前景的对齐方式；默认靠尾侧（LTR 下 = 右），避让 hero 左下的标题/按钮。
  final AlignmentGeometry foregroundAlignment;

  /// 竖图前景的内边距（避让 AppBar 与底部安全区）。横图路径不受影响。
  final EdgeInsetsGeometry foregroundPadding;

  /// 加载/解码失败时的替代内容。
  final WidgetBuilder? errorBuilder;

  /// 横图判定阈值：宽高比 ≥ 此值直接 cover。抽帧 16:9≈1.78 是横图；刮削海报
  /// 2:3≈0.71 与方图 1.0 都要走模糊垫底（方图 cover 进 2.7:1 槽也要裁掉 63%）。
  static const double landscapeAspectThreshold = 1.2;

  /// 竖图垫底的模糊强度（sigma）。比竖版槽的 14 更强：这里垫底被放大 4.5 倍，
  /// 同样的 sigma 相对画面显得太锐。
  static const double backdropBlurSigma = 28;

  /// 竖图垫底之上的压暗层（与 `PortraitCoverImage` 同值）。
  static const Color backdropDimColor = Color(0x59000000);

  @override
  State<LandscapeCoverImage> createState() => _LandscapeCoverImageState();
}

class _LandscapeCoverImageState extends State<LandscapeCoverImage> {
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
  void didUpdateWidget(LandscapeCoverImage oldWidget) {
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
    // 首帧前 aspect 未知 → 按横图走（= 引入本组件前的行为），拿到尺寸再切。
    final bool portrait =
        aspect != null && aspect < LandscapeCoverImage.landscapeAspectThreshold;

    if (!portrait) {
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image(
              key: widget.imageKey,
              image: widget.image,
              fit: BoxFit.cover,
              errorBuilder: widget.errorBuilder == null
                  ? null
                  : (BuildContext context, Object _, StackTrace? __) =>
                      widget.errorBuilder!(context),
            ),
            ...widget.overlays,
          ],
        ),
      );
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 垫底：同图放大模糊（blur 溢出由外层 ClipRect 收口）。
          ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: LandscapeCoverImage.backdropBlurSigma,
              sigmaY: LandscapeCoverImage.backdropBlurSigma,
            ),
            child: Image(
              image: widget.image,
              fit: BoxFit.cover,
              // 垫底解码失败不接管整块（前景/流监听兜底），静默留空。
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          const ColoredBox(color: LandscapeCoverImage.backdropDimColor),
          // 遮罩压在模糊垫底上（保证文字可读），但压不到下面的清晰海报。
          ...widget.overlays,
          Padding(
            padding: widget.foregroundPadding,
            child: Image(
              key: widget.imageKey,
              image: widget.image,
              fit: BoxFit.contain,
              alignment: widget.foregroundAlignment,
              errorBuilder: widget.errorBuilder == null
                  ? null
                  : (BuildContext context, Object _, StackTrace? __) =>
                      widget.errorBuilder!(context),
            ),
          ),
        ],
      ),
    );
  }
}

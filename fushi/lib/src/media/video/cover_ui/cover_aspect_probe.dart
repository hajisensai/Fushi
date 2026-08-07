import 'package:flutter/material.dart';

/// 槽向自适应封面组件的**共享内核**（TODO-2426）。
///
/// `PortraitCoverImage`（竖槽，兼横槽变体）与 `LandscapeCoverImage`（宽幅 hero 槽）
/// 是同一手法的两侧镜像：先拿图片固有宽高比，再决定「直接铺满」还是「模糊垫底 +
/// contain 前景」。两者**渲染分支不同**（overlays 层序 / 前景 alignment+padding /
/// 模糊强度），那是各自槽位的真实产品差异，不该硬合成一个组件；但**取宽高比这段
/// 状态机逐字相同**（ImageStream 生命周期 + 首帧前按合槽渲染 + 解码失败兜底），
/// 那才是真重复。这里抽的就是后者：零渲染行为变化，两侧 build 各自保留。
///
/// 用法：State 类 `with CoverAspectProbe<自己的 Widget>`，实现 [probedImageOf]，
/// 在 build 里读 [coverAspect] / [coverFailed]。生命周期钩子由本 mixin 提供，
/// 子类不要再自己写 `didChangeDependencies` / `didUpdateWidget` / `dispose`。
mixin CoverAspectProbe<T extends StatefulWidget> on State<T> {
  /// 从 widget 取出要探测的图片源。前景 [Image] 必须用同一个 provider——两者共享
  /// 同一 [ImageStream]，宽高比探测因此是零额外解码成本。
  ImageProvider probedImageOf(T widget);

  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;
  bool _failed = false;

  /// 图片固有宽高比（宽 / 高）；null = 首帧解码前尺寸未知。
  ///
  /// 调用方一律把 null 当「合槽」处理（先按 `cover` 渲染，拿到尺寸再切），避免
  /// 先占位后闪换。
  double? get coverAspect => _aspect;

  /// 加载 / 解码是否已失败（调用方据此走 errorBuilder）。
  bool get coverFailed => _failed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveProbedImage();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (probedImageOf(widget) != probedImageOf(oldWidget)) {
      _aspect = null;
      _failed = false;
      _resolveProbedImage();
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

  void _resolveProbedImage() {
    final ImageStream newStream =
        probedImageOf(widget).resolve(createLocalImageConfiguration(context));
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
}

/// 「这是一张横图」的判定阈值：宽高比 ≥ 此值算横图。
///
/// **两个槽向组件共用同一个真相源**：抽帧 16:9≈1.78 是横图；刮削海报 2:3≈0.71
/// 与方图 1.0 都不是。此前竖槽组件与宽幅组件各写了一份 `1.2`，同一个概念两处独立
/// 常量 —— 改一个不会带动另一个（TODO-2426）。
const double kCoverLandscapeAspectThreshold = 1.2;

/// 不合槽时压在模糊垫底之上的半透明压暗层颜色（两个槽向组件同值）。
const Color kCoverBackdropDimColor = Color(0x59000000);

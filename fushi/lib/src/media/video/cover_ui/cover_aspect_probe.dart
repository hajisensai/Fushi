import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/cover_ui/cover_backdrop_color.dart';

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

  /// 宽高比为 [aspect] 的图会走「模糊垫底」吗？
  ///
  /// **只有走垫底的图才需要主色底**，所以这也是采样的开关：取主色要 `toByteData`
  /// 把整图 RGBA 拉出来（一张 400×600 就是近 1MB），视频库墙格几十上百张卡全采
  /// 一遍纯属白烧。合槽直接 `cover` 铺满的图压根看不到底色。
  ///
  /// 判据就是子类 build 里那条 mismatch 分支，两处必须同源——各写一份迟早漂移。
  bool needsBackdropSeed(double aspect);

  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;
  bool _failed = false;
  Color? _backdropSeed;

  /// 每次换图自增：异步主色采样回来时对不上号就丢弃（图片已经换了）。
  int _sampleGeneration = 0;

  /// 图片固有宽高比（宽 / 高）；null = 首帧解码前尺寸未知。
  ///
  /// 调用方一律把 null 当「合槽」处理（先按 `cover` 渲染，拿到尺寸再切），避免
  /// 先占位后闪换。
  double? get coverAspect => _aspect;

  /// 加载 / 解码是否已失败（调用方据此走 errorBuilder）。
  bool get coverFailed => _failed;

  /// 垫底底色种子（图片非透明像素的加权平均色），null = 尚未采样完成，或整图
  /// 几乎不透明、压根不需要底色。语义与调制手法见 [sampleCoverBackdropSeed]。
  Color? get coverBackdropSeed => _backdropSeed;

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
      _backdropSeed = null;
      _sampleGeneration++;
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
    // 主色采样要读像素（异步），而 info.dispose() 之后底层 image 就不能再用了。
    // clone 拿一份自己的句柄，采样完在 [_sampleBackdrop] 里各自释放。
    final ui.Image sample = info.image.clone();
    info.dispose();
    if (needsBackdropSeed(aspect)) {
      _sampleBackdrop(sample, _sampleGeneration);
    } else {
      sample.dispose();
    }
    if (!mounted || _aspect == aspect) return;
    setState(() {
      _aspect = aspect;
      _failed = false;
    });
  }

  /// 异步取垫底底色。[generation] 用来丢弃过期结果：采样期间 widget 可能已经换图。
  Future<void> _sampleBackdrop(ui.Image image, int generation) async {
    try {
      final CoverBackdropSeed? seed = await sampleCoverBackdropSeed(image);
      if (!mounted || generation != _sampleGeneration) return;
      final Color? color = seed?.color;
      if (_backdropSeed == color) return;
      setState(() => _backdropSeed = color);
    } finally {
      image.dispose();
    }
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

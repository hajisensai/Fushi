import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/media/video/cover_ui/cover_backdrop_color.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 槽向自适应封面（Kazumi 式，用户拍板 2026-07-24 统一竖版；BUG-1299 推广为
/// 横竖槽通用）。
///
/// 外层由调用方给定槽位区域（主网格是 `AspectRatio(aspectRatio: 2 / 3)`），本组件
/// 按图片固有宽高比与槽位朝向选择填充手法，**不出黑边、不变形，也不搞「有海报
/// 竖版、无海报横版」的混排特例**：
///
/// * 图片朝向与槽位一致（竖槽竖图 / 横槽横图）→ 直接 `BoxFit.cover` 铺满；
/// * 朝向不一致（竖槽里的 16:9 截帧 / 横槽里的 2:3 海报）→ 同图分层：主色底 +
///   `cover` 放大高斯模糊（自身压暗）+ 前景 `contain` 居中完整显示；
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
    this.landscapeSlot = false,
  });

  /// 已解析好的图片源。本地文件请自带解码上限（如 `resizedFileImage`），远端用
  /// `RemoteCoverImage`——本组件不关心来源，垫底/前景共享同一 provider 的解码缓存。
  final ImageProvider image;

  /// 前景 [Image] 的 key（widget 测试按此定位，沿用旧封面 key 习惯）。
  final Key? imageKey;

  /// 加载/解码失败时的替代内容（通常是调用方的无封面占位）。
  final WidgetBuilder? errorBuilder;

  /// 槽位朝向：false = 竖版槽（默认，主网格 2:3），横图垫底；true = 横版槽
  /// （合集详情 16:9 单集缩略图等），竖图垫底（BUG-1299）。
  final bool landscapeSlot;

  /// 竖图判定阈值：宽高比 ≤ 此值直接 cover（海报 2:3≈0.67，留裕量收到 0.85）。
  static const double portraitAspectThreshold = 0.85;

  /// 横版槽的横图判定阈值：宽高比 ≥ 此值直接 cover（截帧 16:9≈1.78；方图/竖图
  /// cover 进 16:9 槽会裁掉四成以上，走垫底）。与 `LandscapeCoverImage` 共用同一
  /// 真相源 [kCoverLandscapeAspectThreshold]（TODO-2426）。
  static const double landscapeAspectThreshold = kCoverLandscapeAspectThreshold;

  /// 横图垫底的模糊强度（sigma，任务定 12~16 取中）。
  static const double backdropBlurSigma = 14;

  @override
  State<PortraitCoverImage> createState() => _PortraitCoverImageState();
}

class _PortraitCoverImageState extends State<PortraitCoverImage>
    with CoverAspectProbe<PortraitCoverImage> {
  @override
  ImageProvider probedImageOf(PortraitCoverImage widget) => widget.image;

  /// 朝向是否不合槽 —— build 的渲染分支与主色采样开关共用的唯一判据。
  bool _mismatch(double aspect) => widget.landscapeSlot
      ? aspect < PortraitCoverImage.landscapeAspectThreshold
      : aspect > PortraitCoverImage.portraitAspectThreshold;

  @override
  bool needsBackdropSeed(double aspect) => _mismatch(aspect);

  @override
  Widget build(BuildContext context) {
    if (coverFailed) {
      return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
    }
    final double? aspect = coverAspect;
    // 朝向不合槽 = 垫底 + contain；首帧前（aspect 未知）按合槽 cover 渲染。
    final bool mismatch = aspect != null && _mismatch(aspect);
    final Widget foreground = Image(
      key: widget.imageKey,
      image: widget.image,
      // 合槽 / 首帧前：cover 铺满；已知不合槽：contain 完整居中浮于模糊垫底上。
      fit: mismatch ? BoxFit.contain : BoxFit.cover,
      errorBuilder: widget.errorBuilder == null
          ? null
          : (BuildContext context, Object error, StackTrace? stackTrace) =>
              widget.errorBuilder!(context),
    );
    if (!mismatch) return foreground;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ..._backdropLayers(context),
          foreground,
        ],
      ),
    );
  }

  /// 前景之下的垫底层序（底 → 上）：主色底 → 模糊图（自身压暗）。
  ///
  /// **压暗只作用于模糊图自身**（[BlendMode.srcATop] 保留源 alpha），这是与旧
  /// 实现的关键差别：旧实现把压暗铺成一整层 `ColoredBox`，图片带透明区时那层就
  /// 直接涂在空白上——galgame 封面链末端的 exe 内嵌图标正是四周整片透明的立绘，
  /// 模糊之后仍然透明，于是卡片只剩压暗色涂出来的一圈死灰。图片不透明时两种写法
  /// 等价，所以这个缺陷一直藏着。
  List<Widget> _backdropLayers(BuildContext context) {
    return <Widget>[
      if (_backdropDecoration(context) case final BoxDecoration decoration)
        DecoratedBox(decoration: decoration),
      // 压暗在内、模糊在外：压暗作用于**原图的 alpha**，透明区因此原样透出下面
      // 的主色底；随后整体模糊，边缘羽化也跟着自然衰减。反过来嵌套（先模糊再压暗）
      // 视觉几乎等价，但会把 ImageFiltered 从 Stack 的直接子节点上挪走，hero 的
      // 层序守卫按类型认这一层（collection_hero_cover_orientation_test）。
      ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: PortraitCoverImage.backdropBlurSigma,
          sigmaY: PortraitCoverImage.backdropBlurSigma,
        ),
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(
            kCoverBackdropDimColor,
            BlendMode.srcATop,
          ),
          child: Image(
            image: widget.image,
            fit: BoxFit.cover,
            // 垫底解码失败不接管整卡（前景/流监听兜底），静默留空。
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    ];
  }

  /// 主色底装饰；采样未完成 / 图片几乎不透明（不需要底色）时返回 null。
  ///
  /// 墨水屏不上色：屏幕本就是灰阶，有色底只会把立绘背景压成中灰、削掉对比。
  BoxDecoration? _backdropDecoration(BuildContext context) {
    if (isEinkTheme(context)) return null;
    final Color? seed = coverBackdropSeed;
    if (seed == null) return null;
    return BoxDecoration(
      gradient: coverBackdropGradient(
        harmonizeBackdrop(seed, Theme.of(context).brightness),
      ),
    );
  }
}

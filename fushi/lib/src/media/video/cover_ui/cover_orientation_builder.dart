import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';

/// 按封面固有朝向重建子树（TODO-2486 视频首页混排墙/横滚行的卡宽分流）。
///
/// 与 PortraitCoverImage 同一套 [CoverAspectProbe] 内核：探测与前景渲染共用
/// 同一个 [ImageProvider]（同一 ImageStream），零额外解码。[image] 为 null
/// （无封面占位）或首帧未解码时按竖卡渲染（拍板：朝向未知默认竖卡），解码
/// 出横图后重建为横卡。
///
/// **调用方必须把传进来的同一个 provider 实例交给卡内封面渲染**（如
/// PortraitCoverImage），否则两个 provider 各开一条流、白解码一次。
class CoverOrientationBuilder extends StatelessWidget {
  const CoverOrientationBuilder({
    super.key,
    required this.image,
    required this.builder,
  });

  /// 封面源；null = 无封面（恒竖卡）。
  final ImageProvider? image;

  /// 以当前朝向重建子树。
  final Widget Function(BuildContext context, VideoCardOrientation orientation)
      builder;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = image;
    if (provider == null) {
      return builder(context, VideoCardOrientation.portrait);
    }
    return _CoverOrientationProbe(image: provider, builder: builder);
  }
}

class _CoverOrientationProbe extends StatefulWidget {
  const _CoverOrientationProbe({required this.image, required this.builder});

  final ImageProvider image;
  final Widget Function(BuildContext context, VideoCardOrientation orientation)
      builder;

  @override
  State<_CoverOrientationProbe> createState() => _CoverOrientationProbeState();
}

class _CoverOrientationProbeState extends State<_CoverOrientationProbe>
    with CoverAspectProbe<_CoverOrientationProbe> {
  @override
  ImageProvider probedImageOf(_CoverOrientationProbe widget) => widget.image;

  @override
  Widget build(BuildContext context) {
    // 解码失败按竖卡渲染（卡内封面组件自会走占位 errorBuilder）。
    final double? aspect = coverFailed ? null : coverAspect;
    return widget.builder(context, videoCardOrientationForAspect(aspect));
  }
}

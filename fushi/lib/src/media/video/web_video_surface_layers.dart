import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_return_bar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 网页档播放页的视频槽叠层（`VideoFushiPage` 的 `_wrapVideoWebSurface`）：站点 WebView 垫在
/// 最底层；有站点视频时上面是（广告遮罩 +）原生播放器层；没有视频 / 站点弹层打断时顶部留一条
/// 返回条（[returnBarExtent] 高，含顶部让位），站点页面与 OSD 都让在它下面。
///
/// 纯布局，与设计系统无关：各层的外观由调用方传进来的子树决定。
///
/// 每个入参都是**未定位**的子树，定位只在这里做一次。BUG-5612：OSD 层原来自带
/// `Positioned.fill`，这里又在外面套了一层 `Positioned(top: 返回条高)`，同一个 RenderObject
/// 叠了两层 `Positioned`，Debug 报 `Incorrect use of ParentDataWidget`，Release 里两层
/// 谁的偏移生效取决于框架内部的应用顺序。[osd] 的顶部系统让位已被返回条吃掉，这里替它去掉
/// （`MediaQuery.removePadding(removeTop:)`），OSD 里的 `SafeArea` 不再重复让一次。
class WebVideoSurfaceLayers extends StatelessWidget {
  const WebVideoSurfaceLayers({
    required this.surface,
    required this.hasVideo,
    required this.video,
    required this.returnBar,
    required this.osd,
    this.adCover,
    super.key,
  });

  /// 站点 WebView（调用方已按档位决定是否接命中测试）。
  final Widget surface;

  /// 观看页有站点视频（播放器档）：画面铺满，返回条与本层 OSD 隐藏。
  final bool hasVideo;

  /// 原生播放器层（透明底 + 控制条），只在 [hasVideo] 时挂。
  final Widget video;

  /// 跳过广告期间盖在画面上的遮罩，只在 [hasVideo] 时挂；null = 没有广告。
  final Widget? adCover;

  /// 没有视频时顶部的返回条（[WebVideoReturnBar]）。
  final Widget returnBar;

  /// 没有视频时的 OSD 层（播放器档的 OSD 挂在控制条里）。
  final Widget osd;

  @override
  Widget build(BuildContext context) {
    final double barExtent = webVideoReturnBarExtent(context);
    final Widget? cover = adCover;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          top: hasVideo ? 0 : barExtent,
          child: surface,
        ),
        if (hasVideo && cover != null) Positioned.fill(child: cover),
        if (hasVideo) Positioned.fill(child: video),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: barExtent,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: hasVideo
                ? const SizedBox.shrink(
                    key: ValueKey<String>('video-web-return-bar-hidden'),
                  )
                : returnBar,
          ),
        ),
        if (!hasVideo)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: barExtent,
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: osd,
            ),
          ),
      ],
    );
  }
}

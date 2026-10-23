import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 取一张遥控封面的字节（电脑 `cover` 操作）；没有封面返回 null。
typedef VideoRemoteCoverLoader = Future<Uint8List?> Function();

/// 电脑上的封面（点播清单 / 选集）：按 [cacheKey] 进全局图片缓存，同一张封面
/// 滚出又滚回、重开弹层都不再问电脑。[cacheKey] 由调用方拼上电脑身份与条目
/// 身份（换电脑 / 换集不串图）；[load] 不参与相等判断。
@immutable
class VideoRemoteCoverImage extends ImageProvider<VideoRemoteCoverImage> {
  const VideoRemoteCoverImage({required this.cacheKey, required this.load});

  final String cacheKey;
  final VideoRemoteCoverLoader load;

  @override
  Future<VideoRemoteCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<VideoRemoteCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    VideoRemoteCoverImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(key, decode),
    scale: 1,
    debugLabel: 'VideoRemoteCoverImage($cacheKey)',
  );

  static Future<ui.Codec> _decode(
    VideoRemoteCoverImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List? bytes = await key.load();
    if (bytes == null || bytes.isEmpty) {
      // 失败不进缓存（ImageCache 只留成功的帧），下次进入视野会重新问。
      throw StateError('video remote cover missing: ${key.cacheKey}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is VideoRemoteCoverImage && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;

  @override
  String toString() => 'VideoRemoteCoverImage($cacheKey)';
}

/// 遥控弹层里的封面缩略图：圆角卡片形状、`BoxFit.cover` 裁切；没有封面 / 取图
/// 失败画 surfaceContainerHighest 底 + [placeholderIcon]。按显示尺寸解码，长列表
/// 不会把整张海报解进内存。
class VideoRemoteCoverThumb extends StatelessWidget {
  const VideoRemoteCoverThumb({
    super.key,
    required this.cover,
    required this.width,
    required this.height,
    this.placeholderIcon = FushiIcons.video,
    this.badge,
  });

  final ImageProvider? cover;
  final double width;
  final double height;
  final IconData placeholderIcon;

  /// 叠在右下角的小角标（例如「正在播放」）。
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final Widget placeholder = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: FushiIcon(
          placeholderIcon,
          size: math.min(width, height) * 0.42,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
    final ImageProvider? image = cover;
    return ClipRRect(
      borderRadius: FushiM3eShape.cardRadius,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (image == null)
              placeholder
            else
              Image(
                image: ResizeImage.resizeIfNeeded(
                  (width * dpr).round(),
                  null,
                  image,
                ),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                frameBuilder:
                    (
                      BuildContext context,
                      Widget child,
                      int? frame,
                      bool wasSynchronouslyLoaded,
                    ) => wasSynchronouslyLoaded
                    ? child
                    : AnimatedSwitcher(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        child: frame == null ? placeholder : child,
                      ),
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        placeholder,
              ),
            if (badge != null) Positioned(right: 4, bottom: 4, child: badge!),
          ],
        ),
      ),
    );
  }
}

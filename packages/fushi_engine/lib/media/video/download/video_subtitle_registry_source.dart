/// 下载管线字幕阶段的来源入口：每进一次字幕阶段借一份 [VideoSubtitleRegistry]，
/// 阶段结束归还。
///
/// 为什么不是构造期传一份 registry：来源集合由偏好（各家 key / 开关）决定，而偏好
/// 在宿主运行期间会变（互联同步、WebUI、ctl）。构造期快照只能靠整套重建管线才换得掉
/// ——app 在设置页改字幕来源时就是这么做的（[FixedVideoSubtitleRegistrySource]），
/// 服务端没有对应的设置入口，就改成每次用时按当前偏好现借一份。借出的 registry
/// 由借方用到阶段结束，期间偏好再变也不影响这一轮（在飞的字幕阶段不会被拔掉 client）。
library;

import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';

/// 字幕阶段向它借当前的来源集合。
abstract interface class VideoSubtitleRegistrySource {
  /// 借一份当前的来源集合；本机一家字幕来源都没配时返回 null（管线按「本机没配
  /// 字幕」处理：best-effort 直接入库，required 报 needsAttention）。
  ///
  /// 借到的必须恰好 [VideoSubtitleRegistryLease.release] 一次。
  VideoSubtitleRegistryLease? acquire();
}

/// 借出的一份来源集合。
final class VideoSubtitleRegistryLease {
  VideoSubtitleRegistryLease(this.registry, {void Function()? onRelease})
    : _onRelease = onRelease;

  final VideoSubtitleRegistry registry;
  void Function()? _onRelease;

  /// 归还（重复调用无副作用）。
  void release() {
    final void Function()? onRelease = _onRelease;
    _onRelease = null;
    onRelease?.call();
  }
}

/// 固定一份 registry：每次借出的都是它，归还不关闭（生命周期归构造方，app 在设置
/// 改了之后整套重建管线时自己关）。
final class FixedVideoSubtitleRegistrySource
    implements VideoSubtitleRegistrySource {
  const FixedVideoSubtitleRegistrySource(this.registry);

  final VideoSubtitleRegistry registry;

  @override
  VideoSubtitleRegistryLease? acquire() => VideoSubtitleRegistryLease(registry);
}

/// 每次借时现建一份、归还时关闭（服务端：key / 开关改了下一轮字幕阶段即生效，
/// 不用重建管线）。[build] 装出空 registry 视为「没配字幕」，当场关掉并返回 null。
final class PerUseVideoSubtitleRegistrySource
    implements VideoSubtitleRegistrySource {
  const PerUseVideoSubtitleRegistrySource(this.build);

  final VideoSubtitleRegistry Function() build;

  @override
  VideoSubtitleRegistryLease? acquire() {
    final VideoSubtitleRegistry registry = build();
    if (registry.providers.isEmpty) {
      registry.close();
      return null;
    }
    return VideoSubtitleRegistryLease(registry, onRelease: registry.close);
  }
}

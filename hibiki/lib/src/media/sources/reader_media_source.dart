import 'package:flutter/widgets.dart';

import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';

/// A source for the [ReaderMediaType], which handles primarily text-based
/// media.
abstract class ReaderMediaSource extends MediaSource {
  /// Initialise a media source.
  ReaderMediaSource({
    required super.uniqueKey,
    required super.sourceName,
    required super.description,
    required super.icon,
    required super.implementsSearch,
    required super.implementsHistory,
    super.overridesAutoImage = false,
    super.overridesAutoAudio = false,
  }) : super(
          mediaType: ReaderMediaType.instance,
        );

  // TODO-786：阅读类媒体源默认卡槽比例归到书封比例 [kShelfBookCardAspectRatio]
  // （≈160/260），让书架封面 fitHeight 自然铺满、消除两侧白带。（书架视频分区
  // 死路径已删，视频卡槽比例随之移除，视频卡归「视频」tab 自管。）
  @override
  double get aspectRatio => kShelfBookCardAspectRatio;

  /// The body widget to show in the tab when this source's media type and this
  /// source is selected.
  @override
  BasePage buildHistoryPage({MediaItem? item, Widget? navigation}) {
    // 通用回退页无页头，导航条无处安放——忽略它只是没有视图切换，不影响正确性。
    return const HistoryReaderPage();
  }
}

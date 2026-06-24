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
  // （≈160/260），让书架封面 fitHeight 自然铺满、消除两侧白带。视频卡在书架页用
  // [kShelfVideoCardAspectRatio] 单独传入，不走这个默认值。
  @override
  double get aspectRatio => kShelfBookCardAspectRatio;

  /// The body widget to show in the tab when this source's media type and this
  /// source is selected.
  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const HistoryReaderPage();
  }
}

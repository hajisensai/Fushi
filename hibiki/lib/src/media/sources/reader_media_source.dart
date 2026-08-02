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

  /// BUG-1317：EPUB / 漫画 / PDF 是**同一本书**的三种 `EpubBooks.format`，共享
  /// `hoshi://book/<bookKey>` 身份，而 `mediaSourceIdentifier` 由**当前** format
  /// 现算（转化后会变）。override 书名 / 封面必须跟着**书**走，不跟着阅读器走，
  /// 所以三源统一存进 EPUB 源的偏好命名空间。
  @override
  MediaSource get overrideStore => ReaderHibikiSource.instance;

  /// BUG-1317 读取期回退：存量 override 按写入时的 format 散落在三个源各自的
  /// `src:<sourceId>:` 命名空间里，三个都要试。
  @override
  List<MediaSource> get legacyOverrideStores => <MediaSource>[
        ReaderHibikiSource.instance,
        MangaHibikiSource.instance,
        ReaderPdfSource.instance,
      ];

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

/// 资料源的用户可见名称装配点。
///
/// 发现 provider（`video_discovery_adapters.dart` / `video_metadata_discovery_provider.dart`）
/// 要给来源 chip 一个名字，而本地化表在 app 里。与 [engineLog] 同一范式：引擎给一个
/// 与语言无关的品牌名默认值，app 在 `installEngineHostBindings()` 换成 i18n 出口
/// `videoMetadataProviderLabel`；无头服务端不渲染来源 chip，用默认值即可。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

typedef VideoMetadataProviderDisplayName =
    String Function(VideoMetadataProviderKind kind);

/// 品牌名兜底（不翻译）。
String defaultVideoMetadataProviderDisplayName(
  VideoMetadataProviderKind kind,
) => switch (kind) {
  VideoMetadataProviderKind.anidb => 'AniDB',
  VideoMetadataProviderKind.mal => 'MAL',
  VideoMetadataProviderKind.tmdb => 'TMDB',
  _ => kind.name.toUpperCase(),
};

/// 宿主装配点。
VideoMetadataProviderDisplayName videoMetadataProviderDisplayName =
    defaultVideoMetadataProviderDisplayName;

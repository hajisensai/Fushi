/// 可选主资料源的用户可见名称。品牌名不翻译，但经 i18n 表统一出口，
/// 来源设置对话框与全局设置页共用一份。
library;

import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/utils.dart';

String videoMetadataProviderLabel(VideoMetadataProviderKind kind) =>
    switch (kind) {
      VideoMetadataProviderKind.mal => t.video_metadata_provider_mal,
      VideoMetadataProviderKind.tmdb => t.video_metadata_provider_tmdb,
      _ => kind.name.toUpperCase(),
    };

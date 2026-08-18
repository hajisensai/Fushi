import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/utils.dart';

/// 发现域的用户可见名。
///
/// 原先只作为发现页里的一个私有 `_kindLabel` 存在；设置页「发现来源」要列每个源
/// 覆盖哪些域，需要同一份映射。抄一份就等于两份真相源——加一个域时必然漏改一处。
String discoveryMediaKindLabel(DiscoveryMediaKind kind) => switch (kind) {
      DiscoveryMediaKind.novel => t.discovery_kind_novel,
      DiscoveryMediaKind.audiobook => t.discovery_kind_audiobook,
      DiscoveryMediaKind.game => t.game_library,
      DiscoveryMediaKind.manga => t.library_view_browse,
    };

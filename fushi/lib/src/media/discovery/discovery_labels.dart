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
      DiscoveryMediaKind.manga => t.discovery_kind_manga,
    };

/// 发现域的字节数可读格式（`1.2 GiB` / `512 B`）。
///
/// 发现页条目副标题与下载页直链任务行共用；原先是发现页的私有静态方法，
/// 任务行要显示「已收/总」时抄一份就是两份真相源。
String formatDiscoveryBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

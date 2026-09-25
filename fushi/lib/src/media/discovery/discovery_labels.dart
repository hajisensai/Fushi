import 'package:fushi_engine/media/discovery/discovery_models.dart';
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

/// 发现条目日期原文的展示形态。
///
/// OPDS Atom 的 `<updated>` 是完整 RFC 3339 时间戳（`2026-09-25T04:55:58.997Z`），
/// 原样塞进副标题既长又是 UTC，同系列几卷只差几秒、对挑书毫无信息量。
/// 只有带 `T` 的完整 ISO 8601 时间戳才换成**本地日期** `yyyy-MM-dd`；
/// 其余源的原文（nyaa `2026-09-25 04:55` 等，时区语义各源不一）原样返回——
/// 解析它们只会把时区猜错。这里只管显示，排序仍按源返回顺序
/// （见 `DiscoveryResourceItem.dateText`）。
String formatDiscoveryDate(String raw) {
  final String text = raw.trim();
  if (!_isoTimestamp.hasMatch(text)) return raw;
  final DateTime? parsed = DateTime.tryParse(text);
  if (parsed == null) return raw;
  final DateTime local = parsed.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}';
}

final RegExp _isoTimestamp = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}');

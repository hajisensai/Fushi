import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    as discovery;
import 'package:material_ui/material_ui.dart';

/// 发现条目标题 logo（透明底艺术字）的懒取缓存，发现页 / 今日放送 / 放送日历
/// 共用：列表接口与 AniList 放送数据都不带 logo，按需经详情端口（provider
/// 自带详情缓存）各取一次；同一条（canonicalIdentityKey）进程内只发起一次。
///
/// 取不到（无 logo / 离线 / 限流 / 未配置详情端口）为 null，色块回落标题文字
/// ——logo 只是增强，详情页打开时走自己的加载与报错。
final Map<String, Future<ImageProvider?>> _discoveryLogoFutures =
    <String, Future<ImageProvider?>>{};

/// [item] 的标题 logo（见文件头）。已带完整图组的直接给，不发请求。
Future<ImageProvider?> discoveryLogoFor(
  discovery.VideoDiscoveryItem item,
  VideoDiscoveryDetailLoader? loader,
) {
  final String? known = item.logoUrl;
  if (known != null && known.trim().isNotEmpty) {
    return SynchronousFuture<ImageProvider?>(AppCachedHttpImage(known));
  }
  if (loader == null) return SynchronousFuture<ImageProvider?>(null);
  return _discoveryLogoFutures.putIfAbsent(
    item.reference.canonicalIdentityKey,
    () => loader(item).then((VideoDiscoveryDetailData data) {
      final String? url = data.item.logoUrl;
      return url == null || url.trim().isEmpty
          ? null
          : AppCachedHttpImage(url) as ImageProvider;
    }, onError: (Object _) => null),
  );
}

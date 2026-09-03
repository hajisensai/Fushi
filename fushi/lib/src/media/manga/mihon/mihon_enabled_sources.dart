/// 「已启用在线来源」的唯一口径：来源自身启用，**且**提供它的扩展也启用。
///
/// 浏览页、发现详情页、发现源热门行三处消费同一份判据；口径不一致会出现
/// 「来源页关了、别处还在发请求」这类用户没法解释的行为（与 BUG-1431 同因）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';

/// 纯过滤：从扩展表 + 来源表算出已启用来源（保持 [sources] 原有顺序）。
List<MangaOnlineSourceRow> filterEnabledMangaOnlineSources({
  required List<MangaExtensionRow> installed,
  required List<MangaOnlineSourceRow> sources,
}) {
  final Set<String> enabledExtensions = installed
      .where((MangaExtensionRow row) => row.enabled)
      .map((MangaExtensionRow row) => row.packageName)
      .toSet();
  return sources
      .where(
        (MangaOnlineSourceRow row) =>
            row.enabled && enabledExtensions.contains(row.extensionPackage),
      )
      .toList(growable: false);
}

List<MangaOnlineSourceRow> enabledMangaOnlineSources(MihonManager manager) =>
    filterEnabledMangaOnlineSources(
      installed: manager.installed,
      sources: manager.sources,
    );

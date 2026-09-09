/// 更新中心的条目跳转（v101）。
///
/// 与页面分开：`UpdatesCenterPage` 只认识「一条更新」，跳转要认识四个域各自的页面
/// 与它们的装配，塞进页面就等于把四棵依赖树焊进一个本该能独立构建的 widget。
library;

import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart' show UpdateFeedEntryRow;
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/updates/update_feed_kind.dart';
import 'package:fushi/utils.dart';

/// 打开一条更新。
///
/// **视频新集刻意不深链**：合集详情页要 5 个装配正确的回调（打开集、变更回写、
/// 重刮削、删成员、规格服务），在这里现造一套就会与 `home_video_page` 的那套并存，
/// 两份装配一漂移就是一类必然的 bug。番剧新集的落点已经有一个更好的：视频首页
/// 「已更新未看」那一行本来就按订阅算，点开直接播。这里只标已读，不假装能跳。
Future<void> openUpdateFeedEntry(
  BuildContext context,
  UpdateFeedEntryRow entry,
) async {
  final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(entry.kind);
  if (kind == null) return;
  final Map<String, Object?> detail = _decodeDetail(entry.detailJson);
  switch (kind) {
    case UpdateFeedKind.mangaChapter:
      final String? bookKey = detail['bookKey'] as String?;
      if (bookKey == null || !context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MangaSeriesPage(
            target: ShelfMangaSeriesTarget(bookKey),
          ),
        ),
      );
    case UpdateFeedKind.mangaExtension:
      if (!context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => const MihonExtensionsPage(),
        ),
      );
    case UpdateFeedKind.appRelease:
      final String? url = detail['releaseUrl'] as String?;
      if (url == null || url.isEmpty) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    case UpdateFeedKind.videoEpisode:
      // 见上方注释：不深链。
      return;
  }
}

Map<String, Object?> _decodeDetail(String? json) {
  if (json == null || json.isEmpty) return const <String, Object?>{};
  try {
    final Object? decoded = jsonDecode(json);
    return decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
  } on FormatException {
    // 载荷是本机自己写的，坏掉只可能是版本间格式漂移——那时「打不开」比崩掉好。
    return const <String, Object?>{};
  }
}

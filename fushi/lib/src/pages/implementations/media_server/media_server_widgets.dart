import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth;
import 'package:fushi/utils.dart';

/// 横滚行里一张竖卡的宽度（2:3 海报）。与视频首页横滚行同量级。
const double kMediaServerRowCardWidth = 150;

/// 横滚行里一张媒体库横卡的宽度（16:9）。
const double kMediaServerLibraryCardWidth = 220;

/// 服务器条目封面（缩放到 [kLocalCoverDecodePixelWidth] 以内解码）。fetcher 就是
/// 浏览器本身（[MediaServerBrowser] implements `RemoteCoverFetcher`）；无图返回 null，
/// 页面画占位图，**不**拿一个必 404 的地址去请求。
ImageProvider? mediaServerCoverImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  MediaServerImageKind kind = MediaServerImageKind.primary,
}) {
  final String? url = browser.coverUrl(item, kind: kind);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: '${item.id}:${kind.name}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// 详情页 hero 用的大图（横版背景 / 标题 logo）：请求宽度与解码宽度都比网格卡大
/// ——背景要铺满 1600+ 逻辑像素宽的 hero，720 像素放大后一片糊；logo 在 hero 里
/// 最大 460×110 逻辑像素 × dpr。缓存键带上请求宽度，与网格卡的 720 版本互不串。
/// 其它 [kind] 退回 [mediaServerCoverImage] 的常规尺寸。无图返回 null。
ImageProvider? mediaServerHeroImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  required MediaServerImageKind kind,
}) {
  final (int requestWidth, int decodeWidth) = switch (kind) {
    MediaServerImageKind.backdrop => (1920, 2560),
    MediaServerImageKind.logo => (800, 800),
    MediaServerImageKind.primary || MediaServerImageKind.thumb => (
      kMediaServerCoverMaxWidth,
      kLocalCoverDecodePixelWidth,
    ),
  };
  final String? url = browser.coverUrl(
    item,
    kind: kind,
    maxWidth: requestWidth,
  );
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(
      url,
      browser,
      cacheKey: '${item.id}:${kind.name}:$requestWidth',
    ),
    width: decodeWidth,
    allowUpscaling: false,
  );
}

ImageProvider? mediaServerLibraryCoverImage(
  MediaServerBrowser browser,
  MediaServerLibrary library,
) {
  final String? url = browser.libraryCoverUrl(library);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: 'library:${library.id}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// `1:32:05` / `24:10` 形态的时长；null / 0 返回空串。
String formatMediaServerDuration(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '';
  final Duration d = Duration(milliseconds: durationMs);
  final int hours = d.inHours;
  final int minutes = d.inMinutes.remainder(60);
  final int seconds = d.inSeconds.remainder(60);
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}

/// 服务器端观看进度（0..1）；无断点 / 无时长返回 null。
double? mediaServerProgress(MediaServerItem item) {
  final int? duration = item.durationMs;
  if (item.positionMs <= 0 || duration == null || duration <= 0) return null;
  return (item.positionMs / duration).clamp(0.0, 1.0);
}

/// 卡片 / 列表行的第二行元数据：年份 · 类型 / 季集号 · 时长。
String mediaServerItemMetadata(MediaServerItem item) {
  final List<String> parts = <String>[];
  switch (item.type) {
    case MediaServerItemType.movie:
      if (item.productionYear != null) parts.add('${item.productionYear}');
      parts.add(t.collection_relation_movie);
    case MediaServerItemType.series:
      if (item.productionYear != null) parts.add('${item.productionYear}');
      parts.add(t.series);
    case MediaServerItemType.season:
      if (item.seasonNumber != null) {
        parts.add(t.collection_group_season(n: item.seasonNumber!));
      }
    case MediaServerItemType.episode:
      final String code = item.episodeCode;
      if (code.isNotEmpty) parts.add(code);
      final String duration = formatMediaServerDuration(item.durationMs);
      if (duration.isNotEmpty) parts.add(duration);
    case MediaServerItemType.folder:
      parts.add(t.media_server_item_folder);
      if (item.childCount != null) parts.add('${item.childCount}');
  }
  return parts.join(' · ');
}

/// 卡片文字块高度（一行名称 + 一行元数据 + 上下 padding）。行高 = 封面高 + 它。
double mediaServerCardTextBlock(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double titleLine = textLineHeight(context, tokens.type.listTitle);
  final double metaLine = textLineHeight(context, tokens.type.metadata);
  return titleLine + metaLine + 12 + kTextBlockSlack;
}

/// 横滚行竖卡的整卡高度。
double mediaServerRowCardHeight(BuildContext context) =>
    kMediaServerRowCardWidth * 3 / 2 + mediaServerCardTextBlock(context);

/// 一张服务器条目卡：2:3 封面 + 名称 + 元数据。角标：剧的未看集数（右上）、
/// 已看勾（右上）、服务器端断点进度条（封面底边）。
class MediaServerItemCard extends StatelessWidget {
  const MediaServerItemCard({
    required this.browser,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider? image = mediaServerCoverImage(browser, item);
    final double? progress = mediaServerProgress(item);
    final int unplayed = item.unplayedChildCount ?? 0;
    return FushiCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      focusId: focusId,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (image == null)
                  ShelfCoverPlaceholder(icon: _placeholderIcon(item.type))
                else
                  PortraitCoverImage(
                    image: image,
                    errorBuilder: (_) => ShelfCoverPlaceholder(
                      icon: Icons.broken_image_outlined,
                    ),
                  ),
                if (item.isContainer && unplayed > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: CoverBadge(label: '$unplayed'),
                  ),
                if (item.isPlayable && item.played)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: CoverBadge(icon: Icons.check_rounded),
                  ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  item.type == MediaServerItemType.episode &&
                          (item.seriesName?.isNotEmpty ?? false)
                      ? item.seriesName!
                      : item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                Text(
                  item.type == MediaServerItemType.episode
                      ? '${item.episodeCode} ${item.name}'.trim()
                      : mediaServerItemMetadata(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _placeholderIcon(MediaServerItemType type) => switch (type) {
    MediaServerItemType.movie => Icons.movie_outlined,
    MediaServerItemType.series ||
    MediaServerItemType.season ||
    MediaServerItemType.episode => Icons.tv_outlined,
    MediaServerItemType.folder => Icons.folder_outlined,
  };
}

/// 库封面拼贴最多取几张条目海报（220 宽的 16:9 槽里三张 2:3 海报各裁掉约一成，
/// 再多就只剩细条）。
const int kMediaServerLibraryCollageCount = 3;

/// 媒体库横卡（16:9）：库封面或按类型的图标 + 库名。
///
/// 库自身没图（Jellyfin 库可以不配封面）或图取不回来时，用 [fallbackItems] 里
/// 前几条有海报的条目拼一张 [MediaServerLibraryCollage] 顶上，实在一张都没有
/// 才画类型图标。**图取不回来也要回退**（BUG-2602）：UHD Media Server 这类
/// Emby 兼容层会给每个库都报 `ImageTags.Primary`，其中一部分库的图片端点却任何
/// 变体都 404——按 `hasCover` 判完仍然可能拿到一张必失败的图。
class MediaServerLibraryCard extends StatelessWidget {
  const MediaServerLibraryCard({
    required this.browser,
    required this.library,
    required this.onTap,
    this.fallbackItems = const <MediaServerItem>[],
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerLibrary library;
  final VoidCallback onTap;

  /// 库封面缺失 / 加载失败时拼贴用的条目（首页已经为每库拉了前 20 条，直接
  /// 复用，不多发请求）。
  final List<MediaServerItem> fallbackItems;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider? image = mediaServerLibraryCoverImage(browser, library);
    final IconData icon = switch (library.kind) {
      MediaServerLibraryKind.movies => Icons.movie_outlined,
      MediaServerLibraryKind.tvShows => Icons.tv_outlined,
      MediaServerLibraryKind.mixed => Icons.video_library_outlined,
    };
    final Widget fallback = MediaServerLibraryCollage(
      browser: browser,
      items: fallbackItems,
      placeholderIcon: icon,
    );
    return FushiCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      focusId: focusId,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: image == null
                ? fallback
                : PortraitCoverImage(
                    image: image,
                    landscapeSlot: true,
                    errorBuilder: (_) => fallback,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 16),
                SizedBox(width: tokens.spacing.gap / 2),
                Expanded(
                  child: Text(
                    library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 库封面的回退画面：[items] 里前 [kMediaServerLibraryCollageCount] 条有海报的
/// 条目并排铺满槽位（每列 cover 裁切），一张都没有时画 [placeholderIcon]。
///
/// 每列各自失败各自变成空底色，不再往下回退——一列 404 不该把已经画出来的另外
/// 两列一起抹掉。
class MediaServerLibraryCollage extends StatelessWidget {
  const MediaServerLibraryCollage({
    required this.browser,
    required this.items,
    required this.placeholderIcon,
    super.key,
  });

  final MediaServerBrowser browser;
  final List<MediaServerItem> items;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<(MediaServerItem, ImageProvider)> posters =
        <(MediaServerItem, ImageProvider)>[];
    for (final MediaServerItem item in items) {
      if (posters.length >= kMediaServerLibraryCollageCount) break;
      final ImageProvider? provider = mediaServerCoverImage(browser, item);
      if (provider != null) posters.add((item, provider));
    }
    if (posters.isEmpty) return ShelfCoverPlaceholder(icon: placeholderIcon);
    return ColoredBox(
      color: tokens.surfaces.group,
      child: Row(
        children: <Widget>[
          for (final (MediaServerItem item, ImageProvider provider) in posters)
            Expanded(
              child: Image(
                key: ValueKey<String>('media-server-collage-${item.id}'),
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 服务器首页的一条横滚行：区块标题（可带「查看全部」）+ 定高横向懒构建列表。
/// 与合集横滚行同一套鼠标拖拽 / 桌面物理；不复用它本身（那是合集域的行头）。
class MediaServerRow extends StatelessWidget {
  const MediaServerRow({
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.rowHeight,
    required this.itemBuilder,
    required this.storageKey,
    this.onViewAll,
    this.viewAllFocusId,
    super.key,
  });

  final String title;
  final int itemCount;
  final double itemWidth;
  final double rowHeight;
  final IndexedWidgetBuilder itemBuilder;

  /// 行内 ListView 的 PageStorage 键（带服务器前缀，切服务器不串滚动位置）。
  final String storageKey;
  final VoidCallback? onViewAll;
  final FushiFocusId? viewAllFocusId;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (onViewAll != null)
                  FushiIconButton(
                    icon: Icons.chevron_right_rounded,
                    tooltip: t.media_server_row_view_all,
                    label: t.media_server_row_view_all,
                    onTap: onViewAll,
                    focusId: viewAllFocusId,
                  ),
              ],
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          SizedBox(
            height: rowHeight,
            child: HorizontalDragScrollable(
              child: ListView.separated(
                key: PageStorageKey<String>(storageKey),
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                scrollDirection: Axis.horizontal,
                physics: desktopAwareScrollPhysics(),
                itemCount: itemCount,
                separatorBuilder: (_, __) =>
                    SizedBox(width: tokens.spacing.gap),
                itemBuilder: (BuildContext context, int index) => SizedBox(
                  width: itemWidth,
                  child: itemBuilder(context, index),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
